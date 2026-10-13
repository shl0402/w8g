"""Read frequency-based GTFS without presenting its synthetic times as live trains."""

import csv, io, zipfile, math, time
from functools import lru_cache
from datetime import datetime, timedelta
from .routing import ROOT, router
from .arrivals import STATIONS


def seconds(s):
	h, m, s = map(int, s.split(":"))
	return h * 3600 + m * 60 + s


@lru_cache(maxsize=1)
def index():
	with zipfile.ZipFile(ROOT / "data/generated/hk-transit-EXPERIMENTAL.gtfs.zip") as z:

		def read(n):
			return csv.DictReader(io.TextIOWrapper(z.open(n), encoding="utf-8-sig"))

		stops = {r["stop_id"]: r for r in read("stops.txt")}
		ids = {}
		for name, line, code, lat, lon in STATIONS:
			ids[code] = {
				k
				for k, s in stops.items()
				if k.startswith("RAIL:MTR:")
				and abs(float(s["stop_lat"]) - lat) < 0.005
				and abs(float(s["stop_lon"]) - lon) < 0.005
				and k.endswith(":" + line)
			}
		wanted = set.union(*ids.values())
		calls = {}
		for r in read("stop_times.txt"):
			if r["stop_id"] in wanted and r.get("pickup_type") != "1":
				calls.setdefault(r["trip_id"], []).append(r)
		trips = {r["trip_id"]: r for r in read("trips.txt") if r["trip_id"] in calls}
		routes = {r["route_id"]: r for r in read("routes.txt")}
		freq = {}
		for r in read("frequencies.txt"):
			if r["trip_id"] in calls:
				freq.setdefault(r["trip_id"], []).append(r)
		calendar = {r["service_id"]: r for r in read("calendar.txt")}
		exceptions = {}
		if "calendar_dates.txt" in z.namelist():
			for r in read("calendar_dates.txt"):
				exceptions[(r["service_id"], r["date"])] = r["exception_type"]
	return ids, calls, trips, routes, freq, calendar, exceptions


def get(code):
	now = datetime.now(router.HK)
	if not router.service_window()[0] <= now < router.service_window()[1]:
		return dict(
			source="Server GTFS timetable",
			live=False,
			updated=now.isoformat(),
			rows=[],
			message="Current date is outside this copied timetable. Rebuild the feed or choose live operator arrivals.",
		)
	ids, calls, trips, routes, freq, calendar, exceptions = index()
	groups = {}
	mid = now.replace(hour=0, minute=0, second=0, microsecond=0)
	for day in [mid - timedelta(days=1), mid]:
		date = day.strftime("%Y%m%d")
		weekday = day.strftime("%A").lower()
		offset = (now - day).total_seconds()
		for trip, rows in calls.items():
			tr = trips.get(trip)
			if not tr:
				continue
			service = tr["service_id"]
			cal = calendar.get(service, {})
			override = exceptions.get((service, date))
			active = cal.get(weekday) == "1" and cal.get(
				"start_date", "99999999"
			) <= date <= cal.get("end_date", "00000000")
			if override:
				active = override == "1"
			if not active:
				continue
			for call in rows:
				if call["stop_id"] not in ids[code]:
					continue
				for f in freq.get(trip, []):
					# This experimental rail feed's eligible boarding calls are at trip origin.
					shift = seconds(call["departure_time"])
					start = seconds(f["start_time"]) + shift
					end = seconds(f["end_time"]) + shift
					if not start <= offset < end:
						continue
					route = routes.get(tr["route_id"], {})
					key = (tr["route_id"], tr.get("direction_id", ""))
					headway = int(f["headway_secs"])
					if key not in groups:
						groups[key] = dict(headways=set(), route=route, start=start, end=end)
					groups[key]["headways"].add(headway)
					groups[key]["start"] = min(groups[key]["start"], start)
					groups[key]["end"] = max(groups[key]["end"], end)
	out = []
	for (route, direction), g in groups.items():
		h = math.ceil(max(g["headways"]) / 60)
		r = g["route"]
		out.append(
			dict(
				time=None,
				estimate=f"~0–{h} min wait",
				destination=r.get("route_long_name") or r.get("route_short_name"),
				direction=(r.get("route_short_name") or "") + " · direction " + direction,
				headwaySeconds=max(g["headways"]),
				serviceHours=f"{g['start'] // 3600:02}:{g['start'] % 3600 // 60:02}–{g['end'] // 3600:02}:{g['end'] % 3600 // 60:02}",
			)
		)
	return dict(
		source="Server GTFS frequency estimate",
		live=False,
		updated=now.isoformat(),
		rows=out[:12],
		message="Frequency-based waiting ranges, not exact train arrival times. Experimental timetable; check live operator information when available."
		if out
		else "No active timetable frequencies for this station at the current time.",
	)
