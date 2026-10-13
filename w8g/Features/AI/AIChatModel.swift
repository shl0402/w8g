//
//  AIChatModel.swift
//  w8g
//
//  Created by Samuel on 2/10/2026.
//

import Foundation
import Observation
import CoreLocation

struct AIStopChoice: Identifiable, Codable {
    var id = UUID()
    let name: String
    var stayMinutes: Int
    var place: Place?
    var isCurrentLocation = false
    var suggestions: [Place] = []
}

@Observable
@MainActor
final class AIChatModel {
    var input = "" { didSet { persist() } }
    private(set) var messages: [AIMessage] = [] { didSet { persist() } }
    private(set) var stops: [AIStopChoice] = [] { didSet { schedulePersist() } }
    private(set) var isSending = false
    private(set) var replyProgress = "Gemini is typing…"
    private(set) var errorMessage: String?
    private(set) var proposal: AIProposal? { didSet { schedulePersist() } }
    private(set) var planner: RoutePlannerModel
    private(set) var routeEditor: RoutePlannerModel?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var revision = UUID()

    @ObservationIgnored private var storageKey: String?
    @ObservationIgnored private var persistenceScheduled = false
    private struct Transcript: Codable {
        var messages: [AIMessage]
        var draft: String
        var stops: [AIStopChoice]?
        var proposal: AIProposal?
        var planner: RoutePlannerModel.Snapshot?
        var editor: RoutePlannerModel.Snapshot?
    }

    private func schedulePersist() {
        guard storageKey != nil, !persistenceScheduled else { return }
        persistenceScheduled = true
        Task { [weak self] in
            await Task.yield()
            guard let self else { return }
            persistenceScheduled = false
            persist()
        }
    }

    private func observePlanner(_ value: RoutePlannerModel) {
        value.onStateChange = { [weak self] in self?.schedulePersist() }
    }

    func saveState() { persist() }

    func load(accountID: String) {
        let key = "w8g.ai.chat." + accountID
        guard storageKey != key else { return }
        storageKey = nil
        clear()
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode(Transcript.self, from: data) {
            messages = saved.messages.map { item in
                var item = item
                if item.status == .sending { item.status = .cancelled }
                return item
            }
            input = saved.draft
            stops = saved.stops ?? []
            proposal = saved.proposal
            if let state = saved.planner { planner.restore(state) }
            if let state = saved.editor {
                let editor = planner.editingCopy()
                editor.restore(state)
                routeEditor = editor
                observePlanner(editor)
            }
        }
        storageKey = key
    }

    private func persist() {
        guard let storageKey,
              let data = try? JSONEncoder().encode(Transcript(messages: Array(messages.suffix(100)), draft: String(input.prefix(3000)), stops: stops, proposal: proposal, planner: planner.snapshot(), editor: routeEditor?.snapshot())) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    var needsCurrentLocation: Bool { stops.contains { $0.isCurrentLocation && $0.place == nil } }
    var canRetry: Bool { !isSending && !isRouteSearchWaiting && messages.last?.isUser == true && (messages.last?.status == .failed || messages.last?.status == .cancelled) }

    func resolveCurrentLocation(_ coordinate: CLLocationCoordinate2D) {
        guard stops.contains(where: { $0.isCurrentLocation }) else { return }
        let place = Place(name: "Current location", lat: coordinate.latitude, lon: coordinate.longitude)
        guard place.isInHongKong else { errorMessage = "Routing currently covers Hong Kong. Choose a starting place there."; return }
        for index in stops.indices where stops[index].isCurrentLocation { stops[index].place = place }
        prepareReviewIfPossible()
    }

    init(routeService: (any RouteServing)? = nil) {
        planner = RoutePlannerModel(service: routeService ?? AIConfirmedRouteService())
        observePlanner(planner)
    }

    var reviewIssue: String? {
        if stops.count < 2 { return "Choose a starting place and a destination." }
        let missing = stops.filter { $0.place == nil }.count
        if missing > 0 { return "Choose a location for \(stops.first { $0.place == nil }!.name)." }
        let places = stops.compactMap(\.place)
        if !places.allSatisfy(\.isInHongKong) { return "Choose places within Hong Kong." }
        let visits = places.count > 2 && places.first?.id == places.last?.id ? Array(places.dropLast()) : places
        if Set(visits.map(\.id)).count != visits.count { return "A stop is repeated. Change or remove the extra stop." }
        return nil
    }

    var canReview: Bool { !isSending && proposal != nil && reviewIssue == nil }

    var arrivalDeadline: Date? { JourneyTime.parse(proposal?.arrivalDeadline) }

    var searchTimeIssue: String? { searchTimeIssue(for: planner) }

    func searchTimeIssue(for planner: RoutePlannerModel) -> String? {
        guard let arrivalDeadline else { return nil }
        if planner.leaveNow { return "Choose a departure time." }
        if planner.departure >= arrivalDeadline { return "Choose a departure before your requested arrival time." }
        return nil
    }

    var isRouteSearchWaiting: Bool { planner.isWaiting || routeEditor?.isWaiting == true }

    func beginRouteEdit() {
        guard routeEditor == nil, planner.selectedRoute != nil, !isSending else { return }
        routeEditor = planner.editingCopy()
        observePlanner(routeEditor!)
        schedulePersist()
    }

    func cancelRouteEdit() {
        routeEditor?.close()
        routeEditor = nil
        schedulePersist()
    }

    func finishRouteEditIfReady() {
        guard let draft = routeEditor, draft.selectedRoute != nil else { return }
        planner = draft
        routeEditor = nil
        schedulePersist()
    }

    func confirmAndSearch() {
        guard !planner.isWaiting else { return }
        if planner.origin == nil || planner.destination == nil {
            guard review() else { return }
        }
        if let issue = searchTimeIssue { errorMessage = issue; return }
        planner.plan(current: nil) // GPS has already been resolved into the reviewed origin.
    }

    @discardableResult
    func editMessage(_ id: UUID, text: String, key: String, options: GeminiOptions) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSending, !isRouteSearchWaiting, !text.isEmpty, text.count <= 3000,
              let index = messages.firstIndex(where: { $0.id == id && $0.isUser }) else { return false }
        // Replace this turn and discard answers/follow-ups that relied on the old question.
        let original = messages[index]
        messages = Array(messages.prefix(index)) + [AIMessage(
            id: original.id, date: Date(), status: .cancelled, isUser: true, text: text)]
        send(key: key, options: options, retry: true)
        return true
    }

    func send(key: String, options: GeminiOptions, retry: Bool = false) {
        let text = (retry ? (messages.last?.text ?? "") : input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSending, !isRouteSearchWaiting, !text.isEmpty else { return }
        guard text.count <= 3000 else { errorMessage = "Use up to 3,000 characters."; return }
        if retry && !canRetry { return }
        let history = (retry ? Array(messages.dropLast()) : messages).filter { $0.status == .sent }
        if retry { messages[messages.count - 1].status = .sending }
        else {
            messages.append(AIMessage(status: .sending, isUser: true, text: text))
            input = ""
        }
        let messageID = messages.last!.id
        stops = []
        proposal = nil
        cancelRouteEdit()
        planner.close()
        errorMessage = nil
        isSending = true
        replyProgress = "Gemini is typing…"
        let version = UUID()
        revision = version
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if revision == version {
                    isSending = false
                    task = nil
                    prepareReviewIfPossible()
                }
            }
            do {
                let reply = try await GeminiService().reply(to: text, history: history, key: key, options: options)
                try Task.checkCancellation()
                guard revision == version else { return }
                proposal = reply
                configureProposalSettings(reply)
                stops = reply.places.map { AIStopChoice(name: $0.name, stayMinutes: $0.stayMinutes) }
                if reply.useCurrentLocation == true && !stops.isEmpty {
                    stops.insert(AIStopChoice(name: "Current location", stayMinutes: 0, isCurrentLocation: true), at: 0)
                }
                replyProgress = "Checking places…"
                var evidence: [AIPlaceSearchEvidence] = []
                for (index, slot) in stops.enumerated() where !slot.isCurrentLocation {
                    do {
                        let places = try await PlaceService().search(slot.name)
                        try Task.checkCancellation()
                        guard revision == version else { return }
                        let usable = Array(places.filter(\.isInHongKong).prefix(3))
                        evidence.append(AIPlaceSearchEvidence(index: index, query: slot.name,
                            status: usable.isEmpty ? "no_matches" : "matched", matches: usable.map(AIPlaceSearchEvidence.Match.init)))
                        if let place = usable.first, stops[index].place == nil { choose(place, for: slot.id) }
                    } catch {
                        try Task.checkCancellation()
                        guard revision == version else { return }
                        evidence.append(AIPlaceSearchEvidence(index: index, query: slot.name, status: "unavailable", matches: []))
                    }
                }
                var responseText = reply.reply
                if evidence.contains(where: { $0.status != "matched" }) {
                    responseText = await clarifySearch(text: text, evidence: evidence, key: key, options: options, version: version)
                }
                try Task.checkCancellation()
                guard revision == version else { return }
                if let index = messages.firstIndex(where: { $0.id == messageID }) { messages[index].status = .sent }
                messages.append(AIMessage(isUser: false, text: responseText))

            } catch {
                guard revision == version, !Task.isCancelled else { return }
                if let index = messages.firstIndex(where: { $0.id == messageID }), messages[index].status == .sending { messages[index].status = .failed }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func clarifySearch(text: String, evidence initial: [AIPlaceSearchEvidence], key: String,
                               options: GeminiOptions, version: UUID) async -> String {
        var evidence = initial
        replyProgress = "Checking other matches…"
        do {
            let advice = try await GeminiService().clarifyPlaces(userMessage: text, evidence: evidence,
                allowSearches: true, key: key, options: options)
            try Task.checkCancellation()
            guard revision == version else { return "" }
            var searched = Set<Int>()
            for request in advice.searches.prefix(3) {
                guard let position = evidence.firstIndex(where: { $0.index == request.index && $0.status == "no_matches" }),
                      stops.indices.contains(request.index), !stops[request.index].isCurrentLocation,
                      !searched.contains(request.index) else { continue }
                let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard (2...150).contains(query.count), query.caseInsensitiveCompare(evidence[position].query) != .orderedSame else { continue }
                searched.insert(request.index)
                evidence[position].alternateQuery = query
                do {
                    let found = try await PlaceService().search(query)
                    try Task.checkCancellation()
                    guard revision == version else { return "" }
                    let candidates = Array(found.filter(\.isInHongKong).prefix(3))
                    evidence[position].matches = candidates.map(AIPlaceSearchEvidence.Match.init)
                    if !candidates.isEmpty { evidence[position].status = "matched" }
                    // Preselect a real result; the user can still change it before routing.
                    if let first = candidates.first { choose(first, for: stops[request.index].id) }
                } catch {
                    try Task.checkCancellation()
                    guard revision == version else { return "" }
                    evidence[position].status = "unavailable"
                }
            }
            if !searched.isEmpty {
                let final = try await GeminiService().clarifyPlaces(userMessage: text, evidence: evidence,
                    allowSearches: false, key: key, options: options)
                try Task.checkCancellation()
                guard revision == version else { return "" }
                return final.reply
            }
            return advice.reply
        } catch {
            // A second AI call failing must not restore the original misleading success reply.
            return searchFallback(evidence, chinese: text.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) })
        }
    }

    private func searchFallback(_ evidence: [AIPlaceSearchEvidence], chinese: Bool) -> String {
        evidence.filter { $0.status != "matched" || $0.alternateQuery != nil }.map { item in
            if item.status == "unavailable" {
                return chinese ? "暫時無法查詢「\(item.query)」，請稍後再試或手動搜尋。" : "I couldn't check \(item.query) because place search is unavailable. Please retry or search manually."
            }
            if !item.matches.isEmpty {
                return chinese ? "找不到「\(item.query)」的直接結果。已選擇 \(item.matches[0].name)，你仍可更改。" : "No direct match for \(item.query). I selected \(item.matches[0].name); you can change it."
            }
            return chinese ? "找不到「\(item.query)」的搜尋結果，可以提供地區、地址或其他名稱嗎？" : "I couldn't find a search match for \(item.query). Can you give a district, address or another name?"
        }.joined(separator: "\n")
    }

    func choose(_ place: Place, for id: UUID) {
        guard let index = stops.firstIndex(where: { $0.id == id }) else { return }
        stops[index].place = place
        stops[index].suggestions = []
        stops[index].isCurrentLocation = false
        prepareReviewIfPossible()
    }

    func setStayMinutes(_ minutes: Int, for id: UUID) {
        guard (0...720).contains(minutes), let index = stops.firstIndex(where: { $0.id == id }) else { return }
        stops[index].stayMinutes = minutes
        if planner.visits.indices.contains(index - 1) {
            planner.setStayMinutes(minutes, for: planner.visits[index - 1].id)
        }
    }

    private func prepareReviewIfPossible() {
        guard canReview, !planner.isWaiting, planner.routes.isEmpty,
              planner.origin == nil || planner.destination == nil else { return }
        review()
    }

    private func configureProposalSettings(_ proposal: AIProposal) {
        let count = proposal.places.count + (proposal.useCurrentLocation == true ? 1 : 0)
        planner.setMultiStop(count > 2)
        planner.setDefaultStayMinutes(0)
        planner.setOptimiseOrder(count > 2 && proposal.order == "optimise")
        if !planner.optimiseOrder, let preference = RoutePreference(rawValue: proposal.preference) {
            planner.setPreference(preference)
        }
        for mode in RouteTransport.allCases {
            planner.setTransport(mode, enabled: proposal.modes.contains(mode.rawValue))
        }
        if let date = JourneyTime.parse(proposal.departure) {
            planner.setDeparture(now: false, date: date)
        } else { planner.setDeparture(now: true, date: Date()) }
    }

    @discardableResult
    func review() -> Bool {
        guard canReview else {
            errorMessage = reviewIssue ?? "Wait for the assistant to finish, then try again."
            return false
        }
        let places = stops.compactMap(\.place)
        let optimise = planner.optimiseOrder
        planner.close()
        planner.setMultiStop(places.count > 2)
        planner.choose(places[0], for: .origin)
        planner.choose(places[places.count - 1], for: .destination)
        for index in 1..<(places.count - 1) {
            planner.choose(places[index], for: .addStop)
            if let visit = planner.visits.last {
                planner.setStayMinutes(stops[index].stayMinutes, for: visit.id)
            }
        }
        planner.setOptimiseOrder(places.count > 2 && optimise)
        errorMessage = nil
        // Reviewing settings alone never starts a server job.
        return true
    }

    func cancelReply() {
        if let index = messages.lastIndex(where: { $0.isUser && $0.status == .sending }) { messages[index].status = .cancelled }
        revision = UUID()
        task?.cancel()
        task = nil
        isSending = false
    }

    func clear() {
        cancelRouteEdit()
        cancelReply()
        planner.close()
        messages = []
        stops = []
        proposal = nil
        errorMessage = nil
        input = ""
    }
}
