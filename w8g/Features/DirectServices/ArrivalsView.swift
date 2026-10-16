import SwiftUI

struct ArrivalsView: View {
	let query: String
	let leg: JourneyLeg?
	@State private var provider: ArrivalProvider?
	@State private var line: String
	@State private var station: String
	@State private var route = ""
	@State private var direction = "O"
	@State private var stops: [ArrivalStop] = []
	@State private var selected: ArrivalStop?
	@State private var result: ArrivalResult?
	@State private var loading = false
	@State private var error: String?
	@State private var task: Task<Void, Never>?
	@State private var revision = UUID()
	init(query: String = "", leg: JourneyLeg? = nil) {
		self.query = query
		self.leg = leg
		let seed = ArrivalSelection(query: query, leg: leg)
		_provider = State(initialValue: seed.provider)
		_line = State(initialValue: seed.line)
		_station = State(initialValue: seed.station)
		_route = State(initialValue: seed.route)
	}
	var body: some View {
		Form {
			if !query.isEmpty { Section { Text(query) } }
			if let leg {
				Section {
					Text(TransitAppearance.detailName(leg))
					Text(JourneyText.stopName(leg.from.name)).font(.subheadline)
				}
			}
			Section {
				Picker("Operator", selection: $provider) {
					Text("Choose operator").tag(Optional<ArrivalProvider>.none)
					ForEach(ArrivalProvider.allCases) {
						Text($0.rawValue).tag(Optional($0))
					}
				}
				if provider == .mtr {
					Picker("Line", selection: $line) {
						Text("Choose line").tag("")
						ForEach(MTRStations.lines.keys.sorted(), id: \.self) {
							Text(MTRLineStyle.line(named: $0)?.name ?? $0).tag($0)
						}
					}
					Picker("Station", selection: $station) {
						Text("Choose station").tag("")
						ForEach(MTRStations.stops(line)) { Text($0.name).tag($0.id) }
					}
					Button("Check next trains") {
						lookup(MTRStations.stops(line).first { $0.id == station })
					}.disabled(line.isEmpty || station.isEmpty || loading)
				} else if provider != nil {
					TextField("Route number", text: $route).textInputAutocapitalization(
						.characters
					).autocorrectionDisabled()
					Picker("Direction", selection: $direction) {
						Text("Outbound").tag("O")
						Text("Inbound").tag("I")
					}.pickerStyle(.segmented)
					Button("Find boarding stops") { loadStops() }.disabled(
						route.isEmpty || loading)
				}
			}
			if loading { ProgressView("Checking operator…") }
			if let error { Text(error).foregroundStyle(.red) }
			if !stops.isEmpty {
				Section("Choose your boarding stop") {
					ForEach(stops, id: \.identity) { stop in
						Button {
							selected = stop
							lookup(stop)
						} label: {
							HStack {
								Text("\(stop.sequence). " + stop.name)
								Spacer()
								if provider == .kmb {
									Text("Service " + stop.service).font(
										.caption)
								}
								if selected == stop {
									Image(systemName: "checkmark")
								}
							}
						}
					}
				}
			}
			if let result {
				Section {
					if let selected { Text(selected.name).font(.headline) }
					if !result.message.isEmpty { Text(result.message).font(.subheadline) }
					if result.rows.isEmpty {
						Text(
							"No estimates available. The service may not be running."
						)
					}
					ForEach(result.rows) { row in
						HStack {
							VStack(alignment: .leading) {
								Text("To " + row.destination)
								if !row.detail.isEmpty {
									Text(row.detail).font(.caption)
								}
							}
							Spacer()
							Text(
								row.time.map { JourneyTime.clock($0) }
									?? "Unavailable"
							).monospacedDigit()
						}
					}
					Text(sourceDescription(result))
						.font(.caption).foregroundStyle(.secondary)
					if let updated = result.updated,
						Date().timeIntervalSince(updated) > 120
					{
						Text(
							"These estimates may be stale. Refresh before travelling."
						).font(.caption).foregroundStyle(.orange)
					}
					Button("Refresh") { lookup(selected) }
				} header: {
					Text("Estimated arrivals · now")
				}
			}
			Section {
				Text(
					"Select the operator, direction and boarding stop. Minibus, ferry, tram and other providers are not connected yet. Estimates require internet, but not the w8g server or an API key."
				).font(.footnote)
			}
		}
		.navigationTitle("Next arrivals").navigationBarTitleDisplayMode(.inline)
		.task {
			if provider == .mtr && !line.isEmpty && !station.isEmpty {
				lookup(MTRStations.stops(line).first { $0.id == station })
			}
		}
		.onDisappear { invalidate() }
		.onChange(of: provider) { _, _ in invalidate() }
		.onChange(of: line) { _, _ in
			invalidate()
			if !MTRStations.stops(line).contains(where: { $0.id == station }) { station = "" }
		}
		.onChange(of: station) { _, _ in invalidate() }
		.onChange(of: route) { _, _ in invalidate() }
		.onChange(of: direction) { _, _ in invalidate() }
	}
	private func sourceDescription(_ result: ArrivalResult) -> String {
		let source = provider?.rawValue ?? "Operator"
		let timestamp =
			result.updated.map { "Updated " + JourneyTime.clock($0) } ?? "Update time unavailable"
		return "Source: " + source + " · " + timestamp
	}
	private func invalidate() {
		revision = UUID()
		task?.cancel()
		loading = false
		result = nil
		stops = []
		selected = nil
		error = nil
	}
	private func loadStops() {
		guard let provider, provider != .mtr else { return }
		invalidate()
		let version = revision
		loading = true
		let number = route.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
		task = Task {
			do {
				let found = try await ArrivalService().stops(
					provider: provider, route: number, direction: direction)
				guard revision == version, !Task.isCancelled else { return }
				stops = found
				if found.isEmpty { error = "No stops found for this route and direction." }
			} catch {
				if revision == version, !Task.isCancelled {
					self.error = error.localizedDescription
				}
			}
			if revision == version { loading = false }
		}
	}
	private func lookup(_ stop: ArrivalStop?) {
		guard let stop, let provider else { return }
		task?.cancel()
		revision = UUID()
		let version = revision
		selected = stop
		result = nil
		error = nil
		loading = true
		task = Task {
			do {
				let fetched = try await ArrivalService().fetch(
					provider: provider,
					route: provider == .mtr
						? line
						: route.trimmingCharacters(in: .whitespacesAndNewlines)
							.uppercased(), stop: stop)
				guard revision == version, !Task.isCancelled else { return }
				result = fetched
			} catch {
				if revision == version, !Task.isCancelled {
					self.error = error.localizedDescription
				}
			}
			if revision == version { loading = false }
		}
	}
}
