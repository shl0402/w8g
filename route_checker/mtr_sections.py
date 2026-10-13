"""Expose train sections without changing the exact whole-journey routing cost.

The GTFS OD connection is deliberately atomic. These sections are presentation
data, not extra OTP boardings or independently timed trains. Boundary offsets
come from the cached MTR path and already include internal interchange time.
"""
import copy

# Same official MTR journey-planner palette used by the native client.
# https://www.mtr.com.hk/en/customer/css/common.css (.farec-rdetail-from-to)
MTR_LINES = {
	'AEL': ('Airport Express', '1C7670'),
	'TWL': ('Tsuen Wan Line', 'FF0000'),
	'KTL': ('Kwun Tong Line', '1A9431'),
	'ISL': ('Island Line', '0860A8'),
	'TCL': ('Tung Chung Line', 'FE7F1D'),
	'TKL': ('Tseung Kwan O Line', '6B208B'),
	'DRL': ('Disneyland Resort Line', 'F550A6'),
	'EAL': ('East Rail Line', '5EB6E4'),
	'SIL': ('South Island Line', 'B5BD00'),
	'TML': ('Tuen Ma Line', '923011'),
}


def rail_sections(leg, journey):
	calls = leg.get('stopCalls') or []
	ids = journey.get('stop_ids') or []
	times = journey.get('seconds') or []
	if len(calls) < 2 or len(calls) != len(ids) or len(times) != len(ids):
		return []
	if journey.get('sections'):
		return explicit_sections(leg, journey, calls)
	lines = [sid.rsplit(':', 1)[-1] for sid in ids]
	if any(line not in MTR_LINES for line in lines):
		return []
	changes = journey.get('interchanges') or []
	boundaries = {i for i in range(1, len(ids) - 1) if lines[i] != lines[i - 1]}
	# Same-line branch changes still require a different train.
	boundaries.update(i for i in range(1, len(ids) - 1)
		if any(c.get('stop_id') == ids[i] and c.get('seconds') == times[i] for c in changes))
	if not boundaries:
		return []
	indices = [0, *sorted(boundaries), len(ids) - 1]
	sections = []
	for a, b in zip(indices, indices[1:]):
		part = copy.deepcopy(leg)
		part.pop('railSections', None)
		part['route'] = dict(leg.get('route') or {}, shortName=lines[a], longName=lines[a])
		# Never carry the parent connection's colour to another line.
		for key in ('displayColor', 'badgeColor', 'textColor'):
			part['route'].pop(key, None)
		name, color = MTR_LINES[lines[a]]
		part['route'].update(longName=name, displayColor=color, badgeColor=color,
			textColor='20231D' if lines[a] in ('EAL', 'SIL', 'TCL') else 'FFFFFF')
		part['stopCalls'] = copy.deepcopy(calls[a:b + 1])
		part['from'] = copy.deepcopy(leg['from'] if a == 0 else calls[a]['stopLocation'])
		part['to'] = copy.deepcopy(leg['to'] if b == len(ids) - 1 else calls[b]['stopLocation'])
		part['start'] = leg['start'] if a == 0 else {'scheduledTime': calls[a]['schedule']['time']['arrival']}
		part['end'] = leg['end'] if b == len(ids) - 1 else {'scheduledTime': calls[b]['schedule']['time']['arrival']}
		part['duration'] = times[b] - times[a]
		part['distance'] = None  # No measured per-section distance in this API.
		part['legGeometry'] = None
		part['apiPath'] = leg['apiPath'][a:b + 1]
		part['internalTransfers'] = 0
		part['waitBeforeSeconds'] = leg.get('waitBeforeSeconds', 0) if a == 0 else 0
		part['headsign'] = None
		part['journeyInstructions'] = []
		part['sectionTimingBasis'] = 'MTR cumulative path offsets; internal interchange time included'
		sections.append(part)
	return sections


def explicit_sections(leg, journey, calls):
	"""Use published section boundaries; null intermediate timestamps stay null."""
	result = []
	for section in journey['sections']:
		a, b = section['from_index'], section['to_index']
		start, end = section['start_seconds'], section['end_seconds']
		if not 0 <= a < b < len(calls) or start is None or end is None or end < start:
			return []
		part = copy.deepcopy(leg)
		part.pop('railSections', None)
		system = section.get('system')
		walk = system == 'WALK' or section.get('mode') == 'WALK'
		options = section.get('line_options', [])
		codes = list(dict.fromkeys(str(o['line']) for o in options if o.get('line')))
		label = ' / '.join(codes) or ('Walk' if walk else 'MTR' if system == 'HR' else 'Light Rail')
		part['route'] = dict(leg.get('route') or {}, shortName=label, longName=label)
		for key in ('displayColor', 'badgeColor', 'textColor'):
			part['route'].pop(key, None)
		if len(codes) == 1 and codes[0] in MTR_LINES:
			name, color = MTR_LINES[codes[0]]
			part['route'].update(longName=name, displayColor=color, badgeColor=color,
				textColor='20231D' if codes[0] in ('EAL', 'SIL', 'TCL') else 'FFFFFF')
		part.update(mode='WALK' if walk else 'TRAM' if system == 'LR' else 'SUBWAY',
			transportGroup='WALK' if walk else 'light_rail' if system == 'LR' else 'mtr',
			transportLabel='Walk' if walk else 'Light Rail' if system == 'LR' else 'MTR',
			transitLeg=not walk, duration=end-start, distance=None, legGeometry=None,
			internalTransfers=0, waitBeforeSeconds=leg.get('waitBeforeSeconds', 0) if not result else 0,
			headsign=None, journeyInstructions=[], lineOptions=options,
			sectionTimingBasis='Operator section times; part of one complete cached journey')
		part['stopCalls'] = copy.deepcopy(calls[a:b + 1])
		part['from'] = copy.deepcopy(leg['from'] if a == 0 else calls[a]['stopLocation'])
		part['to'] = copy.deepcopy(leg['to'] if b == len(calls)-1 else calls[b]['stopLocation'])
		part['start'] = leg['start'] if a == 0 else {'scheduledTime': calls[a]['schedule']['time']['arrival']}
		part['end'] = leg['end'] if b == len(calls)-1 else {'scheduledTime': calls[b]['schedule']['time']['arrival']}
		part['apiPath'] = leg['apiPath'][a:b + 1]
		result.append(part)
	if not result or sum(p['duration'] for p in result) != journey['api_total_seconds']:
		return []
	return result
