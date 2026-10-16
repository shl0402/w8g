import Foundation

struct ArrivalStop: Identifiable, Hashable, Codable {
	let id: String
	let name: String
	let direction: String
	let service: String
	let sequence: Int
	var identity: String { id + direction + service + String(sequence) }
}
struct ArrivalRow: Identifiable {
	let id = UUID()
	let time: Date?
	let destination: String
	let detail: String
	var direction: String = ""
	var destinationCode: String?
}
struct ArrivalResult {
	let rows: [ArrivalRow]
	let updated: Date?
	let message: String
}
enum ArrivalProvider: String, CaseIterable, Identifiable, Codable {
	case mtr = "MTR"
	case kmb = "KMB / LWB"
	case citybus = "Citybus"
	var id: String { rawValue }
}

// Source: https://opendata.mtr.com.hk/doc/Next_Train_DataDictionary_v1.7.pdf
// Official Next Train station codes, dictionary v1.7. No coordinate-based station guessing.
enum MTRStations {
	static let lines: [String: String] = [
		"TKL":
			"NOP:North Point|QUB:Quarry Bay|YAT:Yau Tong|TIK:Tiu Keng Leng|TKO:Tseung Kwan O|LHP:LOHAS Park|HAH:Hang Hau|POA:Po Lam",
		"ISL":
			"KET:Kennedy Town|HKU:HKU|SYP:Sai Ying Pun|SHW:Sheung Wan|CEN:Central|ADM:Admiralty|WAC:Wan Chai|CAB:Causeway Bay|TIH:Tin Hau|FOH:Fortress Hill|NOP:North Point|QUB:Quarry Bay|TAK:Tai Koo|SWH:Sai Wan Ho|SKW:Shau Kei Wan|HFC:Heng Fa Chuen|CHW:Chai Wan",
		"TWL":
			"CEN:Central|ADM:Admiralty|TST:Tsim Sha Tsui|JOR:Jordan|YMT:Yau Ma Tei|MOK:Mong Kok|PRE:Prince Edward|SSP:Sham Shui Po|CSW:Cheung Sha Wan|LCK:Lai Chi Kok|MEF:Mei Foo|LAK:Lai King|KWF:Kwai Fong|KWH:Kwai Hing|TWH:Tai Wo Hau|TSW:Tsuen Wan",
		"KTL":
			"WHA:Whampoa|HOM:Ho Man Tin|YMT:Yau Ma Tei|MOK:Mong Kok|PRE:Prince Edward|SKM:Shek Kip Mei|KOT:Kowloon Tong|LOF:Lok Fu|WTS:Wong Tai Sin|DIH:Diamond Hill|CHH:Choi Hung|KOB:Kowloon Bay|NTK:Ngau Tau Kok|KWT:Kwun Tong|LAT:Lam Tin|YAT:Yau Tong|TIK:Tiu Keng Leng",
		"TCL":
			"HOK:Hong Kong|KOW:Kowloon|OLY:Olympic|NAC:Nam Cheong|LAK:Lai King|TSY:Tsing Yi|SUN:Sunny Bay|TUC:Tung Chung",
		"AEL": "HOK:Hong Kong|KOW:Kowloon|TSY:Tsing Yi|AIR:Airport|AWE:AsiaWorld-Expo",
		"DRL": "SUN:Sunny Bay|DIS:Disneyland Resort",
		"SIL": "ADM:Admiralty|OCP:Ocean Park|WCH:Wong Chuk Hang|LET:Lei Tung|SOH:South Horizons",
		"EAL":
			"ADM:Admiralty|EXC:Exhibition Centre|HUH:Hung Hom|MKK:Mong Kok East|KOT:Kowloon Tong|TAW:Tai Wai|SHT:Sha Tin|FOT:Fo Tan|RAC:Racecourse|UNI:University|TAP:Tai Po Market|TWO:Tai Wo|FAN:Fanling|SHS:Sheung Shui|LOW:Lo Wu|LMC:Lok Ma Chau",
		"TML":
			"WKS:Wu Kai Sha|MOS:Ma On Shan|HEO:Heng On|TSH:Tai Shui Hang|SHM:Shek Mun|CIO:City One|STW:Sha Tin Wai|CKT:Che Kung Temple|TAW:Tai Wai|HIK:Hin Keng|DIH:Diamond Hill|KAT:Kai Tak|SUW:Sung Wong Toi|TKW:To Kwa Wan|HOM:Ho Man Tin|HUH:Hung Hom|ETS:East Tsim Sha Tsui|AUS:Austin|NAC:Nam Cheong|MEF:Mei Foo|TWW:Tsuen Wan West|KSR:Kam Sheung Road|YUL:Yuen Long|LOP:Long Ping|TIS:Tin Shui Wai|SIH:Siu Hong|TUM:Tuen Mun",
	]
	static func stops(_ line: String) -> [ArrivalStop] {
		(lines[line] ?? "").split(separator: "|").enumerated().map { index, part in
			let pair = part.split(separator: ":", maxSplits: 1).map(String.init)
			return ArrivalStop(
				id: pair[0], name: pair[1], direction: "", service: "", sequence: index)
		}
	}
	static func name(_ code: String) -> String {
		lines.keys.flatMap { stops($0) }.first { $0.id == code }?.name ?? code
	}
}

@MainActor
struct ArrivalService {
	var request: @MainActor (URL) async throws -> [String: Any] = { try await DirectAPI.json($0) }
	func stops(provider: ArrivalProvider, route: String, direction: String) async throws -> [ArrivalStop]
	{
		guard ["O", "I"].contains(direction),
			route.range(of: "^[A-Z0-9]{1,8}$", options: .regularExpression) != nil
		else { throw APIError(message: "Enter a route number, such as 690S.") }
		if provider == .kmb {
			// Keep service type and direction distinct, including joint-operated route variants.
			let routes = try await request(
				URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/route")!)
			let types = Set(
				(routes["data"] as? [[String: Any]] ?? []).filter {
					$0["route"] as? String == route && $0["bound"] as? String == direction
				}.compactMap { $0["service_type"] as? String }
			).filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }.sorted()
			guard !types.isEmpty else { return [] }
			var routeStops: [[String: Any]] = []
			for type in types {
				let list = try await request(
					URL(
						string:
							"https://data.etabus.gov.hk/v1/transport/kmb/route-stop/\(route)/\(direction == "O" ? "outbound" : "inbound")/\(type)"
					)!)
				routeStops += list["data"] as? [[String: Any]] ?? []
			}
			let names = try await request(
				URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/stop")!)
			let dictionary = Dictionary(
				(names["data"] as? [[String: Any]] ?? []).compactMap {
					row -> (String, String)? in
					guard let id = row["stop"] as? String,
						let name = row["name_en"] as? String
					else { return nil }
					return (id, name)
				}, uniquingKeysWith: { a, _ in a })
			return routeStops.filter {
				$0["route"] as? String == route && $0["bound"] as? String == direction
			}.compactMap { row in
				guard let id = row["stop"] as? String else { return nil }
				return ArrivalStop(
					id: id, name: dictionary[id] ?? id, direction: direction,
					service: String(describing: row["service_type"] ?? "1"),
					sequence: Int(String(describing: row["seq"] ?? "0")) ?? 0)
			}.sorted { ($0.service, $0.sequence) < ($1.service, $1.sequence) }
		}
		let base = "https://rt.data.gov.hk/v2/transport/citybus/"
		let list = try await request(
			URL(
				string: base
					+ "route-stop/CTB/\(route)/\(direction == "O" ? "outbound" : "inbound")"
			)!)
		var result: [ArrivalStop] = []
		for row in list["data"] as? [[String: Any]] ?? [] {
			try Task.checkCancellation()
			guard let id = row["stop"] as? String, id.allSatisfy(\.isNumber) else { continue }
			let stop = try await request(URL(string: base + "stop/" + id)!)
			result.append(
				ArrivalStop(
					id: id,
					name: (stop["data"] as? [String: Any])?["name_en"] as? String ?? id,
					direction: direction, service: "",
					sequence: Int(String(describing: row["seq"] ?? "0")) ?? 0))
		}
		return result.sorted { $0.sequence < $1.sequence }
	}
	func fetch(provider: ArrivalProvider, route: String, stop: ArrivalStop) async throws -> ArrivalResult
	{
		if provider == .mtr {
			guard MTRStations.stops(route).contains(where: { $0.id == stop.id }) else {
				throw APIError(message: "Choose a station on this line.")
			}
			let json = try await request(
				URL(
					string:
						"https://rt.data.gov.hk/v1/transport/mtr/getSchedule.php?line=\(route)&sta=\(stop.id)&lang=EN"
				)!)
			return Self.mtrResult(json, line: route, station: stop.id)
		}
		guard route.range(of: "^[A-Z0-9]{1,8}$", options: .regularExpression) != nil,
			stop.id.range(of: "^[A-Fa-f0-9]{1,20}$", options: .regularExpression) != nil,
			["O", "I"].contains(stop.direction), stop.sequence > 0,
			stop.service.isEmpty || stop.service.allSatisfy(\.isNumber)
		else { throw APIError(message: "Choose a valid operator stop.") }
		let path =
			provider == .kmb
			? "https://data.etabus.gov.hk/v1/transport/kmb/eta/\(stop.id)/\(route)/\(stop.service)"
			: "https://rt.data.gov.hk/v2/transport/citybus/eta/CTB/\(stop.id)/\(route)"
		let json = try await request(URL(string: path)!)
		return Self.busResult(json, route: route, stop: stop)
	}
	static func mtrResult(_ json: [String: Any], line route: String, station: String) -> ArrivalResult {
		let data = (json["data"] as? [String: Any])?[route + "-" + station] as? [String: Any] ?? [:]
		let rows = ["UP", "DOWN"].flatMap { direction in
			(data[direction] as? [[String: Any]] ?? []).map { row in
				ArrivalRow(
					time: Self.date(row["time"] as? String),
					destination: MTRStations.name(row["dest"] as? String ?? ""),
					detail: "Platform " + (row["plat"] as? String ?? "—")
						+ (row["route"] as? String == "RAC"
							? " · via Racecourse" : ""), direction: direction, destinationCode: row["dest"] as? String)
			}
		}
		let alert =
			String(describing: json["status"] ?? "0") != "1" || json["isdelay"] as? String == "Y"
		return ArrivalResult(
			rows: rows, updated: Self.date(json["curr_time"] as? String),
			message: alert
				? (json["isdelay"] as? String == "Y"
					? "Service delay reported by MTR."
					: json["message"] as? String ?? "Service alert") : "")
	}
	static func busResult(_ json: [String: Any], route: String, stop: ArrivalStop) -> ArrivalResult {
		let matching = (json["data"] as? [[String: Any]] ?? []).filter {
			$0["route"] as? String == route && $0["dir"] as? String == stop.direction
				&& (Int(String(describing: $0["seq"] ?? "0")) ?? 0) == stop.sequence
				&& (stop.service.isEmpty
					|| String(describing: $0["service_type"] ?? "") == stop.service)
		}
		let rows = matching.map { row in
			ArrivalRow(
				time: Self.date(row["eta"] as? String),
				destination: row["dest_en"] as? String ?? route,
				detail: row["rmk_en"] as? String ?? "")
		}
		return ArrivalResult(
			rows: rows,
			updated: matching.compactMap { Self.date($0["data_timestamp"] as? String) }.min()
				?? Self.date(json["generated_timestamp"] as? String), message: "")
	}
	static func date(_ value: String?) -> Date? {
		guard let value, !value.isEmpty else { return nil }
		if let date = ISO8601DateFormatter().date(from: value) { return date }
		let f = DateFormatter()
		f.locale = Locale(identifier: "en_US_POSIX")
		f.timeZone = TimeZone(identifier: "Asia/Hong_Kong")
		f.dateFormat = "yyyy-MM-dd HH:mm:ss"
		return f.date(from: value)
	}
}
