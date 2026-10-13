import Foundation
import CoreLocation

// Stand-ins keep this executable focused on the real planner and request types.
struct Journey: Codable { let id: String }
enum JourneyTime {
    static func parse(_ value: String?) -> Date? { value.flatMap { ISO8601DateFormatter().date(from: $0) } }
    static func departure(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    static func day(_ date: Date) -> String { departure(date) }
    static func string(_ date: Date, format: String) -> String { departure(date) }
}
struct APIError: LocalizedError { let message: String; var errorDescription: String? { message } }
@MainActor final class APIClient {
    static let shared = APIClient()
    func get<T: Decodable>(_ path: String) async throws -> T { fatalError("Unexpected network") }
    func post<B: Encodable, T: Decodable>(_ path: String, body: B) async throws -> T { fatalError("Unexpected network") }
}
@MainActor final class FakeRoutes: RouteServing {
    var requests: [RouteRequest] = []
    var hold = false
    var jobContinuation: CheckedContinuation<RouteJob, Never>?
    func status() async throws -> RoutingStatus {
        RoutingStatus(ready: true, minDate: "2020-01-01T00:00:00Z", maxDate: "2040-01-01T00:00:00Z")
    }
    func start(_ request: RouteRequest) async throws -> String { requests.append(request); return "job" }
    func job(_ id: String) async throws -> RouteJob {
        if hold { return await withCheckedContinuation { jobContinuation = $0 } }
        return RouteJob(id: id, state: "succeeded", progress: nil, error: nil, routes: [Journey(id: "route")])
    }
}
@main struct MultiStopChecks {
    @MainActor static func settle() async { for _ in 0..<100 { await Task.yield() } }
    @MainActor static func main() async throws {
        let a = Place(name: "Central", lat: 22.28, lon: 114.15)
        let b = Place(name: "Admiralty", lat: 22.28, lon: 114.16)
        let c = Place(name: "Wan Chai", lat: 22.28, lon: 114.17)
        let d = Place(name: "North Point", lat: 22.28, lon: 114.19)
        let service = FakeRoutes(), model = RoutePlannerModel(service: nil)
        // Never call the default service: production initializer remains available.
        model.close()
        let planner = RoutePlannerModel(service: service)
        planner.setMultiStop(true)
        planner.choose(a, for: .origin); planner.choose(d, for: .destination)
        planner.choose(b, for: .addStop); planner.choose(c, for: .addStop)
        let firstID = planner.visits[0].id
        planner.moveVisit(firstID, by: 1)
        assert(planner.visits.map(\.place) == [c,b])
        assert(planner.visits[1].id == firstID)
        planner.plan(current: nil); await settle()
        assert(service.requests.last?.stops == [a,c,b,d])
        assert(service.requests.last?.order == "ordered")
        assert(planner.selectedRoute?.id == "route")
        let bytes = try JSONEncoder().encode(service.requests.last!)
        let payload = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        assert(payload["channel"] as? String == "explore")
        assert((payload["stops"] as? [Any])?.count == 4)
        planner.setPreference(.walking); planner.setOptimiseOrder(true)
        assert(planner.preference == .fastest)
        planner.plan(current: nil); await settle()
        assert(service.requests.last?.order == "optimise")
        planner.swap(current: nil)
        assert(planner.origin == d && planner.destination == a)
        assert(planner.visits.map(\.place) == [b,c])
        planner.choose(d, for: .visit(firstID)); planner.plan(current: nil)
        assert(planner.errorMessage != nil && !planner.isWaiting)
        planner.setMultiStop(false)
        assert(planner.visits.isEmpty && !planner.optimiseOrder)
        planner.plan(current: nil); await settle()
        assert(service.requests.last?.stops == [d,a])
        planner.setMultiStop(true)
        for i in 0..<12 { planner.choose(Place(name: "Stop \(i)", lat: 22.3, lon: 114.2 + Double(i)/1000), for: .addStop) }
        assert(planner.visits.count == 8)
        let originalIDs = planner.visits.map(\.id)
        assert(planner.moveVisit(originalIDs[0], to: originalIDs[7]))
        assert(planner.visits.map(\.id) == Array(originalIDs.dropFirst()) + [originalIDs[0]])
        assert(planner.moveVisit(originalIDs[0], to: originalIDs[1]))
        assert(planner.visits.map(\.id) == originalIDs)
        assert(!planner.moveVisit(UUID(), to: originalIDs[1]))
        assert(!planner.moveVisit(originalIDs[0], to: UUID()))
        assert(!planner.moveVisit(originalIDs[0], to: originalIDs[0]))
        assert(planner.visits.map(\.id) == originalIDs)

        // Native List move offsets insert, rather than exchanging two rows.
        planner.moveVisits(fromOffsets: IndexSet(integer: 0), toOffset: 4)
        assert(planner.visits.map(\.id) == Array(originalIDs[1...3]) + [originalIDs[0]] + Array(originalIDs[4...]))
        planner.moveVisits(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        assert(planner.visits.map(\.id) == originalIDs)
        planner.moveVisits(fromOffsets: IndexSet([0, 2]), toOffset: 8)
        assert(planner.visits.map(\.id) == [1, 3, 4, 5, 6, 7, 0, 2].map { originalIDs[$0] })
        let reorderedIDs = planner.visits.map(\.id)
        planner.moveVisits(fromOffsets: IndexSet(integer: 8), toOffset: 0)
        planner.moveVisits(fromOffsets: IndexSet(integer: 0), toOffset: 9)
        planner.moveVisits(fromOffsets: IndexSet(integer: 0), toOffset: 1)
        assert(planner.visits.map(\.id) == reorderedIDs)

        planner.useCurrentLocation()
        planner.stopUsingCurrentLocation()
        assert(!planner.usesCurrentLocation && planner.origin == d)
        planner.plan(current: CLLocationCoordinate2D(latitude: 22.31, longitude: 114.3))
        await settle()
        assert(service.requests.last?.stops.first == d)
        let emptyService = FakeRoutes()
        let emptyOrigin = RoutePlannerModel(service: emptyService)
        emptyOrigin.setMultiStop(true)
        emptyOrigin.choose(d, for: .destination)
        emptyOrigin.stopUsingCurrentLocation()
        assert(emptyOrigin.originTitle == "Choose starting point")
        emptyOrigin.plan(current: CLLocationCoordinate2D(latitude: 22.31, longitude: 114.3))
        await settle()
        assert(emptyOrigin.errorMessage != nil && emptyService.requests.isEmpty)
        emptyOrigin.useCurrentLocation()
        emptyOrigin.plan(current: CLLocationCoordinate2D(latitude: 22.31, longitude: 114.3))
        await settle()
        assert(emptyService.requests.last?.stops.first?.source == "location")

        planner.useCurrentLocation(); planner.plan(current: nil)
        assert(planner.errorMessage != nil)
        planner.plan(current: CLLocationCoordinate2D(latitude: 22.31, longitude: 114.3)); await settle()
        assert(service.requests.last?.stops.count == 10)
        // Background/tab transitions preserve progress and automatically reconnect.
        let backgroundService = FakeRoutes()
        backgroundService.hold = true
        let background = RoutePlannerModel(service: backgroundService)
        background.choose(a, for: .origin)
        background.choose(b, for: .destination)
        background.plan(current: nil)
        await settle()
        assert(backgroundService.requests.count == 1)
        background.suspendProgressUpdates()
        background.suspendProgressUpdates() // Scene change and disappearance may both fire.
        assert(background.isWaiting && !background.canResume)
        backgroundService.jobContinuation?.resume(returning: RouteJob(
            id: "job", state: "succeeded", progress: nil, error: nil,
            routes: [Journey(id: "stale-background-response")]))
        await settle()
        assert(background.routes.isEmpty && background.isWaiting)
        backgroundService.hold = false
        background.continueProgressUpdates()
        background.continueProgressUpdates() // Appearance and activation must not duplicate polling.
        await settle()
        assert(background.selectedID == "route" && !background.isWaiting)
        assert(backgroundService.requests.count == 1)

        // Deliberate stop and closing a draft must never auto-resume.
        backgroundService.hold = true
        background.plan(current: nil)
        await settle()
        background.suspendProgressUpdates()
        background.stopWaiting()
        background.continueProgressUpdates()
        assert(background.canResume && !background.isWaiting)
        backgroundService.jobContinuation?.resume(returning: RouteJob(
            id: "job", state: "succeeded", progress: nil, error: nil, routes: [Journey(id: "stale")]))
        await settle()
        assert(background.routes.isEmpty)
        background.plan(current: nil)
        await settle()
        background.suspendProgressUpdates()
        background.close()
        background.continueProgressUpdates()
        assert(!background.isWaiting && !background.canResume)
        backgroundService.jobContinuation?.resume(returning: RouteJob(
            id: "job", state: "succeeded", progress: nil, error: nil, routes: [Journey(id: "stale")]))
        await settle()
        assert(background.routes.isEmpty)

        // A detail edit updates the visible map/result repeatedly without replanning.
        let editService = FakeRoutes()
        let editable = RoutePlannerModel(service: editService)
        editable.choose(a, for: .origin)
        editable.choose(b, for: .destination)
        editable.plan(current: nil)
        await settle()
        let oldFit = editable.fitID
        editable.replaceRoute("route", with: Journey(id: "edited-one"))
        assert(editable.selectedID == "edited-one" && editable.fitID != oldFit)
        editable.replaceRoute("edited-one", with: Journey(id: "edited-two"))
        assert(editable.selectedID == "edited-two" && editable.routes.count == 1)
        editable.replaceRoute("outdated-id", with: Journey(id: "ignored"))
        assert(editable.selectedID == "edited-two" && editService.requests.count == 1)

        // A trip alternative request includes only its two endpoints and chosen modes.
        let alternativesService = FakeRoutes()
        let alternatives = RoutePlannerModel(service: alternativesService)
        alternatives.choose(b, for: .origin)
        alternatives.choose(c, for: .destination)
        alternatives.setDeparture(now: false, date: JourneyTime.parse("2026-10-02T10:10:00Z")!)
        for mode in RouteTransport.allCases { alternatives.setTransport(mode, enabled: mode == .mtr) }
        alternatives.plan(current: nil)
        await settle()
        assert(alternativesService.requests.count == 1)
        assert(alternativesService.requests[0].stops == [b, c])
        assert(alternativesService.requests[0].modes == ["mtr"])
        assert(alternativesService.requests[0].order == "ordered")

        let stayService = FakeRoutes()
        let stayPlanner = RoutePlannerModel(service: stayService)
        stayPlanner.setMultiStop(true)
        stayPlanner.choose(a, for: .origin)
        stayPlanner.choose(d, for: .destination)
        stayPlanner.choose(b, for: .addStop)
        stayPlanner.choose(c, for: .addStop)
        stayPlanner.setDefaultStayMinutes(15)
        let customVisit = stayPlanner.visits[0].id
        stayPlanner.setStayMinutes(7, for: customVisit)
        stayPlanner.moveVisits(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        assert(stayPlanner.visits.map { stayPlanner.stayMinutes(for: $0) } == [15, 7])
        stayPlanner.setDefaultStayMinutes(20)
        assert(stayPlanner.visits.map { stayPlanner.stayMinutes(for: $0) } == [20, 7])
        stayPlanner.plan(current: nil)
        await settle()
        assert(stayService.requests.last?.defaultStayMinutes == 20)
        assert(stayService.requests.last?.stopStayMinutes == [0, nil, 7, 0])
        let stayPayload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(stayService.requests.last!)) as! [String: Any]
        assert((stayPayload["stopStayMinutes"] as! [Any])[1] is NSNull)
        stayPlanner.setStayMinutes(nil, for: customVisit)
        assert(stayPlanner.visits.map { stayPlanner.stayMinutes(for: $0) } == [20, 20])
        stayPlanner.setStayMinutes(0, for: customVisit)
        stayPlanner.setStayMinutes(721, for: customVisit)
        assert(stayPlanner.visits.last?.stayMinutes == 0)
        stayPlanner.setMultiStop(false)
        stayPlanner.plan(current: nil)
        await settle()
        assert(stayService.requests.last?.defaultStayMinutes == 0 && stayService.requests.last?.stopStayMinutes == nil)

        // A paused request resumes the same key/job; an edited draft rejects late completion.
        let slow = FakeRoutes(); slow.hold = true
        let waiting = RoutePlannerModel(service: slow)
        waiting.choose(a, for: .origin); waiting.choose(b, for: .destination)
        waiting.plan(current: nil); await settle()
        assert(slow.jobContinuation != nil)
        waiting.stopWaiting(); assert(waiting.canResume)
        slow.jobContinuation?.resume(returning: RouteJob(id: "job", state: "succeeded", progress: nil, error: nil, routes: [Journey(id: "stale")]))
        await settle(); assert(waiting.routes.isEmpty)
        slow.hold = false; waiting.resume(); await settle()
        assert(slow.requests.count == 1 && waiting.selectedID == "route")
        waiting.close(); assert(waiting.routes.isEmpty && !waiting.isVisible)
        print("PASS: ordered/optimised payloads, stable drag reordering in both directions and stale-target rejection, native list insertion offsets, GPS toggle restoration, automatic background return, manual-stop preservation, reverse, duplicate validation, two-point switch, 10-stop cap, GPS, pause/resume and stale result protection")
    }
}
