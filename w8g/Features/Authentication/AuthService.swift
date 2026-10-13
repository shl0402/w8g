//
//  AuthService.swift
//  w8g
//
//  Created by Samuel on 26/9/2026.
//

import Foundation

struct Account: Decodable, Equatable, Identifiable {
    let id: String
    let username: String
    let email: String
}

private struct SessionResponse: Decodable {
    let user: Account?
}

private struct LoginResponse: Decodable {
    let user: Account
}

struct SignupResponse: Decodable {
    let user: Account?
    let message: String?
}

struct RecoveryRequest: Decodable {
    let message: String
    let requestToken: String
    let expiresAt: Double
}

private struct RecoveryStatus: Decodable {
    let state: String
}

private struct RecoveryResponse: Decodable {
    let message: String
}

private struct ServerError: Decodable {
    let error: String
}

struct AuthFailure: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

@MainActor
final class AuthService {
    private let session: URLSession

    init(client: APIClient? = nil) {
        session = (client ?? .shared).session
    }

    func signIn(
        login: String,
        password: String
    ) async throws -> Account {
        let data = try await post(
            path: "api/login",
            body: [
                "login": login,
                "password": password
            ]
        )

        let user = try JSONDecoder().decode(LoginResponse.self, from: data).user
        try saveCurrentSession()
        return user
    }
    
    func signUp(
        username: String,
        email: String,
        password: String
    ) async throws -> SignupResponse {
        let data = try await post(
            path: "api/signup",
            body: [
                "username": username,
                "email": email,
                "password": password,
                "client": "ios"
            ]
        )

        let response = try JSONDecoder().decode(
            SignupResponse.self,
            from: data
        )

        guard response.user != nil || response.message != nil else {
            throw AuthFailure(
                message: "The server returned an incomplete response."
            )
        }

        if response.user != nil { try saveCurrentSession() }
        return response
    }
    
    func requestPasswordReset(email: String) async throws -> RecoveryRequest {
        let data = try await post(
            path: "api/recover",
            body: ["email": email]
        )
        return try JSONDecoder().decode(RecoveryRequest.self, from: data)
    }

    func passwordResetStatus(ticket: String) async throws -> String {
        let data = try await post(
            path: "api/recovery/status",
            body: ["requestToken": ticket]
        )
        return try JSONDecoder().decode(RecoveryStatus.self, from: data).state
    }

    func finishPasswordReset(
        ticket: String,
        password: String
    ) async throws -> String {
        let data = try await post(
            path: "api/recovery/finish",
            body: [
                "requestToken": ticket,
                "password": password
            ]
        )
        return try JSONDecoder().decode(RecoveryResponse.self, from: data).message
    }

    func restoreSession() async throws -> Account? {
        guard let cookie = try SessionCredentialStore.load(for: AppConfig.serverURL) else {
            return nil
        }
        session.configuration.httpCookieStorage?.setCookie(cookie)
        let request = URLRequest(url: AppConfig.serverURL.appendingPathComponent("api/session"))
        let (data, response) = try await session.data(for: request)
        // A cancelled restore must not clear credentials from a newer manual sign-in.
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw AuthFailure(message: "Could not check your saved sign-in.")
        }
        if http.statusCode == 401 {
            try clearLocalSession()
            return nil
        }
        guard (200..<300).contains(http.statusCode) else {
            let error = try? JSONDecoder().decode(ServerError.self, from: data)
            throw AuthFailure(message: error?.error ?? "Could not reconnect to the server.")
        }
        let result = try JSONDecoder().decode(SessionResponse.self, from: data)
        if result.user == nil { try clearLocalSession() }
        return result.user
    }

    func signOut() async throws {
        // Always allow local sign-out, even if the server cannot be reached.
        // Server-side revocation is best effort when disconnected.
        _ = try? await post(path: "api/logout", body: [:])
        try clearLocalSession()
    }

    private func saveCurrentSession() throws {
        guard let cookie = session.configuration.httpCookieStorage?
            .cookies(for: AppConfig.serverURL)?.first(where: { $0.name == "w8g" }) else {
            throw AuthFailure(message: "The server did not return a sign-in cookie.")
        }
        try SessionCredentialStore.save(cookie, for: AppConfig.serverURL)
    }

    private func clearLocalSession() throws {
        try SessionCredentialStore.clear(for: AppConfig.serverURL)
        let storage = session.configuration.httpCookieStorage
        for cookie in storage?.cookies(for: AppConfig.serverURL) ?? [] where cookie.name == "w8g" {
            storage?.deleteCookie(cookie)
        }
    }

    private func post(
        path: String,
        body: [String: String]
    ) async throws -> Data {
        var request = URLRequest(
            url: AppConfig.serverURL.appendingPathComponent(path)
        )

        request.httpMethod = "POST"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)

        guard let response = response as? HTTPURLResponse else {
            throw AuthFailure(
                message: "The server returned an invalid response."
            )
        }

        guard (200..<300).contains(response.statusCode) else {
            let serverError = try? JSONDecoder().decode(
                ServerError.self,
                from: data
            )

            throw AuthFailure(
                message: serverError?.error
                    ?? "Could not complete the request. Please try again."
            )
        }

        return data
    }
}
