import Foundation

// Half-open ranges point into Journey.legs so saving/sharing retains one geometry copy.
struct JourneyTrip: Codable {
    let legStartIndex: Int
    let legEndIndex: Int
    let duration: Double
    let start: String?
    let end: String?
    let departure: String?
    let transfers: Int?
    let walkDistance: Double?
}

extension Journey {
    var pointToPointJourneys: [Journey] {
        guard stops.count > 2 else { return [] }
        let summaries = trips ?? legacyTripSummaries()
        guard summaries.count == stops.count - 1 else { return [] }
        var nextLeg = 0
        var result: [Journey] = []
        for (index, trip) in summaries.enumerated() {
            guard trip.legStartIndex == nextLeg,
                trip.legEndIndex > nextLeg,
                trip.legEndIndex <= legs.count else { return [] }
            let tripLegs = Array(legs[nextLeg..<trip.legEndIndex])
            result.append(Journey(
                id: id + "_trip_\(index + 1)",
                stops: [stops[index], stops[index + 1]], legs: tripLegs, trips: nil,
                duration: trip.duration, start: trip.start, end: trip.end,
                departure: trip.departure, transfers: trip.transfers,
                walkDistance: trip.walkDistance, calculatedAt: calculatedAt,
                source: source, availability: availability, feedWindow: feedWindow
            ))
            nextLeg = trip.legEndIndex
        }
        return nextLeg == legs.count ? result : []
    }

    // Older saved routes lack trip ranges. Only split at exact visit endpoints;
    // never guess a boundary from a nearby station or a matching stop name.
    private func legacyTripSummaries() -> [JourneyTrip] {
        func matches(_ endpoint: JourneyLeg.StopPoint, _ place: Place) -> Bool {
            abs(endpoint.lat - place.lat) < 0.000001 && abs(endpoint.lon - place.lon) < 0.000001
        }
        var first = 0
        var summaries: [JourneyTrip] = []
        for index in 0..<(stops.count - 1) {
            guard first < legs.count, matches(legs[first].from, stops[index]),
                let last = (first..<legs.count).first(where: {
                    matches(legs[$0].to, stops[index + 1]) &&
                    (index == stops.count - 2
                        ? $0 == legs.count - 1
                        : $0 + 1 < legs.count && matches(legs[$0 + 1].from, stops[index + 1]))
                }) else { return [] }
            let part = Array(legs[first...last])
            let start = part.first?.start?.scheduledTime
            let end = part.last?.end?.scheduledTime
            let seconds: Double
            if let a = JourneyTime.parse(start), let b = JourneyTime.parse(end) {
                seconds = max(0, b.timeIntervalSince(a))
            } else {
                seconds = part.reduce(0) { $0 + $1.duration + ($1.waitBeforeSeconds ?? 0) }
            }
            let rides = part.filter { $0.transitLeg == true }
            // Internal MTR sections remain one ride for the transfer count.
            var rideCount = 0
            var previousWasMTR = false
            for ride in rides {
                let isMTR = MTRLineStyle.line(named: ride.lineName) != nil
                if !isMTR || !previousWasMTR { rideCount += 1 }
                previousWasMTR = isMTR
            }
            summaries.append(JourneyTrip(
                legStartIndex: first, legEndIndex: last + 1, duration: seconds,
                start: start, end: end, departure: start,
                transfers: max(0, rideCount - 1),
                walkDistance: part.filter(\.isWalking).reduce(0) { $0 + ($1.distance ?? 0) }
            ))
            first = last + 1
        }
        return summaries
    }
}
