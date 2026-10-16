//
//  RoutePlannerPanel.swift
//  w8g
//
//  Created by Samuel on 29/9/2026.
//

import Foundation
import CoreLocation
import SwiftUI

private enum RouteSetting: String, Identifiable {
    case departure, transport, preference, stay
    var id: String { rawValue }
}

struct RoutePlannerControls: View {
    let planner: RoutePlannerModel
    let currentCoordinate: () -> CLLocationCoordinate2D?
    let search: (RouteSearchField) -> Void
    let locate: () -> Void
    let close: () -> Void
    var planButtonTitle: String? = nil
    var planningDisabled = false
    var planAction: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 6) {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 4) {
                    placeField("From", value: planner.originTitle, field: .origin)
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close directions")
                }
                if planner.isMultiStop {
                    MultiStopFields(planner: planner, search: search)
                }
                Divider()
                HStack(spacing: 4) {
                    placeField("To", value: planner.destination?.name ?? "Choose destination", field: .destination)
                    Button { planner.swap(current: currentCoordinate()) } label: {
                        Image(systemName: "arrow.up.arrow.down").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Swap starting point and destination")
                }
            }
            .disabled(planner.isWaiting)
            RouteParameterControls(planner: planner)
            if let error = planner.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red).frame(
                    maxWidth: .infinity, alignment: .leading)
            }
            if planner.isWaiting {
                HStack(spacing: 14) {
                    ProgressView()
                        .frame(width: 24, height: 24)
                    Text(planner.progress)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { planner.stopWaiting() } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .background(AppTheme.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop waiting")
                    .accessibilityHint("The server may continue calculating. You can resume checking later.")
                }.padding(.vertical, 4)
            } else if planner.canResume {
                Text(planner.usesDirectAPIs ? "Retry this route search." : "The server may still be calculating. Resume checks the same request.")
                    .font(.caption).foregroundStyle(AppTheme.secondaryText)
                Button(planner.usesDirectAPIs ? "Retry search" : "Resume route search") { planner.resume() }.buttonStyle(RoutePrimaryButtonStyle())
                Button("Edit / start a new search") { planner.edit() }.font(.caption).padding(.vertical, 6)
            } else {
                Button(planButtonTitle ?? (planner.isMultiStop ? "Plan all stops" : "Find route")) { if let planAction { planAction() } else { planner.plan(current: currentCoordinate()) } }
                    .buttonStyle(RoutePrimaryButtonStyle())
                    .opacity(planningDisabled ? 0.45 : 1)
                    .disabled(planningDisabled)
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 22))
    }

    private func placeField(_ label: String, value: String, field: RouteSearchField) -> some View {
        HStack(spacing: 6) {
            Button {
                search(field)
            } label: {
                HStack(spacing: 8) {
                    Text(label).font(.caption).foregroundStyle(AppTheme.secondaryText).frame(
                        width: 30, alignment: .leading)
                    Text(value).font(.subheadline.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 0)
                }.frame(minHeight: 42).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("\(label): \(value). Change place")
            if field == .origin {
                Button {
                    if planner.usesCurrentLocation {
                        planner.stopUsingCurrentLocation()
                    } else {
                        planner.useCurrentLocation()
                        locate()
                    }
                } label: {
                    Image(systemName: planner.usesCurrentLocation ? "location.fill" : "location")
                        .font(.caption)
                        .foregroundStyle(planner.usesCurrentLocation ? AppTheme.ink : AppTheme.secondaryText)
                        .frame(width: 34, height: 42)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(planner.usesCurrentLocation
                    ? "Stop using current location as starting point"
                    : "Use current location as starting point")
                .accessibilityValue(planner.usesCurrentLocation ? "On" : "Off")
            }
        }
    }

}

struct RouteParameterControls: View {
    let planner: RoutePlannerModel
    @State private var setting: RouteSetting?

    var body: some View {
        VStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    filter(planner.departureTitle, symbol: "clock", setting: .departure)
                    filter(planner.transportTitle, symbol: "tram", setting: .transport)
                    if planner.isMultiStop {
                        filter("Stay \(planner.defaultStayMinutes) min", symbol: "pause.circle", setting: .stay)
                    }
                    if !planner.optimiseOrder {
                        filter(planner.preference.title, symbol: "slider.horizontal.3", setting: .preference)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .disabled(planner.isWaiting)

            if planner.isMultiStop {
                Picker("Stop order", selection: Binding(
                    get: { planner.optimiseOrder }, set: { planner.setOptimiseOrder($0) }
                )) {
                    Text("Keep order").tag(false)
                    Text("Optimise order").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(planner.isWaiting)
                Text(planner.optimiseOrder
                     ? "Faster order; start and end may change."
                     : "Visit stops in this order.")
                    .font(.caption).foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
        }
        .sheet(item: $setting) { choice in
            RouteSettingsView(planner: planner, setting: choice)
        }
    }

    private func filter(_ title: String, symbol: String, setting value: RouteSetting) -> some View {
        Button {
            setting = value
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                Text(title)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(AppTheme.ink.opacity(0.06), in: Capsule())
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct RouteResultsPanel: View {
    let planner: RoutePlannerModel
    @Binding var isExpanded: Bool
    let close: () -> Void
    @State private var detail: Journey?
    @State private var editingRouteID: String?

    var body: some View {
        VStack(spacing: 6) {
            VStack(spacing: 0) {
                Button {
                    setExpanded(!isExpanded)
                } label: {
                    Capsule()
                        .fill(AppTheme.secondaryText.opacity(0.35))
                        .frame(width: 36, height: 4)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse route options" : "Expand route options")

                HStack(spacing: 4) {
                    Text("Route options").font(.headline)
                    Spacer()
                    Button {
                        isExpanded = false
                        planner.edit()
                    } label: {
                        Image(systemName: "pencil")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Edit route")

                    Button {
                        isExpanded = false
                        close()
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Close route options")
                }
                .font(.body.weight(.medium))
                .buttonStyle(.plain)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { value in
                        guard abs(value.translation.height) > abs(value.translation.width) else { return }
                        if value.translation.height < -30 { setExpanded(true) }
                        if value.translation.height > 30 { setExpanded(false) }
                    }
            )

            if planner.selectedRoute?.hasMissingGeometry == true {
                Text("Some route geometry is unavailable; the map may show only part of this journey.")
                    .font(.caption).foregroundStyle(.orange)
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(planner.routes) { route in
                        RouteOptionCard(journey: route, selected: route.id == planner.selectedID) {
                            planner.select(route)
                            editingRouteID = route.id
                            detail = route
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 25)
                    .onEnded { value in
                        // An upward swipe opens more room; the expanded list scrolls normally.
                        if !isExpanded,
                            value.translation.height < -35,
                            abs(value.translation.height) > abs(value.translation.width)
                        {
                            setExpanded(true)
                        }
                    }
            )
        }
        .padding(.horizontal, 14)
        .background(.background, in: UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
        .sheet(item: $detail) { route in
            RouteDetailView(journey: route) { updated in
                planner.replaceRoute(editingRouteID ?? route.id, with: updated)
                editingRouteID = updated.id
            }
        }
    }

    private func setExpanded(_ expanded: Bool) {
        withAnimation(.easeInOut(duration: 0.25)) {
            isExpanded = expanded
        }
    }
}

struct RoutePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(.white)
            .background(
                AppTheme.ink.opacity(configuration.isPressed ? 0.75 : 1),
                in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct RouteSettingsView: View {
    let planner: RoutePlannerModel
    let setting: RouteSetting
    @Environment(\.dismiss) private var dismiss
    @State private var now = true
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            Form {
                switch setting {
                case .departure:
                    Text(now ? "Leave now" : "Selected departure")
                        .font(.headline)
                    DatePicker(
                        "Departure",
                        selection: Binding(
                            get: { date },
                            set: { date = $0; now = false }
                        ),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    Text("Scroll to choose a date, hour and minute in Hong Kong time. Leave now uses the time you press Find route.")
                        .font(.footnote)
                case .transport:
                    ForEach(planner.availableTransports) { mode in
                        Toggle(
                            planner.usesDirectAPIs && mode == .tram ? "Tram / Light Rail" : mode.title,
                            isOn: Binding(
                                get: { planner.modes.contains(mode) },
                                set: { planner.setTransport(mode, enabled: $0) }
                            ))
                    }
                    Text(
                        planner.usesDirectAPIs ? "Google Maps uses transport preferences. Turn all transport off for a walking route." : "Walking is always allowed. Turn all transport off for a walking route. Bus and minibus share one server filter."
                    ).font(.footnote)
                case .stay:
                    StayTimePicker(minutes: Binding(
                        get: { planner.defaultStayMinutes },
                        set: { planner.setDefaultStayMinutes($0) }
                    ))
                    Text("Time spent at each added destination. Individual settings override this default.")
                        .font(.footnote)
                    Text("Stay times follow the location when the order changes, including if it becomes first or last.")
                        .font(.footnote)
                case .preference:
                    ForEach(RoutePreference.allCases) { value in
                        Button {
                            planner.setPreference(value)
                            dismiss()
                        } label: {
                            HStack {
                                Text(value.title)
                                Spacer()
                                if value == planner.preference { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            }
            .navigationTitle(
                setting == .departure
                    ? "Departure time" : setting == .transport ? "Transport" : setting == .stay ? "Default stay time" : "Route preference"
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if setting == .departure {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Leave now") {
                            now = true
                            date = Date()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        if setting == .departure { planner.setDeparture(now: now, date: date) }
                        dismiss()
                    }
                }
            }
        }
        .environment(\.timeZone, JourneyTime.zone)
        .tint(AppTheme.ink)
        .onAppear {
            now = planner.leaveNow
            date = planner.leaveNow ? Date() : planner.departure
        }
        .presentationDetents(setting == .departure ? [.large] : [.medium, .large])
    }
}
