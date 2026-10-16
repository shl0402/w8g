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

            }
            Section("Widgets") {
                NavigationLink("Design your widgets") { WidgetSettingsView() }
            }
            Section("Services") {
                NavigationLink("API keys and arrivals") { ServicesSettingsView(accountID: session.account?.id ?? "guest") }
            }

            Section {
                Button(role: .destructive) {
                    Task {
                        if session.isGuest { session.leaveGuest(); dismiss() }
                        else { await session.signOut() }
                    }
                } label: {
                    HStack {
                        Text(
                            session.isWorking
                                ? "Signing out…"
                                : (session.isGuest ? "Return to sign in" : "Sign out")
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
