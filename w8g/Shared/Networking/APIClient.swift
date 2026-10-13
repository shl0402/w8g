//
//  APIClient.swift
//  w8g
//
//  Created by Samuel on 29/9/2026.
//

import Foundation

struct APIError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

@MainActor
final class APIClient {
    static let shared = APIClient()
    let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = true
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: configuration)
    }

    func get<Response: Decodable>(
        _ path: String,
        query: [URLQueryItem] = []
    ) async throws -> Response {
        var parts = URLComponents(
            url: AppConfig.serverURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        parts?.queryItems = query.isEmpty ? nil : query
        guard let url = parts?.url else {
            throw APIError(message: "The server address is invalid.")
        }
        return try await send(URLRequest(url: url))
    }

    func post<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body
    ) async throws -> Response {
        var request = URLRequest(
            url: AppConfig.serverURL.appendingPathComponent(path)
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request)
    }

    private func send<Response: Decodable>(
        _ request: URLRequest
    ) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(message: "The server returned an invalid response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let error = try? JSONDecoder().decode(ErrorBody.self, from: data)
            throw APIError(message: error?.error ?? "The request failed. Please try again.")
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private struct ErrorBody: Decodable {
        let error: String
    }
}
