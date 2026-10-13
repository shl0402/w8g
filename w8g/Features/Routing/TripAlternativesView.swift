import SwiftUI

struct TripAlternativesView: View {
    let journey: Journey
    let tripIndex: Int
    let onUpdate: (Journey) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var planner = RoutePlannerModel()
    @State private var prepared = false
    @State private var chosen: Journey?
    @State private var applyError: String?

    private var trip: Journey? {
        let parts = journey.pointToPointJourneys
        return parts.indices.contains(tripIndex) ? parts[tripIndex] : nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let trip {
                        Text(trip.displayTitle).font(.headline)
                        Text("Only this trip will change.")
                            .font(.subheadline).foregroundStyle(AppTheme.secondaryText)
                        if let date = journey.departureForAlternatives(at: tripIndex) {
                            Text("Leave from " + JourneyTime.string(date, format: "dd MMM HH:mm"))
                                .font(.caption).foregroundStyle(AppTheme.secondaryText)
                        }
                        let parts = journey.pointToPointJourneys
                        if tripIndex + 1 < parts.count, let nextDeparture = parts[tripIndex + 1].startDate {
                            let deadline = nextDeparture.addingTimeInterval(-Double(journey.stayMinutes(at: tripIndex + 1) * 60))
                            Text("Arrive by " + JourneyTime.clock(deadline) + " to allow the stay and next trip.")
                                .font(.caption).foregroundStyle(AppTheme.secondaryText)
                        }
                        DisclosureGroup("Transport options") {
                            ForEach(RouteTransport.allCases) { mode in
                                Toggle(mode.title, isOn: Binding(
                                    get: { planner.modes.contains(mode) },
                                    set: { planner.setTransport(mode, enabled: $0) }
                                ))
                            }
                        }
                        .disabled(planner.isWaiting)
                        Picker("Prefer", selection: Binding(
                            get: { planner.preference }, set: { planner.setPreference($0) }
                        )) {
                            ForEach(RoutePreference.allCases) { preference in
                                Text(preference.title).tag(preference)
                            }
                        }
                        .disabled(planner.isWaiting)
                        if planner.isWaiting {
                            HStack(spacing: 14) {
                                ProgressView()
                                Text(planner.progress).font(.subheadline)
                            }
                        } else {
                            Button("Find alternatives") {
                                if planner.canResume { planner.resume() }
                                else { planner.plan(current: nil) }
                            }
                            .buttonStyle(RoutePrimaryButtonStyle())
                        }
                        if let error = planner.errorMessage {
                            Text(error).font(.footnote).foregroundStyle(.red)
                        }
                        ForEach(planner.routes) { option in
                            VStack(alignment: .leading, spacing: 8) {
                                RouteOptionCard(journey: option, selected: false) { chosen = option }
                                if let issue = journey.replacementIssue(at: tripIndex, with: option) {
                                    Text(issue).font(.caption).foregroundStyle(AppTheme.secondaryText)
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(AppTheme.background)
            .navigationTitle("Other routes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } }
            }
            .navigationDestination(isPresented: Binding(
                get: { chosen != nil }, set: { if !$0 { chosen = nil } }
            )) {
                if let candidate = chosen {
                    RouteDetailContent(journey: candidate, showsSave: false)
                        .navigationTitle("Route details")
                        .safeAreaInset(edge: .bottom) {
                            VStack(spacing: 8) {
                                if let issue = journey.replacementIssue(at: tripIndex, with: candidate) {
                                    Text(issue).font(.footnote).foregroundStyle(AppTheme.secondaryText)
                                }
                                Button("Use this route") {
                                    do {
                                        let updated = try journey.replacingTrip(at: tripIndex, with: candidate)
                                        onUpdate(updated)
                                        dismiss()
                                    } catch { applyError = error.localizedDescription }
                                }
                                .buttonStyle(RoutePrimaryButtonStyle())
                                .disabled(journey.replacementIssue(at: tripIndex, with: candidate) != nil)
                            }
                            .padding(16)
                            .background(AppTheme.background)
                        }
                }
            }
        }
        .tint(AppTheme.ink)
        .onAppear {
            if !prepared, let trip, let date = journey.departureForAlternatives(at: tripIndex) {
                prepared = true
                planner.choose(trip.stops[0], for: .origin)
                planner.choose(trip.stops[1], for: .destination)
                planner.setDeparture(now: false, date: date)
            }
            if scenePhase == .active { planner.continueProgressUpdates() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { planner.continueProgressUpdates() }
            else { planner.suspendProgressUpdates() }
        }
        .onDisappear { planner.stopWaiting() }
        .alert("Could not change route", isPresented: Binding(
            get: { applyError != nil }, set: { if !$0 { applyError = nil } }
        )) {
            Button("OK", role: .cancel) { applyError = nil }
        } message: { Text(applyError ?? "Please try again.") }
    }
}
