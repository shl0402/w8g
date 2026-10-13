//
//  ProfileView.swift
//  w8g
//
//  Created by Samuel on 29/9/2026.
//

import Foundation

import SwiftUI

struct ProfileView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            if let account = session.account {
                Section("Account") {
                    LabeledContent("Username", value: account.username)
                    LabeledContent("Email", value: account.email)
                }

                Section("AI settings") {
                    NavigationLink {
                        GeminiSettingsView(accountID: account.id)
                    } label: {
                        Label("Gemini API key", systemImage: "sparkles")
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    Task {
                        await session.signOut()
                    }
                } label: {
                    HStack {
                        Text(
                            session.isWorking
                                ? "Signing out…"
                                : "Sign out"
                        )

                        Spacer()

                        if session.isWorking {
                            ProgressView()
                        }
                    }
                }
                .disabled(session.isWorking)

                if let message = session.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    dismiss()
                }
                .disabled(session.isWorking)
            }
        }
    }
}
