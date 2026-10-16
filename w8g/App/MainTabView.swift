//
//  MainTabView.swift
//  w8g
//
//  Created by Samuel on 29/9/2026.
//

import Foundation

import SwiftUI

struct MainTabView: View {
    @Environment(AppSession.self) private var session
    @State private var showingProfile = false

    var body: some View {
        TabView {
            NavigationStack {
                if session.isGuest { DirectExploreView { showingProfile = true } }
                else { ExploreView { showingProfile = true } }
            }
            .toolbarBackground(AppTheme.background, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
            .tabItem {
                Label("Explore", systemImage: "map")
            }

            NavigationStack {
                OfflineSavedView()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            profileButton
                        }
                    }
            }
            .toolbarBackground(AppTheme.background, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
            .tabItem {
                Label("Save", systemImage: "bookmark")
            }

            NavigationStack {
                AIChatView(accountID: session.account?.id ?? "guest", direct: session.isGuest)
                    .id((session.account?.id ?? "guest") + (session.isGuest ? ".direct" : ".server"))
            }
            .toolbarBackground(AppTheme.background, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
            .tabItem {
                Label("AI", systemImage: "sparkles")
            }
        }
        .tint(AppTheme.ink)
        .sheet(isPresented: $showingProfile) {
            NavigationStack {
                ProfileView()
            }
        }
    }

    private var profileButton: some View {
        Button {
            showingProfile = true
        } label: {
            Image(systemName: "person.crop.circle")
                .font(.title2)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("Open profile")
    }
}
