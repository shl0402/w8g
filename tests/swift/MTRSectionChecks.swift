import Foundation

@main
struct MTRSectionChecks {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let sample = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let original = sample["leg"] as! [String: Any]
        func journey(_ leg: [String: Any]) throws -> Journey {
            let envelope: [String: Any] = ["id": "regression", "stops": [], "legs": [leg], "duration": original["duration"]!, "transfers": 0]
            return try JSONDecoder().decode(Journey.self, from: JSONSerialization.data(withJSONObject: envelope))
        }
        func check(_ j: Journey) {
            let parts = j.displayLegs
            precondition(parts.map(\.lineName) == ["TKL", "TKL", "ISL", "TWL"])
            precondition(parts.map { ($0.stopCalls?.count ?? 0) - 1 } == [1, 4, 5, 1])
            precondition(parts.reduce(0) { $0 + $1.duration } == j.duration)
            precondition(j.transferCount == 0)
            precondition(parts.map { MTRLineStyle.line(named: $0.lineName)!.hex } == ["6B208B", "6B208B", "0860A8", "FF0000"])
            for (a, b) in zip(parts, parts.dropFirst()) {
                precondition(a.to.lat == b.from.lat && a.to.lon == b.from.lon)
                precondition(a.end?.scheduledTime == b.start?.scheduledTime)
            }
            precondition(parts.allSatisfy { $0.coordinates.count == $0.stopCalls!.count })
        }
        var busAndRail: [String: Any] = ["id": "bus-rail", "stops": [], "legs": [original], "duration": original["duration"]!, "transfers": 1]
        var bus = original
        bus["mode"] = "BUS"
        bus["internalTransfers"] = 0
        busAndRail["legs"] = [bus, original]
        let busJourney = try JSONDecoder().decode(Journey.self, from: JSONSerialization.data(withJSONObject: busAndRail))
        precondition(busJourney.transferCount == 1)
        let fresh = try journey(original)
        check(fresh)
        check(try JSONDecoder().decode(Journey.self, from: JSONEncoder().encode(fresh)))
        var legacy = original
        legacy["stopCalls"] = (original["stopCalls"] as! [[String: Any]]).map { call -> [String: Any] in
            var stop = call["stopLocation"] as! [String: Any]
            stop.removeValue(forKey: "gtfsId")
            return ["stopLocation": stop]
        }
        check(try journey(legacy))
        var provided = original
        provided["railSections"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fresh.displayLegs))
        check(try journey(provided))
        var incomplete = legacy
        incomplete["journeyInstructions"] = []
        let unchanged = try journey(incomplete)
        precondition(unchanged.displayLegs.count == 1)
        precondition(MTRJourneySections.stopName("Tsim Sha Tsui (TWL) · Platform 1/2") == "Tsim Sha Tsui")
        print("PASS: current API, old saved data, save/reopen, API sections, timing, transfer counts, colours, geometry and incomplete-data fallback")
    }
}
