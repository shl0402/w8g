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
                ExploreView {
                    showingProfile = true
                }
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
                if let account = session.account {
                    AIChatView(accountID: account.id)
                        .id(account.id)
                }
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
