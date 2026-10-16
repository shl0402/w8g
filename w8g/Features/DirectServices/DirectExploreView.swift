import SwiftUI

struct DirectExploreView: View {
	let openProfile: () -> Void
	@State private var planner = RoutePlannerModel(service: GoogleRouteService())
	@State private var location = LocationService()
	@State private var field: RouteSearchField?
	@State private var showPicker = false
	@State private var details: Journey?
	@State private var waitingForLocation = false
	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 16) {
				HStack {
					Text("Explore").font(.largeTitle.bold())
					Spacer()
					Button(action: openProfile) {
						Image(systemName: "person.crop.circle").font(.title2).frame(
							width: 44, height: 44)
					}
				}
				RoutePlannerControls(
					planner: planner, currentCoordinate: { location.coordinate },
					search: {
						field = $0
						showPicker = true
					}, locate: { location.locate(standalone: true) },
					close: {
						waitingForLocation = false
						location.cancel()
						planner.close()
					},
					planningDisabled: location.isLocating,
					planAction: {
						if planner.usesCurrentLocation && location.coordinate == nil {
							waitingForLocation = true
							location.locate(standalone: true)
						} else {
							planner.plan(current: location.coordinate)
						}
					})
				if location.isLocating { ProgressView("Confirming your current location…") }
				GoogleAttributionView(
					places: [planner.origin, planner.destination].compactMap { $0 })
				if let error = location.errorMessage {
					Text(error).font(.caption).foregroundStyle(.red)
				}
				NavigationLink {
					ArrivalsView()
				} label: {
					Label("Next arrivals", systemImage: "clock.arrow.circlepath").frame(
						minHeight: 44)
				}
				if !planner.routes.isEmpty {
					Text("Google Maps").font(.system(size: 14)).foregroundStyle(
						Color(white: 0.37))
					ForEach(planner.routes) { journey in
						RouteOptionCard(
							journey: journey,
							selected: journey.id == planner.selectedID
						) { details = journey }
						GoogleRouteLink(journey: journey)
					}
				}
			}.padding(16)
		}
		.background(AppTheme.background)
		.sheet(isPresented: $showPicker) {
			AIPlacePicker(direct: true) { place in
				if let field { planner.choose(place, for: field) }
			}
		}
		.sheet(item: $details) { RouteDetailView(journey: $0) }
		.onChange(of: location.centerRequestID) { _, _ in
			guard waitingForLocation, location.coordinate != nil else { return }
			waitingForLocation = false
			planner.plan(current: location.coordinate)
		}
		.onChange(of: location.errorMessage) { _, error in
			if error != nil { waitingForLocation = false }
		}
		.onDisappear {
			waitingForLocation = false
			location.cancel()
		}
	}
}

struct GoogleRouteLink: View {
	let journey: Journey
	private var url: URL? {
		guard let start = journey.stops.first, let end = journey.stops.last else { return nil }
		var parts = URLComponents(string: "https://www.google.com/maps/dir/")!
		parts.queryItems = [
			URLQueryItem(name: "api", value: "1"),
			URLQueryItem(name: "origin", value: "\(start.lat),\(start.lon)"),
			URLQueryItem(name: "destination", value: "\(end.lat),\(end.lon)"),
			URLQueryItem(
				name: "travelmode",
				value: journey.legs.contains { $0.transitLeg == true } ? "transit" : "walking"
			),
		]
		return parts.url
	}
	var body: some View {
		if let url {
			Link(destination: url) {
				Label("Open in Google Maps", systemImage: "map").frame(minHeight: 44)
			}
		}
	}
}

struct GoogleAttributionView: View {
	var places: [Place] = []
	private var sources: [Place.Attribution] {
		var seen = Set<String>()
		return places.flatMap { $0.attributions ?? [] }.filter {
			seen.insert($0.provider + ($0.uri ?? "")).inserted
		}
	}
	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text("Google Maps").font(.system(size: 14)).foregroundStyle(Color(white: 0.37))
			ForEach(Array(sources.enumerated()), id: \.offset) { _, attribution in
				if let uri = attribution.uri, let url = URL(string: uri),
					url.scheme == "https"
				{
					Link(attribution.provider, destination: url).font(.caption)
				} else {
					Text(attribution.provider).font(.caption)
				}
			}
		}
	}
}
