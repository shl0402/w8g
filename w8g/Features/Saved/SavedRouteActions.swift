//
//  SavedRouteActions.swift
//  w8g
//
//  Created by Samuel on 30/9/2026.
//

import Foundation
import CoreLocation
import SwiftUI

struct SaveJourneyButton: View {
    let journey: Journey
    var iconOnly = false
    @Environment(AppSession.self) private var session
    @Environment(SavedRouteStore.self) private var saved
    @State private var saveError: String?

    var body: some View {
        if let owner = session.account?.id, journey.source != "Google Maps" {
            let exists = saved.contains(journey, owner: owner)
            Button {
                if saved.save(journey, owner: owner) {
                    Task { await saved.synchronise(owner: owner) }
                } else {
                    saveError = saved.storageError ?? saved.errorMessage ?? "Could not save this route. Please try again."
                }
            } label: {
                Group {
                    if iconOnly {
                        Image(systemName: exists ? "bookmark.fill" : "bookmark")
                            .frame(width: 24)
                    } else {
                        Label(exists ? "Saved" : "Save", systemImage: exists ? "bookmark.fill" : "bookmark")
                    }
                }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(AppTheme.ink.opacity(0.06), in: Capsule())
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.ink)
            .disabled(exists || saved.isSyncing || saved.storageError != nil)
            .accessibilityLabel(exists ? "Route saved" : "Save this route")
            .alert("Could not save route", isPresented: Binding(
                get: { saveError != nil }, set: { if !$0 { saveError = nil } }
            )) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "Please try again.")
            }
        }
    }
}

struct SavedJourneyMapView: View {
    @Environment(OfflineMapStore.self) private var maps
    let route: SavedRoute
    let online: Bool
    let canRemove: Bool
    let share: () -> Void
    let remove: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var location = LocationService()
    @State private var mapIsVisible = false
    @State private var focus = SavedMapFocus.route
    @State private var cameraTarget: MapCameraTarget?
    @State private var fitID = UUID()
    @State private var reloadID = UUID()
    @State private var mapError: String?
    @State private var details = false

    var body: some View {
        VStack(spacing: 0) {
            if online {
                W8gMapView(
                    place: nil, cameraTarget: cameraTarget, showsLocation: showsLocation,
                    onLocation: { location.receive($0) }, onLocationError: { location.reportLocationError() }, reloadID: reloadID,
                    onError: { mapError = $0 }, journey: route.journey, routeFitID: fitID,
                    savedFocus: focus, onMapInteraction: mapMoved
                )
                .overlay(alignment: .bottomTrailing) {
                    mapFocusButton
                }
            } else if let download = maps.covering(route.journey) {
                DownloadedJourneyMap(
                    journey: route.journey, download: download, fitID: fitID,
                    onError: { mapError = $0 }, showsLocation: showsLocation,
                    cameraTarget: cameraTarget, savedFocus: focus,
                    onLocation: { location.receive($0) },
                    onLocationError: { location.reportLocationError() }, onMapInteraction: mapMoved
                )
                .overlay(alignment: .bottomTrailing) {
                    mapFocusButton
                }
                .overlay(alignment: .topLeading) {
                    Text("Downloaded map · zoom 8–16")
                        .font(.caption).padding(8).background(.background)
                        .padding(8).allowsHitTesting(false)
                }
            } else {
                ScrollView {
                    SavedRoutePreview(route: route, online: false)
                    Text(maps.loaded
                        ? "No completed map covers this route. Your saved preview and journey details are still available."
                        : "Checking downloaded maps…")
                        .font(.footnote).foregroundStyle(AppTheme.secondaryText).padding()
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                if let message = location.errorMessage {
                    Text(message).font(.caption).foregroundStyle(AppTheme.secondaryText)
                }
                if let mapError {
                    Text(mapError).font(.caption).foregroundStyle(.red)
                    if online {
                        Button("Retry map") { reloadID = UUID() }
                    }
                }       
                Text(route.journey.displayTitle).font(.headline).lineLimit(3)
                JourneyFlowView(journey: route.journey)
                JourneyTimingView(journey: route.journey)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        detailsButton
                        Spacer(minLength: 0)
                        routeActions
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        detailsButton
                        routeActions
                    }
                }
            }.padding(16)
        }
        .background(AppTheme.background)
        .navigationTitle("Saved journey")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $details) { RouteDetailView(journey: route.journey) }
        .onAppear { mapIsVisible = true }
        .onDisappear { mapIsVisible = false; location.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { location.cancel() }
        }
        .onChange(of: location.centerRequestID) { _, _ in
            guard mapIsVisible, scenePhase == .active, let coordinate = location.coordinate else { return }
            cameraTarget = MapCameraTarget(lat: coordinate.latitude, lon: coordinate.longitude, zoom: 16)
            focus = .user
        }
    }

    private var showsLocation: Bool {
        location.isAuthorized && mapIsVisible && !details && scenePhase == .active
    }

    private func mapMoved() {
        focus = .free
        location.cancel()
    }

    private var mapFocusButton: some View {
        Button {
            if focus.next == .route {
                location.cancel()
                focus = .route
                fitID = UUID()
            } else {
                location.locate()
            }
        } label: {
            Group {
                if location.isLocating { ProgressView() }
                else { Image(systemName: focus == .user ? "location.fill" : "location").font(.title2) }
            }
                .frame(width: 52, height: 52)
                .background(.background, in: Circle())
                .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppTheme.ink)
        .disabled(location.isLocating)
        .accessibilityLabel(focus == .user ? "Show the whole saved route" : "Show my location")
        .accessibilityHint(focus == .user ? "Switches from your location to the route" : "Centres the map on your GPS location")
        .padding(.trailing, 20)
        .padding(.bottom, 44)
    }

    private var detailsButton: some View {
        Button("Journey details") { details = true }
            .buttonStyle(.borderedProminent).frame(minHeight: 44)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var routeActions: some View {
        HStack(spacing: 4) {
            Button(action: share) {
                Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
            }.accessibilityLabel("Share saved route")
            NavigationLink {
                OfflineMapsView(journey: route.journey)
            } label: {
                Image(systemName: "arrow.down.circle").frame(width: 44, height: 44)
            }.accessibilityLabel("Download or manage map")
            Button(role: .destructive, action: remove) {
                Image(systemName: "trash").frame(width: 44, height: 44)
            }.foregroundStyle(.red).disabled(!canRemove)
                .accessibilityLabel("Remove saved route")
        }
        .buttonStyle(.plain)
    }

}

struct SavedJourneyOverview: View {
    let route: SavedRoute
    let online: Bool
    let canRemove: Bool
    let share: () -> Void
    let remove: () -> Void
    @Environment(OfflineMapStore.self) private var maps
    @State private var openMap = false
    @State private var missingMap = false
    @State private var showDetails = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button {
                    if online || maps.covering(route.journey) != nil { openMap = true }
                    else { missingMap = true }
                } label: { SavedRoutePreview(route: route, online: online, allowsRetry: false).allowsHitTesting(false) }
                    .buttonStyle(.plain).accessibilityLabel("Open saved journey map")
                    .disabled(!online && !maps.loaded)
                Text(route.journey.displayTitle).font(.headline)
                JourneyFlowView(journey: route.journey)
                JourneyTimingView(journey: route.journey)
                HStack {
                    Button(action: share) { Image(systemName: "square.and.arrow.up").frame(width: 44,height: 44) }.accessibilityLabel("Share")
                    NavigationLink { OfflineMapsView(journey: route.journey) } label: { Image(systemName: "arrow.down.circle").frame(width: 44,height: 44) }.accessibilityLabel("Manage downloaded map")
                    Spacer()
                    Button(role: .destructive, action: remove) { Image(systemName: "trash").frame(width: 44,height: 44) }.disabled(!canRemove).accessibilityLabel("Remove")
                }
                Button("Journey details") { showDetails = true }.frame(minHeight: 44)
            }.padding(16)
        }
        .navigationDestination(isPresented: $openMap) {
            SavedJourneyMapView(route: route, online: online, canRemove: canRemove, share: share, remove: remove)
        }
        .sheet(isPresented: $showDetails) { RouteDetailView(journey: route.journey) }
        .alert("Map not downloaded", isPresented: $missingMap) {
            Button("OK", role: .cancel) { }
        } message: { Text("Download the map for this journey while online. You can then view the route and your GPS location without Wi-Fi or mobile data.") }
    }
}
