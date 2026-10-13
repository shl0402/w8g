//
//  OfflineMapViews.swift
//  w8g
//
//  Created by Samuel on 1/10/2026.
//

import Foundation
import SwiftUI
import MapLibre
import CoreLocation

struct OfflineMapsView: View {
    var journey: Journey? = nil
    @Environment(OfflineMapStore.self) private var maps
    @State private var proposedArea: OfflineArea?
    @State private var proposedTitle = ""
    @State private var removing: OfflineMapDownload?

    var body: some View {
        List {
            Section {
                Text("Download while connected, then pan and zoom saved journeys without internet. Keep the app open until Ready offline appears.")
                if let message = maps.errorMessage {
                    Text(message).foregroundStyle(.red)
                }
                if !maps.loaded { ProgressView("Reading downloads…") }
                if maps.canDownload {
                    if let journey, let area = OfflineArea.around(journey) {
                        Button("Download this route's map area") {
                            proposedTitle = journey.title
                            proposedArea = area
                        }
                    }
                    Button("Download Hong Kong map") {
                        proposedTitle = "Hong Kong"
                        proposedArea = .hongKong
                    }
                } else {
                    Text("Sign in and connect to download or resume. Existing maps stay on this iPhone after logout.")
                }
            }
            .disabled(maps.busy || !maps.loaded)
            Section("On this iPhone") {
                if maps.loaded && maps.downloads.isEmpty { Text("No downloaded maps yet.") }
                ForEach(maps.downloads) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.info.title).font(.headline).lineLimit(3)
                        Label(item.status, systemImage: item.ready ? "checkmark.circle.fill" : "arrow.down.circle")
                            .foregroundStyle(item.ready ? .green : AppTheme.secondaryText)
                        if item.active {
                            // The resource total can grow as MapLibre discovers tiles and fonts.
                            ProgressView(value: Double(min(item.completed, item.expected)), total: Double(max(1, item.expected)))
                            Text("\(item.completed) / at least \(item.expected) resources").font(.caption)
                        }
                        Text("\(item.size) downloaded · added \(JourneyTime.day(item.info.created))")
                            .font(.caption).foregroundStyle(AppTheme.secondaryText)
                        HStack {
                            if !item.ready {
                                Button(item.active ? "Pause" : "Resume") { maps.toggle(item) }
                                    .disabled(!item.active && (!maps.canDownload || item.state == .unknown))
                            }
                            Spacer()
                            Button("Remove", role: .destructive) { removing = item }
                        }
                        .buttonStyle(.borderless)
                        .frame(minHeight: 44)
                        .disabled(maps.busy)
                    }.padding(.vertical, 4)
                }
            }
            Section {
                Text("Includes map detail at zoom levels 8–16. Areas outside the download may be blank offline. Saved routes remain timetable snapshots: offline maps do not calculate new routes or provide live arrivals.")
                Text("Pack sizes include shared resources, so adding them together can overstate actual disk use. Removing a pack keeps resources used by another pack or the map cache.")
            }.font(.footnote).foregroundStyle(AppTheme.secondaryText)
        }
        .navigationTitle("Offline maps")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Download map?", isPresented: Binding(
            get: { proposedArea != nil }, set: { if !$0 { proposedArea = nil } }
        ), titleVisibility: .visible) {
            Button("Download") {
                if let area = proposedArea { maps.add(title: proposedTitle, area: area) }
                proposedArea = nil
            }
            Button("Cancel", role: .cancel) { proposedArea = nil }
        } message: {
            Text("\(proposedTitle). Size is unknown until download progresses and can be large, especially for all Hong Kong. Use Wi-Fi and check available storage. You can pause or remove the download.")
        }
        .confirmationDialog("Remove downloaded map?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible) {
            Button("Remove map", role: .destructive) {
                if let item = removing { maps.remove(item) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("Saved journeys and directions stay on this iPhone. The deleted area's map may no longer be available offline.")
        }
    }
}

// Uses exactly the style URL and MapLibre database used by the completed pack.
struct DownloadedJourneyMap: UIViewRepresentable {
    let journey: Journey
    let download: OfflineMapDownload
    let fitID: UUID
    let onError: (String?) -> Void
    var showsLocation = false
    var cameraTarget: MapCameraTarget? = nil
    var savedFocus: SavedMapFocus? = nil
    var onLocation: (CLLocation?) -> Void = { _ in }
    var onLocationError: () -> Void = { }
    var onMapInteraction: () -> Void = { }

    func makeCoordinator() -> Coordinator { Coordinator(onError: onError) }
    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleURL: URL(string: download.info.style))
        map.delegate = context.coordinator
        map.minimumZoomLevel = download.info.minimumZoom
        map.maximumZoomLevel = download.info.maximumZoom
        map.showsUserLocation = showsLocation
        map.showsUserHeadingIndicator = true
        map.setCenter(CLLocationCoordinate2D(
            latitude: (download.info.area.south + download.info.area.north) / 2,
            longitude: (download.info.area.west + download.info.area.east) / 2
        ), zoomLevel: 11, animated: false)
        return map
    }
    func updateUIView(_ map: MLNMapView, context: Context) {
        context.coordinator.onError = onError
        context.coordinator.onLocation = onLocation
        context.coordinator.onLocationError = onLocationError
        if map.showsUserLocation != showsLocation { map.showsUserLocation = showsLocation }
        context.coordinator.savedCamera.onInteraction = onMapInteraction
        context.coordinator.savedCamera.update(map, focus: savedFocus, target: cameraTarget)
        context.coordinator.overlay.update(map, journey: journey, fitID: fitID)
        // A stationary map may not render another frame just because fitID changed.
        context.coordinator.overlay.fitIfNeeded(map, enabled: context.coordinator.savedCamera.allowsRouteFit)
    }
    static func dismantleUIView(_ map: MLNMapView, coordinator: Coordinator) {
        map.showsUserLocation = false
        map.delegate = nil
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        let overlay = RouteMapOverlay()
        let savedCamera = SavedMapCamera()
        var onLocation: (CLLocation?) -> Void = { _ in }
        var onLocationError: () -> Void = { }
        func mapView(_ mapView: MLNMapView, regionWillChangeWith reason: MLNCameraChangeReason, animated: Bool) {
            savedCamera.willChange(mapView, reason: reason)
        }
        func mapView(_ mapView: MLNMapView, didUpdate userLocation: MLNUserLocation?) {
            let fix = userLocation?.location
            Task { @MainActor [weak self] in self?.onLocation(fix) }
        }
        func mapView(_ mapView: MLNMapView, didFailToLocateUserWithError error: Error) {
            Task { @MainActor [weak self] in self?.onLocationError() }
        }
        var onError: (String?) -> Void
        init(onError: @escaping (String?) -> Void) { self.onError = onError }
        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            overlay.refreshStyle(mapView)
            Task { @MainActor [weak self] in self?.onError(nil) }
        }
        func mapViewDidFinishRenderingFrame(_ mapView: MLNMapView, fullyRendered: Bool) {
            overlay.fitIfNeeded(mapView, enabled: savedCamera.allowsRouteFit)
        }
        func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
            Task { @MainActor [weak self] in
                self?.onError("The downloaded map could not load. Your saved journey details remain available. Reconnect and download the area again if needed.")
            }
        }
    }
}

// Keep lifecycle modifiers separate so ContentView stays small enough for Swift's type checker.
struct OfflineMapLifecycle: ViewModifier {
    let maps: OfflineMapStore
    let accountID: String?
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .environment(maps)
            .onChange(of: accountID, initial: true) { _, account in
                maps.setOnline(account != nil && scenePhase == .active)
            }
            .onChange(of: scenePhase) { _, phase in
                maps.setOnline(accountID != nil && phase == .active)
            }
            .task { await maps.monitor() }
    }
}
