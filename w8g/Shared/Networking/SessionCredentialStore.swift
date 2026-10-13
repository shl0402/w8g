//
//  SessionCredentialStore.swift
//  w8g
//
//  Created by Samuel on 29/9/2026.
//

import Foundation
import Security

// Store only the server session token, never the user's password.
enum SessionCredentialStore {
    private struct Credential: Codable {
        let value: String
        let expires: Date
        let secure: Bool
    }

    static func save(_ cookie: HTTPCookie, for server: URL) throws {
        guard cookie.name == "w8g", let expires = cookie.expiresDate else {
            throw AuthFailure(message: "The server did not provide a persistent sign-in session.")
        }
        let data = try JSONEncoder().encode(
            Credential(value: cookie.value, expires: expires, secure: cookie.isSecure)
        )
        let key = query(for: server)
        let update = [kSecValueData as String: data]
        var result = SecItemUpdate(key as CFDictionary, update as CFDictionary)
        if result == errSecItemNotFound {
            var item = key
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            result = SecItemAdd(item as CFDictionary, nil)
        }
        guard result == errSecSuccess else {
            throw AuthFailure(message: "Could not securely save sign-in on this iPhone. Please try again.")
        }
    }

    static func load(for server: URL) throws -> HTTPCookie? {
        var key = query(for: server)
        key[kSecReturnData as String] = true
        key[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let result = SecItemCopyMatching(key as CFDictionary, &item)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = item as? Data else {
            throw AuthFailure(message: "Could not read the saved sign-in. Unlock your iPhone and retry.")
        }
        guard let saved = try? JSONDecoder().decode(Credential.self, from: data),
            saved.expires > Date(), !saved.value.isEmpty else {
            try clear(for: server)
            return nil
        }
        guard let host = server.host else { return nil }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: "w8g", .value: saved.value, .domain: host,
            .path: "/", .expires: saved.expires
        ]
        if saved.secure { properties[.secure] = "TRUE" }
        return HTTPCookie(properties: properties)
    }

    static func clear(for server: URL) throws {
        let result = SecItemDelete(query(for: server) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else {
            throw AuthFailure(message: "Could not remove the saved sign-in. Please try signing out again.")
        }
    }

    private static func query(for server: URL) -> [String: Any] {
        // The full configured server address keeps development and production separate.
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "w8g.server-session",
            kSecAttrAccount as String: server.absoluteString
        ]
    }
}
