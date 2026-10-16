import Foundation

// Ephemeral HTTPS requests: no cookies, disk cache, redirects or credential logging.
final class DirectRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
	func urlSession(
		_ session: URLSession, task: URLSessionTask,
		willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
		completionHandler: @escaping (URLRequest?) -> Void
	) { completionHandler(nil) }
}
enum DirectAPI {
	static let session: URLSession = {
		let config = URLSessionConfiguration.ephemeral
		config.timeoutIntervalForRequest = 25
		config.timeoutIntervalForResource = 45
		config.httpShouldSetCookies = false
		return URLSession(configuration: config, delegate: DirectRedirectGuard(), delegateQueue: nil)
	}()
	static func json(_ url: URL, body: [String: Any]? = nil, key: String? = nil, fields: String? = nil)
		async throws -> [String: Any]
	{
		guard url.scheme == "https", let host = url.host,
			[
				"places.googleapis.com", "routes.googleapis.com", "rt.data.gov.hk",
				"data.etabus.gov.hk",
			].contains(host)
		else {
			throw APIError(message: "Unsupported service address.")
		}
		var request = URLRequest(url: url)
		if let body {
			request.httpMethod = "POST"
			request.httpBody = try JSONSerialization.data(withJSONObject: body)
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		}
		if let key {
			guard host.hasSuffix("googleapis.com") else {
				throw APIError(message: "Invalid key destination.")
			}
			request.setValue(key, forHTTPHeaderField: "X-Goog-Api-Key")
			request.setValue(
				Bundle.main.bundleIdentifier, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
		}
		if let fields { request.setValue(fields, forHTTPHeaderField: "X-Goog-FieldMask") }
		let (data, response) = try await session.data(for: request)
		guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
			let status = (response as? HTTPURLResponse)?.statusCode ?? 0
			throw APIError(
				message:
					"Service request failed (HTTP \(status)). Check internet access, API activation, key restrictions and quota in Settings."
			)
		}
		guard data.count < 12_000_000,
			let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
		else {
			throw APIError(message: "The service returned an unreadable response.")
		}
		return object
	}
}

@MainActor
struct GooglePlacesService {
	func search(_ text: String) async throws -> [Place] {
		guard let key = try DeviceAPIKeys.google(), !key.isEmpty else {
			throw APIError(message: "Add your Google Maps key in Settings to search places.")
		}
		let object = try await DirectAPI.json(
			URL(string: "https://places.googleapis.com/v1/places:searchText")!,
			body: [
				"textQuery": text, "languageCode": "en", "regionCode": "HK", "pageSize": 8,
				"locationRestriction": [
					"rectangle": [
						"low": ["latitude": 22.08, "longitude": 113.8],
						"high": ["latitude": 22.6, "longitude": 114.5],
					]
				],
			], key: key,
			fields:
				"places.displayName,places.formattedAddress,places.location,places.attributions"
		)
		return (object["places"] as? [[String: Any]] ?? []).compactMap { item in
			guard let point = item["location"] as? [String: Double], let lat = point["latitude"],
				let lon = point["longitude"],
				let title = (item["displayName"] as? [String: Any])?["text"] as? String
			else { return nil }
			let place = Place(
				name: title, lat: lat, lon: lon, address: item["formattedAddress"] as? String,
				source: "Google Maps",
				attributions: (item["attributions"] as? [[String: Any]] ?? []).compactMap {
					guard let provider = $0["provider"] as? String, !provider.isEmpty
					else { return nil }
					return Place.Attribution(
						provider: provider, uri: $0["providerUri"] as? String)
				})
			return place.isInHongKong ? place : nil
		}
	}
}

@MainActor
final class GoogleRouteService: RouteServing {
	let usesDirectAPIs = true
	private let readKey: @MainActor () throws -> String?
	private let send: @MainActor (URL, [String: Any], String, String) async throws -> [String: Any]
	init(
		readKey: @escaping @MainActor () throws -> String? = { try DeviceAPIKeys.google() },
		send:
			@escaping @MainActor (URL, [String: Any], String, String) async throws -> [String:
			Any] = { try await DirectAPI.json($0, body: $1, key: $2, fields: $3) }
	) {
		self.readKey = readKey
		self.send = send
	}
	private var results: [String: [Journey]] = [:]
	func status() async throws -> RoutingStatus {
		RoutingStatus(
			ready: true, minDate: JourneyTime.departure(Date().addingTimeInterval(-60)),
			maxDate: JourneyTime.departure(Date().addingTimeInterval(7 * 86400)))
	}
	func start(_ request: RouteRequest) async throws -> String {
		guard request.stops.count == 2, request.order == "ordered" else {
			throw APIError(
				message:
					"Multi-stop planning requires w8g server mode. Choose one starting point and one destination here."
			)
		}
		guard Set(request.modes).isSubset(of: ["mtr", "bus", "tram"]) else {
			throw APIError(message: "Choose MTR, bus or tram preferences for Google routing.")
		}
		if results[request.key] != nil { return request.key }
		guard let key = try readKey(), !key.isEmpty else {
			throw APIError(message: "Add your Google Maps key in Settings to plan a route.")
		}
		func waypoint(_ place: Place) -> [String: Any] {
			["location": ["latLng": ["latitude": place.lat, "longitude": place.lon]]]
		}
		var body: [String: Any] = [
			"origin": waypoint(request.stops[0]), "destination": waypoint(request.stops[1]),
			"travelMode": request.modes.isEmpty ? "WALK" : "TRANSIT",
			"computeAlternativeRoutes": true, "languageCode": "en", "units": "METRIC",
		]
		if !request.modes.isEmpty {
			body["departureTime"] = request.departure
			var modes: [String] = []
			if request.modes.contains("bus") { modes.append("BUS") }
			if request.modes.contains("mtr") { modes += ["SUBWAY", "TRAIN"] }
			if request.modes.contains("light_rail") || request.modes.contains("tram") {
				modes.append("LIGHT_RAIL")
			}
			var preferences: [String: Any] = [:]
			if !modes.isEmpty && !request.modes.contains("ferry")
				&& !request.modes.contains("funicular")
			{
				preferences["allowedTravelModes"] = modes
			}
			if request.preference == "walking" {
				preferences["routingPreference"] = "LESS_WALKING"
			}
			if request.preference == "transfers" {
				preferences["routingPreference"] = "FEWER_TRANSFERS"
			}
			body["transitPreferences"] = preferences
		}
		let json = try await send(
			URL(string: "https://routes.googleapis.com/directions/v2:computeRoutes")!, body, key,
			"routes.duration,routes.legs.duration,routes.legs.steps.travelMode,routes.legs.steps.staticDuration,routes.legs.steps.distanceMeters,routes.legs.steps.startLocation,routes.legs.steps.endLocation,routes.legs.steps.transitDetails"
		)
		let journeys = try Self.decode(json, request: request)
		guard !journeys.isEmpty else {
			throw APIError(
				message:
					"Google Maps found no route. Try another departure or transport selection."
			)
		}
		if results.count > 10 { results.removeAll() }
		results[request.key] = journeys
		return request.key
	}
	func job(_ id: String) async throws -> RouteJob {
		guard let routes = results[id] else {
			throw APIError(message: "This Google search has expired. Search again.")
		}
		return RouteJob(id: id, state: "succeeded", progress: nil, error: nil, routes: routes)
	}
	static func decode(_ json: [String: Any], request: RouteRequest) throws -> [Journey] {
		func seconds(_ value: Any?) -> Double {
			Double((value as? String ?? "0s").replacingOccurrences(of: "s", with: "")) ?? 0
		}
		return try (json["routes"] as? [[String: Any]] ?? []).enumerated().compactMap { index, item in
			var cursor = JourneyTime.parse(request.departure) ?? Date()
			var legs: [[String: Any]] = []
			for leg in item["legs"] as? [[String: Any]] ?? [] {
				for step in leg["steps"] as? [[String: Any]] ?? [] {
					let transit = step["transitDetails"] as? [String: Any]
					let times = transit?["stopDetails"] as? [String: Any] ?? [:]
					let line = transit?["transitLine"] as? [String: Any] ?? [:]
					let duration = seconds(step["staticDuration"] ?? step["duration"])
					let start =
						JourneyTime.parse(times["departureTime"] as? String) ?? cursor
					let end =
						JourneyTime.parse(times["arrivalTime"] as? String)
						?? start.addingTimeInterval(duration)
					func point(_ field: String, stop: String, fallback: String)
						-> [String: Any]
					{
						let details = times[stop] as? [String: Any] ?? [:]
						let location =
							(details["location"] ?? step[field]) as? [String: Any]
							?? [:]
						let latLng = location["latLng"] as? [String: Double] ?? [:]
						return [
							"name": details["name"] as? String ?? fallback,
							"lat": latLng["latitude"] ?? request.stops[0].lat,
							"lon": latLng["longitude"] ?? request.stops[0].lon,
						]
					}
					let vehicle =
						(line["vehicle"] as? [String: Any])?["type"] as? String
						?? "BUS"
					let mode =
						transit == nil
						? "WALK"
						: ([
							"SUBWAY", "HEAVY_RAIL", "METRO_RAIL", "RAIL",
							"COMMUTER_TRAIN", "HIGH_SPEED_TRAIN",
						].contains(vehicle)
							? "RAIL"
							: vehicle == "FERRY"
								? "FERRY"
								: ["TRAM", "LIGHT_RAIL"].contains(vehicle)
									? "TRAM" : "BUS")
					let operators = line["agencies"] as? [[String: Any]] ?? []
					var row: [String: Any] = [
						"mode": mode, "transitLeg": transit != nil,
						"duration": max(0, end.timeIntervalSince(start)),
						"distance": step["distanceMeters"] as? Double ?? 0,
						"from": point(
							"startLocation", stop: "departureStop",
							fallback: legs.isEmpty
								? request.stops[0].name : "Walk"),
						"to": point(
							"endLocation", stop: "arrivalStop", fallback: "Walk"),
						"start": ["scheduledTime": JourneyTime.departure(start)],
						"end": ["scheduledTime": JourneyTime.departure(end)],
						"waitBeforeSeconds": max(0, start.timeIntervalSince(cursor)),
					]
					if transit != nil {
						row["route"] = [
							"shortName": line["nameShort"] as? String ?? line[
								"name"] as? String ?? "Transit",
							"longName": line["name"] as? String ?? "Transit",
							"operatorName": operators.compactMap {
								$0["name"] as? String
							}.joined(separator: " / "),
							"displayColor": (line["color"] as? String ?? "555555")
								.replacingOccurrences(of: "#", with: ""),
						]
						row["headsign"] = transit?["headsign"] as? String ?? ""
					}
					// Adjacent walking instructions are one walking leg in the compact flow.
					if transit == nil, var previous = legs.last,
						previous["mode"] as? String == "WALK"
					{
						previous["to"] = row["to"]
						previous["end"] = row["end"]
						previous["duration"] =
							(previous["duration"] as? Double ?? 0) + duration
						previous["distance"] =
							(previous["distance"] as? Double ?? 0)
							+ (row["distance"] as? Double ?? 0)
						legs[legs.count - 1] = previous
					} else {
						legs.append(row)
					}
					cursor = end
				}
			}
			guard !legs.isEmpty else { return nil }
			// Walking segment endpoint labels come from the adjacent verified stop.
			for i in legs.indices where legs[i]["mode"] as? String == "WALK" {
				var from = legs[i]["from"] as? [String: Any] ?? [:]
				var to = legs[i]["to"] as? [String: Any] ?? [:]
				from["name"] =
					i == 0
					? request.stops[0].name
					: (legs[i - 1]["to"] as? [String: Any])?["name"]
				to["name"] =
					i == legs.count - 1
					? request.stops[1].name
					: (legs[i + 1]["from"] as? [String: Any])?["name"]
				legs[i]["from"] = from
				legs[i]["to"] = to
			}
			// Preserve w8g's convention: consecutive MTR lines count as one ride.
			var rides = 0
			var lastWasMTR = false
			for leg in legs where leg["transitLeg"] as? Bool == true {
				let route = leg["route"] as? [String: Any] ?? [:]
				let name = route["shortName"] as? String ?? ""
				let isMTR =
					leg["mode"] as? String == "RAIL"
					&& MTRLineStyle.line(named: name) != nil
				if !isMTR || !lastWasMTR { rides += 1 }
				lastWasMTR = isMTR
			}
			let value: [String: Any] = [
				"id": "google_" + request.key + "_\(index)",
				"stops": try JSONSerialization.jsonObject(
					with: JSONEncoder().encode(request.stops)),
				"legs": legs,
				"duration": max(
					0,
					cursor.timeIntervalSince(
						JourneyTime.parse(
							(legs.first?["start"] as? [String: String])?[
								"scheduledTime"]) ?? cursor)),
				"departure": request.departure,
				"start": (legs.first?["start"] as? [String: String])?["scheduledTime"]
					?? request.departure,
				"end": JourneyTime.departure(cursor), "transfers": max(0, rides - 1),
				"source": "Google Maps",
				"walkDistance": legs.filter { $0["mode"] as? String == "WALK" }.reduce(0.0) {
					$0 + ($1["distance"] as? Double ?? 0)
				},
			]
			return try JSONDecoder().decode(
				Journey.self, from: JSONSerialization.data(withJSONObject: value))
		}
	}
}
