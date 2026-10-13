from .network import urlopen
import urllib.request, urllib.parse, json, re, time
from .routing import router

# Explicit provider identifiers; no guessing station codes from coordinates.
STATIONS = [
	("Central", "TWL", "CEN", 22.2819, 114.1582),
	("Admiralty", "TWL", "ADM", 22.2793, 114.165),
	("Tsim Sha Tsui", "TWL", "TST", 22.2976, 114.1722),
	("Mong Kok", "TWL", "MOK", 22.3192, 114.1694),
	("Sha Tin", "EAL", "SHT", 22.3818, 114.1875),
	("Hong Kong", "TCL", "HOK", 22.2846, 114.158),
	("Tung Chung", "TCL", "TUC", 22.2893, 113.941),
]


def get(url):
	with urlopen(url, timeout=15) as r:
		return json.load(r)


def arrivals(d):
	station = next((s for s in STATIONS if s[2] == d.get("station")), STATIONS[0])
	source = d.get("source", "gtfs")
	if source == "operator":
		provider = d.get("provider", "mtr")
		if provider == "mtr":
			name, line, code, lat, lon = station
			r = get(
				"https://rt.data.gov.hk/v1/transport/mtr/getSchedule.php?"
				+ urllib.parse.urlencode({"line": line, "sta": code, "lang": "EN"})
			)
			data = r.get("data", {}).get(line + "-" + code, {})
			rows = [
				dict(
					time=x.get("time"),
					destination={
						"TSW": "Tsuen Wan",
						"CEN": "Central",
						"ADM": "Admiralty",
						"LOW": "Lo Wu",
						"LMC": "Lok Ma Chau",
						"HUH": "Hung Hom",
						"SHT": "Sha Tin",
						"TUC": "Tung Chung",
						"HOK": "Hong Kong",
						"AIR": "Airport",
						"AWE": "AsiaWorld-Expo",
						"TIK": "Tiu Keng Leng",
						"WHA": "Whampoa",
						"WKS": "Wu Kai Sha",
						"TUM": "Tuen Mun",
						"CHW": "Chai Wan",
						"KET": "Kennedy Town",
						"NOP": "North Point",
						"POA": "Po Lam",
						"LHP": "LOHAS Park",
					}.get(x.get("dest"), x.get("dest")),
					platform=x.get("plat"),
					direction=direction,
				)
				for direction in ["UP", "DOWN"]
				for x in data.get(direction, [])
			]
			return dict(
				source="MTR Next Train API",
				live=True,
				updated=r.get("curr_time"),
				rows=rows,
				message=r.get("message", "No arrivals returned"),
			)
		stop = d.get("stop", "")
		route = d.get("route", "").upper()
		if not re.fullmatch(r"[A-Fa-f0-9]{16}", stop) or not re.fullmatch(r"[A-Z0-9]{1,8}", route):
			raise ValueError("Enter a 16-character KMB stop ID and route number.")
		r = get(f"https://data.etabus.gov.hk/v1/transport/kmb/eta/{stop}/{route}/1")
		return dict(
			source="KMB ETA API",
			live=True,
			updated=r.get("generated_timestamp"),
			rows=[
				dict(
					time=x.get("eta"),
					destination=x.get("dest_en"),
					direction=x.get("dir"),
					remark=x.get("rmk_en"),
				)
				for x in r.get("data", [])
			],
			message="No ETA available" if not r.get("data") else "",
		)
	from .timetable import get as timetable

	return timetable(station[2])
