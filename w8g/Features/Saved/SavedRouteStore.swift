//
//  SavedRouteStore.swift
//  w8g
//
//  Created by Samuel on 30/9/2026.
//

import Foundation
import Observation
import CryptoKit

struct SavedRoute: Codable, Identifiable, Hashable {
    enum Pending: String, Codable { case none, save, delete }
    let ownerID: String
    let recordID: String
    var journey: Journey
    var updated: Double
    var pending: Pending

    // Record IDs belong to an account. Offline mode may show downloads from several accounts.
    var id: String { ownerID + ":" + recordID }

    // Navigation compares the identity and immutable saved revision, not every geometry point.
    static func == (lhs: SavedRoute, rhs: SavedRoute) -> Bool {
        lhs.id == rhs.id && lhs.updated == rhs.updated && lhs.pending == rhs.pending
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(updated)
        hasher.combine(pending)
    }
    var previewName: String {
        SHA256.hash(data: Data((id + ":" + String(updated)).utf8))
            .map { String(format: "%02x", $0) }.joined() + ".png"
    }
}

@Observable
@MainActor
final class SavedRouteStore {
    private(set) var records: [SavedRoute] = []
    private(set) var accountID: String?
    private(set) var isSyncing = false
    private(set) var errorMessage: String?
    private(set) var storageError: String?
    private(set) var skippedRows = 0
    @ObservationIgnored private let file: URL
    @ObservationIgnored private let service: any SavedRouteRemote
    @ObservationIgnored private var revision = UUID()

    private struct Archive: Codable {
        let version: Int
        let records: [SavedRoute]
    }

    init(file: URL? = nil, service: (any SavedRouteRemote)? = nil) {
        self.file = file ?? URL.applicationSupportDirectory
            .appendingPathComponent("SavedJourneys", isDirectory: true)
            .appendingPathComponent("routes-v1.json")
        self.service = service ?? SavedRouteService()
        do {
            if FileManager.default.fileExists(atPath: self.file.path) {
                let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: self.file))
                guard archive.version == 1 else {
                    throw APIError(message: "This saved-route file needs a newer app version.")
                }
                records = archive.records
            }
        } catch {
            // Preserve the original file. Never silently replace unreadable user data.
            storageError = "Saved routes could not be opened. " + error.localizedDescription
        }
    }

    func selectAccount(_ id: String?) {
        guard accountID != id else { return }
        revision = UUID()
        accountID = id
        isSyncing = false
        errorMessage = nil
        skippedRows = 0
    }

    func visible(for owner: String?) -> [SavedRoute] {
        records.filter {
            $0.pending != .delete && (owner == nil || $0.ownerID == owner)
        }.sorted { $0.updated > $1.updated }
    }

    func contains(_ journey: Journey, owner: String) -> Bool {
        records.contains {
            $0.ownerID == owner && $0.recordID == journey.id && $0.pending != .delete
        }
    }

    func pendingCount(for owner: String) -> Int {
        records.filter { $0.ownerID == owner && $0.pending != .none }.count
    }

    @discardableResult
    func save(_ journey: Journey, owner: String) -> Bool {
        guard accountID == owner else { return false }
        guard journey.id.range(of: "^[A-Za-z0-9_-]{1,100}$", options: .regularExpression) != nil else {
            errorMessage = "This route has an invalid record ID. Search for it again."
            return false
        }
        if contains(journey, owner: owner) { return true }
        var next = records.filter { !($0.ownerID == owner && $0.recordID == journey.id) }
        next.append(SavedRoute(
            ownerID: owner, recordID: journey.id, journey: journey,
            updated: Date().timeIntervalSince1970, pending: .save
        ))
        return persist(next)
    }

    func remove(_ route: SavedRoute, online: Bool) {
        guard !isSyncing else { return }
        if online {
            guard accountID == route.ownerID else { return }
            var next = records
            guard let index = next.firstIndex(where: { $0.id == route.id }) else { return }
            next[index].pending = .delete
            _ = persist(next)
        } else {
            // Offline removal affects this device only, and never sends a server request.
            _ = persist(records.filter { $0.id != route.id })
        }
    }

    func synchronise(owner: String) async {
        guard accountID == owner, !isSyncing, storageError == nil else { return }
        let token = revision
        isSyncing = true
        errorMessage = nil
        defer { if token == revision { isSyncing = false } }
        do {
            while let change = records.first(where: { $0.ownerID == owner && $0.pending != .none }) {
                try check(owner, token)
                try await service.write(
                    id: change.recordID, journey: change.journey, deleting: change.pending == .delete
                )
                try check(owner, token)
                var next = records
                if let index = next.firstIndex(where: { $0.id == change.id }),
                    next[index].pending == change.pending
                {
                    if change.pending == .delete {
                        next.remove(at: index)
                    } else {
                        next[index].pending = .none
                    }
                }
                guard persist(next) else { return }
            }
            let remote = try await service.load()
            try check(owner, token)
            var next = records
            skippedRows = remote.filter { $0.kind == "saved" && $0.journey == nil }.count
            for row in remote where row.kind == "saved" {
                guard let journey = row.journey else { continue }
                let index = next.firstIndex { $0.ownerID == owner && $0.recordID == row.id }
                // A save/delete made while GET was in flight must win over that old response.
                if let index, next[index].pending != .none { continue }
                let item = SavedRoute(
                    ownerID: owner, recordID: row.id, journey: journey,
                    updated: row.updated, pending: .none
                )
                if let index { next[index] = item } else { next.append(item) }
            }
            // Keep downloaded copies absent from a response: it may be paginated/limited.
            _ = persist(next)
        } catch {
            guard token == revision, accountID == owner else { return }
            if error is CancellationError || Task.isCancelled { return }
            errorMessage = "Account sync failed. Your downloaded routes are still available. "
                + error.localizedDescription
        }
    }

    private func check(_ owner: String, _ token: UUID) throws {
        try Task.checkCancellation()
        guard accountID == owner, revision == token else { throw CancellationError() }
    }

    private func persist(_ next: [SavedRoute]) -> Bool {
        guard storageError == nil else { return false }
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(Archive(version: 1, records: next))
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            records = next
            return true
        } catch {
            errorMessage = "Could not save changes on this iPhone. " + error.localizedDescription
            return false
        }
    }
}
