"""Compile cached whole Light Rail / MTR–Light Rail journeys into GTFS.

These two-stop routing connections are not physical through trains. Their cost
is the published endpoint total; unknown intermediate times remain unknown.
Existing line timetables control availability and the first boarding frequency.
"""

import collections
import csv
import datetime
import hashlib
import io
import json
import pathlib
import shutil
import zipfile
from functools import lru_cache

try:
    from compile_mtr_od import clock, seconds, encode
    from compile_mtr_interchanges import merged, intersect_windows
    from scrape_mtr_mixed import read_verified, station_index, digest
except ModuleNotFoundError:  # Importing as scripts.compile_mtr_light_rail.
    from .compile_mtr_od import clock, seconds, encode
    from .compile_mtr_interchanges import merged, intersect_windows
    from .scrape_mtr_mixed import read_verified, station_index, digest


class UnusableJourney(ValueError):
    pass


MIXED_ENDPOINT_ALIASES = {'44': '39', '45': '40', '46': '42'}


def matching_alias_metadata(stations):
    """Only these observed CompleteRoutes endpoint aliases are eligible.

    This does not equate Airport Express and Tung Chung Line platforms or
    authorize substitution in the separate HRRoutes response cache.
    """
    result = {}
    for alias, canonical in MIXED_ENDPOINT_ALIASES.items():
        a, b = stations.get('HR', {}).get(alias), stations.get('HR', {}).get(canonical)
        if not a or not b or not all(a.get(k) for k in ('alias', 'name', 'coordinate', 'lineIDs')):
            continue
        left = {k: v for k, v in a.items() if k != 'ID'}
        right = {k: v for k, v in b.items() if k != 'ID'}
        if left == right:
            result[alias] = dict(canonical=canonical, station_metadata_sha256=digest(left))
    return result


def verified_redundant_alias(file, raw, stations, metadata_aliases):
    """Skip a duplicate request only with an independently verified response."""
    pair = tuple(raw[k] for k in ('origin_type', 'origin', 'destination_type', 'destination'))
    endpoint = 1 if pair[0] == 'HR' else 3
    alias = metadata_aliases.get(pair[endpoint])
    if not alias:
        return None
    canonical_pair = list(pair)
    canonical_pair[endpoint] = alias['canonical']
    canonical_pair = tuple(canonical_pair)
    canonical_file = file.parent / ('_'.join(canonical_pair) + '.json')
    canonical = read_verified(canonical_file, canonical_pair, stations)
    if not canonical or canonical['status'] != 'ok' or raw['response'] != canonical['response']:
        return None
    return dict(alias_pair=list(pair), canonical_pair=list(canonical_pair),
                alias_key=file.stem, canonical_key=canonical_file.stem,
                alias_response_sha256=raw['sha256'], canonical_response_sha256=canonical['sha256'],
                alias_cache_sha256=hashlib.sha256(file.read_bytes()).hexdigest(),
                canonical_cache_sha256=hashlib.sha256(canonical_file.read_bytes()).hexdigest(),
                station_metadata_sha256=alias['station_metadata_sha256'],
                reason='Identical verified CompleteRoutes response and identical station metadata except ID; canonical journey compiled once.')


def station(value):
    return str(int(value))


def source_seconds(value):
    if value is None or isinstance(value, bool):
        raise UnusableJourney('missing source time')
    try:
        result = float(value) * 60
    except (ValueError, TypeError):
        raise UnusableJourney('invalid source time')
    if not 0 <= result < 86400 or result != int(result):
        raise UnusableJourney('invalid source time')
    return int(result)


def active_dates(calendar, exceptions):
    days = collections.defaultdict(set)
    names = ('monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday')
    for row in calendar:
        date = datetime.datetime.strptime(row['start_date'], '%Y%m%d').date()
        last = datetime.datetime.strptime(row['end_date'], '%Y%m%d').date()
        while date <= last:
            if row.get(names[date.weekday()]) == '1':
                days[row['service_id']].add(date.strftime('%Y%m%d'))
            date += datetime.timedelta(days=1)
    for row in exceptions:
        if row['exception_type'] == '1':
            days[row['service_id']].add(row['date'])
        else:
            days[row['service_id']].discard(row['date'])
    return {key: frozenset(value) for key, value in days.items()}


def matching_positions(sequence, wanted, circular=False):
    """Only explicitly closed source patterns may cross a circular boundary."""
    sequence, wanted = tuple(sequence), tuple(wanted)
    if len(wanted) < 2:
        return []
    extended = sequence
    limit = len(sequence) - len(wanted) + 1
    if circular and sequence[0] == sequence[-1] and len(wanted) <= len(sequence):
        extended += sequence[1:]
        limit = len(sequence) - 1
    return [i for i in range(max(0, limit)) if extended[i:i + len(wanted)] == wanted]


def subtract_windows(source, covered):
    result = []
    for a, b in source:
        cursor = a
        for c, d in covered:
            if d <= cursor or c >= b:
                continue
            if c > cursor:
                result.append((cursor, min(c, b)))
            cursor = max(cursor, d)
            if cursor >= b:
                break
        if cursor < b:
            result.append((cursor, b))
    return result


def parse_lr(raw, route_index=0):
    """Retain time anchors and alternative line/platform instructions verbatim."""
    if raw.get('status') != 'ok' or str(raw.get('response', {}).get('errorCode')) != '0':
        raise UnusableJourney('unsuccessful LR response')
    route = raw['response']['routes'][route_index]
    if any(route.get(k) for k in ('special', 'rules', 'routeStatus', 'messages')):
        raise UnusableJourney('conditional LR route')
    nodes = route.get('path') or []
    if len(nodes) < 2 or nodes[-1].get('linkType') != 'END':
        raise UnusableJourney('invalid LR path')
    if any(n.get('linkType') not in ('RIDE', 'INTERCHANGE') for n in nodes[:-1]):
        raise UnusableJourney('unsupported LR link type')
    ids = [station(n['ID']) for n in nodes]
    if (ids[0], ids[-1]) != (station(raw['origin']), station(raw['destination'])):
        raise UnusableJourney('LR endpoint mismatch')
    total = source_seconds(route['time'])
    times = [source_seconds(n['time']) if n.get('time') is not None else None for n in nodes]
    known = [t for t in times if t is not None]
    if total <= 0 or times[0] != 0 or times[-1] != total or any(b <= a for a, b in zip(known, known[1:])):
        raise UnusableJourney('invalid LR cumulative anchors')
    bounds = [0] + [i for i, n in enumerate(nodes) if n['linkType'] == 'INTERCHANGE'] + [len(nodes) - 1]
    sections = []
    for a, b in zip(bounds, bounds[1:]):
        if times[a] is None or times[b] is None:
            raise UnusableJourney('missing interchange time')
        options = []
        for step in nodes[a].get('step') or []:
            if not step.get('lineID'):
                continue
            options.append(dict(line=str(step['lineID']), platform=step.get('platform'),
                                towards=step.get('towards'), instruction=step.get('linkText'),
                                track=step.get('track')))
        if not options:
            raise UnusableJourney('missing LR boarding line')
        sections.append(dict(system='LR', mode='TRAM', line_options=options,
                             from_index=a, to_index=b, start_seconds=times[a], end_seconds=times[b],
                             station_ids=ids[a:b + 1], source_path_indices=list(range(a, b + 1))))
    return dict(system='LR', required_modes=['light_rail'], path=['LR:' + i for i in ids],
                station_ids=ids, seconds=times, sections=sections, api_total_seconds=total,
                url=raw['url'], fetched_at=raw['fetched_at'], internal_transfers=len(sections) - 1,
                source_route_index=route_index, messages=[],
                semantics='Whole MTR Light Rail endpoint estimate; internal changes included. Intermediate null times are not interpolated.')


def offset_journey(journey, offset, index):
    result = dict(journey)
    result['seconds'] = [None if x is None else x + offset for x in journey['seconds']]
    result['sections'] = [dict(s, from_index=s['from_index'] + index, to_index=s['to_index'] + index,
                               start_seconds=s['start_seconds'] + offset,
                               end_seconds=s['end_seconds'] + offset) for s in journey['sections']]
    return result


class Timetable:
    """Read source templates once; preserve dated, directed line availability."""

    def __init__(self, root, archive, proof, needed_hr):
        self.root, self.proof = pathlib.Path(root), proof
        def read(name):
            return list(csv.DictReader(io.TextIOWrapper(archive.open(name), encoding='utf-8-sig'))) if name in archive.namelist() else []
        self.routes = read('routes.txt')
        self.byroute = {r['route_id']: r for r in self.routes}
        self.trips = read('trips.txt')
        self.bytid = {r['trip_id']: r for r in self.trips}
        self.stops = read('stops.txt')
        self.stopmap = {r['stop_id']: r for r in self.stops}
        self.stop_lookup = {}
        self.station_stops = collections.defaultdict(list)
        for sid in self.stopmap:
            parts = sid.split(':')
            if len(parts) == 4 and parts[0] == 'RAIL' and parts[1] in ('MTR', 'LRT'):
                self.stop_lookup[('HR' if parts[1] == 'MTR' else 'LR', station(parts[2]), parts[3])] = sid
                self.station_stops[('HR' if parts[1] == 'MTR' else 'LR', station(parts[2]))].append(sid)
        self.calendar = read('calendar.txt')
        self.dates = read('calendar_dates.txt')
        self.attributions = read('attributions.txt')
        self.transfers = read('transfers.txt')
        self.hr_tids = {tid for tid, o in proof.get('od_trips', {}).items() if o['journey'] in needed_hr}
        self.lr_tids = {tid for tid, t in self.bytid.items() if t['route_id'].startswith('RAIL:LRT:')}
        needed_services = {self.bytid[tid]['service_id'] for tid in self.hr_tids | self.lr_tids}
        # Surface feeds can contain 100-year calendars; do not expand unrelated
        # services while checking a small, dated rail compilation.
        self.active = active_dates([c for c in self.calendar if c['service_id'] in needed_services],
                                   [d for d in self.dates if d['service_id'] in needed_services])
        self.frequencies = read('frequencies.txt')
        self.byfreq = collections.defaultdict(list)
        for row in self.frequencies:
            self.byfreq[row['trip_id']].append(row)
        self.lrrows = collections.defaultdict(list)
        self.scheduled = {}
        for r in csv.DictReader(io.TextIOWrapper(archive.open('stop_times.txt'), encoding='utf-8-sig')):
            tid = r['trip_id']
            if tid in self.lr_tids:
                self.lrrows[tid].append(r)
            elif tid in self.hr_tids and r['stop_sequence'] == '1':
                self.scheduled[tid] = seconds(r['departure_time'])
        self.byline = collections.defaultdict(list)
        for tid, rows in self.lrrows.items():
            rows.sort(key=lambda r: int(r['stop_sequence']))
            line = self.bytid[tid]['route_id'].split(':')[-1]
            ids = tuple(station(r['stop_id'].split(':')[2]) for r in rows)
            self.byline[line].append((tid, ids, rows))
        self.hr_bands = collections.defaultdict(list)
        for tid in self.hr_tids:
            o = proof['od_trips'][tid]
            journey = proof['od_journeys'][o['journey']]
            firstline = journey['stop_ids'][0].split(':')[-1]
            for band in self.trip_bands(tid, 0, firstline, 'existing_HR_API_timetable_phase'):
                self.hr_bands[o['journey']].append(band)

    def trip_bands(self, tid, offset, line, phase_kind):
        dates = self.active.get(self.bytid[tid]['service_id'], frozenset())
        if not dates:
            return []
        rows = self.byfreq[tid]
        if rows:
            return [(seconds(f['start_time']) + offset, seconds(f['end_time']) + offset,
                     int(f['headway_secs']), f.get('exact_times', '0'), tid, line, phase_kind, offset, dates) for f in rows]
        dep = self.scheduled.get(tid)
        if dep is None and tid in self.lrrows:
            dep = seconds(self.lrrows[tid][0]['departure_time'])
        return [(dep + offset, dep + offset + 1, 0, '1', tid, line, phase_kind, offset, dates)] if dep is not None else []

    @lru_cache(maxsize=None)
    def detail(self, system, origin, destination):
        name = f'{system}_{origin}_{destination}.json'
        for directory in ('raw', 'mixed/details'):
            path = self.root / 'data/mtr_api' / directory / name
            if path.exists():
                return json.loads(path.read_text())
        raise UnusableJourney('missing constituent cache ' + name)

    @lru_cache(maxsize=None)
    def lr_phase(self, line, prefix, fallback):
        if len(prefix) == 1:
            return 0, 'source_terminal_timetable'
        try:
            raw = self.detail('LR', prefix[0], prefix[-1])
            for i in range(len(raw.get('response', {}).get('routes', []))):
                j = parse_lr(raw, i)
                if tuple(j['station_ids']) == prefix and len(j['sections']) == 1 and any(o['line'] == line for o in j['sections'][0]['line_options']):
                    return j['api_total_seconds'], 'matching_API_prefix_journey_phase_estimate'
        except (UnusableJourney, ValueError, KeyError):
            pass
        return fallback, 'existing_timetable_phase_estimate'

    @lru_cache(maxsize=None)
    def lr_bands(self, line, ids):
        result = []
        for tid, pattern, rows in self.byline[line]:
            for i in matching_positions(pattern, ids, circular=line in ('705', '706')):
                fallback = seconds(rows[i]['departure_time']) - seconds(rows[0]['departure_time'])
                offset, kind = self.lr_phase(line, pattern[:i + 1], fallback)
                result.extend(self.trip_bands(tid, offset, line, kind))
        return tuple(result)

    def section_bands(self, section):
        if section.get('availability_journey'):
            return self.hr_bands[section['availability_journey']]
        return [band for o in section['line_options'] for band in self.lr_bands(o['line'], tuple(section['station_ids']))]

    @lru_cache(maxsize=None)
    def windows(self, system, key):
        if system == 'HR':
            bands = self.hr_bands[key]
        else:
            options, ids = key
            bands = [b for line in options for b in self.lr_bands(line, ids)]
        bydate = collections.defaultdict(list)
        for a, b, *_, dates in bands:
            for date in dates:
                bydate[date].append((a, b))
        return {date: merged(rows) for date, rows in bydate.items()}

    def allowed_windows(self, section):
        if section.get('availability_journey'):
            return self.windows('HR', section['availability_journey'])
        return self.windows('LR', (tuple(sorted(o['line'] for o in section['line_options'])), tuple(section['station_ids'])))

    def bind_stops(self, journey, firstline=None):
        # A CompleteRoutes connector may start/end at the other system without
        # boarding it. Use an existing logical stop at that station for walking.
        stopids = []
        for typed in journey['path']:
            system, sid = typed.split(':')
            matches = sorted(self.station_stops.get((system, sid), []))
            stopids.append(matches[0] if matches else None)
        first_rail = next(s for s in journey['sections'] if s['mode'] != 'WALK')
        for section in journey['sections']:
            if section['mode'] == 'WALK':
                continue
            opts = section['line_options']
            line = firstline if section is first_rail and firstline else opts[0]['line']
            system = section['system']
            ids = section.get('logical_station_ids', section['station_ids'])
            section['stop_ids'] = [self.stop_lookup.get((system, sid, line)) for sid in ids]
            for i, sid in enumerate(section['stop_ids'], section['from_index']):
                stopids[i] = sid
        if not all(stopids):
            raise UnusableJourney('missing GTFS logical stop')
        journey['stop_ids'] = stopids
        for section in journey['sections']:
            if section['mode'] == 'WALK':
                section['stop_ids'] = stopids[section['from_index']:section['to_index'] + 1]
        return journey


def restrict_bands(timetable, journey):
    """Intersect every dated section at its source cumulative boarding offset."""
    sections = journey.get('availability_sections', journey['sections'])
    sections = [s for s in sections if s['mode'] != 'WALK']
    first = sections[0]
    bands = timetable.section_bands(first)
    others = [(s['start_seconds'], timetable.allowed_windows(s)) for s in sections[1:]]
    grouped = collections.defaultdict(set)
    for a, b, h, exact, parent, line, phase, offset, dates in bands:
        # A supplied access walk precedes the first train in some mixed paths.
        # Shift the actual train's departure band, without adding another wait.
        a, b = a - first['start_seconds'], b - first['start_seconds']
        anchor = a
        a = max(0, a)
        for date in dates:
            allowed = [(a, b)]
            for shift, windows in others:
                shifted = [(c - shift, d - shift) for c, d in windows.get(date, [])]
                allowed = intersect_windows(allowed, shifted)
                if not allowed:
                    break
            for c, d in allowed:
                # Exact departures cannot be moved to a new phase by clipping.
                if exact == '1' and h:
                    c = anchor + max(0, (c - anchor + h - 1) // h) * h
                if c < d:
                    grouped[(c, d, h, exact, parent, line, phase, offset)].add(date)
    return grouped


def hr_component(key, j):
    ids = [station(x) for x in j['path']]
    times = j['seconds']
    if len(ids) != len(times) or times[0] != 0 or times[-1] != j['api_total_seconds']:
        raise UnusableJourney('invalid compiled HR constituent')
    lines = [s.split(':')[-1] for s in j['stop_ids']]
    bounds = [0] + [i for i in range(1, len(ids) - 1) if lines[i] != lines[i - 1]] + [len(ids) - 1]
    # Same-line changes (e.g. Tseung Kwan O) also have a source time anchor.
    for change in j.get('interchanges', []):
        for i, (sid, value) in enumerate(zip(ids, times)):
            if 0 < i < len(ids) - 1 and sid == str(change['station_id']) and value == change['seconds']:
                bounds.append(i)
    bounds = sorted(set(bounds))
    sections = []
    instructions = {x.get('seconds'): x for x in j.get('instructions', [])}
    for a, b in zip(bounds, bounds[1:]):
        change = next((x for x in j.get('interchanges', []) if x['seconds'] == times[a]), {})
        sections.append(dict(system='HR', mode='SUBWAY', from_index=a, to_index=b,
                             start_seconds=times[a], end_seconds=times[b], station_ids=ids[a:b + 1],
                             line_options=[dict(line=lines[a], platform=change.get('platform'),
                                                instruction=instructions.get(times[a], {}).get('text'))],
                             source_path_indices=list(range(a, b + 1))))
        resolved = next((x for x in j.get('station_id_alias_resolutions', [])
                         if x['from_index'] == a and x['to_index'] == b and x['line'] == lines[a]), None)
        if resolved:
            if resolved['source_station_ids'] != ids[a:b + 1]:
                raise UnusableJourney('HR station alias proof differs from source path')
            sections[-1]['logical_station_ids'] = resolved['timetable_station_ids']
            sections[-1]['station_id_alias_resolutions'] = resolved['aliases']
    return dict(system='HR', path=['HR:' + i for i in ids], seconds=list(times), sections=sections,
                api_total_seconds=j['api_total_seconds'], url=j['url'], fetched_at=j['fetched_at'],
                availability_sections=[dict(sections[0], availability_journey=key)],
                internal_transfers=j.get('internal_transfers', 0))


def hr_walking_component(raw, route_index, aliases, journeys):
    """An HR connector walk can be used without inventing its railway timing.

    Earlier HR compilation excluded WALKINTERCHANGE. A CompleteRoutes rail
    constituent can nevertheless use it when every actual train section has an
    exact directed stop-path timetable in the compiled HR evidence.
    """
    if raw.get('status') != 'ok' or str(raw.get('response', {}).get('errorCode')) != '0':
        raise UnusableJourney('unsuccessful HR detail')
    route = raw['response']['routes'][route_index]
    if any(route.get(k) for k in ('special', 'rules', 'routeStatus', 'messages')):
        raise UnusableJourney('conditional HR detail')
    nodes = route.get('path') or []
    if not nodes or nodes[-1].get('linkType') != 'END' or not any(n.get('linkType') == 'WALKINTERCHANGE' for n in nodes):
        raise UnusableJourney('not an HR walking connector path')
    if any(n.get('stationStatus') or n.get('linkStatus') for n in nodes):
        raise UnusableJourney('HR station/link restriction')
    ids = [station(n['ID']) for n in nodes]
    times = [source_seconds(n.get('time')) for n in nodes]
    total = source_seconds(route['time'])
    if (ids[0], ids[-1]) != (station(raw['origin']), station(raw['destination'])) or times[0] != 0 or times[-1] != total or any(b <= a for a, b in zip(times, times[1:])):
        raise UnusableJourney('invalid HR walking cumulative path')
    sections, availability = [], []
    i = 0
    while i < len(nodes) - 1:
        node = nodes[i]
        if node['linkType'] == 'WALKINTERCHANGE':
            j = i + 1
            section = dict(system='WALK', mode='WALK', line_options=[], from_index=i, to_index=j,
                           start_seconds=times[i], end_seconds=times[j], source_path_indices=[i, j],
                           instruction=node.get('linkText'), timing_basis='MTR walking/interchange cumulative interval')
        else:
            if node['linkType'] not in ('RIDE', 'INTERCHANGE'):
                raise UnusableJourney('unsupported HR walking path link')
            j = i + 1
            while j < len(nodes) - 1 and nodes[j]['linkType'] == 'RIDE':
                j += 1
            line = aliases.get(str(node.get('lineID')))
            if not line or any(aliases.get(str(n.get('lineID'))) != line for n in nodes[i:j]):
                raise UnusableJourney('HR connector line mismatch')
            key = line + ':' + '>'.join(ids[i:j + 1])
            if key not in journeys:
                raise UnusableJourney('HR connector section has no matching timetable')
            section = dict(system='HR', mode='SUBWAY', from_index=i, to_index=j,
                           start_seconds=times[i], end_seconds=times[j], station_ids=ids[i:j + 1],
                           line_options=[dict(line=line, platform=node.get('platform'), towards=node.get('towards'),
                                              instruction=node.get('linkText'))], source_path_indices=list(range(i, j + 1)))
            availability.append(dict(section, availability_journey=key))
        sections.append(section)
        i = j
    if not availability:
        raise UnusableJourney('HR detail contains no train')
    return dict(system='HR', path=['HR:' + i for i in ids], seconds=times, sections=sections,
                availability_sections=availability, api_total_seconds=total, url=raw['url'], fetched_at=raw['fetched_at'],
                internal_transfers=max(0, len(availability) - 1))


def mixed_journeys(raw, proof, hr_index, timetable, extra_hr=None):
    """Expand only constituent paths with exactly the CompleteRoutes section cost."""
    if raw.get('status') != 'ok' or str(raw.get('response', {}).get('errorCode')) != '0':
        raise UnusableJourney('unsuccessful mixed response')
    for ri, route in enumerate(raw.get('normalized', {}).get('routes', [])):
        ri = route.get('source_route_index', ri)
        sections = route['sections']
        if not sections or not any(s['kind'] in ('HR', 'LR') for s in sections):
            raise UnusableJourney('mixed path has no rail journey')
        if sum(s['seconds'] for s in sections) != route['total_seconds']:
            raise UnusableJourney('mixed component total mismatch')
        if (sections[0]['origin_type'], str(sections[0]['origin']), sections[-1]['destination_type'], str(sections[-1]['destination'])) != (
                raw['origin_type'], str(raw['origin']), raw['destination_type'], str(raw['destination'])):
            raise UnusableJourney('mixed typed endpoint mismatch')
        for a, b in zip(sections, sections[1:]):
            if (a['destination_type'], str(a['destination'])) != (b['origin_type'], str(b['origin'])):
                raise UnusableJourney('mixed constituent connection mismatch')
        alternatives = [[]]
        for s in sections:
            if s['kind'] == 'WALK':
                parts = [s]
            elif s['kind'] == 'LR':
                detail = timetable.detail('LR', str(s['origin']), str(s['destination']))
                parts = [parse_lr(detail, i) for i in range(len(detail['response']['routes']))]
                parts = [p for p in parts if p['api_total_seconds'] == s['seconds']]
            elif s['kind'] == 'HR':
                if '70' in (str(s['origin']), str(s['destination'])) and not timetable.station_stops.get(('HR', '70')):
                    raise UnusableJourney('Racecourse has no dated GTFS service or logical stop')
                keys = hr_index.get((str(s['origin']), str(s['destination']), s['seconds']), [])
                parts = [(extra_hr or {}).get(k) or hr_component(k, proof['od_journeys'][k]) for k in keys]
            else:
                raise UnusableJourney('unsupported mixed mode')
            if not parts:
                raise UnusableJourney('constituent path/time unavailable')
            alternatives = [a + [(s, p)] for a in alternatives for p in parts]
        for vi, parts in enumerate(alternatives):
            modes = [mode for system, mode in [('HR', 'mtr'), ('LR', 'light_rail')] if any(s['kind'] == system for s in sections)]
            journey = dict(system='MIXED', required_modes=modes, path=[], seconds=[],
                           sections=[], availability_sections=[], api_total_seconds=route['total_seconds'],
                           url=raw['url'], fetched_at=raw['fetched_at'], source_route_index=ri,
                           internal_transfers=0, component_sources=[], messages=[],
                           semantics='Whole MTR CompleteRoutes endpoint estimate; operator-supplied rail and interchange walk totals, no extra internal waiting.')
            offset = 0
            previous_rail = False
            for source, part in parts:
                if source['kind'] == 'WALK':
                    origin = source['origin_type'] + ':' + str(source['origin'])
                    destination = source['destination_type'] + ':' + str(source['destination'])
                    if not journey['path']:
                        journey['path'].append(origin)
                        journey['seconds'].append(offset)
                    if journey['path'][-1] != origin:
                        raise UnusableJourney('walking connector origin mismatch')
                    walk = dict(system='WALK', mode='WALK', line_options=[], from_index=len(journey['path']) - 1,
                                        to_index=len(journey['path']), start_seconds=offset, end_seconds=offset + source['seconds'],
                                        source_path_indices=[source['source_path_index']],
                                        instruction=raw['response']['routes'][ri]['path'][source['source_path_index']].get('routeText'))
                    journey['path'].append(destination)
                    offset += source['seconds']
                    journey['seconds'].append(offset)
                    journey['sections'].append(walk)
                    previous_rail = False
                    continue
                if previous_rail:
                    raise UnusableJourney('mixed rail connection has no explicit walk')
                shared = bool(journey['path'])
                if shared and journey['path'][-1] != part['path'][0]:
                    raise UnusableJourney('walking connector destination mismatch')
                index = len(journey['path']) - int(shared)
                shifted = offset_journey(part, offset, index)
                journey['path'].extend(part['path'][int(shared):])
                journey['seconds'].extend(shifted['seconds'][int(shared):])
                for s in shifted['sections']:
                    s['complete_source_path_index'] = source['source_path_index']
                journey['sections'].extend(shifted['sections'])
                for s in part.get('availability_sections', part['sections']):
                    journey['availability_sections'].append(dict(s, start_seconds=s['start_seconds'] + offset))
                journey['component_sources'].append(dict(system=part['system'], url=part['url'],
                                                          fetched_at=part['fetched_at'], seconds=part['api_total_seconds']))
                journey['internal_transfers'] += part.get('internal_transfers', 0)
                offset += part['api_total_seconds']
                previous_rail = True
            journey['internal_transfers'] += max(0, sum(s['kind'] != 'WALK' for s in sections) - 1)
            if offset != journey['api_total_seconds']:
                raise UnusableJourney('mixed assembled total mismatch')
            yield f'MIXED:{raw["origin_type"]}:{raw["origin"]}>{raw["destination_type"]}:{raw["destination"]}:{ri}:{vi}', journey


def compile_light_rail(root, path, mixed_cache=None):
    root, path = pathlib.Path(root), pathlib.Path(path)
    mixed_cache = pathlib.Path(mixed_cache) if mixed_cache else root / 'data/mtr_api/mixed/raw'
    with zipfile.ZipFile(path) as archive:
        proof = json.loads(archive.read('mtr_api_provenance.json'))
        if proof.get('light_rail_whole_journey_version'):
            raise ValueError('Light Rail whole-journey compilation already applied; rebuild from the source feed')
        hr_index = collections.defaultdict(list)
        for key, j in proof.get('od_journeys', {}).items():
            if j.get('stop_ids') and all(s.startswith('RAIL:MTR:') for s in j['stop_ids']):
                hr_index[(station(j['path'][0]), station(j['path'][-1]), j['api_total_seconds'])].append(key)
        mixed = []
        extra_hr = {}
        needed_hr_pairs = set()
        needed_hr = set()
        rejected = []
        equivalent_aliases = []
        physical_pair_keys = set()
        metadata_aliases = {}
        source_files = []
        mixed_files = sorted(mixed_cache.glob('*.json'))
        mixed_file_names = {file.name for file in mixed_files}
        verified_stations = None
        if mixed_files:
            metadata_file = mixed_cache.parent / 'metadata.json'
            if not metadata_file.exists():
                raise ValueError('Mixed cache metadata missing; run the mixed collector/verification first')
            metadata = json.loads(metadata_file.read_text())
            if metadata.get('sha256') != digest(metadata.get('metadata')):
                raise ValueError('Mixed metadata hash mismatch')
            verified_stations = station_index(metadata['metadata'])
            metadata_aliases = matching_alias_metadata(verified_stations)
        for file in mixed_files:
            raw = json.loads(file.read_text())
            pair = tuple(raw[k] for k in ('origin_type', 'origin', 'destination_type', 'destination'))
            verified = read_verified(file, pair, verified_stations)
            if not verified or file.stem != '_'.join(pair):
                raise ValueError('Mixed cache verification failed: ' + file.name)
            raw = verified
            equivalent = verified_redundant_alias(file, raw, verified_stations, metadata_aliases)
            if equivalent and equivalent['canonical_key'] + '.json' in mixed_file_names:
                equivalent_aliases.append(equivalent)
                physical_pair_keys.add(equivalent['canonical_key'])
                source_files.append(dict(file='mixed/' + file.name, sha256=equivalent['alias_cache_sha256']))
                continue
            physical_pair_keys.add(file.stem)
            if raw.get('status') != 'ok':
                rejected.append(dict(source=file.name, reason=raw.get('unavailability', {}).get('reason') or 'mixed cache status ' + str(raw.get('status')),
                                     status=raw.get('status'), source_sha256=hashlib.sha256(file.read_bytes()).hexdigest()))
                continue
            mixed.append((file.name, raw))
            for r in raw.get('normalized', {}).get('routes', []):
                for s in r['sections']:
                    if s['kind'] == 'HR':
                        pair_key = (str(s['origin']), str(s['destination']), s['seconds'])
                        needed_hr_pairs.add(pair_key)
                        needed_hr.update(hr_index.get(pair_key, []))
        inventory_file = root / 'data/mtr_api/inventory.json'
        aliases = {str(l['ID']): l['alias'] for l in json.loads(inventory_file.read_text())['HR']['metadata']['lines']} if inventory_file.exists() else {}
        for origin, destination, total in sorted(needed_hr_pairs):
            file = next((root / 'data/mtr_api' / d / f'HR_{origin}_{destination}.json'
                         for d in ('raw', 'mixed/details') if (root / 'data/mtr_api' / d / f'HR_{origin}_{destination}.json').exists()), None)
            if not file:
                continue
            raw = json.loads(file.read_text())
            for ri, route in enumerate(raw.get('response', {}).get('routes', [])):
                try:
                    if source_seconds(route.get('time')) != total:
                        continue
                    component = hr_walking_component(raw, ri, aliases, proof['od_journeys'])
                except (UnusableJourney, KeyError, ValueError):
                    continue
                key = f'HR_WALK:{origin}>{destination}:{ri}'
                extra_hr[key] = component
                hr_index[(origin, destination, total)].append(key)
                needed_hr.update(s['availability_journey'] for s in component['availability_sections'])
        timetable = Timetable(root, archive, proof, needed_hr)
        newtrips, newrows, newfreq, newdates = [], [], [], []
        newroutes, services = {}, {}
        route_sources = collections.defaultdict(set)
        wiki = json.loads(archive.read('rail_wiki_provenance.json')) if 'rail_wiki_provenance.json' in archive.namelist() else None
        wiki_urls = collections.defaultdict(set)
        for source in (wiki or {}).get('trips', {}).values():
            if source.get('url') and source.get('line') and source.get('system') in ('LRT', 'MTR'):
                wiki_urls[('LR' if source['system'] == 'LRT' else 'HR', source['line'])].add(source['url'])
        route_modes = proof.setdefault('route_required_modes', {})
        coverage = collections.defaultdict(lambda: collections.defaultdict(list))
        accepted = collections.Counter()
        accepted_pairs = collections.defaultdict(set)
        phases = collections.Counter()

        def emit(key, journey):
            # Discard structurally inapplicable line choices, never invent a line.
            for s in journey['sections']:
                if s['system'] == 'LR':
                    s['line_options'] = [o for o in s['line_options'] if timetable.lr_bands(o['line'], tuple(s['station_ids']))]
                    if not s['line_options']:
                        raise UnusableJourney('no matching dated LR line/path')
            grouped = restrict_bands(timetable, journey)
            if not grouped:
                raise UnusableJourney('no overlapping dated service windows')
            byfirst = collections.defaultdict(dict)
            for band, ds in grouped.items():
                byfirst[band[5]][band] = ds
            for firstline, bands in sorted(byfirst.items()):
                variant = dict(journey, sections=[dict(s) for s in journey['sections']])
                variant.pop('availability_sections', None)
                # Each variant uses this line's boarding frequency. Present
                # that same line, while preserving later operator choices.
                first_section = next(s for s in variant['sections'] if s['mode'] != 'WALK')
                first_section['line_options'] = [o for o in first_section['line_options'] if o['line'] == firstline]
                if not first_section['line_options']:
                    raise UnusableJourney('first boarding line differs from source path')
                timetable.bind_stops(variant, firstline)
                variant['boarding_line'] = firstline
                access_seconds = next(s['start_seconds'] for s in variant['sections'] if s['mode'] != 'WALK')
                variant['access_walk_seconds'] = access_seconds
                variant['line'] = ' → '.join('/'.join(o['line'] for o in s['line_options']) if s['mode'] != 'WALK' else 'Walk' for s in variant['sections'])
                variant_key = key + ':FIRST:' + firstline
                lanes = collections.defaultdict(list)
                scheduled = []
                for band, ds in sorted(bands.items()):
                    a, b, h, exact, *_ = band
                    dates = tuple(sorted(ds))
                    if not h:
                        scheduled.append((dates, [band]))
                    else:
                        group = lanes[(dates, exact)]
                        lane = next((v for v in group if v[-1][1] <= a), None)
                        if lane is None:
                            lane = []
                            group.append(lane)
                        lane.append(band)
                bundles = scheduled + [(ds, lane) for (ds, _), group in lanes.items() for lane in group]
                for n, (ds, bundle) in enumerate(bundles):
                    a, b, h, exact, parent, line, phase, offset = bundle[0]
                    template = timetable.bytid[parent]
                    first_system = next(s['system'] for s in variant['sections'] if s['mode'] != 'WALK')
                    mode_key = '+'.join('MTR' if m == 'mtr' else 'LR' for m in journey['required_modes'])
                    rid = f'RAIL:JOURNEY:{journey["system"]}:{first_system}:{firstline}:MODES:{mode_key}:PATH:{journey["api_total_seconds"]}'
                    if rid not in newroutes:
                        base = timetable.byroute[template['route_id']]
                        newroutes[rid] = dict(base, route_id=rid,
                                             route_short_name='Light Rail journey' if journey['system'] == 'LR' else 'MTR + Light Rail',
                                             route_long_name='Whole cached operator journey; may include internal changes',
                                             route_type='0' if first_system == 'LR' else base['route_type'])
                        route_modes[rid] = journey['required_modes']
                    for section in variant['sections']:
                        for option in section['line_options']:
                            route_sources[rid].update(wiki_urls.get((section['system'], option['line']), ()))
                    if ds not in services:
                        sid = 'LRAPI:DATES:' + hashlib.sha256(','.join(ds).encode()).hexdigest()[:16]
                        services[ds] = sid
                        newdates.extend(dict(service_id=sid, date=d, exception_type='1') for d in ds)
                    tid = 'LRAPI:' + hashlib.sha256((variant_key + ':' + str(n)).encode()).hexdigest()[:24]
                    newtrips.append(dict(template, trip_id=tid, route_id=rid, service_id=services[ds],
                                         trip_headsign=timetable.stopmap[variant['stop_ids'][-1]]['stop_name'], shape_id=''))
                    departure = 0 if h else a
                    for sequence, sid, t, pickup, dropoff in [(1, variant['stop_ids'][0], departure, '0', '1'),
                                                           (2, variant['stop_ids'][-1], departure + journey['api_total_seconds'], '1', '0')]:
                        newrows.append(dict(trip_id=tid, stop_id=sid, stop_sequence=str(sequence),
                                            arrival_time=clock(t), departure_time=clock(t), pickup_type=pickup,
                                            drop_off_type=dropoff, timepoint='0', shape_dist_traveled=''))
                    if h:
                        for c, d, headway, ex, *_ in bundle:
                            newfreq.append(dict(trip_id=tid, start_time=clock(c), end_time=clock(d), headway_secs=str(headway), exact_times=ex))
                    proof['od_trips'][tid] = dict(original_trip=parent, journey=variant_key,
                                                 boarding_offset_seconds=offset - access_seconds, required_modes=journey['required_modes'],
                                                 frequency_parents=[dict(start=c, end=d, parent=p, line=ln, phase_source=pk,
                                                                         phase_seconds=off - access_seconds,
                                                                         station_phase_seconds=off, access_walk_seconds=access_seconds)
                                                                    for c, d, _, _, p, ln, pk, off in bundle])
                    phases.update(x[6] for x in bundle)
                proof['od_journeys'][variant_key] = variant
            if journey['system'] == 'LR':
                pair = (journey['station_ids'][0], journey['station_ids'][-1])
                for (a, b, *other), ds in grouped.items():
                    for d in ds:
                        coverage[pair][d].append((a, b))
            accepted[journey['system']] += 1
            accepted_pairs[journey['system']].add((journey['path'][0], journey['path'][-1]))
            if sum(accepted.values()) % 500 == 0:
                print('Whole LR/mixed paths:', dict(accepted), 'connections:', len(newtrips), flush=True)

        for file in sorted((root / 'data/mtr_api/raw').glob('LR_*.json')):
            raw = json.loads(file.read_text())
            source_files.append(dict(file=file.name, sha256=hashlib.sha256(file.read_bytes()).hexdigest()))
            for i in range(len(raw.get('response', {}).get('routes', []))):
                try:
                    emit(f'LR:{raw["origin"]}>{raw["destination"]}:{i}', parse_lr(raw, i))
                except (UnusableJourney, KeyError, ValueError) as exc:
                    rejected.append(dict(source=file.name, route_index=i, reason=str(exc)))
        for filename, raw in mixed:
            source_files.append(dict(file='mixed/' + filename, sha256=hashlib.sha256((mixed_cache / filename).read_bytes()).hexdigest()))
            try:
                for key, journey in mixed_journeys(raw, proof, hr_index, timetable, extra_hr):
                    emit(key, journey)
            except (UnusableJourney, KeyError, ValueError) as exc:
                rejected.append(dict(source=filename, reason=str(exc)))
        for days in coverage.values():
            for day in days:
                days[day] = merged(days[day])
        whole_tids = {t['trip_id'] for t in newtrips}
        removed = set()
        retained = collections.Counter()
        retained_edges = set()
        legacy_aliases = proof.setdefault('legacy_lr_trips', {})
        protected_tids = {r.get(key) for r in timetable.transfers for key in ('from_trip_id', 'to_trip_id') if r.get(key)}
        legacy_clones = 0
        original_window_seconds = retained_window_seconds = 0
        # Retain old source services only in windows that whole journeys cannot
        # replace. One missing pair must not preserve an all-day model service.
        for tid, rows in timetable.lrrows.items():
            line = timetable.bytid[tid]['route_id'].split(':')[-1]
            ids = tuple(station(r['stop_id'].split(':')[2]) for r in rows)
            if line in ('507P', '751P'):
                retained['special line absent from API inventory'] += 1
                retained_edges.update(f'LRT:{line}:{a}>{b}' for a, b in zip(ids, ids[1:]))
                continue
            if tid in protected_tids:
                retained['trip-specific transfer constraint preserved'] += 1
                retained_edges.update(f'LRT:{line}:{a}>{b}' for a, b in zip(ids, ids[1:]))
                continue
            base_bands = timetable.trip_bands(tid, 0, line, 'source_terminal_timetable')
            common = {day: merged((a, b) for a, b, *_, dates in base_bands if day in dates)
                      for day in timetable.active.get(timetable.bytid[tid]['service_id'], [])}
            for i in range(len(ids) - 1):
                fallback = seconds(rows[i]['departure_time']) - seconds(rows[0]['departure_time'])
                phase, kind = timetable.lr_phase(line, ids[:i + 1], fallback)
                for destination in set(ids[i + 1:]) - {ids[i]}:
                    covered = coverage.get((ids[i], destination), {})
                    for day in common:
                        if common[day]:
                            common[day] = intersect_windows(common[day], [(a - phase, b - phase) for a, b in covered.get(day, [])])
                if not any(common.values()):
                    break
            leftover = collections.defaultdict(set)
            for a, b, h, exact, *_, dates in base_bands:
                for day in dates:
                    original_window_seconds += b - a
                    for c, d in subtract_windows([(a, b)], common.get(day, [])):
                        if exact == '1' and h:
                            c = a + max(0, (c - a + h - 1) // h) * h
                        if c < d:
                            retained_window_seconds += d - c
                            leftover[(c, d, h, exact)].add(day)
            removed.add(tid)
            if leftover:
                retained['uncovered source dates/windows only'] += 1
                retained_edges.update(f'LRT:{line}:{a}>{b}' for a, b in zip(ids, ids[1:]))
            for n, ((a, b, h, exact), ds_set) in enumerate(sorted(leftover.items())):
                ds = tuple(sorted(ds_set))
                if ds not in services:
                    sid = 'LRAPI:DATES:' + hashlib.sha256(','.join(ds).encode()).hexdigest()[:16]
                    services[ds] = sid
                    newdates.extend(dict(service_id=sid, date=d, exception_type='1') for d in ds)
                clone = tid + ':UNCOVERED:' + str(n)
                newtrips.append(dict(timetable.bytid[tid], trip_id=clone, service_id=services[ds]))
                newrows.extend(dict(r, trip_id=clone) for r in rows)
                if h:
                    newfreq.append(dict(trip_id=clone, start_time=clock(a), end_time=clock(b), headway_secs=str(h), exact_times=exact))
                legacy_aliases[clone] = dict(original_trip=tid, reason='Source service preserved only where whole-journey date/window coverage is incomplete',
                                             start_seconds=a, end_seconds=b)
                if wiki and tid in wiki.get('trips', {}):
                    wiki['trips'][clone] = dict(wiki['trips'][tid], retained_legacy_window=dict(start=a, end=b))
                legacy_clones += 1
        report = dict(version=1, accepted_paths=dict(accepted), new_connections=len(whole_tids),
                      accepted_pairs={system: len(pairs) for system, pairs in accepted_pairs.items()},
                      mixed_cached_responses=len(mixed_files),
                      mixed_requested_id_pairs=len(mixed_files), mixed_physical_pairs_observed=len(physical_pair_keys),
                      mixed_equivalent_alias_requests=len(equivalent_aliases), mixed_equivalent_aliases=equivalent_aliases,
                      mixed_expected_id_pairs=(len(verified_stations['HR']) * len(verified_stations['LR']) * 2) if verified_stations else 0,
                      mixed_expected_metadata_physical_pairs=((len(verified_stations['HR']) - len(metadata_aliases)) * len(verified_stations['LR']) * 2) if verified_stations else 0,
                      original_lr_templates=len(timetable.lrrows), replaced_lr_templates=len(removed),
                      removed_lr_templates=len(timetable.lrrows) - sum(retained.values()),
                      retained_lr_source_templates=sum(retained.values()), retained_lr_window_templates=legacy_clones,
                      retained_reasons=dict(retained), new_whole_connections=len(whole_tids),
                      original_frequency_window_seconds=original_window_seconds, retained_frequency_window_seconds=retained_window_seconds,
                      retained_lr_unique_segments=len(retained_edges),
                      retained_lr_api_derived_segments=sum(k in proof.get('segments', {}) for k in retained_edges),
                      retained_lr_model_segments=sum(k not in proof.get('segments', {}) for k in retained_edges),
                      rejected_paths=len(rejected), rejection_reasons=dict(collections.Counter(r['reason'] for r in rejected)),
                      rejected=rejected, first_boarding_phase_sources=dict(phases),
                      source_files=source_files,
                      policy='Whole endpoint operator estimates; no extra internal wait and no interpolated intermediate timestamps. Frequency phases may retain explicitly labelled source-feed estimates. Legacy services remain where full dated availability is not replaced.')
        proof.update(light_rail_whole_journey_version=1, light_rail_whole_journey=report,
                     od_connections=len(proof['od_trips']), od_paths=len(proof['od_journeys']),
                     policy='Whole endpoint MTR, Light Rail and mixed-system cached API journeys preferred within verified dated timetable windows. No added internal transfer wait. Limited legacy Light Rail timing is retained only outside covered windows and for unsupported special services.',
                     semantics='Operator journey estimates, not live arrivals or measured running times. Unknown intermediate times remain null. Timetable frequencies and first-boarding phases remain separately sourced or explicitly labelled estimates. Whole connections may contain multiple lines and supplied walks; they are not physical through trains.')
        # Source attribution must follow replacement trips rather than retaining
        # foreign keys to removed timetable templates. Route-level credit keeps
        # every contributing wiki line without millions of duplicate trip rows.
        attributions = [r for r in timetable.attributions if r.get('trip_id') not in removed]
        by_attribution_trip = collections.defaultdict(list)
        for r in timetable.attributions:
            if r.get('trip_id'):
                by_attribution_trip[r['trip_id']].append(r)
        for clone, info in legacy_aliases.items():
            for r in by_attribution_trip[info['original_trip']]:
                aid = 'LRLEGACY:' + hashlib.sha256((clone + ':' + r.get('attribution_id', '')).encode()).hexdigest()[:24]
                attributions.append(dict(r, attribution_id=aid, trip_id=clone))
        for rid in newroutes:
            credits = [('MTR Corporation (whole journey estimates)', 'https://www.mtr.com.hk/en/customer/jp/index.php', '1')]
            credits += [('Hong Kong Railway Wiki contributors (line timetables)', url, '0') for url in sorted(route_sources[rid])]
            for organization, url, operator in credits:
                aid = 'LRAPI:SOURCE:' + hashlib.sha256((rid + ':' + url).encode()).hexdigest()[:24]
                attributions.append(dict(attribution_id=aid, organization_name=organization, is_producer='1',
                                         is_operator=operator, is_authority='0', attribution_url=url, route_id=rid, trip_id=''))
        report['attributions_added'] = len(attributions) - sum(r.get('trip_id') not in removed for r in timetable.attributions)
        report['orphan_attributions_replaced'] = sum(r.get('trip_id') in removed for r in timetable.attributions)
        temporary = path.with_suffix('.lr.tmp')
        replaced = {'routes.txt', 'trips.txt', 'stop_times.txt', 'frequencies.txt', 'calendar_dates.txt', 'attributions.txt', 'mtr_api_provenance.json', 'rail_wiki_provenance.json'}
        with zipfile.ZipFile(temporary, 'w', zipfile.ZIP_DEFLATED) as target:
            for name in archive.namelist():
                if name not in replaced:
                    with archive.open(name) as src, target.open(name, 'w') as dst:
                        shutil.copyfileobj(src, dst)
            for name, original, additions in [('routes.txt', timetable.routes, list(newroutes.values())),
                                                ('trips.txt', [t for t in timetable.trips if t['trip_id'] not in removed], newtrips),
                                                ('frequencies.txt', [f for f in timetable.frequencies if f['trip_id'] not in removed], newfreq),
                                                ('calendar_dates.txt', timetable.dates, newdates),
                                                ('attributions.txt', [], attributions)]:
                fields = list(dict.fromkeys(k for row in original + additions for k in row))
                target.writestr(name, encode(original + additions, fields))
            with archive.open('stop_times.txt') as src, target.open('stop_times.txt', 'w') as dst:
                reader = csv.DictReader(io.TextIOWrapper(src, encoding='utf-8-sig'))
                stream = io.TextIOWrapper(dst, encoding='utf-8', newline='')
                writer = csv.DictWriter(stream, reader.fieldnames, lineterminator='\n', extrasaction='ignore')
                writer.writeheader()
                for row in reader:
                    if row['trip_id'] not in removed:
                        writer.writerow(row)
                writer.writerows(newrows)
                stream.flush()
                stream.detach()
            target.writestr('mtr_api_provenance.json', json.dumps(proof, ensure_ascii=False))
            if wiki:
                target.writestr('rail_wiki_provenance.json', json.dumps(wiki, ensure_ascii=False))
    # Independent endpoint checks before publishing this candidate.
    validate_connections(temporary, whole_tids)
    temporary.replace(path)
    return report


def validate_connections(path, tids):
    with zipfile.ZipFile(path) as z:
        proof = json.loads(z.read('mtr_api_provenance.json'))
        # Attribution and trip-specific transfers are standard GTFS foreign
        # keys, unlike our historical provenance references. Validate them
        # independently so deleting a source template cannot orphan a credit
        # or silently discard a service constraint.
        route_ids = {r['route_id'] for r in csv.DictReader(io.TextIOWrapper(z.open('routes.txt'), encoding='utf-8-sig'))}
        referenced_trips = set(tids)
        attribution_ids = set()
        for name, trip_fields, route_fields in [('attributions.txt', ('trip_id',), ('route_id',)),
                                                ('transfers.txt', ('from_trip_id', 'to_trip_id'), ('from_route_id', 'to_route_id'))]:
            if name not in z.namelist():
                continue
            for row in csv.DictReader(io.TextIOWrapper(z.open(name), encoding='utf-8-sig')):
                referenced_trips.update(row[k] for k in trip_fields if row.get(k))
                for key in route_fields:
                    if row.get(key) and row[key] not in route_ids:
                        raise ValueError(f'Orphan {name} {key}: {row[key]}')
                if name == 'attributions.txt' and row.get('attribution_id'):
                    aid = row['attribution_id']
                    if aid in attribution_ids:
                        raise ValueError('Duplicate attribution ID ' + aid)
                    attribution_ids.add(aid)
        for row in csv.DictReader(io.TextIOWrapper(z.open('trips.txt'), encoding='utf-8-sig')):
            referenced_trips.discard(row['trip_id'])
        if referenced_trips:
            raise ValueError('Orphan trip reference: ' + min(referenced_trips))
        first = {}
        count = 0
        for row in csv.DictReader(io.TextIOWrapper(z.open('stop_times.txt'), encoding='utf-8-sig')):
            tid = row['trip_id']
            if tid not in tids:
                continue
            if row['stop_sequence'] == '1':
                if tid in first:
                    raise ValueError('Repeated first call ' + tid)
                first[tid] = row
                continue
            a = first.pop(tid)
            j = proof['od_journeys'][proof['od_trips'][tid]['journey']]
            if row['stop_sequence'] != '2' or seconds(row['arrival_time']) - seconds(a['departure_time']) != j['api_total_seconds']:
                raise ValueError('Whole endpoint time mismatch ' + tid)
            if (a['stop_id'], row['stop_id']) != (j['stop_ids'][0], j['stop_ids'][-1]):
                raise ValueError('Whole endpoint stop mismatch ' + tid)
            if (a['pickup_type'], a['drop_off_type'], row['pickup_type'], row['drop_off_type']) != ('0', '1', '1', '0'):
                raise ValueError('Invalid endpoint pickup/dropoff ' + tid)
            count += 1
        if first or count != len(tids):
            raise ValueError('Missing whole endpoint calls')
    return count


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=pathlib.Path, required=True)
    parser.add_argument('--input', type=pathlib.Path, required=True)
    parser.add_argument('--mixed-cache', type=pathlib.Path)
    args = parser.parse_args()
    result = compile_light_rail(args.root, args.input, args.mixed_cache)
    print(json.dumps({k: v for k, v in result.items() if k not in ('rejected', 'source_files')}, indent=2))
