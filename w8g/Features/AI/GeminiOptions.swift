//
//  GeminiOptions.swift
//  w8g
//
//  Created by Samuel on 2/10/2026.
//

import Foundation

enum GeminiModel: String, CaseIterable, Identifiable {
    case flashLite = "gemini-3.5-flash-lite"
    case flash = "gemini-3.8-flash"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .flashLite: "Gemini 3.5 Flash-Lite · lower cost"
        case .flash: "Gemini 3.8 Flash"
        }
    }
}

struct GeminiOptions {
    var model: GeminiModel = .flashLite
    var extendedThinking = false

    var thinkingLevel: String {
        if extendedThinking { return "high" }
        return model == .flashLite ? "minimal" : "low"
    }

    static func modelKey(_ accountID: String) -> String {
        "w8g.gemini.model." + accountID
    }
    static func thinkingKey(_ accountID: String) -> String {
        "w8g.gemini.extendedThinking." + accountID
    }
    static func load(accountID: String) -> GeminiOptions {
        let stored = UserDefaults.standard.string(forKey: modelKey(accountID)) ?? ""
        return GeminiOptions(
            model: GeminiModel(rawValue: stored) ?? .flashLite,
            extendedThinking: UserDefaults.standard.bool(forKey: thinkingKey(accountID))
        )
    }
}
