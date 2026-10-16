//
//  ContentView.swift
//  w8g
//
//  Created by Samuel on 26/9/2026.
//

import SwiftUI

enum AppDestination: Hashable {
    case offline
}

struct ContentView: View {
    @State private var session = AppSession()
    @State private var savedRoutes = SavedRouteStore()
    @State private var offlineMaps = OfflineMapStore()
    @State private var signInPath = NavigationPath()
    @State private var widgetRequest: WidgetOpenRequest?
    @State private var emailReturnMessage = ""
    @State private var showEmailReturnMessage = false

    var body: some View {
        Group {
            if session.isRestoringSession {
                ProgressView("Restoring sign-in…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppTheme.background)
                    .overlay(alignment: .bottom) {
                        Button("Sign in manually") { session.useManualSignIn() }
                            .font(.footnote)
                            .foregroundStyle(AppTheme.secondaryText)
                            .buttonStyle(.plain)
                            .frame(minHeight: 44)
                            .padding(.bottom, 24)
                    }
            } else if session.account != nil || session.isGuest {
                MainTabView()
            } else {
                NavigationStack(path: $signInPath) {
                    AccountEntryView(screen: .signIn)
                        .navigationDestination(
                            for: AccountScreen.self
                        ) { screen in
                            AccountEntryView(screen: screen)
                        }
                        .navigationDestination(
                            for: AppDestination.self
                        ) { destination in
                            switch destination {
                            case .offline:
                                OfflineSavedView()
                            }
                        }
                }
            }
        }
        .environment(session)
        .environment(savedRoutes)
        .modifier(OfflineMapLifecycle(maps: offlineMaps, accountID: session.account?.id))
        .task(id: session.account?.id) {
            let owner = session.account?.id
            savedRoutes.selectAccount(owner)
            if let owner {
                _ = try? GeminiKeyStore.load(accountID: owner)
                await savedRoutes.synchronise(owner: owner)
            }
        }
        .task { await session.restoreSession() }
        .tint(AppTheme.ink)
        .preferredColorScheme(.light)
        .sheet(item: $widgetRequest) { request in
            WidgetDestinationView(request: request)
                .environment(session)
                .environment(savedRoutes)
                .environment(offlineMaps)
        }
        .onOpenURL { url in
            if url.scheme == "w8g", url.host == "widgets" {
                widgetRequest = WidgetOpenRequest(url: url)
                return
            }
            if url.scheme == "w8g", url.host == "auth", url.path == "/reset" {
                guard session.account == nil else { return }
                session.leaveGuest()
                if !session.isResetScreenVisible {
                    signInPath = NavigationPath([AccountScreen.resetPassword])
                }
                Task {
                    await session.acceptPasswordResetLink(url)
                }
                return
            }
            guard url.scheme == "w8g",
                url.host == "auth",
                url.path == "/confirmed",
                session.account == nil
            else {
                return
            }

            session.leaveGuest()
            let parts = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )

            let fragment = URLComponents(
                string: "?" + (parts?.percentEncodedFragment ?? "")
            )

            let items = (parts?.queryItems ?? [])
                + (fragment?.queryItems ?? [])

            let description = items.first {
                $0.name == "error_description"
            }?.value

            let hasError = items.contains {
                $0.name == "error" || $0.name == "error_code"
            }

            signInPath = NavigationPath()

            emailReturnMessage = description ?? (
                hasError
                    ? "This confirmation link could not be completed."
                    : "Sign in with your email and password to continue."
            )

            showEmailReturnMessage = true
        }
        .alert(
            "Email verification",
            isPresented: $showEmailReturnMessage
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(emailReturnMessage)
        }
    }
}

#Preview {
    ContentView()
}
