import Foundation

// Keep the server's atomic MTR cost for routing/sharing, but expose each train to
// every UI and map. The fallback also repairs routes saved before railSections.
enum MTRJourneySections {
    static func sections(_ leg: JourneyLeg) -> [JourneyLeg] {
        if let sections = leg.railSections, !sections.isEmpty { return sections }
        guard ["SUBWAY", "RAIL"].contains(leg.mode),
              let calls = leg.stopCalls, calls.count > 2 else { return [leg] }
        let codes = calls.map { call -> String? in
            let id = call.stopLocation.gtfsId ?? call.stopLocation.stop?.gtfsId ?? ""
            if id.contains("RAIL:MTR:"), let code = id.split(separator: ":").last,
               MTRLineStyle.lines[String(code)] != nil { return String(code) }
            // Older saved routes kept the explicit (TKL)/(ISL) suffix but not IDs.
            return MTRLineStyle.lines.keys.first {
                call.stopLocation.name.contains("(" + $0 + ")")
            }
        }
        guard codes.allSatisfy({ $0 != nil }), let start = JourneyTime.parse(leg.start?.scheduledTime) else { return [leg] }
        let instructions = leg.journeyInstructions ?? []
        func changeInstruction(at i: Int) -> JourneyLeg.Instruction? {
            let name = stopName(calls[i].stopLocation.name)
            guard calls.filter({ stopName($0.stopLocation.name) == name }).count == 1 else { return nil }
            return instructions.first {
                $0.text.localizedCaseInsensitiveContains("interchange")
                    && $0.text.localizedCaseInsensitiveContains("at " + name)
                    && ($0.seconds ?? 0) > 0
            }
        }
        let changes = (1..<(calls.count - 1)).filter { i in
            codes[i] != codes[i - 1] || changeInstruction(at: i) != nil
        }
        guard !changes.isEmpty else { return [leg] }
        let boundaries = [0] + changes + [calls.count - 1]
        var dates: [Int: Date] = [0: start, calls.count - 1: start.addingTimeInterval(leg.duration)]
        for i in changes {
            if let recorded = JourneyTime.parse(calls[i].schedule?.time?.arrival ?? calls[i].schedule?.time?.departure) {
                dates[i] = recorded
            } else if let offset = changeInstruction(at: i)?.seconds {
                dates[i] = start.addingTimeInterval(offset)
            } else {
                return [leg] // Never invent an interchange time for incomplete saved data.
            }
        }
        guard zip(boundaries, boundaries.dropFirst()).allSatisfy({ dates[$0]! < dates[$1]! }) else { return [leg] }
        return zip(boundaries, boundaries.dropFirst()).map { a, b in
            let code = codes[a]!
            return JourneyLeg(
                mode: leg.mode, transitLeg: leg.transitLeg,
                duration: dates[b]!.timeIntervalSince(dates[a]!), distance: nil,
                from: a == 0 ? leg.from : calls[a].stopLocation,
                to: b == calls.count - 1 ? leg.to : calls[b].stopLocation,
                route: JourneyLeg.TransitLine(
                    agencyId: "MTR", operatorIds: ["MTR"], operatorName: "MTR",
                    serviceKind: nil, displayColor: MTRLineStyle.lines[code]?.hex,
                    badgeColor: nil, textColor: nil, gtfsId: leg.route?.gtfsId,
                    shortName: code, longName: MTRLineStyle.lines[code]?.name),
                start: .init(scheduledTime: JourneyTime.departure(dates[a]!)),
                end: .init(scheduledTime: JourneyTime.departure(dates[b]!)),
                headsign: nil, legGeometry: nil,
                apiPath: calls[a...b].map { [$0.stopLocation.lat, $0.stopLocation.lon] },
                steps: nil, stopCalls: Array(calls[a...b]), journeyInstructions: [],
                internalTransfers: 0, transportLabel: nil,
                waitBeforeSeconds: a == 0 ? leg.waitBeforeSeconds : 0, railSections: nil)
        }
    }

    static func stopName(_ name: String) -> String {
        name.replacingOccurrences(of: "\\s*·\\s*Platform.*$", with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "\\s*\\((?:" + MTRLineStyle.lines.keys.sorted().joined(separator: "|") + ")\\)", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
