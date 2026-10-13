#!/usr/bin/env python3
"""Count physical/public lines by timing evidence in a specific built feed.

Generated OD connections and duration buckets never count as new public lines.
Categories overlap: one line can have both sourced and modelled trip variants.
"""
import argparse
from collections import defaultdict
from datetime import date, timedelta
import json
from pathlib import Path
import zipfile

from transit_enrichment.feed import rows, save, sha

LABELS = {'KMB': 'KMB', 'LWB': 'Long Win', 'CTB': 'Citybus', 'KMB+CTB': 'KMB / Citybus',
          'LWB+CTB': 'Long Win / Citybus', 'GMB': 'Green minibus', 'FERRY': 'Ferry',
          'TRAM': 'HK Island tram', 'PTRAM': 'Peak Tram', 'LRTFeeder': 'MTR Bus',
          'NLB': 'New Lantao Bus', 'DB': 'Discovery Bay bus', 'PI': 'Park Island bus', 'XB': 'Cross-boundary bus'}


def active_services(calendars, exceptions, start, end):
    dates = [(start + timedelta(days=i)).strftime('%Y%m%d') for i in range((end-start).days+1)]
    byday = {(r['service_id'], r['date']): r['exception_type'] for r in exceptions}
    names = ('monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday')
    active = {sid for (sid, day), value in byday.items() if start.strftime('%Y%m%d') <= day <= end.strftime('%Y%m%d') and value == '1'}
    for r in calendars:
        if r['service_id'] in active:
            continue
        for d in dates:
            override = byday.get((r['service_id'], d))
            if override == '2':
                continue
            if override == '1' or r['start_date'] <= d <= r['end_date'] and r[names[date(int(d[:4]), int(d[4:6]), int(d[6:])).weekday()]] == '1':
                active.add(r['service_id']); break
    return active


def public_line(route, districts):
    rid = route['route_id']
    if rid.startswith('RAIL:MTR:'):
        return ('MTR', rid.split(':')[2])
    if rid.startswith('RAIL:LRT:'):
        return ('Light Rail', rid.split(':')[2])
    agency = route['agency_id']
    name = route['route_short_name'] or route['route_long_name']
    if agency == 'GMB':
        name = districts.get(rid, 'unresolved region ' + rid) + ':' + name
    return (LABELS.get(agency, agency), name)


def journey_lines(journey):
    result = set()
    for section in journey.get('sections', []):
        if section.get('system') in ('HR', 'LR'):
            result.update(('MTR' if section['system'] == 'HR' else 'Light Rail', str(o['line']))
                          for o in section.get('line_options', []) if o.get('line'))
    if not result:
        for sid in journey.get('stop_ids', []):
            p = sid.split(':')
            if len(p) == 4 and p[:2] in (['RAIL', 'MTR'], ['RAIL', 'LRT']):
                result.add(('MTR' if p[1] == 'MTR' else 'Light Rail', p[3]))
    return result


def summarize(lines):
    groups = defaultdict(list)
    for (group, name), item in sorted(lines.items()):
        groups[group].append(dict(line=name, **{k: sorted(v) if isinstance(v, set) else v for k, v in item.items()}))
    summary = []
    for group, entries in sorted(groups.items()):
        summary.append(dict(transport=group, total_lines=len(entries),
            count_unit='TD named route records' if group == 'Ferry' else 'public lines',
            our_model=sum('model' in x['ride_time_kinds'] for x in entries),
            source_calculated=sum('calculated' in x['ride_time_kinds'] for x in entries),
            source_duration=sum('direct' in x['ride_time_kinds'] for x in entries),
            unknown=sum('unknown' in x['ride_time_kinds'] for x in entries),
            exact_measured=0,
            no_own_ride_model=sum(bool(x['ride_time_kinds']) and not {'model', 'unknown'} & set(x['ride_time_kinds']) for x in entries),
            scheduled_departures=sum('scheduled' in x['departure_kinds'] for x in entries),
            frequency_departures=sum('frequency' in x['departure_kinds'] for x in entries),
            variants=len({r for x in entries for r in x['route_ids']})))
    return summary, dict(groups)


def coverage(root, feed, anchors, start, end):
    root, feed, anchors = Path(root), Path(feed), Path(anchors)
    districts = {}
    source = root / 'data/raw/2026-09-17/td/routes_fares/JSON_GMB.json'
    if source.exists():
        districts = {str(f['properties']['routeId']): f['properties'].get('district', '')
                     for f in json.loads(source.read_text(encoding='utf-8-sig'))['features']}
    lines = defaultdict(lambda: dict(ride_time_kinds=set(), departure_kinds=set(), route_ids=set()))
    unclassified_journeys = set()
    with zipfile.ZipFile(feed) as z:
        load = lambda name: json.loads(z.read(name)) if name in z.namelist() else {}
        rail = load('mtr_api_provenance.json')
        history = load('transit_enrichment_provenance.json').get('history', {})
        kmb = load('kmb_pair_timing_provenance.json')
        ferry = load('operator_timing_provenance.json').get('trips', {})
        services = active_services(list(rows(z, 'calendar.txt')), list(rows(z, 'calendar_dates.txt')), start, end)
        routes = {r['route_id']: r for r in rows(z, 'routes.txt')}
        trips = {t['trip_id']: t for t in rows(z, 'trips.txt') if t['service_id'] in services}
        frequencies = {r['trip_id'] for r in rows(z, 'frequencies.txt') if r.get('exact_times', '0') != '1'}
        # Only non-synthetic source templates need anchor inspection. Keep the
        # millions of rail OD rows out of memory.
        base = defaultdict(list)
        with zipfile.ZipFile(anchors) as a:
            if 'surface_timing_provenance.json' in a.namelist():
                raise ValueError('Coverage anchors must be the stage before surface interpolation')
            for r in rows(a, 'stop_times.txt'):
                tid = r['trip_id']
                if tid in trips and tid not in rail.get('od_trips', {}):
                    base[tid].append(r)
        for tid, trip in trips.items():
            route = routes[trip['route_id']]
            od = rail.get('od_trips', {}).get(tid)
            if od:
                journey = rail['od_journeys'][od['journey']]
                keys = journey_lines(journey)
                if not keys:
                    unclassified_journeys.add(od['journey'])
                kinds = {'direct'}
            else:
                keys = {public_line(route, districts)}
                if tid in kmb.get('trips', {}):
                    # Adjacent durations are supplied; longer journeys sum them.
                    kinds = {'direct', 'calculated'}
                elif tid in ferry:
                    kinds = {'direct'}
                elif trip['route_id'].startswith('RAIL:LRT:'):
                    rr = sorted(base.get(tid, []), key=lambda r: int(r['stop_sequence']))
                    kinds = set()
                    line = trip['route_id'].split(':')[2]
                    for a, b in zip(rr, rr[1:]):
                        key = f'LRT:{line}:{int(a["stop_id"].split(":")[2])}>{int(b["stop_id"].split(":")[2])}'
                        kinds.add('calculated' if key in rail.get('segments', {}) else 'model')
                    if not kinds:
                        kinds = {'unknown'}
                else:
                    rr = sorted(base.get(tid, []), key=lambda r: int(r['stop_sequence']))
                    h = history.get(tid, {})
                    source_spans = [(int(s['start_sequence']), int(s['end_sequence'])) for s in h.get('spans', [])]
                    kinds = set()
                    for a, b in zip(rr, rr[1:]):
                        if a.get('departure_time') and b.get('arrival_time'):
                            kinds.add('calculated')
                        elif any(lo <= int(a['stop_sequence']) and int(b['stop_sequence']) <= hi for lo, hi in source_spans):
                            kinds.add('calculated')
                        else:
                            kinds.add('model')
                    if not kinds:
                        kinds = {'unknown'}
            for key in keys:
                entry = lines[key]
                entry['ride_time_kinds'].update(kinds)
                entry['departure_kinds'].add('frequency' if tid in frequencies else 'scheduled')
                # Buckets and mixed OD links are implementation artefacts.
                if not trip['route_id'].startswith('RAIL:JOURNEY:'):
                    entry['route_ids'].add(trip['route_id'].split(':PATH:')[0])
    summary, detail = summarize(lines)
    return dict(format=1, feed_sha256=sha(feed), anchor_sha256=sha(anchors), date_range=[str(start), str(end)],
        definitions=dict(scope='Lines active at least once in this feed window; bus variants share an operator/number, minibus numbers include region. Joint operators are separate groups. Ferry counts are TD named route records, not a verified distinct-public-service count: some reverse/variant records may describe one service, but operator identities are incomplete.',
            model='Our distance allocation, speed formula or unsupported rail segment timing.',
            calculated='Differences of source stop timestamps, sums of operator-provided segment durations, or source-derived historical ETA proportions; these may still be estimates.',
            direct='Operator-supplied journey/segment duration, used without a distance formula. These are published estimates, not measured exact times.',
            exact='No verified measured exact running-time dataset is used; every exact_measured count is zero.',
            overlap='Timing columns count lines with at least some journeys in that category, and overlap. no_own_ride_model is exclusive of model/unknown.',
            departures='Scheduled means GTFS stop-time departures without an inexact frequency row. It does not prove an actual vehicle departure was measured or independently published.',
            waiting='Counts classify transit-duration sources, not our separate timetable/boarding/walking assumptions. Operator totals may themselves include waiting and interchange walks. External walking, frequency phase and transfer constraints can remain modelled.'),
        summary=summary, lines=detail, unclassified_journeys=sorted(unclassified_journeys))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    p.add_argument('--feed', type=Path); p.add_argument('--anchors', type=Path)
    p.add_argument('--start', type=date.fromisoformat, required=True); p.add_argument('--end', type=date.fromisoformat, required=True)
    a = p.parse_args(); gen = a.root / 'data/generated'
    result = coverage(a.root, a.feed or gen / 'hk-transit-EXPERIMENTAL.gtfs.zip', a.anchors or gen / 'hk-transit-ENRICHED-BASE.gtfs.zip', a.start, a.end)
    save(gen / 'timing-coverage.json', result)
    print(json.dumps(result['summary'], ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
