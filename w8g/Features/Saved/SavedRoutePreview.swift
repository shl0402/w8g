//
//  SavedRoutePreview.swift
//  w8g
//
//  Created by Samuel on 30/9/2026.
//

import Foundation
import SwiftUI
import MapLibre
import Observation

// A small, cached image: cards do not each create a live interactive map.
@Observable
@MainActor
final class SavedRoutePreviewModel {
    var image: UIImage?
    var isLoading = false
    var message: String?
    @ObservationIgnored private var snapshotter: MLNMapSnapshotter?
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    func load(_ route: SavedRoute, online: Bool, scale: CGFloat) {
        cancel()
        image = nil
        message = nil
        let folder = URL.applicationSupportDirectory.appendingPathComponent("SavedJourneyPreviews")
        let file = folder.appendingPathComponent(route.previewName)
        if let cached = UIImage(contentsOfFile: file.path) {
            image = cached
            return
        }
        guard online else {
            message = "No map preview downloaded. Journey details remain available."
            return
        }
        let points = route.journey.mapCoordinates
        guard let south = points.map(\.latitude).min(), let north = points.map(\.latitude).max(),
            let west = points.map(\.longitude).min(), let east = points.map(\.longitude).max()
        else {
            message = "Map preview unavailable."
            return
        }
        let latPad = max(0.0005, (north - south) * 0.25)
        let lonPad = max(0.0005, (east - west) * 0.15)
        let options = MLNMapSnapshotOptions(
            styleURL: URL(string: "https://tiles.openfreemap.org/styles/liberty"),
            camera: MLNMapCamera(), size: CGSize(width: 360, height: 180)
        )
        options.coordinateBounds = MLNCoordinateBounds(
            sw: CLLocationCoordinate2D(latitude: south - latPad, longitude: west - lonPad),
            ne: CLLocationCoordinate2D(latitude: north + latPad, longitude: east + lonPad)
        )
        let renderScale = max(1, min(scale, 3))
        options.scale = renderScale
        options.showsAttribution = true
        let worker = MLNMapSnapshotter(options: options)
        snapshotter = worker
        isLoading = true
        let token = generation
        worker.start { [weak self] snapshot, error in
            // MapLibre documents this completion callback as running on the main queue.
            MainActor.assumeIsolated {
                guard let self, self.generation == token else { return }
                self.timeout?.cancel()
                self.timeout = nil
                self.isLoading = false
                self.snapshotter = nil
                guard let snapshot else {
                    self.message = "Preview could not load. Retry when connected."
                    return
                }
                let format = UIGraphicsImageRendererFormat()
                format.scale = renderScale
                let rendered = UIGraphicsImageRenderer(size: snapshot.image.size, format: format).image { ctx in
                    snapshot.image.draw(at: .zero)
                    for leg in route.journey.displayLegs {
                        let path = UIBezierPath()
                        let points = leg.coordinates
                        guard let first = points.first else { continue }
                        path.move(to: snapshot.point(for: first))
                        for point in points.dropFirst() { path.addLine(to: snapshot.point(for: point)) }
                        path.lineWidth = 5
                        UIColor.white.setStroke()
                        path.stroke()
                        path.lineWidth = 3
                        UIColor(TransitAppearance.color(leg)).setStroke()
                        path.stroke()
                    }
                    for stop in route.journey.stops {
                        let point = snapshot.point(for: stop.coordinate)
                        let dot = UIBezierPath(ovalIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
                        UIColor(AppTheme.ink).setFill()
                        dot.fill()
                    }
                }
                self.image = rendered
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    guard let data = rendered.pngData() else { return }
                    try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                } catch {
                    self.message = "Preview is visible but could not be stored for offline use."
                }
            }
        }

        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard let self, self.generation == token else { return }
            self.cancel()
            self.message = "Preview timed out. Retry when connected."
        }
    }

    func cancel() {
        generation = UUID()
        timeout?.cancel()
        timeout = nil
        snapshotter?.cancel()
        snapshotter = nil
        isLoading = false
    }
}

struct SavedRoutePreview: View {
    let route: SavedRoute
    let online: Bool
    var allowsRetry = true
    @Environment(\.displayScale) private var displayScale
    @State private var model = SavedRoutePreviewModel()

    var body: some View {
        VStack(spacing: 6) {
            if let image = model.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .accessibilityLabel("Route map preview of " + route.journey.title)
            } else {
                ZStack {
                    AppTheme.ink.opacity(0.04)
                    if model.isLoading {
                        ProgressView("Loading preview…")
                    } else {
                        Label("Map preview unavailable", systemImage: "map")
                            .font(.footnote)
                    }
                }.frame(height: 150)
            }
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(AppTheme.secondaryText)
                if online && allowsRetry {
                    Button("Retry preview") { model.load(route, online: true, scale: displayScale) }
                        .font(.caption).frame(minHeight: 44)
                }
            }
        }
        .task(id: route.previewName + (online ? "online" : "offline")) {
            model.load(route, online: online, scale: displayScale)
        }
        .onDisappear { model.cancel() }
    }
}
