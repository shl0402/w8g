import Foundation

struct APIError: LocalizedError {
	let message: String
	var errorDescription: String? { message }
}
enum DeviceAPIKeys {
	static func google() throws -> String? { fatalError("Tests must not read real keys") }
}
@MainActor final class APIClient {
	static let shared = APIClient()
	func get<T: Decodable>(_ path: String) async throws -> T {
		fatalError("Direct mode called the server")
	}
	func post<B: Encodable, T: Decodable>(_ path: String, body: B) async throws -> T {
		fatalError("Direct mode called the server")
	}
}

@main struct DirectServiceChecks {
	static func location(_ lat: Double = 22.28, _ lon: Double = 114.15) -> [String: Any] {
		["latLng": ["latitude": lat, "longitude": lon]]
	}
	static func walk(_ seconds: Int) -> [String: Any] {
		[
			"staticDuration": "\(seconds)s", "distanceMeters": 120.0, "startLocation": location(),
			"endLocation": location(),
		]
	}
	static func train(_ code: String, from: String, to: String, depart: String, arrive: String)
		-> [String: Any]
	{
		[
			"staticDuration": "900s",
			"transitDetails": [
				"stopDetails": [
					"departureTime": "2026-10-15T\(depart):00+08:00",
					"arrivalTime": "2026-10-15T\(arrive):00+08:00",
					"departureStop": ["name": from, "location": location()],
					"arrivalStop": ["name": to, "location": location()],
				],
				"transitLine": [
					"nameShort": code, "name": MTRLineStyle.lines[code]?.name ?? code,
					"vehicle": ["type": "SUBWAY"], "agencies": [["name": "MTR"]],
				],
			],
		]
	}
	@MainActor static func main() async throws {
		let a = Place(name: "Origin", lat: 22.28, lon: 114.15)
		let b = Place(name: "Destination", lat: 22.29, lon: 114.16)
		var request = RouteRequest(
			key: "check", stops: [a, b], departure: "2026-10-15T08:00:00+08:00", modes: ["mtr"],
			preference: "fastest")
		let fixture: [String: Any] = [
			"routes": [
				[
					"duration": "4200s",
					"legs": [
						[
							"steps": [
								walk(120), walk(180),
								train(
									"TKL", from: "LOHAS Park",
									to: "North Point", depart: "08:10",
									arrive: "08:25"),
								train(
									"ISL", from: "North Point", to: "HKU",
									depart: "08:27", arrive: "08:50"),
								walk(300),
							]
						]
					],
				]
			]
		]
		let routes = try GoogleRouteService.decode(fixture, request: request)
		let journey = routes[0]
		assert(journey.legs.count == 4 && journey.legs[0].duration == 300)
		assert(journey.legs[1].waitBeforeSeconds == 300 && journey.legs[2].waitBeforeSeconds == 120)
		assert(journey.legs.last?.to.name == "Destination")
		assert(journey.duration == 3300 && journey.transferCount == 0)
		assert(journey.source == "Google Maps" && journey.legs.allSatisfy { $0.coordinates.isEmpty })
		assert(journey.legs[1].lineName == "TKL" && journey.legs[2].lineName == "ISL")
		let seed = ArrivalSelection(leg: journey.legs[2])
		assert(seed.provider == .mtr && seed.line == "ISL" && seed.station == "NOP")
		print(
			"PASS: Google decoding, combined walks, wait times, MTR ride count, no MapLibre geometry"
		)

		var keyReads = 0
		var calls = 0
		let service = GoogleRouteService(readKey: {
			keyReads += 1
			return "test-key"
		}) { url, body, key, fields in
			calls += 1
			assert(url.host == "routes.googleapis.com" && key == "test-key")
			assert(body["departureTime"] as? String == request.departure)
			assert(body["travelMode"] as? String == "TRANSIT")
			assert(
				(body["transitPreferences"] as? [String: Any])?["allowedTravelModes"]
					as? [String] == ["SUBWAY", "TRAIN"])
			assert(!fields.contains("polyline") && body["intermediates"] == nil)
			return fixture
		}
		let planner = RoutePlannerModel(service: service)
		assert(planner.usesDirectAPIs && planner.availableTransports == [.mtr, .bus, .tram])
		assert(planner.editingCopy().usesDirectAPIs)
		_ = try await service.start(request)
		_ = try await service.start(request)
		let job = try await service.job(request.key)
		assert(calls == 1 && keyReads == 1 && job.routes?.count == 1)
		let invalid = RouteRequest(
			key: "bad", stops: [a, b, a], departure: request.departure, modes: ["mtr"],
			preference: "fastest")
		do {
			_ = try await service.start(invalid)
			fatalError("Multi-stop accepted")
		} catch {}
		request = RouteRequest(
			key: "bad-mode", stops: [a, b], departure: request.departure, modes: ["ferry"],
			preference: "fastest")
		do {
			_ = try await service.start(request)
			fatalError("Unsupported filter accepted")
		} catch {}
		assert(calls == 1 && keyReads == 1)
		print(
			"PASS: direct provider isolation, exact Google request, cached retry, multi-stop/filter rejection before network"
		)

		let mtr: [String: Any] = [
			"status": 1, "isdelay": "Y", "curr_time": "2026-10-15 08:00:00",
			"message": "successful",
			"data": [
				"ISL-HKU": [
					"UP": [["time": "2026-10-15 08:03:00", "dest": "CHW", "plat": "1"]],
					"DOWN": [],
				]
			],
		]
		let rail = ArrivalService.mtrResult(mtr, line: "ISL", station: "HKU")
		assert(rail.rows.count == 1 && rail.rows[0].destination == "Chai Wan")
		assert(
			rail.rows[0].time!.timeIntervalSince(rail.updated!) == 180
				&& rail.message.contains("delay"))
		assert(ArrivalService.mtrResult(["status": 0], line: "ISL", station: "HKU").rows.isEmpty)
		assert(
			ArrivalService.date("2026-10-15 08:03:00")
				== ArrivalService.date("2026-10-15T08:03:00+08:00"))
		let stop = ArrivalStop(id: "123ABC", name: "Stop", direction: "O", service: "1", sequence: 2)
		let good: [String: Any] = [
			"route": "690S", "dir": "O", "service_type": 1, "seq": 2, "dest_en": "Central",
			"eta": "2026-10-15T08:04:00+08:00", "data_timestamp": "2026-10-15T07:55:00+08:00",
		]
		var inbound = good
		inbound["dir"] = "I"
		var variant = good
		variant["service_type"] = 2
		var repeated = good
		repeated["seq"] = 8
		var another = good
		another["route"] = "690"
		let bus = ArrivalService.busResult(
			[
				"generated_timestamp": "2026-10-15T08:00:00+08:00",
				"data": [good, inbound, variant, repeated, another],
			], route: "690S", stop: stop)
		assert(bus.rows.count == 1 && bus.rows[0].destination == "Central")
		assert(bus.updated == ArrivalService.date("2026-10-15T07:55:00+08:00"))
		var missing = good
		missing["eta"] = NSNull()
		assert(
			ArrivalService.busResult(["data": [missing]], route: "690S", stop: stop).rows[0].time
				== nil)
		print(
			"PASS: real API-shaped MTR and bus responses, HK timezone, delay, direction/service/sequence filters, stale timestamps, unavailable ETA"
		)

		var urls: [URL] = []
		let api = ArrivalService { url in
			urls.append(url)
			return [:]
		}
		do {
			_ = try await api.fetch(
				provider: .mtr, route: "ISL",
				stop: MTRStations.stops("TKL").first { $0.id == "LHP" }!)
			fatalError("Wrong-line station accepted")
		} catch {}
		do {
			_ = try await api.stops(provider: .kmb, route: "../bad", direction: "O")
			fatalError("Invalid route accepted")
		} catch {}
		assert(urls.isEmpty)
		assert(ArrivalSelection(query: "MTR at HKU").station == "HKU")
		assert(ArrivalSelection(query: "MTR at North Point").line.isEmpty)
		assert(ArrivalSelection(query: "MTR Island Line North Point").station == "NOP")
		assert(ArrivalSelection(query: "Citybus 690S at LOHAS Park").provider == .citybus)
		assert(ArrivalSelection(query: "KMB 690S").route == "690S")
		assert(ArrivalSelection(query: "KMB Citybus 690S").provider == nil)
		assert(ArrivalSelection(query: "minibus 11 at Central").line.isEmpty)
		print(
			"PASS: no fabricated station/line or provider mapping, invalid operator input rejected before network"
		)
	}
}
