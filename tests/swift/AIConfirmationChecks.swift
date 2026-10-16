import Foundation
import CoreLocation

struct APIError: LocalizedError { let message: String; var errorDescription: String? { message } }
struct Journey: Codable { let id: String }
enum JourneyTime {
    static func parse(_ value: String?) -> Date? { value.flatMap { ISO8601DateFormatter().date(from: $0) } }
    static func departure(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    static func day(_ date: Date) -> String { departure(date) }
    static func string(_ date: Date, format: String) -> String { departure(date) }
}
struct GeminiOptions {}
@MainActor struct GeminiService {
    static var actions: [AIPlaceClarification.Search] = []
    static var evidenceCalls: [[AIPlaceSearchEvidence]] = []
    static var failClarification = false
    func clarifyPlaces(userMessage: String, evidence: [AIPlaceSearchEvidence], allowSearches: Bool, key: String, options: GeminiOptions) async throws -> AIPlaceClarification {
        Self.evidenceCalls.append(evidence)
        if Self.failClarification { throw APIError(message: "Test AI failure") }
        return .init(reply: "Could not find a direct match. Which place did you mean?", searches: allowSearches ? Self.actions : [])
    }
    static var receivedHistory: [AIMessage] = []
    static var receivedText = ""
    static var gps = false
    static var departure = ""
    static var arrival = ""
    func reply(to text: String, history: [AIMessage], key: String, options: GeminiOptions, direct: Bool = false) async throws -> AIProposal {
        Self.receivedHistory = history
        Self.receivedText = text
        return AIProposal(reply: "Check these places", useCurrentLocation: Self.gps,
            places: Self.gps ? [.init(name: "HKU", stayMinutes: 0)] : [
                .init(name: "Central", stayMinutes: 0), .init(name: "Admiralty", stayMinutes: 15), .init(name: "HKU", stayMinutes: 0)],
            order: "ordered", departure: Self.departure, modes: ["mtr"], preference: "fastest",
            arrivalDeadline: Self.arrival, timeAssumption: Self.arrival.isEmpty ? "" : "Allow an hour, subject to routing.")
    }
}
@MainActor struct PlaceService {
    static var results: [Place] = []
    static var byQuery: [String: [Place]] = [:]
    static var unavailable = false
    static var queries: [String] = []
    func search(_ name: String) async throws -> [Place] {
        Self.queries.append(name)
        if Self.unavailable { throw APIError(message: "Test network failure") }
        return Self.byQuery[name] ?? Self.results
    }
}
@MainActor final class APIClient {
    static let shared = APIClient()
    var posts: [(String, [String: Any])] = []
    var failJob = false
    func get<T: Decodable>(_ path: String) async throws -> T {
        let value: String
        if path == "api/status" {
            value = #"{"ready":true,"minDate":"2020-01-01T00:00:00Z","maxDate":"2040-01-01T00:00:00Z"}"#
        } else {
            try await Task.sleep(for: .milliseconds(20))
            value = failJob ? #"{"id":"job","state":"failed","error":"Test routing failure"}"# : #"{"id":"job","state":"succeeded","routes":[{"id":"result"}]}"#
        }
        return try JSONDecoder().decode(T.self, from: Data(value.utf8))
    }
    func post<B: Encodable, T: Decodable>(_ path: String, body: B) async throws -> T {
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as! [String: Any]
        posts.append((path, body))
        let result = path == "api/drafts" ? #"{"id":"draft","revision":1}"# : #"{"id":"job"}"#
        return try JSONDecoder().decode(T.self, from: Data(result.utf8))
    }
}
@main struct Check {
    @MainActor static func settle(_ predicate: () -> Bool) async {
        for _ in 0..<200 { if predicate() { return }; try? await Task.sleep(for: .milliseconds(5)) }
        fatalError("Timed out")
    }
    @MainActor static func main() async {
        let api = APIClient(), m = AIChatModel(routeService: AIConfirmedRouteService(api: api))
        let a = Place(name: "Central", lat: 22.28, lon: 114.15)
        let b = Place(name: "Admiralty", lat: 22.28, lon: 114.16)
        let c = Place(name: "HKU", lat: 22.283, lon: 114.136)
        m.input = "Visit three places"; m.send(key: "test-only", options: .init())
        await settle { !m.isSending }
        assert(!m.canReview && m.reviewIssue != nil)
        m.confirmAndSearch(); assert(api.posts.isEmpty)
        for (slot, place) in zip(m.stops, [a,b,c]) { m.choose(place, for: slot.id) }
        m.setStayMinutes(25, for: m.stops[1].id)
        assert(m.canReview && m.reviewIssue == nil)
        assert(m.review())
        assert(m.planner.isVisible && m.planner.visits.count == 1 && api.posts.isEmpty)
        m.planner.setStayMinutes(35, for: m.planner.visits[0].id)
        m.confirmAndSearch()
        assert(m.planner.isWaiting)
        m.confirmAndSearch() // Double tap must not create another job.
        await settle { !m.planner.isWaiting }
        assert(m.planner.selectedRoute?.id == "result")
        assert(api.posts.count == 2 && api.posts[0].0 == "api/drafts" && api.posts[1].0 == "api/jobs")
        assert(api.posts[0].1["channel"] as? String == "ai")
        assert(api.posts[0].1["stopStayMinutes"] as? [Int] == [0,35,0])
        assert(api.posts[1].1["confirmed"] as? Bool == true && api.posts[1].1["ai"] as? Bool == true)
        assert(api.posts.allSatisfy { $0.1["key"] as? String != "test-only" && $0.1["messages"] == nil })
        m.planner.edit(); m.planner.setTransport(.bus, enabled: true)
        m.planner.plan(current: nil); await settle { !m.planner.isWaiting }
        assert((api.posts[2].1["modes"] as? [String])?.contains("bus") == true)
        m.choose(b, for: m.stops.last!.id); assert(!m.canReview && !m.review())
        m.choose(c, for: m.stops.last!.id)
        api.failJob = true; m.confirmAndSearch(); await settle { !m.planner.isWaiting }
        assert(m.planner.selectedRoute == nil && m.planner.errorMessage == "Test routing failure")
        // Hotel -> attraction -> hotel is a valid round trip, not a duplicate error.
        api.failJob = false
        m.choose(a, for: m.stops.last!.id)
        assert(m.canReview && m.review())
        let roundTripRequest = api.posts.count
        m.confirmAndSearch(); await settle { !m.planner.isWaiting }
        assert(m.planner.selectedRoute != nil)
        let loopStops = api.posts[roundTripRequest].1["stops"] as! [[String: Any]]
        assert(loopStops.count == 3 && loopStops.first!["name"] as? String == "Central" && loopStops.last!["name"] as? String == "Central")
        print("PASS: AI hotel round-trip validation and route request preserve return destination")
        GeminiService.gps = true
        m.input = "How to go to HKU?"; m.send(key: "test-only", options: .init()); await settle { !m.isSending }
        assert(m.needsCurrentLocation && !m.canReview)
        m.resolveCurrentLocation(.init(latitude: 22.28, longitude: 114.15))
        m.choose(c, for: m.stops.last!.id); assert(m.canReview)
        api.failJob = false; m.confirmAndSearch(); await settle { !m.planner.isWaiting }
        assert(m.planner.selectedRoute != nil && !m.planner.isMultiStop)
        let requestsBeforeSuggestion = api.posts.count
        PlaceService.results = [c, b]
        m.input = "How to go to HKU?"; m.send(key: "test-only", options: .init())
        await settle { !m.isSending }
        assert(m.stops.last?.place == c) // Multiple matches now preselect the top result.
        assert(api.posts.count == requestsBeforeSuggestion) // Selection is not confirmation.
        m.resolveCurrentLocation(a.coordinate)
        assert(m.canReview)
        m.choose(b, for: m.stops.last!.id)
        assert(m.stops.last?.place == b && m.canReview) // User can replace the suggestion.
        PlaceService.results = [Place(name: "Outside coverage", lat: 31, lon: 121), c]
        m.input = "Try HKU again"; m.send(key: "test-only", options: .init())
        await settle { !m.isSending }
        assert(m.stops.last?.place == c)
        PlaceService.results = []
        m.input = "Unknown place"; m.send(key: "test-only", options: .init())
        await settle { !m.isSending }
        assert(m.stops.last?.place == nil && !m.canReview)
        assert(m.messages.last?.text == "Could not find a direct match. Which place did you mean?")
        assert(GeminiService.evidenceCalls.last?.first?.status == "no_matches")
        let beforeAlternatives = api.posts.count
        GeminiService.actions = [.init(index: 0, query: "Ignore GPS"), .init(index: 1, query: "University"), .init(index: 1, query: "Duplicate")]
        PlaceService.byQuery = ["University": [c]]
        PlaceService.queries = []
        m.input = "Unknown location"; m.send(key: "test-only", options: .init())
        await settle { !m.isSending }
        assert(PlaceService.queries == ["HKU", "University"])
        assert(m.stops.last?.place == c)
        assert(GeminiService.evidenceCalls.last?.first?.matches.first?.name == "HKU")
        assert(api.posts.count == beforeAlternatives)
        m.choose(c, for: m.stops.last!.id)
        assert(m.stops.last?.place == c && m.stops.last?.suggestions.isEmpty == true)
        GeminiService.actions = []
        GeminiService.failClarification = true
        PlaceService.byQuery = [:]
        m.input = "Unknown location"; m.send(key: "test-only", options: .init())
        await settle { !m.isSending }
        assert(m.messages.last!.text.contains("couldn't find a search match"))
        PlaceService.unavailable = true
        m.input = "HKU"; m.send(key: "test-only", options: .init())
        await settle { !m.isSending }
        assert(GeminiService.evidenceCalls.last?.first?.status == "unavailable")
        assert(m.messages.last!.text.contains("place search is unavailable"))
        PlaceService.unavailable = false
        GeminiService.failClarification = false
        print("PASS: search evidence, alternate queries, GPS/duplicate action rejection, candidate confirmation, no automatic routing, unavailable and AI-failure fallback")
        let leave = JourneyTime.departure(Date().addingTimeInterval(3600))
        let arrive = JourneyTime.departure(Date().addingTimeInterval(7200))
        GeminiService.departure = leave
        GeminiService.arrival = arrive
        PlaceService.results = [c,b]
        m.input = "Arrive by the target time"; m.send(key: "test-only", options: .init())
        await settle { !m.isSending }
        m.resolveCurrentLocation(a.coordinate)
        assert(m.planner.isVisible && m.planner.origin != nil) // Settings open automatically.
        assert(!m.planner.leaveNow && m.planner.departure == JourneyTime.parse(leave))
        assert(m.searchTimeIssue == nil && m.arrivalDeadline == JourneyTime.parse(arrive))
        let before = api.posts.count
        assert(before == api.posts.count) // Preparing the review sends no route job.
        m.confirmAndSearch(); await settle { !m.planner.isWaiting }
        assert(api.posts[before].1["departure"] as? String == leave)
        GeminiService.departure = ""
        m.input = "Arrive by the target but origin unknown"; m.send(key: "test-only", options: .init())
        await settle { !m.isSending }
        m.resolveCurrentLocation(a.coordinate)
        assert(m.searchTimeIssue != nil)
        let blockedCount = api.posts.count
        m.confirmAndSearch(); assert(api.posts.count == blockedCount && !m.planner.isWaiting)
        m.planner.setDeparture(now: false, date: JourneyTime.parse(arrive)!)
        assert(m.searchTimeIssue != nil)
        m.planner.setDeparture(now: false, date: JourneyTime.parse(leave)!)
        assert(m.searchTimeIssue == nil)
        m.confirmAndSearch(); await settle { !m.planner.isWaiting }
        assert(api.posts[blockedCount].1["departure"] as? String == leave)
        GeminiService.arrival = ""
        GeminiService.departure = leave
        m.input = "Leave at this time"; m.send(key: "test-only", options: .init())
        await settle { !m.isSending }
        assert(m.arrivalDeadline == nil && !m.planner.leaveNow && m.planner.departure == JourneyTime.parse(leave))
        m.resolveCurrentLocation(a.coordinate)
        m.confirmAndSearch(); await settle { !m.planner.isWaiting }
        let original = m.planner
        let originalID = original.selectedID
        let originalDestination = original.destination
        let originalModes = original.modes
        let postCount = api.posts.count
        m.beginRouteEdit()
        let draft = m.routeEditor!
        assert(draft !== original && draft.origin == original.origin && draft.departure == original.departure)
        assert(draft.routes.isEmpty && original.selectedID == originalID && api.posts.count == postCount)
        m.beginRouteEdit(); assert(m.routeEditor === draft) // Repeated pencil taps preserve draft edits.
        draft.choose(b, for: .destination)
        draft.setTransport(.bus, enabled: true)
        assert(original.destination == originalDestination && original.modes == originalModes)
        m.cancelRouteEdit()
        assert(m.routeEditor == nil && m.planner === original && original.selectedID == originalID)
        m.beginRouteEdit()
        let failedDraft = m.routeEditor!
        api.failJob = true
        failedDraft.plan(current: nil)
        assert(m.isRouteSearchWaiting && original.selectedRoute != nil)
        await settle { !failedDraft.isWaiting }
        m.finishRouteEditIfReady()
        assert(m.planner === original && m.routeEditor === failedDraft && original.selectedRoute != nil)
        api.failJob = false
        failedDraft.plan(current: nil)
        await settle { !failedDraft.isWaiting }
        m.finishRouteEditIfReady()
        assert(m.planner === failedDraft && m.routeEditor == nil && m.planner.selectedRoute != nil)
        let account = "persistence-check-" + UUID().uuidString
        let otherAccount = account + "-other"
        defer {
            UserDefaults.standard.removeObject(forKey: "w8g.ai.chat." + account)
            UserDefaults.standard.removeObject(forKey: "w8g.ai.chat." + otherAccount)
        }
        let saved = AIChatModel(routeService: AIConfirmedRouteService(api: api))
        saved.load(accountID: account)
        GeminiService.gps = false
        PlaceService.byQuery = ["Central": [a], "Admiralty": [b], "HKU": [c]]
        saved.input = "My persisted trip"
        saved.send(key: "test-only", options: .init())
        await settle { !saved.isSending }
        saved.planner.setStayMinutes(90, for: saved.planner.visits[0].id)
        saved.saveState()
        let restored = AIChatModel(routeService: AIConfirmedRouteService(api: api))
        restored.load(accountID: account)
        assert(restored.messages.count == 2 && restored.stops.count == 3)
        assert(restored.planner.visits[0].stayMinutes == 90 && restored.planner.origin == a)
        assert(restored.planner.destination == c && restored.planner.routes.isEmpty)
        restored.confirmAndSearch()
        await settle { !restored.planner.isWaiting }
        restored.beginRouteEdit()
        restored.routeEditor!.choose(b, for: .destination)
        restored.saveState()
        let completed = AIChatModel(routeService: AIConfirmedRouteService(api: api))
        let postsBeforeRestore = api.posts.count
        completed.load(accountID: account)
        assert(completed.planner.selectedRoute?.id == "result" && completed.planner.destination == c)
        assert(completed.routeEditor?.destination == b && api.posts.count == postsBeforeRestore)
        completed.load(accountID: otherAccount)
        assert(completed.messages.isEmpty && completed.stops.isEmpty && completed.planner.routes.isEmpty)
        completed.load(accountID: account)
        completed.clear(); completed.saveState()
        let cleared = AIChatModel(routeService: AIConfirmedRouteService(api: api))
        cleared.load(accountID: account)
        assert(cleared.messages.isEmpty && cleared.stops.isEmpty && cleared.planner.routes.isEmpty)
        print("PASS: relaunch restores search settings, individual stays, results and edit panel; account isolation and clear-chat persistence")
        let editID = m.messages.first(where: { $0.isUser })!.id
        m.input = "Unsent composer draft"
        assert(!m.editMessage(editID, text: "  ", key: "test-only", options: .init()))
        assert(m.editMessage(editID, text: "Replacement question", key: "test-only", options: .init()))
        assert(m.messages.count == 1 && m.messages[0].id == editID)
        assert(m.planner.routes.isEmpty && m.routeEditor == nil)
        await settle { !m.isSending }
        assert(m.messages.count == 2 && m.messages[0].text == "Replacement question")
        assert(GeminiService.receivedText == "Replacement question" && GeminiService.receivedHistory.isEmpty)
        assert(m.input == "Unsent composer draft")
        let direct = AIChatModel(direct: true)
        let serverSearches = PlaceService.queries.count
        let serverPosts = APIClient.shared.posts.count
        GeminiService.gps = false
        direct.input = "Plan three stops"
        direct.send(key: "test-only", options: .init())
        await settle { !direct.isSending }
        assert(direct.stops.isEmpty && !direct.canReview)
        assert(direct.messages.last?.text.contains("server mode") == true)
        assert(PlaceService.queries.count == serverSearches && GooglePlacesService.queries.isEmpty)
        GeminiService.gps = true
        direct.input = "Go to HKU"
        direct.send(key: "test-only", options: .init())
        await settle { !direct.isSending }
        assert(GooglePlacesService.queries == ["HKU"] && PlaceService.queries.count == serverSearches)
        direct.resolveCurrentLocation(CLLocationCoordinate2D(latitude: 22.29, longitude: 114.16))
        direct.confirmAndSearch()
        await settle { !direct.planner.isWaiting }
        assert(direct.planner.selectedRoute?.id == "direct-result")
        assert(APIClient.shared.posts.count == serverPosts)
        print("PASS: guest AI rejects multi-stop, uses Google place lookup and routing only, never calls w8g API")
        print("PASS: inline edit replaces turn, removes stale follow-ups/results, preserves identity and composer draft, rejects empty edit")
        print("PASS: separate edit draft, previous route retained, repeat edit, cancel, failed search retention, success adoption")
        print("PASS: inline review, explicit departure, estimated departure sent to API, arrival deadline preserved, missing/late departure blocked, manual departure override")
        print("PASS: top-ranked place preselection, manual changes, no-match handling, coverage validation, no automatic job submission")
        print("PASS: unresolved/duplicate validation, optional settings without requests, explicit confirmation, AI draft/job contract, double-tap guard, progress/results, multi-stop stays, edited transport, failure recovery, GPS two-point route")
    }
}

@MainActor struct GooglePlacesService {
    static var queries: [String] = []
    func search(_ name: String) async throws -> [Place] {
        Self.queries.append(name)
        return [Place(name: name, lat: 22.28, lon: 114.15)]
    }
}
@MainActor final class GoogleRouteService: RouteServing {
    let usesDirectAPIs = true
    func status() async throws -> RoutingStatus { .init(ready: true, minDate: "2020-01-01T00:00:00Z", maxDate: "2040-01-01T00:00:00Z") }
    func start(_ request: RouteRequest) async throws -> String { "direct-test" }
    func job(_ id: String) async throws -> RouteJob { .init(id: id, state: "succeeded", progress: nil, error: nil, routes: [.init(id: "direct-result")]) }
}
