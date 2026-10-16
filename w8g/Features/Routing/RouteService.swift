//
//  RouteService.swift
//  w8g
//
//  Created by Samuel on 29/9/2026.
//

import Foundation

struct RouteRequest: Codable {
    let key: String
    let stops: [Place]
    let departure: String
    let modes: [String]
    let preference: String
    var order = "ordered"
    var defaultStayMinutes = 0
    var stopStayMinutes: [Int?]?
    var channel = "explore"
}

struct RouteJob: Decodable {
    let id: String
    let state: String
    let progress: String?
    let error: String?
    let routes: [Journey]?
}

struct RoutingStatus: Decodable {
    let ready: Bool
    let minDate: String
    let maxDate: String

    func check(_ date: Date) throws {
        guard ready else {
            throw APIError(
                message:
                    "The route engine is still starting or unavailable. Wait for it to be ready, then retry.")
        }
        guard let first = JourneyTime.parse(minDate), let last = JourneyTime.parse(maxDate) else {
            throw APIError(message: "The server did not provide a valid timetable date range.")
        }
        guard date >= first, date < last else {
            throw APIError(
                message:
                    "This test timetable covers \(JourneyTime.day(first))–\(JourneyTime.day(last.addingTimeInterval(-1))). Choose a departure in that range, or update the server timetable."
            )
        }
    }
}

@MainActor
protocol RouteServing {
    var usesDirectAPIs: Bool { get }
    func status() async throws -> RoutingStatus
    func start(_ request: RouteRequest) async throws -> String
    func job(_ id: String) async throws -> RouteJob
}

@MainActor
extension RouteServing { var usesDirectAPIs: Bool { false } }

@MainActor
struct RouteService: RouteServing {
    private let client: APIClient

    init(client: APIClient? = nil) { self.client = client ?? .shared }
    func status() async throws -> RoutingStatus { try await client.get("api/status") }
    func start(_ request: RouteRequest) async throws -> String {
        struct Response: Decodable { let id: String }
        let result: Response = try await client.post("api/jobs", body: request)
        return result.id
    }
    func job(_ id: String) async throws -> RouteJob {
        try await client.get("api/jobs/" + id)
    }
}
