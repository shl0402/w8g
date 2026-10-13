#!/usr/bin/env python3
"""Check whole rail journeys and KMB timing evidence in a rebuilt feed/server.

Example: python route_checker/check_operator_journeys.py --date 2026-10-04
Use --feed-only before starting OTP. Live searches check every returned route,
but do not require a particular winning route or boarding station. Exact pair
durations are checked independently against GTFS and its cached source evidence.
No source cache, feed or running server is modified.
"""
from __future__ import annotations

import argparse
from collections import defaultdict
import csv
from datetime import datetime
import hashlib
import io
import json
from pathlib import Path
import sys
import time
import urllib.error
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
RAIL_CASES = [
    ('goodview_depot', 'LR', '260', 'LR', '20', 840, ['light_rail']),
    ('central_depot', 'HR', '1', 'LR', '20', 4380, ['mtr', 'light_rail']),
    ('depot_central', 'LR', '20', 'HR', '1', 4080, ['mtr', 'light_rail']),
    ('airport_depot', 'HR', '47', 'LR', '20', 4920, ['mtr', 'light_rail']),
    ('depot_airport', 'LR', '20', 'HR', '47', 4860, ['mtr', 'light_rail']),
    ('loop_705', 'LR', '445', 'LR', '435', 420, ['light_rail']),
    ('loop_706', 'LR', '435', 'LR', '445', 480, ['light_rail']),
]


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + '\n')


def digest_file(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def rows(archive, name):
    if name not in archive.namelist():
        return iter(())
    return csv.DictReader(io.TextIOWrapper(archive.open(name), encoding='utf-8-sig'))


def seconds(clock):
    hours, minutes, second = map(int, clock.split(':'))
    return hours * 3600 + minutes * 60 + second


def require(condition, message):
    if not condition:
        raise ValueError(message)


def point(stop):
    return dict(lat=float(stop['stop_lat']), lon=float(stop['stop_lon']))


def record(checks, name, function):
    try:
        result = function()
        item = dict(check=name, status='passed', **(result or {}))
    except (ValueError, KeyError, TypeError, IndexError, FileNotFoundError) as error:
        item = dict(check=name, status='failed', error=str(error), error_type=type(error).__name__)
    checks.append(item)
    print(json.dumps(item, ensure_ascii=False), flush=True)
    return item


def typed_path(journey):
    system = journey.get('system', 'HR')
    return [str(s) if ':' in str(s) else system + ':' + str(s) for s in journey['path']]


def endpoint_matches(actual, logical, stops, indoor):
    """Accept a physical area only with its active, correctly parented binding."""
    if actual not in stops or logical not in stops:
        return False
    if actual == logical:
        return True
    prefix = logical + ':AREA:'
    if ':AREA:' in logical or not actual.startswith(prefix) or not actual[len(prefix):]:
        return False
    physical, legacy = stops[actual], stops[logical]
    if physical.get('location_type', '') != '0':
        return False
    matches = []
    for station in indoor.get('stations', []):
        parent = station.get('parent_stop_id')
        bindings = station.get('bindings', {})
        if (station.get('status') not in ('activated', 'partial')
                or not isinstance(bindings, dict) or not bindings.get(actual)
                or not station.get('venue_id')
                or parent != 'INDOOR:STATION:' + station['venue_id']
                or physical.get('parent_station') != parent
                or stops.get(parent, {}).get('location_type') != '1'
                or legacy.get('parent_station') not in station.get('legacy_parent_stop_ids', [])
                or stops.get(legacy.get('parent_station'), {}).get('location_type') != '1'):
            continue
        matches.append(station)
    return len(matches) == 1


def source_pair(root, a_system, origin, b_system, destination, expected):
    mixed = a_system != b_system
    path = root / 'data/mtr_api' / ('mixed/raw' if mixed else 'raw') / (
        f'{a_system}_{origin}_{b_system}_{destination}.json' if mixed else f'{a_system}_{origin}_{destination}.json')
    raw = json.loads(path.read_text())
    body = raw['response']
    require(raw['status'] == 'ok' and str(body.get('errorCode')) == '0', 'Source request was not successful')
    require(str(raw['origin']) == origin and str(raw['destination']) == destination, 'Source endpoints differ')
    if mixed:
        canonical = json.dumps(body, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()
        require(hashlib.sha256(canonical).hexdigest() == raw['sha256'], 'Mixed source content hash differs')
        require(raw['origin_type'] == a_system and raw['destination_type'] == b_system, 'Mixed source types differ')
    routes = [r for r in body['routes'] if float(r['time']) * 60 == expected]
    require(routes, f'Source no longer contains the expected snapshot total {expected}s; inspect before updating this regression')
    return dict(path=str(path), sha256=digest_file(path), url=raw['url'], fetched_at=raw.get('fetched_at'))


def feed_checks(root, feed, date):
    checks, live_cases = [], []
    with zipfile.ZipFile(feed) as archive:
        members = set(archive.namelist())
        rail = json.loads(archive.read('mtr_api_provenance.json')) if 'mtr_api_provenance.json' in members else {}
        kmb = json.loads(archive.read('kmb_pair_timing_provenance.json')) if 'kmb_pair_timing_provenance.json' in members else {}
        indoor = json.loads(archive.read('indoor_provenance.json')) if 'indoor_provenance.json' in members else {}
        trips = {r['trip_id']: r for r in rows(archive, 'trips.txt')}
        stops = {r['stop_id']: r for r in rows(archive, 'stops.txt')}
        stamp = datetime.strptime(date, '%Y-%m-%d')
        day = stamp.strftime('%Y%m%d')
        weekday = stamp.strftime('%A').lower()
        active = {r['service_id'] for r in rows(archive, 'calendar.txt')
                  if r['start_date'] <= day <= r['end_date'] and r[weekday] == '1'}
        for row in rows(archive, 'calendar_dates.txt'):
            if row['date'] == day:
                (active.add if row['exception_type'] == '1' else active.discard)(row['service_id'])
        by_journey = defaultdict(list)
        for tid, item in rail.get('od_trips', {}).items():
            if tid in trips and trips[tid]['service_id'] in active:
                by_journey[item['journey']].append(tid)
        selected = {}
        for case in RAIL_CASES:
            name, a_system, origin, b_system, destination, expected, modes = case
            candidates = [(key, j) for key, j in rail.get('od_journeys', {}).items()
                          if typed_path(j)[0] == a_system + ':' + origin
                          and typed_path(j)[-1] == b_system + ':' + destination
                          and j.get('api_total_seconds') == expected and by_journey[key]]
            selected[name] = candidates
        kmb_selected = {}
        for route in ('1', '74X', '98D'):
            candidates = []
            for tid, key in kmb.get('trips', {}).items():
                pattern = kmb.get('patterns', {}).get(key, {})
                profile = kmb.get('profiles', {}).get(pattern.get('native_pattern_key'), {})
                if profile.get('route') == route and tid in trips and trips[tid]['service_id'] in active:
                    candidates.append((tid, pattern, profile))
            # All matching variants are verified; one supplies live endpoints.
            kmb_selected[route] = candidates
        wanted = {tid for candidates in selected.values() for key, _ in candidates for tid in by_journey[key]}
        wanted.update(tid for candidates in kmb_selected.values() for tid, _, _ in candidates)
        calls = defaultdict(list)
        for row in rows(archive, 'stop_times.txt'):
            if row['trip_id'] in wanted:
                calls[row['trip_id']].append(row)
        for group in calls.values():
            group.sort(key=lambda r: int(r['stop_sequence']))

        for case in RAIL_CASES:
            name, a_system, origin, b_system, destination, expected, modes = case
            def check_rail():
                source = source_pair(root, a_system, origin, b_system, destination, expected)
                candidates = selected[name]
                require(candidates, 'No active whole-journey GTFS connection has this exact source pair/total')
                count = 0
                nulls = 0
                for key, journey in candidates:
                    times = journey['seconds']
                    require(times[0] == 0 and times[-1] == expected, 'Whole journey anchor mismatch')
                    require(set(journey.get('required_modes', ['mtr'])) == set(modes), 'Incorrect required mode set')
                    nulls += sum(t is None for t in times)
                    sections = journey.get('sections') or []
                    require(sections and sum(s['end_seconds'] - s['start_seconds'] for s in sections) == expected,
                            'Sections do not retain the complete operator total')
                    if name.startswith('loop_'):
                        line = name.split('_')[1]
                        require(typed_path(journey) == [f'LR:{origin}', 'LR:430', f'LR:{destination}'],
                                'Circular boundary journey no longer follows its cached three-station path')
                        require(any(o['line'] == line for s in sections for o in s.get('line_options', [])),
                                'Expected circular line absent')
                        require(journey.get('internal_transfers') == 0, 'Circle boundary became a transfer')
                    for tid in by_journey[key]:
                        group = calls[tid]
                        require(len(group) == 2, 'Whole rail journey must remain one two-stop routing connection')
                        require(all(endpoint_matches(call['stop_id'], logical, stops, indoor)
                                    for call, logical in zip(group, [journey['stop_ids'][0], journey['stop_ids'][-1]])),
                                'GTFS endpoint differs from source path without a verified indoor platform binding')
                        require(seconds(group[1]['arrival_time']) - seconds(group[0]['departure_time']) == expected,
                                'GTFS changed the whole operator duration')
                        require(group[0].get('drop_off_type') == '1' and group[1].get('pickup_type') == '1',
                                'Whole-journey boarding/alighting permissions changed')
                        count += 1
                journey = candidates[0][1]
                live_cases.append(dict(name=name, origin=point(stops[journey['stop_ids'][0]]),
                                       destination=point(stops[journey['stop_ids'][-1]]), modes=modes,
                                       preference='walking' if a_system == b_system == 'LR' else 'fastest',
                                       expected_pair_seconds=expected,
                                       feed_route_ids=sorted({trips[tid]['route_id'] for key, _ in candidates for tid in by_journey[key]})))
                return dict(seconds=expected, active_connections=count, variants=len(candidates),
                            null_intermediate_anchors=nulls, source=source)
            record(checks, 'feed_' + name, check_rail)

        for route, candidates in kmb_selected.items():
            def check_kmb():
                require(candidates, 'No active KMB operator timing proof for route ' + route)
                variants = set()
                for tid, pattern, profile in candidates:
                    group = calls[tid]
                    require(profile.get('measured') is False, 'Operator estimate incorrectly marked measured')
                    require(profile.get('source_url') and profile.get('snapshot'), 'Missing KMB source reference')
                    require([r['stop_id'] for r in group] == pattern['stop_ids'], 'KMB native pattern disagrees with GTFS order')
                    require(len(group) == len(profile['native_stop_ids']) == len(profile['adjacent_seconds']) + 1,
                            'KMB pattern length mismatch')
                    gaps = [seconds(b['arrival_time']) - seconds(a['departure_time']) for a, b in zip(group, group[1:])]
                    require(gaps == profile['adjacent_seconds'], 'GTFS still uses different KMB segment timing')
                    require(sum(gaps) == profile['total_seconds'], 'KMB whole total differs')
                    require(profile.get('direct_spans'), 'KMB longer-journey validation evidence absent')
                    for span in profile['direct_spans']:
                        a, b = span['start_index'], span['end_index']
                        require(abs(sum(gaps[a:b]) - span['seconds']) <= max(2, b-a), 'KMB longer direct estimate differs')
                    variants.add(pattern['native_pattern_key'])
                tid, pattern, profile = candidates[0]
                live_cases.append(dict(name='kmb_' + route, origin=point(stops[pattern['stop_ids'][0]]),
                                       destination=point(stops[pattern['stop_ids'][-1]]), modes=['bus'],
                                       expected_bus=route))
                return dict(active_trips=len(candidates), native_variants=sorted(variants),
                            source=profile['source_url'], snapshot=profile['snapshot'])
            record(checks, 'feed_kmb_' + route, check_kmb)
    return checks, live_cases


def graph_check(url, cases, out, timeout):
    """Catch an old OTP graph even when coordinate searches choose other routes."""
    required = {rid for case in cases for rid in case.get('feed_route_ids', [])}
    require(required, 'No verified rail connections available for graph comparison')
    request = dict(query='{routes{gtfsId}}')
    evidence = dict(url=url, request=request)
    req = urllib.request.Request(url, data=json.dumps(request).encode(), headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            evidence['response'] = json.load(response)
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        evidence['error'] = str(error)
        raise ValueError('Live OTP route inventory failed: ' + str(error)) from error
    finally:
        save(out / 'otp-route-inventory.json', evidence)
    result = evidence['response']
    require(not result.get('errors'), 'OTP rejected route-inventory query')
    actual = {r['gtfsId'].partition(':')[2] for r in result['data']['routes']}
    missing = sorted(required - actual)
    require(not missing, 'OTP is missing new feed rail connection routes: ' + ', '.join(missing[:8]))
    return dict(verified_route_ids=len(required), otp_routes=len(actual))


def expected_modes(route_id):
    """Independent assertion: do not reuse the implementation under test."""
    if 'RAIL:JOURNEY:MIXED:' in route_id:
        require(':MODES:' in route_id, 'Mixed route omitted explicit transport permissions')
        codes = route_id.split(':MODES:', 1)[1].split(':', 1)[0].split('+')
        require(set(codes) <= {'MTR', 'LR'}, 'Unknown mixed transport permission')
        return {'mtr' if c == 'MTR' else 'light_rail' for c in codes}
    if any(prefix in route_id for prefix in ('RAIL:JOURNEY:LR:', 'RAIL:LRT:')):
        return {'light_rail'}
    return {'mtr'} if 'RAIL:MTR:' in route_id else set()


def check_response(response, request, require_transit=True):
    require(isinstance(response.get('itineraries'), list), 'Live response omitted its itinerary list')
    itineraries = response['itineraries']
    if require_transit:
        require(itineraries, 'Live search returned no routes')
    selected = set(request['modes'])
    stats = dict(options=len(itineraries), rail_journeys=0, kmb_legs=0, observed_bus_routes=[])
    if not itineraries:
        stats['note'] = 'No route with the restricted mode set; no disabled transport was returned.'
    transit_count = 0
    for item in itineraries:
        require(item['initialWaitExcludedSeconds'] == 0, 'First boarding gap silently removed')
        elapsed = round(datetime.fromisoformat(item['end']).timestamp() - datetime.fromisoformat(request['departure']).timestamp())
        require(item['displayDurationSeconds'] == elapsed, 'Displayed elapsed time differs from requested departure to arrival')
        for leg in item['legs']:
            if not leg.get('transitLeg'):
                continue
            transit_count += 1
            route = leg.get('route') or {}
            required = expected_modes(route.get('gtfsId', ''))
            require(required <= selected, 'Returned route uses disabled rail mode(s): ' + ','.join(required - selected))
            require(set(leg.get('requiredModes', [])) <= selected, 'Displayed leg permits a disabled mode')
            provenance = leg.get('provenance') or {}
            journey = provenance.get('journeyTiming')
            if 'RAIL:JOURNEY:' in route.get('gtfsId', ''):
                require(journey, 'Atomic rail route is missing its active-feed whole-journey provenance')
                require(set(leg.get('requiredModes', [])) == required, 'Atomic rail display lost required-mode evidence')
                require(leg.get('transportGroup') != 'tram', 'MTR Light Rail mislabeled as Hong Kong Island tram')
            if journey:
                stats['rail_journeys'] += 1
                require(abs(leg['duration'] - journey['seconds']) <= 1, 'Live rail cost differs from whole source total')
                parts = leg.get('railSections') or []
                if parts:
                    require(abs(sum(p['duration'] for p in parts) - leg['duration']) <= 1, 'Display sections change complete journey time')
                    require(all(p.get('waitBeforeSeconds', 0) == 0 for p in parts[1:]), 'Extra internal rail wait added')
            kmb = provenance.get('kmbPairTiming')
            if kmb:
                stats['kmb_legs'] += 1
                require(kmb.get('measured') is False and kmb.get('source_url'), 'KMB source label is missing or inaccurate')
                if kmb.get('seconds') is not None:
                    require(abs(leg['duration'] - kmb['seconds']) <= 1, 'Live KMB duration differs from its source proof')
            if leg.get('mode') in ('BUS', 'COACH'):
                stats['observed_bus_routes'].append(route.get('shortName'))
    if require_transit:
        require(transit_count, 'No transit alternative returned for this positive smoke case')
    stats['observed_bus_routes'] = sorted({x for x in stats['observed_bus_routes'] if x})
    return stats


def live_checks(url, date, cases, out, timeout):
    checks = []
    # These restricted searches may legitimately return a long walk. They must
    # never sneak the other railway into a synthetic mixed connection.
    base = next((c for c in cases if c['name'] == 'central_depot'), None)
    reverse = next((c for c in cases if c['name'] == 'depot_central'), None)
    cases = list(cases)
    for item in (base, reverse):
        if item:
            for mode in ('mtr', 'light_rail'):
                cases.append(dict(item, name=item['name'] + '_' + mode + '_only', modes=[mode], permissions_only=True))
    for case in cases:
        request = dict(origin=case['origin'], destination=case['destination'], modes=case['modes'],
                       departure=date + 'T10:00:00+08:00', preference=case.get('preference', 'fastest'),
                       includeAlternatives=True, maxResults=6)
        evidence = dict(case=case, request=request, started_at=datetime.now().astimezone().isoformat())
        def check():
            start = time.monotonic()
            req = urllib.request.Request(url.rstrip('/') + '/api/route', data=json.dumps(request).encode(),
                                         headers={'Content-Type': 'application/json'})
            try:
                with urllib.request.urlopen(req, timeout=timeout) as response:
                    evidence['response'] = json.load(response)
            except (urllib.error.URLError, TimeoutError, OSError) as error:
                evidence['error'] = str(error)
                if isinstance(error, urllib.error.HTTPError):
                    evidence['error_body'] = error.read(16384).decode(errors='replace')
                raise ValueError('Live checker request failed: ' + str(error)) from error
            finally:
                evidence['seconds'] = round(time.monotonic() - start, 3)
                save(out / (case['name'] + '.json'), evidence)
            stats = check_response(evidence['response'], request, not case.get('permissions_only'))
            if case.get('expected_pair_seconds') and not case.get('permissions_only'):
                require(stats['rail_journeys'] > 0, 'Positive rail smoke did not exercise any whole-journey source evidence')
            if case.get('expected_bus') and case['expected_bus'] not in stats['observed_bus_routes']:
                stats['note'] = 'This coordinate search selected other bus routes; exact target line timings were checked in the feed.'
            return dict(seconds=evidence['seconds'], **stats)
        record(checks, 'live_' + case['name'], check)
        save(out / 'live-summary.json', checks)
    return checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    parser.add_argument('--feed', type=Path)
    parser.add_argument('--url', default='http://127.0.0.1:8000')
    parser.add_argument('--otp-url', default='http://127.0.0.1:8081/otp/gtfs/v1')
    parser.add_argument('--date', default='2026-10-04', help='An operating date in the rebuilt graph')
    parser.add_argument('--output', type=Path, default=ROOT / 'data/routing-checks/2026-10-04')
    parser.add_argument('--feed-only', action='store_true')
    parser.add_argument('--timeout', type=int, default=180)
    args = parser.parse_args()
    feed = args.feed or args.root / 'data/generated/hk-transit-EXPERIMENTAL.gtfs.zip'
    args.output.mkdir(parents=True, exist_ok=True)
    checks, cases = feed_checks(args.root, feed, args.date)
    summary = dict(feed=str(feed), feed_sha256=digest_file(feed), date=args.date,
                   feed_checks=checks, live_status='not_run' if args.feed_only else 'pending')
    save(args.output / 'operator-journeys-summary.json', summary)
    if not args.feed_only:
        graph_checks = []
        record(graph_checks, 'live_otp_feed_routes', lambda: graph_check(args.otp_url, cases, args.output, args.timeout))
        summary['live_checks'] = graph_checks + live_checks(args.url, args.date, cases, args.output, args.timeout)
        summary['live_status'] = 'completed'
    all_checks = checks + summary.get('live_checks', [])
    summary['passed'] = sum(c['status'] == 'passed' for c in all_checks)
    summary['failed'] = sum(c['status'] == 'failed' for c in all_checks)
    save(args.output / 'operator-journeys-summary.json', summary)
    print(f"Operator journey checks: {summary['passed']} passed, {summary['failed']} failed. Evidence: {args.output}")
    return 1 if summary['failed'] else 0


if __name__ == '__main__':
    sys.exit(main())
