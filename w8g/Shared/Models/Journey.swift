//
//  Journey.swift
//  w8g
//
//  Created by Samuel on 29/9/2026.
//

import Foundation
import CoreLocation

// Matches the existing server response. Optional fields allow older saved routes to decode.
struct Journey: Codable, Identifiable {
    let id: String
    let stops: [Place]
    let legs: [JourneyLeg]
    let trips: [JourneyTrip]?
    var stopStayMinutes: [Int]? = nil
    let duration: Double
    let start: String?
    let end: String?
    let departure: String?
    let transfers: Int?
    let walkDistance: Double?
    let calculatedAt: String?
    let source: String?
    let availability: Availability?
    let feedWindow: [String]?

    struct Availability: Codable {
        let date: String?
        let text: String?
        let verifiedServiceWindow: Bool?
    }

    var displayLegs: [JourneyLeg] { legs.flatMap(MTRJourneySections.sections) }

    var minutes: Int { max(1, Int(ceil(max(0, duration) / 60))) }
    var title: String { stops.map(\.name).joined(separator: " → ") }
    var startDate: Date? {
        JourneyTime.parse(stayMinutes(at: 0) > 0 ? start : (legs.first?.start?.scheduledTime ?? start))
    }
    var endDate: Date? {
        JourneyTime.parse(stayMinutes(at: stops.count - 1) > 0 ? end : (legs.last?.end?.scheduledTime ?? end))
    }
    func stayMinutes(at index: Int) -> Int {
        guard let values = stopStayMinutes, values.indices.contains(index) else { return 0 }
        return min(720, max(0, values[index]))
    }
    var timeRange: String {
        guard let startDate, let endDate else { return "Time unavailable" }
        let extra =
            JourneyTime.day(startDate) == JourneyTime.day(endDate) ? "" : " · " + JourneyTime.day(endDate)
        return JourneyTime.clock(startDate) + "–" + JourneyTime.clock(endDate) + extra
    }
    var transferCount: Int {
        // The server counts the complete MTR connection as one ride. Internal
        // line changes are instructions, not extra transfers in this summary.
        max(0, transfers ?? 0)
    }
    var hasMissingGeometry: Bool { displayLegs.contains { $0.coordinates.count < 2 } }
    var mapCoordinates: [CLLocationCoordinate2D] {
        displayLegs.flatMap(\.coordinates) + stops.filter(\.isInHongKong).map(\.coordinate)
    }
}

struct JourneyLeg: Codable {
    let mode: String
    let transitLeg: Bool?
    let duration: Double
    let distance: Double?
    let from: StopPoint
    let to: StopPoint
    let route: TransitLine?
    let start: ScheduledTime?
    let end: ScheduledTime?
    let headsign: String?
    let legGeometry: Geometry?
    let apiPath: [[Double]]?
    let steps: [WalkingStep]?
    let stopCalls: [StopCall]?
    let journeyInstructions: [Instruction]?
    let internalTransfers: Int?
    let transportLabel: String?
    let waitBeforeSeconds: Double?
    let railSections: [JourneyLeg]?

    struct StopPoint: Codable {
        let name: String
        let lat: Double
        let lon: Double
        let platformCode: String?
        let gtfsId: String?
        let stop: StopIdentity?
    }
    struct StopIdentity: Codable {
        let gtfsId: String?
        let platformCode: String?
    }
    struct TransitLine: Codable {
        // Optional for compatibility with routes saved before provider metadata was added.
        let agencyId: String?
        let operatorIds: [String]?
        let operatorName: String?
        let serviceKind: String?
        let displayColor: String?
        let badgeColor: String?
        let textColor: String?
        let gtfsId: String?
        let shortName: String?
        let longName: String?
    }
    struct ScheduledTime: Codable { let scheduledTime: String? }
    struct Geometry: Codable { let points: String? }
    struct WalkingStep: Codable {
        let distance: Double?
        let relativeDirection: String?
        let streetName: String?
        let bogusName: Bool?
    }
    struct StopCall: Codable {
        let stopLocation: StopPoint
        let schedule: Schedule?
        struct Schedule: Codable {
            let time: Time?
            struct Time: Codable { let arrival: String?; let departure: String? }
        }
    }
    struct Instruction: Codable {
        let text: String
        let seconds: Double?
    }

    var isWalking: Bool { mode == "WALK" }
    var minutes: String { duration < 60 ? "<1" : String(Int(ceil(duration / 60))) }
    var lineName: String { route?.shortName ?? route?.longName ?? transportLabel ?? mode.capitalized }
    var coordinates: [CLLocationCoordinate2D] {
        let decoded = RouteGeometry.decode(legGeometry?.points ?? "")
        // Prefer the server's station path over a two-endpoint rail line, when supplied.
        if let apiPath, apiPath.count >= max(2, decoded.count) {
            let path = apiPath.compactMap { pair -> CLLocationCoordinate2D? in
                guard pair.count == 2 else { return nil }
                let point = CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1])
                return CLLocationCoordinate2DIsValid(point) ? point : nil
            }
            if path.count == apiPath.count { return path }
        }
        return decoded
    }
}

// All journey dates use Hong Kong time, even when the phone is set to another region.
enum JourneyTime {
    static let zone = TimeZone(identifier: "Asia/Hong_Kong")!

    static func parse(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return date }
        // The server's status endpoint also returns YYYY-MM-DD dates.
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = zone
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
    static func string(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_HK")
        formatter.timeZone = zone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
    static func clock(_ date: Date) -> String { string(date, format: "HH:mm") }
    static func day(_ date: Date) -> String { string(date, format: "dd MMM yyyy") }
    static func departure(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = zone
        return formatter.string(from: date)
    }
}

// OTP uses encoded polyline precision 5. Invalid data produces no line, never a fake straight route.
enum RouteGeometry {
    static func decode(_ encoded: String) -> [CLLocationCoordinate2D] {
        guard encoded.utf8.count <= 2_000_000 else { return [] }
        let bytes = Array(encoded.utf8)
        var index = 0
        var lat = 0
        var lon = 0
        var points: [CLLocationCoordinate2D] = []
        func next() -> Int? {
            var value = 0
            var shift = 0
            while index < bytes.count, shift <= 30 {
                let byte = Int(bytes[index]) - 63
                index += 1
                guard (0...63).contains(byte) else { return nil }
                value |= (byte & 31) << shift
                if byte < 32 { return (value & 1) == 1 ? ~(value >> 1) : value >> 1 }
                shift += 5
            }
            return nil
        }
        while index < bytes.count {
            guard let a = next(), let b = next() else { return [] }
            lat += a
            lon += b
            let point = CLLocationCoordinate2D(
                latitude: Double(lat) / 100_000, longitude: Double(lon) / 100_000)
            guard CLLocationCoordinate2DIsValid(point) else { return [] }
            points.append(point)
        }
        return points
    }
}
