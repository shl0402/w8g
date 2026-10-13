//
//  SavedRouteService.swift
//  w8g
//
//  Created by Samuel on 30/9/2026.
//

import Foundation

// The existing server owns authentication and selects the account from its session.
@MainActor
protocol SavedRouteRemote {
    func load() async throws -> [SavedRouteResponse]
    func write(id: String, journey: Journey?, deleting: Bool) async throws
}

struct SavedRouteResponse: Decodable {
    let id: String
    let kind: String
    let journey: Journey?
    let updated: Double

    private enum CodingKeys: String, CodingKey { case id, kind, payload, updated }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        kind = try values.decode(String.self, forKey: .kind)
        updated = try values.decode(Double.self, forKey: .updated)
        // History has a different payload. One incompatible saved row must not block all others.
        journey = kind == "saved" ? try? values.decode(Journey.self, forKey: .payload) : nil
    }
}

@MainActor
struct SavedRouteService: SavedRouteRemote {
    private let client: APIClient

    init(client: APIClient? = nil) {
        self.client = client ?? .shared
    }

    func load() async throws -> [SavedRouteResponse] {
        try await client.get("api/records")
    }

    func write(id: String, journey: Journey?, deleting: Bool) async throws {
        struct Request: Encodable {
            let id: String
            let kind = "saved"
            let payload: Journey?
            let delete: Bool
        }
        struct Response: Decodable { let ok: Bool }
        let response: Response = try await client.post(
            "api/records",
            body: Request(id: id, payload: journey, delete: deleting)
        )
        guard response.ok else {
            throw APIError(message: "The server did not confirm the saved-route change.")
        }
    }
}
