//
//  GeminiSettingsView.swift
//  w8g
//
//  Created by Samuel on 2/10/2026.
//

import Foundation
import SwiftUI

struct GeminiSettingsView: View {
    let accountID: String
    @AppStorage private var modelChoice: String
    @AppStorage private var extendedThinking: Bool

    init(accountID: String) {
        self.accountID = accountID
        _modelChoice = AppStorage(
            wrappedValue: GeminiModel.flashLite.rawValue,
            GeminiOptions.modelKey(accountID)
        )
        _extendedThinking = AppStorage(
            wrappedValue: false,
            GeminiOptions.thinkingKey(accountID)
        )
    }


    @State private var key = ""
    @State private var showsKey = false
    @State private var hasSavedKey = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var hasLoaded = false

    var body: some View {
        Form {
            Section {
                Picker("Model", selection: $modelChoice) {
                    ForEach(GeminiModel.allCases) { model in
                        Text(model.title).tag(model.rawValue)
                    }
                }
                Toggle("Extended thinking", isOn: $extendedThinking)
            } header: {
                Text("AI responses")
            } footer: {
                Text(
                    "Saved automatically on this iPhone. Applies to your next message. "
                    + "Off uses minimal thinking for Flash-Lite or low for Flash. "
                    + "On uses high thinking and may take longer and cost more. "
                    + "Off does not completely disable thinking."
                )
            }
            Section {
                HStack(spacing: 12) {
                    Group {
                        if showsKey {
                            TextField("Gemini API key", text: $key)
                        } else {
                            SecureField("Gemini API key", text: $key)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    Button {
                        showsKey.toggle()
                    } label: {
                        Image(
                            systemName: showsKey
                                ? "eye.slash"
                                : "eye"
                        )
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        showsKey ? "Hide API key" : "Show API key"
                    )
                }

                Button(hasSavedKey ? "Update key" : "Save key") {
                    saveKey()
                }
                .disabled(
                    key.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                )

                if hasSavedKey {
                    Button("Remove key", role: .destructive) {
                        removeKey()
                    }
                }
            } header: {
                Text("Your Gemini key")
            } footer: {
                Text(
                    "Stored securely on this iPhone, shared between signed-in and guest modes. "
                    + "Sent directly to Google for AI requests, never to the app server or account database."
                )
            }

            if let statusMessage {
                Section {
                    Label(
                        statusMessage,
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                    .font(.footnote)
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }

            Section {
                Link(
                    "Get a Gemini API key",
                    destination: URL(
                        string: "https://aistudio.google.com/apikey"
                    )!
                )
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .navigationTitle("Gemini")
        .navigationBarTitleDisplayMode(.inline)
        .tint(AppTheme.ink)
        .onAppear {
            guard !hasLoaded else { return }
            hasLoaded = true
            loadKey()
        }
        .onChange(of: key) { _, _ in
            statusMessage = nil
            errorMessage = nil
        }
        .onDisappear {
            showsKey = false
        }
    }

    private func loadKey() {
        do {
            let savedKey = try GeminiKeyStore.load(
                accountID: accountID
            )

            key = savedKey ?? ""
            hasSavedKey = savedKey != nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveKey() {
        do {
            try GeminiKeyStore.save(
                key,
                accountID: accountID
            )

            hasSavedKey = true
            showsKey = false
            errorMessage = nil
            statusMessage = "Saved on this iPhone."
        } catch {
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    private func removeKey() {
        do {
            try GeminiKeyStore.remove(
                accountID: accountID
            )

            key = ""
            hasSavedKey = false
            showsKey = false
            statusMessage = nil
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
