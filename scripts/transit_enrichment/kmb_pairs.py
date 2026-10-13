#!/usr/bin/env python3
"""Collect verified KMB route-specific stop-pair estimates and enrich GTFS.

The public operator site supplies seconds, not measured vehicle travel times.
Native website sequences (including 0/999) are obtained from its complete stop
list; never derived from the separate open-data API's one-based sequences.
"""
from __future__ import annotations

import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from contextlib import contextmanager
from datetime import datetime, timezone
from functools import wraps
import hashlib
import io
import json
import math
from pathlib import Path
import re
import shutil
import threading
import time
from urllib.parse import urlencode
import zipfile

if __package__ in (None, ''):
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from transit_enrichment import identity, official
    from transit_enrichment.feed import rows, write_rows, seconds, clock, sha, save
else:
    from . import identity, official
    from .feed import rows, write_rows, seconds, clock, sha, save

BASE = 'https://search.kmb.hk/KMBWebSite/Function/FunctionRequest.ashx'
WEBSITE = 'https://search.kmb.hk/KMBWebSite/'
DOCS = {
    'operator-page-code.js.txt': 'https://search.kmb.hk/kmbwebsite/MapFunction.js?20250611114452',
    'operator-map-metadata.json': 'https://tiles.arcgis.com/tiles/68LnpVE5xMGEflDS/arcgis/rest/services/Basemap25/MapServer?f=pjson',
}
PROOF = 'kmb_pair_timing_provenance.json'
TRANSIT_PROOF = 'transit_enrichment_provenance.json'
MAX_BYTES = 3_000_000
POLICY = dict(kind='operator_stop_pair_estimate', units='seconds', measured=False,
    validity_window='Not supplied by KMB; cached reference estimate, not live traffic',
    identity='Single operator, unique official variant, complete ordered native stop sequence',
    coordinate_crs='EPSG:2326 converted to EPSG:4326', maximum_stop_offset_m=30,
    maximum_mean_stop_offset_m=10, maximum_straight_line_speed_kmh=130,
    segment_seconds=[1, 7200], maximum_route_seconds=21600,
    uniform_value_guard='Retain baseline when 5 or more segments are all 60 seconds; suspicious, not proven fabrication',
    additivity='Full route and two half spans; max(2 seconds, 1 second per segment) tolerance',
    changed='Running-time estimates, including previously modeled endpoint arrival times',
    preserved='Origin departure, calendars, frequency bands, routes, stops, shapes, non-KMB timings',
    unsupported='No added wait, guessed time, speed formula, rescaling to old duration or zero fallback')


def directory(root):
    return Path(root) / 'data/transit_enrichment/kmb_pairs'


@contextmanager
def cache_lock(root):
    """OS-released lock protects raw bytes/metadata from concurrent runs."""
    import fcntl
    folder = directory(root)
    folder.mkdir(parents=True, exist_ok=True)
    with (folder / '.collection.lock').open('a+') as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError('Another KMB collector or build is using this cache; wait for it to finish') from error
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def locked(function):
    @wraps(function)
    def wrapped(root, *args, **kwargs):
        with cache_lock(root):
            return function(root, *args, **kwargs)
    return wrapped


def digest(content):
    return hashlib.sha256(content).hexdigest()


def key_for(match):
    route, direction, service = str(match['route']).upper(), match['direction'], str(match['service_type'])
    if not re.fullmatch(r'[A-Z0-9]{1,8}', route) or direction not in ('O', 'I') or not re.fullmatch(r'[1-9]\d{0,3}', service):
        raise ValueError('Invalid KMB route/direction/service identity')
    return f'{route}-{direction}-{service}'


def params_for(match, action, **extra):
    key_for(match)
    return dict(action=action, route=str(match['route']).upper(),
                bound='1' if match['direction'] == 'O' else '2',
                serviceType=str(match['service_type']), **extra)


def request_url(match, action, **extra):
    return BASE + '?' + urlencode(params_for(match, action, **extra))


def select_targets(root, source, route_numbers=None):
    """Works on both enriched feeds and the raw TD feed on a clean checkout."""
    source = Path(source)
    with zipfile.ZipFile(source) as z:
        if TRANSIT_PROOF in z.namelist():
            crosswalk = json.loads(z.read(TRANSIT_PROOF))['identities']
        else:
            crosswalk = identity.match_patterns(identity.read_patterns(source), {}, official.normalize(root))
    wanted = set(route_numbers or [])
    targets, rejected = {}, Counter()
    for pk, pattern in sorted(crosswalk['patterns'].items()):
        matches = pattern.get('matches', [])
        operators = {identity.operator(v) for v in pattern.get('agency_id', '').split('+')}
        if operators != {'KMB'}:
            continue
        if len(matches) != 1 or matches[0].get('operator') != 'KMB' or matches[0].get('evidence') != 'official_full_stop_sequence':
            rejected['no_unique_official_sequence'] += 1
            continue
        match = matches[0]
        if wanted and match['route'] not in wanted:
            continue
        key = key_for(match)
        target = targets.setdefault(key, dict(key=key, match=match, patterns={}))
        if target['match']['native_stop_ids'] != match['native_stop_ids']:
            raise ValueError('One KMB variant maps to conflicting native stop orders')
        target['patterns'][pk] = dict(route_id=pattern['route_id'], stop_ids=pattern['stop_ids'])
    return targets, dict(rejected)


def _name(value):
    return identity._normalized_name(value)


def validate_stops(payload, match):
    """Validate native metadata before ANY duration request; return exact visits."""
    from pyproj import Transformer
    if not isinstance(payload, dict) or payload.get('result') is not True:
        raise ValueError('Operator stop request unavailable')
    data = payload.get('data')
    if not isinstance(data, dict) or not isinstance(data.get('routeStops'), list):
        raise ValueError('Malformed operator stop list')
    raw = data['routeStops']
    expected = match['stop_visits']
    if len(raw) != len(expected) or len(raw) < 2:
        raise ValueError(f'Operator full stop count changed: website {len(raw)}, verified inventory {len(expected)}')
    transform = Transformer.from_crs(2326, 4326, always_xy=True)
    visits, seqs, offsets = [], [], []
    wanted = params_for(match, 'getstops')
    for i, (stop, old) in enumerate(zip(raw, expected)):
        if not isinstance(stop, dict) or any(str(stop.get(k, '')).strip().upper() != wanted[v]
                for k, v in [('Route', 'route'), ('Bound', 'bound'), ('ServiceType', 'serviceType')]):
            raise ValueError('Operator stop route/direction/service identity mismatch')
        seq = str(stop.get('Seq', '')).strip()
        code = str(stop.get('BSICode', '')).strip()
        if not re.fullmatch(r'\d{1,3}', seq) or not re.fullmatch(r'[A-Z0-9-]{3,40}', code):
            raise ValueError('Invalid operator native sequence/stop code')
        if not _name(stop.get('EName')) or _name(stop.get('EName')) != _name(old.get('name_en')):
            raise ValueError(f"Operator ordered stop name mismatch at visit {i+1}: {stop.get('EName')} / {old.get('name_en')}")
        try:
            x, y = float(stop['X']), float(stop['Y'])
            if not all(math.isfinite(v) and 700000 < v < 950000 for v in (x, y)):
                raise ValueError('Invalid Hong Kong grid coordinate')
            lon, lat = transform.transform(x, y)
            offset = identity.haversine((lat, lon), (float(old['lat']), float(old['lon'])))
        except (KeyError, TypeError, ValueError) as error:
            raise ValueError('Invalid operator stop coordinates') from error
        if offset > POLICY['maximum_stop_offset_m']:
            raise ValueError('Operator ordered stop coordinate mismatch')
        fare = stop.get('AirFare')
        try:
            fare = float(fare)
            if not math.isfinite(fare) or fare < 0:
                fare = None
        except (TypeError, ValueError):
            fare = None
        seqs.append(int(seq)); offsets.append(offset)
        visits.append(dict(index=i, native_sequence=seq, bsi_code=code,
            native_stop_id=old['native_stop_id'], name_en=stop['EName'], name_tc=stop.get('CName'),
            description_en=stop.get('ELocation'), description_tc=stop.get('CLocation'),
            lat=lat, lon=lon, offset_m=round(offset, 3), boarding_fare_hkd=fare))
    if len(set(seqs)) != len(seqs) or seqs != sorted(seqs):
        raise ValueError('Duplicate or unordered native sequence values')
    if sum(offsets) / len(offsets) > POLICY['maximum_mean_stop_offset_m']:
        raise ValueError('Operator mean stop coordinate mismatch')
    return visits


def duration(payload):
    if not isinstance(payload, dict) or payload.get('result') is not True:
        raise ValueError('Operator pair timing unavailable')
    value = payload.get('data', {}).get('Journey_time') if isinstance(payload.get('data'), dict) else None
    if isinstance(value, bool) or not re.fullmatch(r'[1-9]\d{0,5}', str(value)):
        raise ValueError('Missing, zero or malformed operator journey seconds')
    result = int(value)
    if result > POLICY['maximum_route_seconds']:
        raise ValueError('Operator journey exceeds duration guard')
    return result


def span_indices(count):
    middle = (count - 1) // 2
    return sorted({(a, b) for a, b in [(0, count-1), (0, middle), (middle, count-1)] if b > a + 1})


def validate_profile(visits, adjacent, spans):
    if len(adjacent) != len(visits)-1 or len(visits) < 2:
        raise ValueError('Incomplete adjacent-pair coverage')
    for i, value in enumerate(adjacent):
        if isinstance(value, bool) or not isinstance(value, int) or not POLICY['segment_seconds'][0] <= value <= POLICY['segment_seconds'][1]:
            raise ValueError('Invalid adjacent operator duration')
        a, b = visits[i:i+2]
        metres = identity.haversine((a['lat'], a['lon']), (b['lat'], b['lon']))
        if metres * 3.6 / value > POLICY['maximum_straight_line_speed_kmh']:
            raise ValueError('Operator pair has implausible minimum speed: '
                f"visit {i+1}>{i+2}, native {a.get('native_sequence', '?')}>{b.get('native_sequence', '?')}, "
                f'{value}s for {metres:.1f}m straight line ({metres*3.6/value:.1f} km/h)')
    if len(adjacent) >= 5 and set(adjacent) == {60}:
        raise ValueError('suspicious_uniform_operator_values: '
            f'all {len(adjacent)} segments return 60 seconds; retained baseline, not proven fabrication')
    if sum(adjacent) > POLICY['maximum_route_seconds']:
        raise ValueError('Operator route exceeds duration guard')
    required = set(span_indices(len(visits)))
    found = {(s['start_index'], s['end_index']) for s in spans}
    if found != required or len(spans) != len(required):
        raise ValueError('Missing or duplicate span consistency checks')
    for span in spans:
        a, b = span['start_index'], span['end_index']
        delta = span['seconds'] - sum(adjacent[a:b])
        span.update(adjacent_sum_seconds=sum(adjacent[a:b]), difference_seconds=delta)
        if abs(delta) > max(2, b-a):
            raise ValueError('Operator direct span conflicts with adjacent timings')
    return dict(total_seconds=sum(adjacent), adjacent_seconds=adjacent, direct_spans=spans)


class Cache:
    def __init__(self, root, offline=False, refresh=False, interval=.12):
        if offline and refresh:
            raise ValueError('Cannot refresh KMB sources offline')
        self.root = directory(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self.offline, self.refresh, self.interval = offline, refresh, max(.12, interval)
        self.lock, self.rate_lock = threading.Lock(), threading.Lock()
        self.thread = threading.local()
        self.next_request, self.last_progress = 0., 0.
        self.started = time.monotonic()
        self.stats = Counter()
        self.stop = threading.Event()

    def progress(self, **extra):
        with self.lock:
            data = dict(self.stats, elapsed_seconds=round(time.monotonic()-self.started, 2), **extra)
            save(self.root / 'progress.json', data)
            if time.monotonic()-self.last_progress > 10 or extra.get('complete'):
                print(json.dumps(data), flush=True)
                self.last_progress = time.monotonic()

    def get(self, folder, name, url):
        folder = self.root / folder
        folder.mkdir(parents=True, exist_ok=True)
        path, mp = folder / name, folder / (name + '.meta.json')
        if path.exists() and not self.refresh:
            if not mp.exists():
                raise ValueError('Unverified KMB cache file: ' + str(path))
            meta = json.loads(mp.read_text()); content = path.read_bytes()
            if meta.get('url') != url or meta.get('sha256') != digest(content) or meta.get('bytes') != len(content):
                raise ValueError('KMB cache checksum/URL mismatch: ' + str(path))
            with self.lock: self.stats['cache_hits'] += 1
            return content, meta
        if self.offline:
            raise FileNotFoundError('Missing KMB cache: ' + str(path))
        import requests
        if not hasattr(self.thread, 'session'):
            self.thread.session = requests.Session()
            self.thread.session.headers['User-Agent'] = 'map-routing-source-verification/1 (bounded public route reference collector)'
        for attempt in range(3):
            if self.stop.is_set():
                raise RuntimeError('KMB collection stopped after access refusal')
            with self.rate_lock:
                delay = self.next_request-time.monotonic()
                if delay > 0: time.sleep(delay)
                self.next_request = time.monotonic()+self.interval
            retry_delay = 2**attempt
            try:
                with self.thread.session.get(url, timeout=(10, 25), stream=True, allow_redirects=False) as response:
                    with self.lock: self.stats['network_requests'] += 1
                    if response.status_code in (401, 403):
                        self.stop.set()
                    if response.status_code == 429:
                        # Respect the operator's retry deadline across all four
                        # workers, not just the request that saw the limit.
                        value = response.headers.get('Retry-After', '')
                        try:
                            retry_delay = max(retry_delay, float(value))
                        except ValueError:
                            try:
                                from email.utils import parsedate_to_datetime
                                retry_delay = max(retry_delay, (parsedate_to_datetime(value)-datetime.now(timezone.utc)).total_seconds())
                            except (ValueError, TypeError):
                                pass
                        if retry_delay > 60:
                            self.stop.set()  # Retain progress; resume later.
                        with self.rate_lock:
                            self.next_request = max(self.next_request, time.monotonic()+retry_delay)
                    if response.is_redirect:
                        raise ValueError('Unexpected KMB source redirect')
                    response.raise_for_status()
                    content = bytearray()
                    for part in response.iter_content(65536):
                        content.extend(part)
                        if len(content) > MAX_BYTES:
                            raise ValueError('KMB source exceeds size guard')
                    content = bytes(content)
                    if name.endswith('.json') and not isinstance(json.loads(content), dict):
                        raise ValueError('Expected KMB response object')
                    meta = dict(url=url, sha256=digest(content), bytes=len(content),
                        retrieved_at=datetime.now(timezone.utc).isoformat(),
                        last_modified=response.headers.get('Last-Modified'), content_type=response.headers.get('Content-Type'))
                break
            except requests.RequestException:
                if attempt == 2 or self.stop.is_set():
                    self.stop.set()  # Keep collected evidence; resume once healthy.
                    raise
                time.sleep(retry_delay)
        part = path.with_suffix(path.suffix+'.part')
        part.write_bytes(content); part.replace(path); save(mp, meta)
        self.progress(current=url)
        return content, meta


def check_docs(cache):
    code, cm = cache.get('source', 'operator-page-code.js.txt', DOCS['operator-page-code.js.txt'])
    metadata, mm = cache.get('source', 'operator-map-metadata.json', DOCS['operator-map-metadata.json'])
    if b'getjtbyfromtostop' not in code or not re.search(rb'Journey_time["\x27]\]\s*/\s*60', code):
        raise ValueError('Operator seconds-to-minutes declaration changed')
    sr = json.loads(metadata).get('spatialReference', {})
    if sr.get('latestWkid', sr.get('wkid')) != 2326:
        raise ValueError('Operator coordinate reference system changed')
    return dict(page_code=cm, map_metadata=mm)


def collect_target(cache, target):
    key, match = target['key'], target['match']
    folder = 'routes/' + key
    body, stop_meta = cache.get(folder, 'stops.json', request_url(match, 'getstops'))
    visits = validate_stops(json.loads(body), match)
    # A changed route gets a separate pair cache; old requests cannot silently
    # attach themselves to new native sequence meanings after refresh.
    pair_folder = folder + '/pairs-' + stop_meta['sha256'][:16]
    sources = []
    def pair(a, b):
        seq1, seq2 = visits[a]['native_sequence'], visits[b]['native_sequence']
        url = request_url(match, 'getjtbyfromtostop', seq1=seq1, seq2=seq2)
        raw, meta = cache.get(pair_folder, seq1+'-'+seq2+'.json', url)
        sources.append(meta)
        return duration(json.loads(raw)), meta
    adjacent = [pair(i, i+1)[0] for i in range(len(visits)-1)]
    spans = []
    for a, b in span_indices(len(visits)):
        value, meta = pair(a, b)
        spans.append(dict(start_index=a, end_index=b, seconds=value, source_url=meta['url'], source_sha256=meta['sha256']))
    profile = validate_profile(visits, adjacent, spans)
    fetched = sorted(m['retrieved_at'] for m in sources)
    return dict(key=key, route=match['route'], direction=match['direction'], service_type=str(match['service_type']),
        native_stop_ids=match['native_stop_ids'], visits=visits, **profile,
        source_url=WEBSITE+'?action=routesearch&route='+match['route'], api_url=BASE,
        stops_source=stop_meta, source_files=[dict(url=m['url'],sha256=m['sha256'],retrieved_at=m['retrieved_at']) for m in sources],
        snapshot=fetched[-1][:10], timing_retrieved_first=fetched[0], timing_retrieved_last=fetched[-1],
        kind=POLICY['kind'], units='seconds', measured=False)


def default_source(root):
    root = Path(root)
    for path in ['data/generated/hk-transit-ENRICHED.gtfs.zip', 'data/generated/hk-transit-EXPERIMENTAL.gtfs.zip', 'data/raw/2026-09-17/td/gtfs.zip']:
        if (root/path).exists(): return root/path
    raise FileNotFoundError('Pass --input with a raw TD or enriched GTFS feed')


def incomplete_errors(errors):
    """Only explicit source validation rejections may keep the baseline.

    Missing files, malformed JSON, unexpected schemas and damaged metadata
    mean the collection is incomplete, rather than evidence of no coverage.
    """
    return {key:value for key,value in errors.items() if value['type'] != 'ValueError'
            or 'checksum' in value['reason'] or 'Unverified KMB cache' in value['reason']}


@locked
def fetch(root, source=None, offline=False, refresh=False, workers=4, route_numbers=None):
    source = Path(source or default_source(root))
    targets, rejected = select_targets(root, source, route_numbers)
    cache = Cache(root, offline, refresh)
    cache.stats['target_variants'] = len(targets)
    docs = check_docs(cache)
    result, errors = {}, {}
    def task(target):
        try:
            return collect_target(cache, target), None
        except Exception as error:
            # Every failed target remains explicit and can resume on rerun.
            return None, dict(reason=str(error), type=type(error).__name__)
    with ThreadPoolExecutor(max_workers=max(1,min(4,workers))) as pool:
        pending = {pool.submit(task, target): key for key,target in targets.items()}
        for future in as_completed(pending):
            key = pending[future]; value, error = future.result()
            if error:
                errors[key] = error
                # Profiles are derived output; rejected snapshots must not
                # leave an older apparently usable profile alongside them.
                (cache.root / 'profiles' / (key+'.json')).unlink(missing_ok=True)
            else:
                result[key] = value
                save(cache.root / 'profiles' / (key+'.json'), value)
            with cache.lock:
                cache.stats['finished_variants'] += 1
                cache.stats['rejected_variants' if error else 'usable_variants'] += 1
            cache.progress(current_variant=key)
    report = dict(format=1, policy=POLICY, source_gtfs_sha256=sha(source), source=str(source),
        collected_at=datetime.now(timezone.utc).isoformat(), sources=docs,
        targets=list(targets), completed=list(result), errors=errors, selection_rejections=rejected,
        rejection_counts=dict(Counter(v['reason'].split(':', 1)[0] for v in errors.values())),
        statistics=dict(cache.stats, elapsed_seconds=round(time.monotonic()-cache.started,2),
            usable_adjacent_pairs=sum(len(v['adjacent_seconds']) for v in result.values()),
            direct_span_checks=sum(len(v['direct_spans']) for v in result.values())))
    incomplete = incomplete_errors(errors)
    report['incomplete_errors'] = incomplete
    save(cache.root / 'fetch_report.json', report)
    cache.progress(complete=not bool(incomplete))
    if incomplete:
        raise RuntimeError(f'{len(incomplete)} KMB variants are incomplete; successful responses are saved, rerun to resume')
    return report


def _normalize(root, source=None, route_numbers=None):
    """Revalidate original response bytes, not trust derived profile files."""
    source = Path(source or default_source(root))
    targets, rejected = select_targets(root, source, route_numbers)
    cache = Cache(root, offline=True)
    docs = check_docs(cache)
    profiles, errors = {}, {}
    for key,target in targets.items():
        try: profiles[key] = collect_target(cache, target)
        except (ValueError, FileNotFoundError, KeyError, TypeError) as error:
            errors[key] = dict(reason=str(error), type=type(error).__name__)
    return dict(targets=targets, profiles=profiles, errors=errors, source=docs, policy=POLICY,
                selection_rejections=rejected)


@locked
def normalize(root, source=None, route_numbers=None):
    return _normalize(root, source, route_numbers)


def updated_trip(group, profile):
    """Keep source departure; apply supplied adjacent seconds without scaling."""
    if len(group) != len(profile['visits']):
        raise ValueError('GTFS trip count differs from validated operator sequence')
    start = seconds(group[0]['departure_time'])
    for row in group[1:]:
        if row.get('arrival_time') and row.get('departure_time') and seconds(row['departure_time']) != seconds(row['arrival_time']):
            raise ValueError('Nonzero supplied stop dwell needs separate evidence')
    output = [dict(group[0])]
    running = start
    for row, duration_seconds in zip(group[1:], profile['adjacent_seconds']):
        running += duration_seconds
        new = dict(row, arrival_time=clock(running), departure_time=clock(running))
        if 'timepoint' in new: new['timepoint']='0'
        output.append(new)
    return output


def verify_feed(source, output):
    """Independently check routing clocks and byte-preserved non-timing tables."""
    from itertools import groupby, zip_longest
    with zipfile.ZipFile(source) as old, zipfile.ZipFile(output) as new:
        proof=json.loads(new.read(PROOF))
        if set(new.namelist()) != set(old.namelist()) | {PROOF}:
            raise ValueError('KMB stage added or removed unrelated GTFS members')
        unchanged=0
        for name in old.namelist():
            if name=='stop_times.txt':continue
            digests=[]
            for z in (old,new):
                h=hashlib.sha256()
                with z.open(name) as stream:
                    for block in iter(lambda:stream.read(1024*1024),b''):h.update(block)
                digests.append(h.hexdigest())
            if digests[0]!=digests[1]:raise ValueError('KMB stage changed unrelated member: '+name)
            unchanged+=1
        checked=0;retained=0;used=set()
        a=groupby(rows(old,'stop_times.txt'),lambda r:r['trip_id'])
        b=groupby(rows(new,'stop_times.txt'),lambda r:r['trip_id'])
        for before,after in zip_longest(a,b):
            if before is None or after is None or before[0]!=after[0]:
                raise ValueError('KMB stage changed trip row ordering/inventory')
            tid=before[0]
            if tid not in proof['trips']:
                if any(x!=y for x,y in zip_longest(before[1],after[1])):
                    raise ValueError('KMB stage changed an unmatched/rail trip: '+tid)
                retained+=1;continue
            used.add(tid)
            original,updated=list(before[1]),list(after[1])
            pattern=proof['patterns'][proof['trips'][tid]]
            profile=proof['profiles'][pattern['native_pattern_key']]
            if len(original)!=len(updated) or len(updated)!=len(profile['visits']):
                raise ValueError('KMB timing row count differs')
            if [r['stop_id'] for r in original]!=pattern['stop_ids'] or original[0]!=updated[0]:
                raise ValueError('KMB stage changed stop order or originating departure')
            for i,(x,y) in enumerate(zip(original,updated)):
                if {k:v for k,v in x.items() if k not in ('arrival_time','departure_time','timepoint')} != {k:v for k,v in y.items() if k not in ('arrival_time','departure_time','timepoint')}:
                    raise ValueError('KMB stage changed stop identity/other fields')
                if i:
                    gap=seconds(y['arrival_time'])-seconds(updated[i-1]['departure_time'])
                    if gap!=profile['adjacent_seconds'][i-1] or y['departure_time']!=y['arrival_time']:
                        raise ValueError('KMB output disagrees with operator segment seconds')
                    if 'timepoint' in y and y['timepoint']!='0':
                        raise ValueError('Operator estimate mislabeled as an exact GTFS timepoint')
            if seconds(updated[-1]['arrival_time'])-seconds(updated[0]['departure_time'])!=profile['total_seconds']:
                raise ValueError('KMB output route total mismatch')
            checked+=1
        if used!=set(proof['trips']):raise ValueError('KMB provenance references missing trips')
    return dict(applied_trips_verified=checked,unmodified_trips_verified=retained,unchanged_members_verified=unchanged)


@locked
def apply(root, source, output, allow_partial=False):
    """Enrich a separate feed. Existing modeled arrivals can change explicitly."""
    source, output = Path(source), Path(output)
    if source.resolve() == output.resolve():
        raise ValueError('KMB apply requires a separate output file')
    normalized = _normalize(root, source)
    incomplete = incomplete_errors(normalized['errors'])
    blocking = {k:v for k,v in incomplete.items() if not allow_partial or v['type'] != 'FileNotFoundError'}
    if blocking:
        raise ValueError(f'Incomplete or corrupt KMB cache: {len(blocking)} variants; fetch or verify again')
    patterns = {}
    for key,target in normalized['targets'].items():
        if key not in normalized['profiles']: continue
        for pk,pattern in target['patterns'].items():
            patterns[pk] = dict(pattern, native_pattern_key=key)
    proof = dict(format=1, policy=POLICY, source=normalized['source'],
        profiles=normalized['profiles'], patterns=patterns, trips={}, rejected=normalized['errors'],
        statistics={}, original_totals={}, total_conflicts=[], trip_rejections={})
    changed, counts, original_totals = {}, Counter(), {}
    with zipfile.ZipFile(source) as z:
        if PROOF in z.namelist(): raise ValueError('KMB feed already applied; use previous build stage')
        routes = {r['route_id']:r for r in rows(z,'routes.txt') if r['route_type']=='3' and {identity.operator(v) for v in r['agency_id'].split('+')}=={'KMB'}}
        trip_routes = {t['trip_id']:t['route_id'] for t in rows(z,'trips.txt') if t['route_id'] in routes}
        def stream():
            from itertools import groupby
            seen = set()
            for tid, group in groupby(rows(z,'stop_times.txt'),lambda r:r['trip_id']):
                if tid not in trip_routes:
                    yield from group; continue
                if tid in seen: raise ValueError('Non-contiguous GTFS trip rows')
                seen.add(tid); group=list(group)
                pk=identity.pattern_key(trip_routes[tid],[r['stop_id'] for r in group])
                if pk not in patterns:
                    yield from group; continue
                profile=normalized['profiles'][patterns[pk]['native_pattern_key']]
                try:
                    new=updated_trip(group,profile)
                    old_total=seconds(group[-1]['arrival_time'])-seconds(group[0]['departure_time'])
                except (ValueError,KeyError) as error:
                    proof['trip_rejections'][tid]=str(error)
                    yield from group; continue
                proof['trips'][tid]=pk
                original_totals.setdefault(pk,Counter())[old_total]+=1
                counts['applied_trips']+=1
                counts['updated_stop_times']+=sum(a!=b for a,b in zip(group,new))
                changed[pk]=True
                yield from new
        output.parent.mkdir(parents=True,exist_ok=True)
        temp=output.with_suffix('.part')
        with zipfile.ZipFile(temp,'w',zipfile.ZIP_DEFLATED,compresslevel=1) as out:
            for name in z.namelist():
                if name=='stop_times.txt':continue
                with z.open(name) as a,out.open(name,'w') as b:shutil.copyfileobj(a,b,1024*1024)
            reader=rows(z,'stop_times.txt')
            fields=reader.fieldnames
            write_rows(out,'stop_times.txt',fields,stream())
            for pk,totals in original_totals.items():
                new_total=normalized['profiles'][patterns[pk]['native_pattern_key']]['total_seconds']
                proof['original_totals'][pk]=dict(sorted(totals.items()))
                for old_total,number in totals.items():
                    if old_total!=new_total:
                        proof['total_conflicts'].append(dict(pattern=pk,original_seconds=old_total,operator_seconds=new_total,
                            delta_seconds=new_total-old_total,trips=number,
                            decision='Replaced previous modeled running duration with verified operator pair estimates; not measured timing.'))
            proof['statistics']=dict(counts,applied_patterns=len(changed),collected_variants=len(normalized['profiles']),
                retained_variants=len(normalized['errors']),total_comparisons_changed=len(proof['total_conflicts']),
                rejected_trips=len(proof['trip_rejections']))
            out.writestr(PROOF,json.dumps(proof,ensure_ascii=False))
        validation=verify_feed(source,temp)
        temp.replace(output)
    report=dict(statistics=proof['statistics'],policy=POLICY,source_sha256=sha(source),output_sha256=sha(output),
        retained=proof['rejected'],trip_rejections=proof['trip_rejections'],total_conflicts=proof['total_conflicts'],validation=validation)
    save(directory(root)/'apply_report.json',report)
    print(json.dumps(report['statistics']),flush=True)
    return report


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('command',choices=['fetch','verify','apply'])
    p.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[2])
    p.add_argument('--input',type=Path);p.add_argument('--output',type=Path)
    p.add_argument('--offline',action='store_true');p.add_argument('--refresh',action='store_true')
    p.add_argument('--workers',type=int,default=4);p.add_argument('--routes',help='Optional comma-separated sample route numbers')
    p.add_argument('--allow-partial',action='store_true')
    a=p.parse_args();source=a.input or default_source(a.root)
    if a.command=='fetch':
        fetch(a.root,source,a.offline,a.refresh,a.workers,a.routes.split(',') if a.routes else None)
    elif a.command=='verify':
        d=normalize(a.root,source,a.routes.split(',') if a.routes else None)
        print(json.dumps(dict(usable_variants=len(d['profiles']),errors=d['errors'])),flush=True)
        if incomplete_errors(d['errors']):
            p.exit(1, 'Incomplete or corrupt KMB collection; fetch again to resume.\n')
    else:
        apply(a.root,source,a.output or a.root/'data/generated/hk-transit-KMB.gtfs.zip',a.allow_partial)


if __name__=='__main__':main()
