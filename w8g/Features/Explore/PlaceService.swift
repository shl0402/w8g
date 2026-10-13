//
//  PlaceService.swift
//  w8g
//
//  Created by Samuel on 29/9/2026.
//

import Foundation
import CryptoKit

@MainActor
struct PlaceService {
    private let api: APIClient

    init(api: APIClient? = nil) {
        self.api = api ?? .shared
    }

    func search(_ query: String) async throws -> [Place] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = text.split(whereSeparator: { $0 == "," || $0.isWhitespace })
        if pieces.count == 2,
            let lat = Double(pieces[0]), let lon = Double(pieces[1]) {
            let place = Place(name: text, lat: lat, lon: lon, source: "coordinates")
            guard place.isInHongKong else {
                throw APIError(message: "Enter coordinates within Hong Kong: latitude, longitude.")
            }
            return [place]
        }
        guard text.count >= 2 else { return [] }
        let places: [Place] = try await api.get(
            "api/places", query: [URLQueryItem(name: "q", value: text)]
        )
        var seen = Set<String>()
        return places.filter { $0.isInHongKong && seen.insert($0.id).inserted }
    }

    func recentPlaces() async throws -> [Place] {
        let rows: [HistoryRecord] = try await api.get("api/records")
        var seen = Set<String>()
        return Array(rows.sorted { $0.updated > $1.updated }
            .filter { $0.kind == "history" && $0.payload.type == "placeSearch" }
            .compactMap { $0.payload.place }
            .filter { $0.isInHongKong && seen.insert($0.id).inserted }
            .prefix(20))
    }

    func remember(_ place: Place) async throws {
        let digest = SHA256.hash(data: Data(place.id.utf8))
        let key = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        let _: SaveResponse = try await api.post(
            "api/records",
            body: SaveRequest(
                id: "place_" + key,
                kind: "history",
                payload: PlacePayload(type: "placeSearch", place: place)
            )
        )
    }

    private struct PlacePayload: Codable {
        let type: String?
        let place: Place?
    }

    private struct HistoryRecord: Decodable {
        let kind: String
        let payload: PlacePayload
        let updated: Double
    }

    private struct SaveRequest: Encodable {
        let id: String
        let kind: String
        let payload: PlacePayload
    }

    private struct SaveResponse: Decodable {
        let ok: Bool
    }
}
