import Foundation

extension Journey {
    func departureForAlternatives(at index: Int) -> Date? {
        let parts = pointToPointJourneys
        guard parts.indices.contains(index) else { return nil }
        let requested = JourneyTime.parse(parts[index].departure) ?? parts[index].startDate
        if index > 0, let previousArrival = parts[index - 1].endDate {
            let afterStay = previousArrival.addingTimeInterval(Double(stayMinutes(at: index) * 60))
            return max(requested ?? afterStay, afterStay)
        }
        if let requested, let beginning = startDate {
            return max(requested, beginning.addingTimeInterval(Double(stayMinutes(at: 0) * 60)))
        }
        return requested
    }

    func replacementIssue(at index: Int, with candidate: Journey) -> String? {
        let parts = pointToPointJourneys
        guard parts.indices.contains(index), candidate.stops.count == 2,
            candidate.stops.map(\.id) == parts[index].stops.map(\.id),
            !candidate.legs.isEmpty else { return "This route does not connect the selected stops." }
        guard let earliest = departureForAlternatives(at: index),
            let start = candidate.startDate, let end = candidate.endDate,
            end >= start, candidate.duration.isFinite, candidate.duration >= 0 else {
            return "This route has no usable timetable. Search again."
        }
        guard start >= earliest else {
            return "This route leaves before you can reach this stop."
        }
        if index + 1 < parts.count {
            guard let nextStart = parts[index + 1].startDate else {
                return "The next trip has no departure time to check. Plan the journey again."
            }
            if end.addingTimeInterval(Double(stayMinutes(at: index + 1) * 60)) > nextStart {
                return "Not enough time to arrive and complete the stay before " + JourneyTime.clock(nextStart)
                    + ". Choose an earlier arrival to keep that trip unchanged."
            }
        }
        return nil
    }

    func replacingTrip(at index: Int, with candidate: Journey) throws -> Journey {
        if let issue = replacementIssue(at: index, with: candidate) {
            throw TripReplacementError(message: issue)
        }
        var parts = pointToPointJourneys
        parts[index] = candidate
        var combined: [JourneyLeg] = []
        var summaries: [JourneyTrip] = []
        for part in parts {
            summaries.append(JourneyTrip(
                legStartIndex: combined.count, legEndIndex: combined.count + part.legs.count,
                duration: part.duration, start: part.start, end: part.end,
                departure: part.departure, transfers: part.transfers, walkDistance: part.walkDistance
            ))
            combined.append(contentsOf: part.legs)
        }
        guard let firstDeparture = parts.first?.startDate, let finalArrival = parts.last?.endDate else {
            throw TripReplacementError(message: "The journey has incomplete times. Plan it again.")
        }
        let first = stayMinutes(at: 0) > 0 ? (startDate ?? firstDeparture) : firstDeparture
        let last = finalArrival.addingTimeInterval(Double(stayMinutes(at: stops.count - 1) * 60))
        let transitParts = parts.filter { $0.legs.contains { $0.transitLeg == true } }
        var note = availability?.text ?? "Planned for this departure only."
        if let text = candidate.availability?.text, let warning = text.range(of: "Warning:") {
            let extra = String(text[warning.lowerBound...])
            if !note.contains(extra) { note += " " + extra }
        }
        return Journey(
            id: UUID().uuidString, stops: stops, legs: combined, trips: summaries, stopStayMinutes: stopStayMinutes,
            // Include time between visits while retaining every other trip's exact timetable.
            duration: last.timeIntervalSince(first),
            start: JourneyTime.departure(first), end: JourneyTime.departure(last), departure: departure,
            transfers: transitParts.reduce(0) { $0 + $1.transferCount } + max(0, transitParts.count - 1),
            walkDistance: parts.reduce(0) { $0 + ($1.walkDistance ?? 0) },
            calculatedAt: JourneyTime.departure(Date()), source: source,
            availability: Availability(date: availability?.date, text: note, verifiedServiceWindow: false),
            feedWindow: feedWindow
        )
    }
}

struct TripReplacementError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
