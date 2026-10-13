//
//  RoutePlannerModel.swift
//  w8g
//
//  Created by Samuel on 29/9/2026.
//

import Foundation
import CoreLocation
import Observation

enum RouteSearchField: Equatable { case origin, destination, addStop, visit(UUID) }

struct RouteVisit: Identifiable, Codable {
    let id: UUID
    var place: Place
    var stayMinutes: Int?
    init(place: Place) { id = UUID(); self.place = place }
}

enum RouteTransport: String, Codable, CaseIterable, Identifiable {
    case mtr, bus, ferry, tram
    case lightRail = "light_rail"
    case funicular
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mtr: "MTR"
        case .bus: "Bus / minibus"
        case .ferry: "Ferry"
        case .tram: "Tram"
        case .lightRail: "Light Rail"
        case .funicular: "Peak Tram"
        }
    }
}

enum RoutePreference: String, Codable, CaseIterable, Identifiable {
    case fastest, walking, transfers
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fastest: "Fastest"
        case .walking: "Least walking"
        case .transfers: "Fewest transfers"
        }
    }
}

@Observable
@MainActor
final class RoutePlannerModel {
    private(set) var isMultiStop = false { didSet { onStateChange?() } }
    private(set) var visits: [RouteVisit] = [] { didSet { onStateChange?() } }
    private(set) var optimiseOrder = false { didSet { onStateChange?() } }
    private(set) var defaultStayMinutes = 0 { didSet { onStateChange?() } }
    private(set) var origin: Place? { didSet { onStateChange?() } }
    private(set) var destination: Place? { didSet { onStateChange?() } }
    private(set) var usesCurrentLocation = true { didSet { onStateChange?() } }
    private(set) var isVisible = false { didSet { onStateChange?() } }
    private(set) var leaveNow = true { didSet { onStateChange?() } }
    private(set) var departure = Date() { didSet { onStateChange?() } }
    private(set) var modes = Set(RouteTransport.allCases) { didSet { onStateChange?() } }
    private(set) var preference = RoutePreference.fastest { didSet { onStateChange?() } }
    private(set) var routes: [Journey] = [] { didSet { onStateChange?() } }
    private(set) var selectedID: String? { didSet { onStateChange?() } }
    private(set) var isWaiting = false { didSet { onStateChange?() } }
    private(set) var progress = ""
    private(set) var errorMessage: String?
    private(set) var canResume = false { didSet { onStateChange?() } }
    private(set) var fitID = UUID()
    @ObservationIgnored private let service: any RouteServing
    @ObservationIgnored private var pendingRequest: RouteRequest? { didSet { onStateChange?() } }
    @ObservationIgnored private var jobID: String? { didSet { onStateChange?() } }
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var pollingSuspended = false

    @ObservationIgnored var onStateChange: (() -> Void)?

    struct Snapshot: Codable {
        var isMultiStop: Bool
        var visits: [RouteVisit]
        var optimiseOrder: Bool
        var defaultStayMinutes: Int
        var origin: Place?
        var destination: Place?
        var usesCurrentLocation: Bool
        var isVisible: Bool
        var leaveNow: Bool
        var departure: Date
        var modes: Set<RouteTransport>
        var preference: RoutePreference
        var routes: [Journey]
        var selectedID: String?
        var pendingRequest: RouteRequest?
        var jobID: String?
        var wasWaiting: Bool
    }

    func snapshot() -> Snapshot {
        Snapshot(isMultiStop: isMultiStop, visits: visits, optimiseOrder: optimiseOrder,
            defaultStayMinutes: defaultStayMinutes, origin: origin, destination: destination,
            usesCurrentLocation: usesCurrentLocation, isVisible: isVisible, leaveNow: leaveNow,
            departure: departure, modes: modes, preference: preference, routes: routes,
            selectedID: selectedID, pendingRequest: pendingRequest, jobID: jobID, wasWaiting: isWaiting)
    }

    func restore(_ saved: Snapshot) {
        invalidate()
        isMultiStop = saved.isMultiStop
        visits = saved.visits
        optimiseOrder = saved.optimiseOrder
        defaultStayMinutes = saved.defaultStayMinutes
        origin = saved.origin
        destination = saved.destination
        usesCurrentLocation = saved.usesCurrentLocation
        isVisible = saved.isVisible
        leaveNow = saved.leaveNow
        departure = saved.departure
        modes = saved.modes
        preference = saved.preference
        routes = saved.routes
        selectedID = saved.selectedID
        // Reconnect only to a known job; never silently create a fresh route request on launch.
        if let id = saved.jobID, saved.pendingRequest != nil {
            pendingRequest = saved.pendingRequest
            jobID = id
            isWaiting = saved.wasWaiting
            pollingSuspended = saved.wasWaiting
            canResume = !saved.wasWaiting
        }
    }

    init(service: (any RouteServing)? = nil) { self.service = service ?? RouteService() }
    var selectedRoute: Journey? { routes.first { $0.id == selectedID } }
    var departureTitle: String {
        leaveNow ? "Leave now" : JourneyTime.string(departure, format: "dd MMM HH:mm")
    }
    var transportTitle: String {
        if modes.isEmpty { return "Walk only" }
        return modes.count == RouteTransport.allCases.count ? "Transport" : "Transport (\(modes.count))"
    }
    var originTitle: String {
        usesCurrentLocation ? "Current location" : origin?.name ?? "Choose starting point"
    }

    func choose(_ place: Place, for field: RouteSearchField) {
        invalidate()
        isVisible = true
        switch field {
        case .origin:
            origin = place
            usesCurrentLocation = false
        case .destination: destination = place
        case .addStop:
            guard isMultiStop, visits.count < 8 else { return }
            visits.append(RouteVisit(place: place))
        case .visit(let id):
            guard let index = visits.firstIndex(where: { $0.id == id }) else { return }
            visits[index].place = place
        }
    }
    func setMultiStop(_ enabled: Bool) {
        guard enabled != isMultiStop else { return }
        invalidate()
        isMultiStop = enabled
        isVisible = true
        if !enabled { visits = []; optimiseOrder = false }
    }
    func setOptimiseOrder(_ enabled: Bool) {
        invalidate()
        optimiseOrder = enabled
        // The existing server optimiser minimises total travel time only.
        if enabled { preference = .fastest }
    }
    func stayMinutes(for visit: RouteVisit) -> Int {
        visit.stayMinutes ?? defaultStayMinutes
    }
    func setDefaultStayMinutes(_ minutes: Int) {
        guard !isWaiting, (0...720).contains(minutes) else { return }
        invalidate()
        defaultStayMinutes = minutes
    }
    func setStayMinutes(_ minutes: Int?, for id: UUID) {
        guard !isWaiting, minutes == nil || (0...720).contains(minutes!),
            let index = visits.firstIndex(where: { $0.id == id }) else { return }
        invalidate()
        visits[index].stayMinutes = minutes
    }
    func removeVisit(_ id: UUID) {
        invalidate()
        visits.removeAll { $0.id == id }
    }
    func moveVisit(_ id: UUID, by offset: Int) {
        guard let index = visits.firstIndex(where: { $0.id == id }),
            visits.indices.contains(index + offset) else { return }
        invalidate()
        visits.swapAt(index, index + offset)
    }
    @discardableResult
    func moveVisit(_ id: UUID, to target: UUID) -> Bool {
        guard !isWaiting, id != target,
            let source = visits.firstIndex(where: { $0.id == id }),
            let destination = visits.firstIndex(where: { $0.id == target }) else { return false }
        invalidate()
        let visit = visits.remove(at: source)
        visits.insert(visit, at: destination)
        return true
    }
    func moveVisits(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard !isWaiting, !offsets.isEmpty,
            offsets.allSatisfy({ visits.indices.contains($0) }),
            (0...visits.count).contains(destination) else { return }
        let moving = offsets.map { visits[$0] }
        var reordered = visits.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let insertion = destination - offsets.filter { $0 < destination }.count
        reordered.insert(contentsOf: moving, at: insertion)
        guard reordered.map(\.id) != visits.map(\.id) else { return }
        invalidate()
        visits = reordered
    }
    func useCurrentLocation() {
        invalidate()
        // Keep the chosen place so switching GPS off can restore it.
        usesCurrentLocation = true
    }
    func stopUsingCurrentLocation() {
        invalidate()
        usesCurrentLocation = false
    }
    func swap(current: CLLocationCoordinate2D?) {
        let start = usesCurrentLocation ? currentPlace(current) : origin
        guard let start, let end = destination else {
            errorMessage = "Choose both places, or get your current location, before swapping."
            return
        }
        invalidate()
        origin = end
        destination = start
        visits.reverse()
        usesCurrentLocation = false
    }
    func setDeparture(now: Bool, date: Date) {
        invalidate()
        leaveNow = now
        departure = date
    }
    func setTransport(_ mode: RouteTransport, enabled: Bool) {
        invalidate()
        if enabled { modes.insert(mode) } else { modes.remove(mode) }
    }
    func setPreference(_ value: RoutePreference) {
        invalidate()
        preference = value
    }
    // A separate draft keeps existing results intact while the user edits or searches again.
    func editingCopy() -> RoutePlannerModel {
        let draft = RoutePlannerModel(service: service)
        draft.isMultiStop = isMultiStop
        draft.visits = visits
        draft.optimiseOrder = optimiseOrder
        draft.defaultStayMinutes = defaultStayMinutes
        draft.origin = origin
        draft.destination = destination
        draft.usesCurrentLocation = usesCurrentLocation
        draft.isVisible = true
        draft.leaveNow = leaveNow
        draft.departure = departure
        draft.modes = modes
        draft.preference = preference
        return draft
    }

    func edit() { invalidate() }
    func close() {
        invalidate()
        isVisible = false
        origin = nil
        destination = nil
        visits = []
        isMultiStop = false
        optimiseOrder = false
        usesCurrentLocation = true
    }
    func select(_ route: Journey) {
        selectedID = route.id
        fitID = UUID()
    }
    func replaceRoute(_ originalID: String, with updated: Journey) {
        guard let index = routes.firstIndex(where: { $0.id == originalID }) else { return }
        routes[index] = updated
        select(updated)
    }
    func fitRoute() { fitID = UUID() }

    func plan(current: CLLocationCoordinate2D?) {
        guard !isWaiting else { return }
        let start = usesCurrentLocation ? currentPlace(current) : origin
        guard let start, let end = destination else {
            errorMessage = "Choose a starting point, or tap the location arrow to get your position."
            return
        }
        let stops = [start] + (isMultiStop ? visits.map(\.place) : []) + [end]
        guard stops.allSatisfy(\.isInHongKong), (2...10).contains(stops.count) else {
            errorMessage = "Choose 2–10 places within Hong Kong."
            return
        }
        // A round trip legitimately returns to its starting place.
        let distinctStops = stops.count > 2 && stops.first?.id == stops.last?.id ? Array(stops.dropLast()) : stops
        guard Set(distinctStops.map(\.id)).count == distinctStops.count else {
            errorMessage = "Each stop must be a different place. Remove or change the repeated stop."
            return
        }
        invalidate()
        let date = leaveNow ? Date() : departure
        pendingRequest = RouteRequest(
            key: UUID().uuidString, stops: stops, departure: JourneyTime.departure(date),
            modes: RouteTransport.allCases.filter { modes.contains($0) }.map(\.rawValue),
            preference: preference.rawValue, order: isMultiStop && optimiseOrder ? "optimise" : "ordered",
            defaultStayMinutes: isMultiStop ? defaultStayMinutes : 0,
            stopStayMinutes: isMultiStop ? [0] + visits.map(\.stayMinutes) + [0] : nil
        )
        beginWaiting()
    }

    func resume() {
        guard canResume, pendingRequest != nil, !isWaiting else { return }
        beginWaiting()
    }
    // Leaving the screen suspends network polling, not the user's search.
    // Keep the progress UI and reconnect to the same job when visible again.
    func suspendProgressUpdates() {
        guard isWaiting, !pollingSuspended else { return }
        revision += 1
        task?.cancel()
        task = nil
        pollingSuspended = true
    }
    func continueProgressUpdates() {
        guard pollingSuspended, isWaiting, pendingRequest != nil else { return }
        beginWaiting()
    }
    func stopWaiting() {
        guard isWaiting else { return }
        pollingSuspended = false
        revision += 1
        task?.cancel()
        task = nil
        isWaiting = false
        canResume = pendingRequest != nil
        progress = "Waiting paused. The server may still be calculating."
    }

    private func currentPlace(_ coordinate: CLLocationCoordinate2D?) -> Place? {
        guard let coordinate else { return nil }
        return Place(
            name: "Current location", lat: coordinate.latitude, lon: coordinate.longitude, source: "location")
    }
    private func invalidate() {
        pollingSuspended = false
        revision += 1
        task?.cancel()
        task = nil
        isWaiting = false
        canResume = false
        pendingRequest = nil
        jobID = nil
        routes = []
        selectedID = nil
        errorMessage = nil
        progress = ""
    }
    private func beginWaiting() {
        guard let request = pendingRequest else { return }
        pollingSuspended = false
        revision += 1
        let version = revision
        isWaiting = true
        canResume = false
        errorMessage = nil
        progress = jobID == nil ? "Checking the timetable…" : "Checking your route…"
        task = Task { [weak self] in
            guard let self else { return }
            await self.run(request, version: version)
        }
    }
    private func run(_ request: RouteRequest, version: Int) async {
        defer {
            if revision == version {
                isWaiting = false
                task = nil
            }
        }
        do {
            if jobID == nil {
                let status = try await service.status()
                try checkActive(version)
                guard let date = JourneyTime.parse(request.departure) else {
                    throw APIError(message: "Choose a valid departure time.")
                }
                try status.check(date)
                progress = "Starting route search…"
                // Reusing this key makes retries safe if the server accepted a request before a timeout.
                let id = try await service.start(request)
                try checkActive(version)
                jobID = id
            }
            guard let id = jobID else { return }
            for _ in 0..<300 {
                try checkActive(version)
                let job = try await service.job(id)
                try checkActive(version)
                switch job.state {
                case "queued", "running": progress = job.progress ?? "Planning your journey…"
                case "succeeded":
                    guard let found = job.routes, !found.isEmpty else {
                        pendingRequest = nil
                        throw APIError(
                            message: "No route was found. Try another time or transport selection.")
                    }
                    routes = found
                    select(found[0])
                    pendingRequest = nil
                    canResume = false
                    progress = ""
                    return
                case "failed":
                    pendingRequest = nil
                    throw APIError(message: job.error ?? "The route could not be calculated.")
                default: throw APIError(message: "Unknown route status. Try resuming the search.")
                }
                try await Task.sleep(for: .seconds(2))
            }
            throw APIError(
                message: "This calculation is taking longer than expected. You can resume checking it.")
        } catch {
            guard !Task.isCancelled, revision == version else { return }
            errorMessage = error.localizedDescription
            canResume = pendingRequest != nil
        }
    }
    private func checkActive(_ version: Int) throws {
        try Task.checkCancellation()
        if revision != version { throw CancellationError() }
    }
}
