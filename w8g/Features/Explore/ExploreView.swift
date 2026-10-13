//
//  ExploreView.swift
//  w8g
//
//  Created by Samuel on 29/9/2026.
//

import Foundation
import SwiftUI
import CoreLocation

struct ExploreView: View {
    let openProfile: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var mapIsVisible = false
    @State private var model = ExploreModel()
    @State private var location = LocationService()
    @State private var mapError: String?
    @State private var mapReloadID = UUID()
    @State private var planner = RoutePlannerModel()
    @State private var routeListExpanded = false
    @State private var searchField = RouteSearchField.destination
    @State private var latestRouteFix: CLLocation?
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var model = model

        GeometryReader { geometry in
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    W8gMapView(
                        place: planner.selectedRoute == nil ? model.selectedPlace : nil,
                        cameraTarget: model.cameraTarget,
                        showsLocation: location.isAuthorized && mapIsVisible && scenePhase == .active,
                        onLocation: { fix in location.receive(fix); latestRouteFix = fix },
                        onLocationError: { location.reportLocationError() },
                        reloadID: mapReloadID,
                        onError: { mapError = $0 },
                        journey: planner.selectedRoute,
                        routeFitID: planner.fitID
                    )
                    .ignoresSafeArea(edges: .top)
                    .accessibilityHidden(model.isSearching)

                    if model.isSearching {
                        AppTheme.background.ignoresSafeArea(edges: .top)
                    } else if !routeListExpanded || planner.routes.isEmpty {
                        mapControls
                    }
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Button {
                                if model.isSearching {
                                    searchFocused = false
                                    model.closeSearch()
                                } else { startSearch(.destination) }
                            } label: {
                                Image(systemName: model.isSearching ? "chevron.left" : "magnifyingglass")
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel(model.isSearching ? "Close search" : "Search places")
                            TextField(searchPlaceholder, text: $model.query)
                                .focused($searchFocused)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.search)
                                .onSubmit { searchFocused = false }
                                .frame(minHeight: 48)
                            if model.isSearching {
                                if !model.query.isEmpty {
                                    Button { model.query = ""; searchFocused = true } label: {
                                        Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44)
                                    }.accessibilityLabel("Clear search")
                                }
                            } else {
                                Button(action: openProfile) {
                                    Image(systemName: "person.crop.circle").font(.title2).frame(width: 44, height: 44)
                                }.accessibilityLabel("Open profile")
                            }
                        }
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(.background, in: RoundedRectangle(cornerRadius: 24))
                        .shadow(color: .black.opacity(model.isSearching ? 0 : 0.08), radius: 12, y: 4)
                        .padding(.horizontal, 16)

                        if model.isSearching { searchResults }
                        else {
                            if planner.isVisible && planner.routes.isEmpty {
                                ScrollView {
                                    RoutePlannerControls(
                                        planner: planner, currentCoordinate: { currentRouteCoordinate },
                                        search: startSearch, locate: { location.locate() },
                                        close: { planner.close(); model.clearSelection() }
                                    )
                                }
                                .scrollBounceBehavior(.basedOnSize)
                                .frame(maxHeight: min(340, geometry.size.height * 0.48))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 16)
                            }
                            if let mapError {
                                HStack {
                                    Text(mapError).font(.footnote)
                                    Button("Retry") { self.mapError = nil; mapReloadID = UUID() }
                                }.padding(12)
                                .background(.background, in: RoundedRectangle(cornerRadius: 12))
                                .padding(.horizontal, 16)
                            }
                            Spacer(minLength: 0)
                        }
                    }.padding(.top, 8)
                }
                if !model.isSearching, !planner.routes.isEmpty {
                    RouteResultsPanel(
                        planner: planner,
                        isExpanded: $routeListExpanded,
                        close: {
                            planner.close()
                            model.clearSelection()
                        }
                    )
                    .frame(
                        height: routeListExpanded
                            ? geometry.size.height * 0.78
                            : min(330, geometry.size.height * 0.43)
                    )
                }
            }
        }
        .background(AppTheme.background)
        .foregroundStyle(AppTheme.ink)
        .toolbar(.hidden, for: .navigationBar)
        .task { await model.loadRecents() }
        .task(id: model.isSearching ? "search:" + model.query : "closed") { await model.search() }
        .onChange(of: searchFocused) { _, focused in
            if focused && !model.isSearching { searchField = .destination; model.isSearching = true }
        }
        .onChange(of: location.centerRequestID) { _, _ in
            if let coordinate = location.coordinate { model.focusOnUser(lat: coordinate.latitude, lon: coordinate.longitude) }
        }
        .onAppear {
            mapIsVisible = true
            if scenePhase == .active { planner.continueProgressUpdates() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                if mapIsVisible { planner.continueProgressUpdates() }
            } else {
                location.cancel()
                planner.suspendProgressUpdates()
            }
        }
        .onDisappear {
            mapIsVisible = false
            searchFocused = false
            model.closeSearch()
            location.cancel()
            planner.suspendProgressUpdates()
        }
    }

    private var currentRouteCoordinate: CLLocationCoordinate2D? {
        guard location.isAuthorized, let fix = latestRouteFix,
            fix.horizontalAccuracy >= 0, abs(fix.timestamp.timeIntervalSinceNow) < 30 else { return nil }
        return fix.coordinate
    }

    private var searchPlaceholder: String {
        guard model.isSearching else { return "Search location or coordinates" }
        switch searchField {
        case .origin: return "Search starting point"
        case .destination: return "Search destination"
        case .addStop, .visit: return "Search a stop"
        }
    }

    private func startSearch(_ field: RouteSearchField) {
        searchField = field
        model.query = ""
        model.isSearching = true
        searchFocused = true
    }

    private func choosePlace(_ place: Place) {
        searchFocused = false
        model.select(place)
        planner.choose(place, for: searchField)
        searchField = .destination
        Task { await model.saveRecent(place) }
    }
    private var mapControls: some View {
        VStack {
            Spacer()
            if let message = location.errorMessage {
                Text(message)
                    .font(.footnote)
                    .padding(12)
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
            }
            HStack(alignment: .bottom) {
                Text("w8g").font(.title2.bold())
                if planner.selectedRoute != nil {
                    Button { planner.fitRoute() } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .frame(width: 44, height: 44)
                            .background(.background, in: Circle())
                    }.accessibilityLabel("Show the whole route")
                }
                Spacer()
                Button {
                    location.locate()
                } label: {
                    Group {
                        if location.isLocating { ProgressView() }
                        else { Image(systemName: "location").font(.title2) }
                    }
                    .frame(width: 52, height: 52)
                    .background(.background, in: Circle())
                    .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
                }
                .disabled(location.isLocating)
                .accessibilityLabel("Show my location")
            }
            .padding(.horizontal, 20)
            Picker("Journey type", selection: Binding(
                get: { planner.isMultiStop },
                set: { planner.setMultiStop($0) }
            )) {
                Text("1-to-1").tag(false)
                Text("Multi-stop").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 230)
            .padding(6)
            .background(.background, in: RoundedRectangle(cornerRadius: 18))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 20)
            .disabled(planner.isWaiting)
            .padding(.bottom, 20)
        }
    }

    private var searchResults: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(model.trimmedQuery.isEmpty ? "Recent" : "Suggestions")
                    .font(.headline)

                if model.isLoading {
                    ProgressView("Searching…")
                } else if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red)
                } else {
                    let places = model.trimmedQuery.isEmpty ? model.recents : model.results
                    if places.isEmpty {
                        Text(emptySearchMessage)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                    ForEach(places) { place in
                        Button {
                            choosePlace(place)
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: model.trimmedQuery.isEmpty ? "clock" : "mappin")
                                    .frame(width: 40, height: 40)
                                    .background(AppTheme.ink.opacity(0.06), in: Circle())
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(place.name).font(.body.weight(.medium)).lineLimit(2)
                                    Text(place.subtitle)
                                        .font(.subheadline)
                                        .foregroundStyle(AppTheme.secondaryText)
                                        .lineLimit(2)
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
                if let message = model.syncMessage {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await model.loadRecents() }
    }

    private var emptySearchMessage: String {
        if model.trimmedQuery.isEmpty { return "Your recent places will appear here." }
        if model.trimmedQuery.count < 2 { return "Type at least two characters." }
        return "No matching places. Try another name or latitude, longitude."
    }
}
