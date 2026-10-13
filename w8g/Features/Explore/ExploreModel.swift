//
//  ExploreModel.swift
//  w8g
//
//  Created by Samuel on 29/9/2026.
//

import Foundation
import Observation

@Observable
@MainActor
final class ExploreModel {
    var query = ""
    var isSearching = false
    private(set) var results: [Place] = []
    private(set) var recents: [Place] = []
    private(set) var selectedPlace: Place?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var syncMessage: String?
    private(set) var cameraTarget: MapCameraTarget?
    @ObservationIgnored private let service = PlaceService()
    @ObservationIgnored private var searchRevision = 0
    @ObservationIgnored private var historyRevision = 0

    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func search() async {
        searchRevision += 1
        let revision = searchRevision
        let text = trimmedQuery
        results = []
        errorMessage = nil
        isLoading = false
        guard isSearching, !text.isEmpty else { return }
        guard text.count >= 2 else { return }
        isLoading = true
        defer {
            if revision == searchRevision { isLoading = false }
        }
        do {
            // Wait until typing pauses. SwiftUI cancels the old task when text changes.
            try await Task.sleep(for: .milliseconds(300))
            let places = try await service.search(text)
            guard !Task.isCancelled, revision == searchRevision,
                isSearching, text == trimmedQuery else { return }
            results = places
        } catch {
            guard !Task.isCancelled, revision == searchRevision else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadRecents() async {
        let revision = historyRevision
        do {
            let places = try await service.recentPlaces()
            guard !Task.isCancelled, revision == historyRevision else { return }
            recents = places
            syncMessage = nil
        } catch {
            guard !Task.isCancelled, revision == historyRevision else { return }
            syncMessage = "Recent searches could not be loaded. " + error.localizedDescription
        }
    }

    func select(_ place: Place) {
        selectedPlace = place
        cameraTarget = MapCameraTarget(lat: place.lat, lon: place.lon, zoom: 16)
        isSearching = false
        query = ""
        results = []
        errorMessage = nil
        searchRevision += 1
        isLoading = false
        historyRevision += 1
        recents.removeAll { $0.id == place.id }
        recents.insert(place, at: 0)
        recents = Array(recents.prefix(20))
    }

    func saveRecent(_ place: Place) async {
        do {
            try await service.remember(place)
            syncMessage = nil
        } catch {
            syncMessage = "This search is not synced yet. " + error.localizedDescription
        }
    }

    func closeSearch() {
        isSearching = false
        query = ""
        results = []
        errorMessage = nil
        searchRevision += 1
        isLoading = false
    }

    func clearSelection() {
        selectedPlace = nil
    }

    func focusOnUser(lat: Double, lon: Double) {
        cameraTarget = MapCameraTarget(lat: lat, lon: lon, zoom: 16)
    }
}
