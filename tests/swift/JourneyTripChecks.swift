import Foundation

@main
struct JourneyTripChecks {
    static func main() throws {
        func place(_ name: String, _ lon: Double) -> [String: Any] {
            ["name": name, "lat": 22.28, "lon": lon]
        }
        let a = place("A", 114.15), middle = place("Station", 114.155)
        let b = place("B", 114.16), c = place("C", 114.17)
        func leg(_ from: [String: Any], _ to: [String: Any], _ start: String, _ end: String) -> [String: Any] {
            ["mode": "WALK", "transitLeg": false, "duration": 300, "distance": 350,
             "from": from, "to": to, "start": ["scheduledTime": start], "end": ["scheduledTime": end]]
        }
        let times = ["2026-10-02T10:00:00+08:00", "2026-10-02T10:05:00+08:00",
                     "2026-10-02T10:10:00+08:00", "2026-10-02T10:15:00+08:00"]
        let legs = [leg(a, middle, times[0], times[1]), leg(middle, b, times[1], times[2]),
                    leg(b, c, times[2], times[3])]
        let trips: [[String: Any]] = [
            ["legStartIndex": 0, "legEndIndex": 2, "duration": 600, "start": times[0], "end": times[2], "transfers": 0, "walkDistance": 700],
            ["legStartIndex": 2, "legEndIndex": 3, "duration": 300, "start": times[2], "end": times[3], "transfers": 0, "walkDistance": 350]
        ]
        var payload: [String: Any] = ["id": "test", "stops": [a, b, c], "legs": legs, "duration": 900, "trips": trips]
        func decode(_ value: [String: Any]) throws -> Journey {
            try JSONDecoder().decode(Journey.self, from: JSONSerialization.data(withJSONObject: value))
        }
        func check(_ journey: Journey) {
            let parts = journey.pointToPointJourneys
            precondition(parts.count == 2)
            precondition(parts.map(\.title) == ["A → B", "B → C"])
            precondition(parts.map { $0.legs.count } == [2, 1])
            precondition(parts.map(\.duration) == [600, 300])
            precondition(parts.map(\.timeRange) == ["10:00–10:10", "10:10–10:15"])
            precondition(parts.map(\.transferCount) == [0, 0])
            precondition(parts.map { $0.walkDistance! } == [700, 350])
            precondition(Set(parts.map(\.id)).count == 2)
            precondition(parts.allSatisfy { $0.pointToPointJourneys.isEmpty })
        }
        let journey = try decode(payload)
        check(journey)
        // Replacing one trip retains every other leg and its scheduled times exactly.
        func alternative(_ from: [String: Any], _ to: [String: Any], _ start: String, _ end: String) throws -> Journey {
            var step = leg(from, to, start, end)
            let seconds = JourneyTime.parse(end)!.timeIntervalSince(JourneyTime.parse(start)!)
            step["duration"] = seconds
            return try decode(["id": "alternative", "stops": [from, to], "legs": [step],
                               "duration": seconds, "transfers": 0, "walkDistance": 350,
                               "start": start, "end": end, "departure": start])
        }
        let faster = try alternative(a, b, times[0], "2026-10-02T10:08:00+08:00")
        precondition(journey.replacementIssue(at: 0, with: faster) == nil)
        let changed = try journey.replacingTrip(at: 0, with: faster)
        precondition(changed.id != journey.id)
        precondition(changed.stops == journey.stops)
        precondition(changed.legs.count == 2 && journey.legs.count == 3)
        precondition(changed.trips!.map(\.legStartIndex) == [0, 1])
        precondition(changed.trips!.map(\.legEndIndex) == [1, 2])
        precondition(changed.duration == 900) // Includes the two-minute gap at B.
        precondition(changed.walkDistance == 700)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let originalNext = try encoder.encode(journey.pointToPointJourneys[1].legs)
        let unchangedNext = try encoder.encode(changed.pointToPointJourneys[1].legs)
        precondition(originalNext == unchangedNext)
        let savedChange = try JSONDecoder().decode(Journey.self, from: encoder.encode(changed))
        precondition(savedChange.pointToPointJourneys.count == 2)
        precondition(savedChange.pointToPointJourneys[1].timeRange == "10:10–10:15")
        let tooLate = try alternative(a, b, times[0], "2026-10-02T10:11:00+08:00")
        precondition(journey.replacementIssue(at: 0, with: tooLate) != nil)
        do {
            _ = try journey.replacingTrip(at: 0, with: tooLate)
            fatalError("An impossible connection was accepted")
        } catch is TripReplacementError { }
        let tooEarly = try alternative(b, c, times[1], times[3])
        precondition(journey.replacementIssue(at: 1, with: tooEarly) != nil)
        let wrongStops = try alternative(a, c, times[0], times[2])
        precondition(journey.replacementIssue(at: 0, with: wrongStops) != nil)
        let laterLast = try alternative(b, c, times[2], "2026-10-02T10:20:00+08:00")
        let newFinish = try journey.replacingTrip(at: 1, with: laterLast)
        precondition(newFinish.duration == 1200 && newFinish.timeRange == "10:00–10:20")
        let preservedFirst = try encoder.encode(newFinish.pointToPointJourneys[0].legs)
        let originalFirst = try encoder.encode(journey.pointToPointJourneys[0].legs)
        precondition(preservedFirst == originalFirst)
        var stayJourney = changed
        stayJourney.stopStayMinutes = [0, 2, 0]
        let roundTripStay = try JSONDecoder().decode(Journey.self, from: encoder.encode(stayJourney))
        precondition(roundTripStay.stopStayMinutes == [0, 2, 0])
        precondition(stayJourney.replacementIssue(at: 0, with: faster) == nil)
        let tooShortStay = try alternative(a, b, times[0], "2026-10-02T10:09:00+08:00")
        precondition(stayJourney.replacementIssue(at: 0, with: tooShortStay) != nil)
        let keptStay = try stayJourney.replacingTrip(at: 0, with: faster)
        precondition(keptStay.stopStayMinutes == [0, 2, 0] && keptStay.duration == 900)
        var finalStayPayload = payload
        finalStayPayload["stopStayMinutes"] = [0, 0, 10]
        finalStayPayload["end"] = "2026-10-02T10:25:00+08:00"
        finalStayPayload["duration"] = 1500
        let finalStay = try decode(finalStayPayload)
        precondition(finalStay.timeRange == "10:00–10:25")
        let editedFinalStay = try finalStay.replacingTrip(at: 1, with: laterLast)
        precondition(editedFinalStay.duration == 1800 && editedFinalStay.timeRange == "10:00–10:30")
        check(try JSONDecoder().decode(Journey.self, from: JSONEncoder().encode(journey)))
        let shared = try RouteShareCode.encode(journey).dropFirst(5)
        var base64 = String(shared).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        let envelope = try JSONSerialization.jsonObject(with: Data(base64Encoded: base64)!) as! [String: Any]
        check(try decode(envelope["route"] as! [String: Any]))
        payload.removeValue(forKey: "trips")
        check(try decode(payload)) // Older save with exact endpoint boundaries.
        payload["stops"] = [a, place("Unmatched old waypoint", 114.19), c]
        let unavailable = try decode(payload)
        precondition(unavailable.pointToPointJourneys.isEmpty)
        payload["stops"] = [a, b, c]
        var badTrips = trips
        badTrips[1]["legEndIndex"] = 999
        payload["trips"] = badTrips
        let invalid = try decode(payload)
        precondition(invalid.pointToPointJourneys.isEmpty)
        payload["stops"] = [a, c]
        let single = try decode(payload)
        precondition(single.pointToPointJourneys.isEmpty)
        print("PASS: trip boundaries, per-trip times, geometry partition, saved/share round-trip, old saves, invalid-range fallback, individual replacement, unchanged other trips and connection-time validation")
    }
}
