//
//  OfflineMapStore.swift
//  w8g
//
//  Created by Samuel on 1/10/2026.
//

import Foundation
import Observation
import CoreLocation
import MapLibre

struct OfflineArea: Codable, Equatable {
    let south: Double
    let west: Double
    let north: Double
    let east: Double

    static let hongKong = OfflineArea(south: 22.13, west: 113.82, north: 22.58, east: 114.46)

    static func around(_ journey: Journey) -> OfflineArea? {
        let points = journey.mapCoordinates
        guard !points.isEmpty, points.allSatisfy({
            CLLocationCoordinate2DIsValid($0) && $0.latitude >= 22.13 && $0.latitude <= 22.58
                && $0.longitude >= 113.82 && $0.longitude <= 114.46
        }) else { return nil }
        return OfflineArea(
            south: max(hongKong.south, points.map(\.latitude).min()! - 0.008),
            west: max(hongKong.west, points.map(\.longitude).min()! - 0.008),
            north: min(hongKong.north, points.map(\.latitude).max()! + 0.008),
            east: min(hongKong.east, points.map(\.longitude).max()! + 0.008)
        )
    }

    var bounds: MLNCoordinateBounds {
        MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: south, longitude: west),
            ne: CLLocationCoordinate2D(latitude: north, longitude: east))
    }

    func contains(_ other: OfflineArea) -> Bool {
        south <= other.south && west <= other.west && north >= other.north && east >= other.east
    }
}

struct OfflineMapInfo: Codable, Identifiable {
    let version: Int
    let id: UUID
    let title: String
    let area: OfflineArea
    let created: Date
    let style: String
    let minimumZoom: Double
    let maximumZoom: Double
}

struct OfflineMapDownload: Identifiable {
    let info: OfflineMapInfo
    let state: MLNOfflinePackState
    let completed: UInt64
    let expected: UInt64
    let bytes: UInt64
    var id: UUID { info.id }
    var ready: Bool { state == .complete }
    var active: Bool { state == .active }
    var status: String {
        if ready { return "Ready offline" }
        if active { return "Downloading…" }
        if state == .unknown { return "Checking download…" }
        return "Paused / incomplete"
    }
    var size: String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}

@Observable
@MainActor
final class OfflineMapStore {
    static let styleURL = URL(string: "https://tiles.openfreemap.org/styles/liberty")!
    private(set) var downloads: [OfflineMapDownload] = []
    private(set) var loaded = false
    private(set) var busy = false
    private(set) var canDownload = false
    var errorMessage: String?
    @ObservationIgnored private var packs: [UUID: MLNOfflinePack] = [:]
    @ObservationIgnored private var requested = Set<ObjectIdentifier>()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    func setOnline(_ online: Bool) {
        canDownload = online
        OfflineMapNetwork.shared.allowsRequests = online
        if !online { pauseAll() }
    }

    // One shared monitor for the whole app. MapLibre persists packs across app launches.
    func monitor() async {
        let center = NotificationCenter.default
        for name in [NSNotification.Name.MLNOfflinePackError, .MLNOfflinePackMaximumMapboxTilesReached] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.canDownload else { return }
                    self.pauseAll()
                    self.errorMessage = "Download paused. Check internet access and free storage, then tap Resume. A tile limit may require removing an old map."
                }
            })
        }
        defer {
            for observer in observers { center.removeObserver(observer) }
            observers = []
        }
        while !Task.isCancelled {
            refresh()
            do { try await Task.sleep(for: .seconds(1)) } catch { break }
        }
    }

    private func refresh() {
        guard !busy, let stored = MLNOfflineStorage.shared.packs else { return }
        loaded = true
        var next: [OfflineMapDownload] = []
        var nextPacks: [UUID: MLNOfflinePack] = [:]
        for pack in stored {
            guard let info = try? JSONDecoder().decode(OfflineMapInfo.self, from: pack.context),
                info.version == 1 else { continue }
            let identity = ObjectIdentifier(pack)
            if requested.insert(identity).inserted { pack.requestProgress() }
            if !canDownload && pack.state == .active { pack.suspend() }
            let progress = pack.progress
            next.append(OfflineMapDownload(info: info, state: pack.state,
                completed: progress.countOfResourcesCompleted, expected: progress.countOfResourcesExpected,
                bytes: progress.countOfBytesCompleted))
            nextPacks[info.id] = pack
        }
        packs = nextPacks
        downloads = next.sorted { $0.info.created > $1.info.created }
    }

    func covering(_ journey: Journey) -> OfflineMapDownload? {
        guard let area = OfflineArea.around(journey) else { return nil }
        return downloads.first {
            $0.ready && $0.info.style == Self.styleURL.absoluteString && $0.info.area.contains(area)
        }
    }

    func add(title: String, area: OfflineArea) {
        guard canDownload, loaded, !busy else { return }
        if downloads.contains(where: { $0.info.area == area && $0.info.style == Self.styleURL.absoluteString }) {
            errorMessage = "This area is already listed. Resume its download or remove it before downloading again."
            return
        }
        errorMessage = nil
        busy = true
        let info = OfflineMapInfo(version: 1, id: UUID(), title: title, area: area, created: Date(),
            style: Self.styleURL.absoluteString, minimumZoom: 8, maximumZoom: 16)
        guard let context = try? JSONEncoder().encode(info) else { busy = false; return }
        let region = MLNTilePyramidOfflineRegion(styleURL: Self.styleURL, bounds: area.bounds,
            fromZoomLevel: info.minimumZoom, toZoomLevel: info.maximumZoom)
        MLNOfflineStorage.shared.addPack(for: region, withContext: context) { [weak self] pack, error in
            // MapLibre documents this completion as running on the main queue.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.busy = false
                if let error { self.errorMessage = error.localizedDescription }
                if let pack, self.canDownload { pack.resume() }
                self.refresh()
            }
        }
    }

    func toggle(_ item: OfflineMapDownload) {
        guard !busy, let pack = packs[item.id], !item.ready else { return }
        errorMessage = nil
        if pack.state == .active { pack.suspend() }
        else if canDownload { pack.resume() }
        refresh()
    }

    func pauseAll() {
        guard !busy else { return }
        for pack in packs.values where pack.state == .active { pack.suspend() }
    }

    func remove(_ item: OfflineMapDownload) {
        guard !busy, let pack = packs.removeValue(forKey: item.id) else { return }
        busy = true
        // MapLibre invalidates removed packs. Drop all references before the next refresh.
        downloads.removeAll { $0.id == item.id }
        pack.suspend()
        MLNOfflineStorage.shared.removePack(pack) { [weak self] error in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.busy = false
                self.errorMessage = error?.localizedDescription
                self.refresh()
            }
        }
    }
}
