//
//  AIConfirmedRouteService.swift
//  w8g
//
//  Created by Samuel on 2/10/2026.
//

import Foundation

// The planner calls start only after the user presses Confirm and plan.
// The Gemini key and conversation are never part of these server requests.
@MainActor
final class AIConfirmedRouteService: RouteServing {
    private let api: APIClient
    private let routing: RouteService
    private var drafts: [String: Draft] = [:]

    init(api: APIClient? = nil) {
        let client = api ?? .shared
        self.api = client
        routing = RouteService(client: client)
    }

    func status() async throws -> RoutingStatus { try await routing.status() }
    func job(_ id: String) async throws -> RouteJob { try await routing.job(id) }

    func start(_ request: RouteRequest) async throws -> String {
        let draft: Draft
        if let existing = drafts[request.key] {
            draft = existing
        } else {
            var body = request
            body.channel = "ai"
            draft = try await api.post("api/drafts", body: body)
            // Bound this session-only cache; a retry reuses the server's draft/job.
            if drafts.count >= 20 { drafts.removeAll() }
            drafts[request.key] = draft
        }
        try Task.checkCancellation()
        let response: Started = try await api.post(
            "api/jobs", body: Confirmation(draftId: draft.id, revision: draft.revision)
        )
        return response.id
    }

    private struct Draft: Decodable { let id: String; let revision: Int }
    private struct Started: Decodable { let id: String }
    private struct Confirmation: Encodable {
        let draftId: String
        let revision: Int
        let ai = true
        let confirmed = true
    }
}
