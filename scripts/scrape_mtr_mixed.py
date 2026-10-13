#!/usr/bin/env python3
"""Collect typed HR↔LR CompleteRoutes, without inventing times or rail links.

python scripts/scrape_mtr_mixed.py --root .
python scripts/scrape_mtr_mixed.py --root . --offline
Resume uses hash-verified successful/no-route snapshots. --refresh explicitly fetches
all pairs again. Source sections remain operator journey estimates (may include waits).
Five documented LR→HR interchange-only API failures may be recorded as unavailable,
never as journeys. Offline verifies their evidence; online resumes retry them.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import threading
import time
from datetime import datetime, timezone, timedelta
from email.utils import parsedate_to_datetime
from urllib.parse import urlencode, urlsplit, parse_qsl

import requests

BASE = 'https://www.mtr.com.hk/share/customer/jp/api/'
PLANNER = 'https://www.mtr.com.hk/en/customer/jp/index.php'
TYPES = {'HR': 'HRStation', 'LR': 'LRStation'}
KINDS = {'MTR': 'HR', 'LRT': 'LR'}
VERSION = 1
ERROR_RESPONSE_BYTES = 16 * 1024
_MISSING = object()
# The API returns errorCode=3 for these LR→HR walks, although the separately
# requested reverse directions are WALK-only. Do not infer reverse travel times.
WALK_ONLY_API_FAILURES = frozenset({
    ('LR', '600', 'HR', '116'), ('LR', '430', 'HR', '118'),
    ('LR', '100', 'HR', '119'), ('LR', '70', 'HR', '120'),
    ('LR', '295', 'HR', '120'),
})
UNAVAILABLE_REASON = 'Official CompleteRoutes repeatedly returns errorCode=3 for this LR-to-HR interchange-only pair; no forward journey or duration is supplied.'


def now():
    return datetime.now(timezone.utc).isoformat()


def digest(value):
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + '.tmp')
    temp.write_text(json.dumps(value, ensure_ascii=False, separators=(',', ':')) + '\n')
    temp.replace(path)


def key(pair):
    return '_'.join(pair)


def url_for(pair):
    ot, o, dt, d = pair
    return BASE + 'CompleteRoutes/?' + urlencode(dict(oType=TYPES[ot], oValue=o, dType=TYPES[dt], dValue=d, lang='E'))


def seconds(value, positive=True):
    if isinstance(value, bool):
        raise ValueError('Boolean duration')
    number = float(value)
    result = number * 60
    if not math.isfinite(result) or result < 0 or (positive and result == 0) or abs(result - round(result)) > 1e-6:
        raise ValueError('Invalid minute duration')
    return int(round(result))


def station_index(metadata):
    return {system: {str(int(s['ID'])): s for s in meta['stations'] if str(s['ID']) != '888'} for system, meta in metadata.items()}


def coordinates(value):
    values = [float(x) for x in value.split(',')]
    if len(values) != 2 or not all(math.isfinite(x) for x in values):
        raise ValueError('Invalid coordinates')
    return values


def node_matches(node, typed_id, stations):
    system, sid = typed_id
    if KINDS.get(node.get('stopType')) != system or sid not in stations[system]:
        return False
    station = stations[system][sid]
    try:
        a, b = coordinates(node['coordinate']), coordinates(station['coordinate'])
    except (KeyError, TypeError, ValueError):
        return False
    return max(abs(x-y) for x, y in zip(a, b)) <= 0.00001 and node.get('label', '').casefold().strip() == station['name'].casefold().strip()


def normalize_response(body, pair, stations):
    if not isinstance(body, dict) or str(body.get('errorCode')) != '0' or not isinstance(body.get('routes'), list):
        raise ValueError('Source API error or missing routes: ' + str(body.get('errorMsg') if isinstance(body, dict) else type(body).__name__))
    valid, rejected = [], []
    for route_index, route in enumerate(body['routes']):
        try:
            path = route['path']
            if not isinstance(path, list) or len(path) < 2 or path[-1].get('routeType') != 'END':
                raise ValueError('Missing ordered path / END')
            nodes = [None] * len(path)
            def assign(i, ident):
                if nodes[i] is not None and nodes[i] != ident:
                    raise ValueError('Conflicting typed station endpoint')
                if not node_matches(path[i], ident, stations):
                    raise ValueError('Station label/type/coordinate mismatch')
                nodes[i] = ident
            assign(0, (pair[0], pair[1]))
            assign(len(path)-1, (pair[2], pair[3]))
            for i, step in enumerate(path[:-1]):
                kind = step.get('routeType')
                if kind in KINDS:
                    ids = str(step.get('routeText', '')).split('|')
                    if len(ids) != 2 or not all(x.isdigit() for x in ids):
                        raise ValueError('Invalid typed rail pair')
                    system = KINDS[kind]
                    assign(i, (system, str(int(ids[0]))))
                    assign(i+1, (system, str(int(ids[1]))))
                elif kind != 'WALK':
                    raise ValueError('Unsupported section type: ' + str(kind))
            for i, node in enumerate(nodes):
                if node is None:
                    system = KINDS.get(path[i].get('stopType'))
                    candidates = [(system, sid) for sid in stations.get(system, {}) if node_matches(path[i], (system, sid), stations)]
                    if len(candidates) != 1:
                        raise ValueError('Ambiguous intermediate station')
                    assign(i, candidates[0])
            sections = []
            for i, step in enumerate(path[:-1]):
                kind = KINDS.get(step['routeType'], 'WALK')
                duration = seconds(step['time'], positive=kind != 'WALK')
                ot, o = nodes[i]; dt, d = nodes[i+1]
                section = dict(kind=kind, seconds=duration, origin_type=ot, origin=o, destination_type=dt, destination=d, source_path_index=i)
                if kind != 'WALK':
                    if ot != dt or ot != kind or o == d:
                        raise ValueError('Invalid rail endpoint types')
                    section['detail_key'] = '_'.join([kind, o, d])
                    section['detail_url'] = BASE + ('HRRoutes' if kind == 'HR' else 'LRRoute') + '/?' + urlencode(dict(o=o,d=d,lang='E'))
                sections.append(section)
            total = seconds(route['time'])
            walking = seconds(route['walkingTime'], positive=False)
            if sum(s['seconds'] for s in sections) != total or sum(s['seconds'] for s in sections if s['kind'] == 'WALK') != walking:
                raise ValueError('Section / walking / total minutes inconsistent')
            valid.append(dict(source_route_index=route_index,total_seconds=total,walking_seconds=walking,sections=sections))
        except (KeyError, ValueError, TypeError, OverflowError) as exc:
            rejected.append(dict(source_route_index=route_index, reason=str(exc)))
    return dict(routes=valid,rejected_routes=rejected)


def envelope(pair, body, stations):
    normalized = normalize_response(body, pair, stations)
    return dict(format=VERSION, origin_type=pair[0],origin=pair[1],destination_type=pair[2],destination=pair[3], url=url_for(pair), fetched_at=now(), sha256=digest(body),sha256_kind='canonical-json-sort-keys-utf8/v1',status=('ok' if normalized['routes'] else 'no_route' if not body['routes'] else 'invalid'),response=body,normalized=normalized)


def walk_only_api_error(body):
    return (isinstance(body, dict) and str(body.get('errorCode')) == '3'
            and str(body.get('errorMsg', '')).startswith('The service is temporarily not available, please try again later.')
            and not body.get('routes'))


def unavailable_evidence(pair, attempts, stations, reverse):
    """Validate a narrowly documented exclusion; it has no usable forward time."""
    if pair not in WALK_ONLY_API_FAILURES or pair[1] not in stations[pair[0]] or pair[3] not in stations[pair[2]]:
        raise ValueError('Pair is not an evidenced interchange-only API limitation')
    if len(attempts) < 2 or len({a.get('fetched_at') for a in attempts}) < 2:
        raise ValueError('Unavailability requires at least two distinct request snapshots')
    canonical = urlsplit(url_for(pair))
    for attempt in attempts:
        fetched = urlsplit(attempt.get('fetch_url') or attempt.get('url', ''))
        if (attempt.get('url') != url_for(pair)
                or (fetched.scheme, fetched.netloc, fetched.path) != (canonical.scheme, canonical.netloc, canonical.path)
                or sorted(parse_qsl(fetched.query)) != sorted(parse_qsl(canonical.query))
                or fetched.fragment
                or attempt.get('http_status') != 200
                or not walk_only_api_error(attempt.get('response'))
                or attempt.get('sha256_kind') != 'canonical-json-sort-keys-utf8/v1'
                or attempt.get('sha256') != digest(attempt['response'])
                or not re.fullmatch(r'[0-9a-f]{64}', attempt.get('raw_sha256', ''))
                or not attempt.get('fetched_at')):
            raise ValueError('Unavailability source evidence is invalid')
    reverse_pair = (pair[2], pair[3], pair[0], pair[1])
    if (not reverse or reverse.get('status') != 'ok' or reverse.get('url') != url_for(reverse_pair)
            or reverse.get('sha256') != digest(reverse['response'])):
        raise ValueError('Verified reverse source evidence missing')
    normalized = normalize_response(reverse['response'], reverse_pair, stations)
    if (normalized != reverse.get('normalized') or not normalized['routes'] or normalized['rejected_routes']
            or any(len(r['sections']) != 1 or r['sections'][0]['kind'] != 'WALK'
                   or r['walking_seconds'] != r['total_seconds'] for r in normalized['routes'])):
        raise ValueError('Reverse evidence must contain only a supplied interchange walk')
    return dict(kind='documented_operator_api_unavailability', reason=UNAVAILABLE_REASON,
                metadata_station_index_sha256=digest(stations), attempts=attempts,
                reverse_walk_only_evidence=dict(pair=list(reverse_pair), url=reverse['url'],
                    sha256=reverse['sha256'], fetched_at=reverse['fetched_at']),
                forward_duration_available=False, reverse_duration_not_applied=True)


def unavailable_envelope(pair, attempts, stations, reverse):
    evidence = unavailable_evidence(pair, attempts, stations, reverse)
    last = attempts[-1]
    return dict(format=VERSION, origin_type=pair[0], origin=pair[1], destination_type=pair[2], destination=pair[3],
                url=url_for(pair), fetched_at=last['fetched_at'], sha256=digest(last['response']),
                sha256_kind='canonical-json-sort-keys-utf8/v1', raw_sha256=last['raw_sha256'], http_status=200,
                response=last['response'], status='source_unavailable', normalized=dict(routes=[], rejected_routes=[]),
                unavailability=evidence)


def read_verified(path, pair, stations):
    try:
        data = json.loads(path.read_text())
        if data['format'] != VERSION or data['sha256_kind'] != 'canonical-json-sort-keys-utf8/v1' or data['sha256'] != digest(data['response']):
            return None
        if data['url'] != url_for(pair) or tuple(data[k] for k in ['origin_type','origin','destination_type','destination']) != pair:
            return None
        if data['status'] not in ('ok','no_route','invalid','source_unavailable') or not data['fetched_at']:
            return None
        if data['status'] == 'source_unavailable':
            if pair not in WALK_ONLY_API_FAILURES:
                return None
            reverse_pair = (pair[2], pair[3], pair[0], pair[1])
            reverse = read_verified(path.with_name(key(reverse_pair) + '.json'), reverse_pair, stations)
            expected = unavailable_envelope(pair, data['unavailability']['attempts'], stations, reverse)
            return data if data == expected else None
        derived = normalize_response(data['response'], pair, stations)
        expected = 'ok' if derived['routes'] else 'no_route' if not data['response']['routes'] else 'invalid'
        if data['status'] != expected or data.get('normalized') != derived:
            return None
        return data
    except (OSError,ValueError,KeyError,TypeError):
        return None


class RateLimiter:
    def __init__(self, per_second=2):
        self.interval = 1/per_second
        self.next_start = 0.
        self.lock = threading.Lock()
    def wait(self):
        with self.lock:
            remaining = self.next_start - time.monotonic()
            if remaining > 0:
                time.sleep(remaining)
            self.next_start = time.monotonic() + self.interval


class AccessStopped(Exception):
    def __init__(self, message, retry_after=None, response=None):
        super().__init__(message)
        self.retry_after = retry_after
        self.response = response


def failure_record(url, error, response=None, body=_MISSING, pair=None):
    """Keep enough public-response evidence to diagnose failures without a crawl.

    A failed JSON decode must never become an empty successful result. Store a
    bounded decoded prefix, but hash the complete received body for comparison.
    HTTPError and AccessStopped may carry a response even when request() did not
    return normally. Do not use Response truthiness: HTTP 4xx/5xx is false.
    """
    result = dict(url=url, fetched_at=now(), error=str(error)[:500], error_type=type(error).__name__)
    if pair is not None:
        result['pair'] = pair
    if response is None:
        response = getattr(error, 'response', None)
    if response is not None:
        raw = response.content
        prefix = raw[:ERROR_RESPONSE_BYTES]
        try:
            text = prefix.decode(response.encoding or 'utf-8', errors='replace')
        except LookupError:
            text = prefix.decode('utf-8', errors='replace')
        result.update(http_status=response.status_code,
                      content_type=response.headers.get('Content-Type'),
                      raw_sha256=hashlib.sha256(raw).hexdigest(),
                      response_bytes=len(raw), response_prefix_bytes=len(prefix),
                      response_truncated=len(prefix) < len(raw), response_text_prefix=text)
    if body is not _MISSING:
        result.update(response=body, sha256=digest(body), sha256_kind='canonical-json-sort-keys-utf8/v1')
    return result


def retry_delay(value):
    """Do not restart before the server's Retry-After; 60s minimum if absent."""
    try:
        delay = float(value)
    except (ValueError, TypeError):
        try:
            delay = (parsedate_to_datetime(value) - datetime.now(timezone.utc)).total_seconds()
        except (ValueError, TypeError, OverflowError):
            return 60
    return max(0, int(math.ceil(delay))) if math.isfinite(delay) else 60


def request(url, limiter):
    for attempt in range(3):
        limiter.wait()
        try:
            response = requests.get(url, timeout=(10,40), headers={'User-Agent':'map-routing-research/1.0 (public transit data; 2 requests/sec maximum)'})
            if response.status_code in (401,403,429):
                raise AccessStopped('Server refused/rate-limited requests: HTTP ' + str(response.status_code), retry_after=retry_delay(response.headers.get('Retry-After')) if response.status_code == 429 else None, response=response)
            response.raise_for_status()
            if any(x in response.text.lower() for x in ['prove you are not', 'captcha']):
                raise AccessStopped('Access challenge returned; collection stopped', response=response)
            return response
        except requests.RequestException:
            if attempt == 2:
                raise
            time.sleep(2 ** (attempt+1))


def load_metadata(out, offline, refresh, limiter):
    path = out / 'metadata.json'
    if path.exists() and not refresh:
        d = json.loads(path.read_text())
        if d.get('url') == PLANNER and d.get('sha256') == digest(d.get('metadata')):
            return d['metadata']
        if offline:
            raise ValueError('Metadata hash mismatch')
    if offline:
        raise ValueError('Offline metadata missing')
    response = request(PLANNER, limiter)
    meta = {}
    for system, var in [('HR','heavyRailDetails'),('LR','lightRailDetails')]:
        match = re.search(r'var\s+' + var + r'\s*=\s*', response.text)
        if not match:
            raise ValueError('Planner metadata missing ' + var)
        body, _ = json.JSONDecoder().raw_decode(response.text[match.end():])
        if str(body.get('errorCode')) != '0' or not isinstance(body.get('stations'), list):
            raise ValueError('Invalid planner metadata')
        meta[system] = body
    (out / 'planner.html').write_bytes(response.content)
    save(path,dict(url=PLANNER,fetched_at=now(),sha256=digest(meta),sha256_kind='canonical-json-sort-keys-utf8/v1',raw_sha256=hashlib.sha256(response.content).hexdigest(),metadata=meta))
    return meta


def run(root, offline=False, refresh=False, workers=2, limit=None, allow_partial=False):
    if offline and refresh:
        raise ValueError('--offline and --refresh are mutually exclusive')
    out = root / 'data/mtr_api/mixed'; out.mkdir(parents=True,exist_ok=True)
    with (out / 'scraper.lock').open('w') as lock:
        try:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Mixed collector already running; see progress.json')
        if not offline and (out/'access_pause.json').exists():
            paused=json.loads((out/'access_pause.json').read_text())
            until=paused.get('resume_not_before')
            if until and datetime.fromisoformat(until)>datetime.now(timezone.utc):
                raise AccessStopped('Honor Retry-After: resume no earlier than '+until)
        try:
            return _run(root,out,offline,refresh,workers,limit,allow_partial)
        except AccessStopped as exc:
            # Detail and metadata requests also obey server rate-limit pauses;
            # they run outside the parallel-pair exception handler below.
            state = json.loads((out/'progress.json').read_text()) if (out/'progress.json').exists() else {}
            state.update(status='stopped',error=str(exc),updated_at=now())
            if exc.retry_after is not None:
                until=(datetime.now(timezone.utc)+timedelta(seconds=exc.retry_after)).isoformat()
                state['resume_not_before']=until
                save(out/'access_pause.json',dict(resume_not_before=until,error=str(exc),fetched_at=now()))
            save(out/'progress.json',state)
            raise


def _run(root,out,offline,refresh,workers,limit,allow_partial):
    limiter = RateLimiter()
    metadata = load_metadata(out,offline,refresh,limiter)
    stations = station_index(metadata)
    jobs = [(a,x,b,y) for a,b in [('HR','LR'),('LR','HR')] for x in sorted(stations[a],key=int) for y in sorted(stations[b],key=int)]
    # Interleave directions; place the requested Central / Light Rail Depot check first.
    jobs.sort(key=lambda j: (0 if j in [('HR','1','LR','20'),('LR','20','HR','1')] else 1,int(j[1] if j[0]=='HR' else j[3]),int(j[3] if j[0]=='HR' else j[1]),j[0]))
    save(out/'inventory.json',dict(total=len(jobs),stations={k:len(v) for k,v in stations.items()},metadata_sha256=digest(metadata),excluded=[{'type':'HR','id':'888','reason':'High Speed Rail unsupported by this urban-rail workflow'}]))
    cached = {}; pending = []
    for j in jobs:
        d = None if refresh else read_verified(out/'raw'/(key(j)+'.json'),j,stations)
        if d is None or (not offline and d['status'] == 'source_unavailable'): pending.append(j)
        else: cached[key(j)] = d['status']
    if offline and pending and not allow_partial:
        raise ValueError(f'Offline mixed cache incomplete or corrupt: {len(pending)} / {len(jobs)} pairs. Resume collection; --allow-partial is for development only.')
    started = time.monotonic()
    state = dict(pid=os.getpid(),started_at=now(),total=len(jobs),cached=len(cached),pending_at_start=len(pending),completed_this_run=0,failed_this_run=0,status='running',scope='all HR↔LR station pairs',requests_per_second_max=2,workers=workers)
    def progress():
        done = state['completed_this_run'] + state['failed_this_run']
        elapsed = time.monotonic()-started
        state.update(updated_at=now(),elapsed_seconds=round(elapsed,1),remaining=len(jobs)-len(cached)-done,estimated_remaining_seconds=round((len(jobs)-len(cached)-done)*elapsed/done) if done else None)
        save(out/'progress.json',state)
    progress()
    def fetch(j):
        response, body = None, _MISSING
        try:
            response = request(url_for(j),limiter)
            body = response.json()
            if j in WALK_ONLY_API_FAILURES and walk_only_api_error(body):
                attempts = [failure_record(url_for(j), ValueError(UNAVAILABLE_REASON), response, body, pair=j)]
                # One bounded normal retry. HTTP refusals/challenges still stop.
                response = request(url_for(j),limiter)
                body = response.json()
                if walk_only_api_error(body):
                    attempts.append(failure_record(url_for(j), ValueError(UNAVAILABLE_REASON), response, body, pair=j))
                    reverse_pair = (j[2], j[3], j[0], j[1])
                    reverse = read_verified(out/'raw'/(key(reverse_pair)+'.json'), reverse_pair, stations)
                    result = unavailable_envelope(j, attempts, stations, reverse)
                else:
                    result = envelope(j,body,stations)
            else:
                result = envelope(j,body,stations)
            result['http_status'] = response.status_code
            result['raw_sha256'] = hashlib.sha256(response.content).hexdigest()
            save(out/'raw'/(key(j)+'.json'),result)
            return result['status']
        except (AccessStopped,requests.RequestException,ValueError,TypeError,KeyError) as exc:
            save(out/'errors'/(key(j)+'.json'),failure_record(url_for(j),exc,response,body,pair=j))
            if isinstance(exc,AccessStopped):
                raise
            return 'error'
    target = pending[:limit] if limit is not None else pending
    if not offline:
        with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
            todo = iter(target); active = {}
            for j in [next(todo,None) for _ in range(workers)]:
                if j: active[pool.submit(fetch,j)] = j
            try:
                while active:
                    done,_ = concurrent.futures.wait(active,return_when=concurrent.futures.FIRST_COMPLETED)
                    for future in done:
                        j = active.pop(future)
                        status = future.result()
                        state['failed_this_run' if status=='error' else 'completed_this_run'] += 1
                        progress()
                        count=state['completed_this_run']+state['failed_this_run']
                        if count % 20 == 0 or count == len(target): print(json.dumps(state),flush=True)
                        nxt = next(todo,None)
                        if nxt: active[pool.submit(fetch,nxt)] = nxt
            except (AccessStopped,KeyboardInterrupt) as exc:
                state['status']='stopped';state['error']=str(exc)
                if isinstance(exc,AccessStopped) and exc.retry_after is not None:
                    until=(datetime.now(timezone.utc)+timedelta(seconds=exc.retry_after)).isoformat()
                    state['resume_not_before']=until
                    save(out/'access_pause.json',dict(resume_not_before=until,error=str(exc),fetched_at=now()))
                for future in active:future.cancel()
                progress()
                raise
    # Explicitly inventory successful/invalid/absent pairs. A partial cache is not complete.
    counts = {'ok':0,'no_route':0,'invalid':0,'source_unavailable':0,'missing_or_corrupt':0}
    dependencies = {}
    unavailable = []
    for j in jobs:
        value=read_verified(out/'raw'/(key(j)+'.json'),j,stations)
        counts[value['status'] if value else 'missing_or_corrupt'] += 1
        if value:
            if value['status'] == 'source_unavailable':
                unavailable.append(dict(pair=list(j), reason=value['unavailability']['reason'], sha256=value['sha256']))
            for route in value['normalized']['routes']:
                for section in route['sections']:
                    if 'detail_key' in section:dependencies[section['detail_key']] = section['detail_url']
    missing_details=[]
    for dk,url in dependencies.items():
        # Existing all-pair bodies are kept unmodified; their published legacy hashes
        # were byte hashes of unsaved JSON whitespace, so integrity cannot be rechecked.
        old=root/'data/mtr_api/raw'/(dk+'.json')
        dest=out/'details'/(dk+'.json')
        good=False
        if old.exists() and not refresh:
            try:
                v=json.loads(old.read_text());good=v.get('status')=='ok' and str(v['response'].get('errorCode'))=='0' and v.get('url')==url
            except (ValueError,KeyError,TypeError): pass
        if not good:
            if dest.exists() and not refresh:
                try:
                    v=json.loads(dest.read_text());good=v.get('sha256')==digest(v['response']) and v.get('url')==url and str(v['response'].get('errorCode'))=='0'
                except (ValueError,KeyError,TypeError): pass
            if not good and not offline:
                response, body = None, _MISSING
                try:
                    response=request(url,limiter);body=response.json()
                    if str(body.get('errorCode'))=='0':
                        save(dest,dict(system=dk.split('_')[0],origin=dk.split('_')[1],destination=dk.split('_')[2],status='ok',url=url,fetched_at=now(),sha256=digest(body),sha256_kind='canonical-json-sort-keys-utf8/v1',response=body));good=True
                except (AccessStopped,requests.RequestException,ValueError,TypeError,KeyError) as exc:
                    save(out/'errors'/('detail_'+dk+'.json'),failure_record(url,exc,response,body))
                    state.update(status='stopped',error='Dependency '+dk+': '+str(exc)[:500])
                    progress()
                    raise
        if not good:missing_details.append(dk)
    complete = counts['missing_or_corrupt']==0 and not missing_details
    report=dict(format=VERSION,generated_at=now(),counts=counts,total=len(jobs),complete=complete,
                inventory_complete=complete, all_pairs_have_usable_journeys=counts['ok']==len(jobs),
                completion_policy='Every requested pair has verified source evidence, including separately counted documented unavailability; this does not mean every pair has a usable journey.',
                source_unavailable=unavailable, dependencies=len(dependencies),missing_details=missing_details,metadata_sha256=digest(metadata),timing_policy='Unchanged operator CompleteRoutes section/total minutes including supplied WALK; not measured train times or wait-free durations.')
    save(out/'report.json',report)
    if offline and not report['complete'] and not allow_partial:
        raise ValueError('Offline mixed dependencies incomplete: '+str(missing_details))
    state['source_unavailable'] = counts['source_unavailable']
    state['status']=('complete_with_source_unavailable' if counts['source_unavailable'] else 'complete') if report['complete'] else 'partial';progress()
    print(json.dumps(report),flush=True)
    return report


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[1]);p.add_argument('--offline',action='store_true');p.add_argument('--refresh',action='store_true');p.add_argument('--workers',type=int,choices=range(1,5),default=2);p.add_argument('--limit',type=int);p.add_argument('--allow-partial',action='store_true',help='Development only: permit incomplete offline cache')
    a=p.parse_args()
    if a.limit is not None and a.limit<0:p.error('--limit must be nonnegative')
    report=run(a.root.resolve(),a.offline,a.refresh,a.workers,a.limit,a.allow_partial)
    if a.offline and not report['complete'] and not a.allow_partial:raise SystemExit(2)


if __name__=='__main__':main()
