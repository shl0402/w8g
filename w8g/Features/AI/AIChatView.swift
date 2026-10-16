//
//  AIChatView.swift
//  w8g
//
//  Created by Samuel on 2/10/2026.
//

import Foundation
import SwiftUI
import UIKit

struct AIChatView: View {
    let accountID: String
    let direct: Bool
    @State private var model: AIChatModel
    init(accountID: String, direct: Bool = false) {
        self.accountID = accountID
        self.direct = direct
        _model = State(initialValue: AIChatModel(direct: direct))
    }
    @State private var location = LocationService()
    @State private var settings = false
    @State private var confirmClear = false
    @State private var picker: PlaceSelection?
    @State private var details: Journey?
    @State private var editingRouteID: String?
    @State private var stayStop: AIStopChoice?
    @State private var stayMinutes = 0
    @State private var editingMessage: UUID?
    @State private var editDraft = ""
    @State private var keyError: String?
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @FocusState private var isMessageFocused: Bool

    private struct PlaceSelection: Identifiable {
        let id = UUID()
        var slot: UUID?
        var field: RouteSearchField?
        var targetPlanner: RoutePlannerModel?
        var query = ""
    }

    var body: some View {
        @Bindable var model = model
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.messages.isEmpty {
                    Text("Where would you like to go?").font(.title2.bold())
                    Text("Describe a trip or ask for places to visit. Review locations and settings before planning.")
                        .foregroundStyle(AppTheme.secondaryText)
                    Text("Your messages are sent to Google using your saved Gemini key.")
                        .font(.caption).foregroundStyle(AppTheme.secondaryText)
                }
                ForEach(model.messages) { message in
                    AIMessageBubble(message: message, editingMessage: $editingMessage,
                        canEdit: !model.isSending && !model.isRouteSearchWaiting, draft: $editDraft) { text in
                        submitEdit(message.id, text: text)
                    }
                    .id(message.id)
                }
                if model.isSending {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(model.replyProgress).font(.subheadline)
                        Spacer()
                    }
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.vertical, 8)
                }
                if let error = keyError ?? model.errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("Couldn't complete that request", systemImage: "exclamationmark.circle")
                                .font(.footnote).foregroundStyle(.red)
                            Spacer()
                            if model.canRetry { Button("Retry") { submit(retry: true) }.font(.footnote.bold()) }
                        }
                        DisclosureGroup("Details") { Text(error).font(.caption).textSelection(.enabled) }
                            .font(.caption).tint(AppTheme.secondaryText)
                    }
                } else if model.canRetry {
                    Button("Reply stopped · Retry") { submit(retry: true) }.font(.footnote)
                }
                if !model.isSending, let query = model.proposal?.arrivalQuery, !query.isEmpty {
                    NavigationLink { ArrivalsView(query: query) } label: {
                        Label("Check next arrivals", systemImage: "clock.arrow.circlepath").padding(14)
                    }
                }
                if !model.isSending && !model.stops.isEmpty {
                    if direct { GoogleAttributionView(places: model.stops.compactMap(\.place)) }
                    VStack(alignment: .leading, spacing: 12) {
                    if model.planner.isWaiting || model.planner.canResume {
                        searchProgress
                    } else if model.planner.origin == nil || model.planner.destination == nil {
                        locationCard
                    } else if model.planner.routes.isEmpty {
                    Text("Are these the right places?").font(.headline)
                    if let issue = model.searchTimeIssue {
                        Text(issue).font(.caption).foregroundStyle(AppTheme.secondaryText)
                    }
                    RoutePlannerControls(
                        planner: model.planner,
                        currentCoordinate: { location.coordinate },
                        search: { picker = PlaceSelection(field: $0) },
                        locate: { location.locate(standalone: true) },
                        close: { model.planner.close() },
                        planButtonTitle: "Confirm and search",
                        planAction: { model.confirmAndSearch() }
                    )
                    if let error = location.errorMessage {
                        Text(error).font(.caption).foregroundStyle(AppTheme.secondaryText)
                    }
                    } else if let journey = model.planner.selectedRoute {
                    HStack {
                        Text("Your route").font(.headline)
                        Spacer()
                        Button { isMessageFocused = false; model.beginRouteEdit() } label: {
                            Image(systemName: "pencil").frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Edit trip")
                        SaveJourneyButton(journey: journey, iconOnly: true)
                    }
                    if direct {
                        Text("Google Maps").font(.system(size: 14)).foregroundStyle(.secondary)
                        GoogleRouteLink(journey: journey)
                    } else {
                    SavedRoutePreview(
                        route: SavedRoute(ownerID: accountID, recordID: journey.id,
                            journey: journey, updated: 0, pending: .none),
                        online: true
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .onTapGesture {
                        editingRouteID = journey.id
                        details = journey
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Open journey details")
                    }
                    Text("Tap a route to see journey details.")
                        .font(.caption).foregroundStyle(AppTheme.secondaryText)
                    ForEach(model.planner.routes) { route in
                        RouteOptionCard(journey: route, selected: route.id == model.planner.selectedID) {
                            model.planner.select(route)
                            editingRouteID = route.id
                            details = route
                        }
                    }
                    }
                    }
                    .padding(14)
                    .background(.background, in: RoundedRectangle(cornerRadius: 18))
                    .id("routeCard")
                }
                if let editor = model.routeEditor {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Edit your search").font(.headline)
                        Text("Your previous route stays above until a new route is ready.")
                            .font(.caption).foregroundStyle(AppTheme.secondaryText)
                        if let issue = model.searchTimeIssue(for: editor) {
                            Text(issue).font(.caption).foregroundStyle(AppTheme.secondaryText)
                        }
                        RoutePlannerControls(
                            planner: editor,
                            currentCoordinate: { location.coordinate },
                            search: { picker = PlaceSelection(field: $0, targetPlanner: editor) },
                            locate: { location.locate(standalone: true) },
                            close: { model.cancelRouteEdit() },
                            planButtonTitle: "Search again",
                            planningDisabled: model.searchTimeIssue(for: editor) != nil
                        )
                        Button("Cancel changes") { model.cancelRouteEdit() }
                            .font(.subheadline)
                        if let error = location.errorMessage {
                            Text(error).font(.caption).foregroundStyle(AppTheme.secondaryText)
                        }
                    }
                    .padding(14)
                    .background(.background, in: RoundedRectangle(cornerRadius: 18))
                    .id("routeEditor")
                }
                Color.clear.frame(height: 1).id("chatBottom")
            }
            .padding(16)
        }
        .onChange(of: model.messages.count) { _, _ in
            withAnimation { proxy.scrollTo(model.messages.last?.id, anchor: .bottom) }
        }
        .onChange(of: model.isSending) { _, sending in
            if !sending && !model.stops.isEmpty {
                withAnimation { proxy.scrollTo("routeCard", anchor: .top) }
            }
        }
        .onChange(of: model.planner.isVisible) { _, _ in
            isMessageFocused = false
            withAnimation { proxy.scrollTo("routeCard", anchor: .top) }
        }
        .onChange(of: model.planner.routes.count) { _, count in
            if count > 0 { withAnimation { proxy.scrollTo("routeCard", anchor: .top) } }
        }
        .onChange(of: model.routeEditor != nil) { _, editing in
            if editing {
                withAnimation { proxy.scrollTo("routeEditor", anchor: .top) }
            }
        }
        .onChange(of: model.routeEditor?.selectedID) { _, _ in
            model.finishRouteEditIfReady()
            if model.routeEditor == nil {
                withAnimation { proxy.scrollTo("routeCard", anchor: .top) }
            }
        }
        .onChange(of: isMessageFocused) { _, focused in
            if focused { withAnimation { proxy.scrollTo("chatBottom", anchor: .bottom) } }
        }
        .overlay(alignment: .bottomTrailing) {
            if !model.messages.isEmpty {
                Button { withAnimation { proxy.scrollTo("chatBottom", anchor: .bottom) } } label: {
                    Image(systemName: "arrow.down").frame(width: 44, height: 44)
                        .background(.regularMaterial, in: Circle())
                }
                .padding(10).accessibilityLabel("Latest messages")
            }
        }
        }
        .scrollDismissesKeyboard(.immediately)
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    if abs(value.translation.height) > abs(value.translation.width) {
                        isMessageFocused = false
                    }
                }
        )
        .background(AppTheme.background)
        .foregroundStyle(AppTheme.ink)
        .navigationTitle("Trip assistant")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { confirmClear = true } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("New chat")
                    .disabled(model.isSending || model.isRouteSearchWaiting)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { settings = true } label: { Image(systemName: "key") }
                    .accessibilityLabel("Gemini settings")
            }
        }
        .confirmationDialog("Start a new chat?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear chat", role: .destructive) { model.clear(); editingMessage = nil; keyError = nil; location.cancel() }
        } message: { Text("This clears the conversation on this device. Saved routes are kept.") }
        .safeAreaInset(edge: .bottom) {
            HStack(alignment: .bottom, spacing: 8) {
                if isMessageFocused {
                    Button {
                        isMessageFocused = false
                    }
                    label: { Image(systemName: "keyboard.chevron.compact.down") }
                    .font(.subheadline)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Dismiss keyboard")
                }

                TextField("Ask about your trip", text: $model.input, axis: .vertical)
                    .focused($isMessageFocused)
                    .disabled(editingMessage != nil)
                    .lineLimit(1...5)
                    .padding(10)
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
                Button {
                    if model.isSending { model.cancelReply() } else { send() }
                } label: {
                    Image(systemName: model.isSending ? "stop.fill" : "arrow.up")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(AppTheme.ink, in: Circle())
                }
                .accessibilityLabel(model.isSending ? "Stop reply" : editingMessage != nil ? "Send edited message" : "Send message")
                .disabled(!model.isSending && (model.isRouteSearchWaiting || activeDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || activeDraft.count > 3000))

            }
            .padding(12)
            .background(AppTheme.background)
        }
        .sheet(isPresented: $settings) {
            NavigationStack {
                ServicesSettingsView(accountID: accountID)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { settings = false } } }
            }
        }
        .sheet(item: $stayStop) { stop in
            NavigationStack {
                StayTimePicker(minutes: $stayMinutes).padding()
                    .navigationTitle("Stay time")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) { Button("Cancel") { stayStop = nil } }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { model.setStayMinutes(stayMinutes, for: stop.id); stayStop = nil }
                        }
                    }
            }.presentationDetents([.medium])
        }
        .sheet(item: $picker) { target in
            AIPlacePicker(query: target.query, direct: direct) { place in
                if let slot = target.slot { model.choose(place, for: slot) }
                if let field = target.field { (target.targetPlanner ?? model.planner).choose(place, for: field) }
            }
        }
        .sheet(item: $details) { journey in
            RouteDetailView(journey: journey) { updated in
                model.planner.replaceRoute(editingRouteID ?? journey.id, with: updated)
                editingRouteID = updated.id
            }
        }
        .onAppear {
            model.load(accountID: accountID)
            isVisible = true
            if model.needsCurrentLocation { location.locate(standalone: true) }
            if scenePhase == .active {
                model.planner.continueProgressUpdates()
                model.routeEditor?.continueProgressUpdates()
            }
        }
        .onDisappear {
            model.saveState()
            isMessageFocused = false
            isVisible = false
            location.cancel()
            model.planner.suspendProgressUpdates()
            model.routeEditor?.suspendProgressUpdates()
        }
        .onChange(of: model.needsCurrentLocation) { _, needed in
            if needed && isVisible { location.locate(standalone: true) }
        }
        .onChange(of: location.centerRequestID) { _, _ in
            if let coordinate = location.coordinate { model.resolveCurrentLocation(coordinate) }
        }
        .onChange(of: scenePhase) { _, phase in
            model.saveState()
            if phase == .active && isVisible {
                model.planner.continueProgressUpdates()
                model.routeEditor?.continueProgressUpdates()
            } else {
                model.planner.suspendProgressUpdates()
                model.routeEditor?.suspendProgressUpdates()
            }
        }
    }

    private var locationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Are these the right places?").font(.headline)
            ForEach(model.stops) { slot in
                Button { picker = PlaceSelection(slot: slot.id, query: slot.isCurrentLocation ? "" : slot.name) } label: {
                    HStack {
                        Image(systemName: slot.place == nil ? "mappin.circle" : "checkmark.circle")
                        VStack(alignment: .leading) {
                            Text(slot.id == model.stops.first?.id ? "From" : slot.id == model.stops.last?.id ? "To" : "Stop")
                                .font(.caption).foregroundStyle(AppTheme.secondaryText)
                            Text(slot.place?.name ?? slot.name)
                            if let place = slot.place {
                                Text(place.subtitle).font(.caption).foregroundStyle(AppTheme.secondaryText)
                            }
                            if slot.place == nil {
                                Text(slot.isCurrentLocation ? "Use GPS or choose a starting place" : "Choose a matching location").font(.caption)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if model.stops.count > 2, slot.id != model.stops.first?.id, slot.id != model.stops.last?.id {
                    Button {
                        stayMinutes = slot.stayMinutes
                        stayStop = slot
                    } label: {
                        Label("Stay \(slot.stayMinutes) min", systemImage: "pause.circle")
                            .font(.subheadline).frame(minHeight: 44)
                    }
                }
                if slot.place == nil {
                    ForEach(slot.suggestions) { suggestion in
                        Button {
                            model.choose(suggestion, for: slot.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(suggestion.name).font(.subheadline)
                                Text(suggestion.subtitle).font(.caption).foregroundStyle(AppTheme.secondaryText)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(8)
                            .background(AppTheme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Use suggested place: " + suggestion.name)
                    }
                }
            }
            if model.needsCurrentLocation {
                HStack {
                    if location.isLocating { ProgressView(); Text("Confirming your current location…").font(.caption) }
                    else { Button("Try current location") { location.locate(standalone: true) }.font(.caption) }
                }
                if let error = location.errorMessage { Text(error).font(.caption).foregroundStyle(AppTheme.secondaryText) }
            }
            RouteParameterControls(planner: model.planner)
            if let issue = model.searchTimeIssue {
                Text(issue).font(.caption).foregroundStyle(AppTheme.secondaryText)
            }
            Button("Confirm and search") {
                isMessageFocused = false
                model.confirmAndSearch()
            }
            .buttonStyle(RoutePrimaryButtonStyle())

        }
    }

    private var searchProgress: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Finding your route").font(.headline)
            Text(model.planner.originTitle + " → " + (model.planner.destination?.name ?? "Destination"))
                .font(.subheadline)
            if model.planner.isWaiting {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(model.planner.progress).font(.caption)
                    Spacer()
                    Button { model.planner.stopWaiting() } label: {
                        Image(systemName: "stop.fill").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Pause route updates")
                }
            } else {
                if let error = model.planner.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Button("Continue search") { model.planner.resume() }
                    .buttonStyle(RoutePrimaryButtonStyle())
                Button("Edit places and settings") { model.planner.edit() }
                    .font(.subheadline)
            }
        }
    }

    private func submitEdit(_ id: UUID, text: String) -> Bool {
        isMessageFocused = false
        do {
            guard let key = try GeminiKeyStore.load(accountID: accountID), !key.isEmpty else {
                settings = true
                return false
            }
            keyError = nil
            return model.editMessage(id, text: text, key: key, options: GeminiOptions.load(accountID: accountID))
        } catch {
            keyError = error.localizedDescription
            return false
        }
    }

    private var activeDraft: String { editingMessage == nil ? model.input : editDraft }

    private func send() {
        if let id = editingMessage {
            if submitEdit(id, text: editDraft) { editingMessage = nil }
        } else {
            submit(retry: false)
        }
    }

    private func submit(retry: Bool) {
        isMessageFocused = false
        do {
            guard let key = try GeminiKeyStore.load(accountID: accountID), !key.isEmpty else {
                settings = true
                return
            }
            keyError = nil
            model.send(key: key, options: GeminiOptions.load(accountID: accountID), retry: retry)
        } catch { keyError = error.localizedDescription }
    }
}
