//
//  GeminiKeyStore.swift
//  w8g
//
//  Created by Samuel on 2/10/2026.
//

import Foundation
import Security

enum GeminiKeyStore {
    static func load(accountID: String) throws -> String? {
        if let key = try loadValue(slot: "device.gemini") { return key }
        guard !UserDefaults.standard.bool(forKey: "w8g.gemini.sharedKeyRemoved") else { return nil }
        let legacySlot = try loadValue(slot: accountID) != nil ? accountID : soleLegacySlot()
        if let legacySlot, let old = try loadValue(slot: legacySlot) {
            try saveValue(old, slot: "device.gemini")
            try removeValue(slot: legacySlot)
            return old
        }
        return nil
    }
    static func save(_ value: String, accountID: String) throws {
        try saveValue(value, slot: "device.gemini")
        UserDefaults.standard.set(false, forKey: "w8g.gemini.sharedKeyRemoved")
    }
    private static func soleLegacySlot() -> String? {
        var query = baseQuery(accountID: "")
        query.removeValue(forKey: kSecAttrAccount as String)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return nil }
        let slots = items.compactMap { $0[kSecAttrAccount as String] as? String }.filter { !$0.hasPrefix("device.") }
        // Multiple old accounts need an explicit signed-in owner; never pick another account arbitrarily.
        return slots.count == 1 ? slots[0] : nil
    }
    static func remove(accountID: String) throws {
        UserDefaults.standard.set(true, forKey: "w8g.gemini.sharedKeyRemoved")
        try removeValue(slot: "device.gemini")
        try removeValue(slot: accountID)
    }
    static func loadValue(slot accountID: String) throws -> String? {
        var query = baseQuery(accountID: accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(
            query as CFDictionary,
            &item
        )

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw KeyError.readFailed
        }

        return key
    }

    static func saveValue(_ value: String, slot accountID: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !key.isEmpty,
              !key.contains(where: { $0.isWhitespace }) else {
            throw KeyError.invalidInput
        }

        let query = baseQuery(accountID: accountID)
        let data = Data(key.utf8)

        var status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] =
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly

            status = SecItemAdd(item as CFDictionary, nil)
        }

        guard status == errSecSuccess else {
            throw KeyError.saveFailed
        }
    }

    static func removeValue(slot accountID: String) throws {
        let status = SecItemDelete(
            baseQuery(accountID: accountID) as CFDictionary
        )

        guard status == errSecSuccess ||
              status == errSecItemNotFound else {
            throw KeyError.removeFailed
        }
    }

    private static func baseQuery(accountID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "w8g.gemini-api-key",
            kSecAttrAccount as String: accountID,
            kSecAttrSynchronizable as String: false
        ]
    }

    enum KeyError: LocalizedError {
        case invalidInput
        case readFailed
        case saveFailed
        case removeFailed

        var errorDescription: String? {
            switch self {
            case .invalidInput:
                return "Enter an API key without spaces."
            case .readFailed:
                return "Could not read your key. Unlock your iPhone and try again."
            case .saveFailed:
                return "Could not save your key. Please try again."
            case .removeFailed:
                return "Could not remove your key. Please try again."
            }
        }
    }
}

// Provider slots share device storage, not account credentials or database rows.
enum DeviceAPIKeys {
    static func google() throws -> String? { try GeminiKeyStore.loadValue(slot: "device.google") }
    static func saveGoogle(_ key: String) throws { try GeminiKeyStore.saveValue(key, slot: "device.google") }
    static func removeGoogle() throws { try GeminiKeyStore.removeValue(slot: "device.google") }
}
