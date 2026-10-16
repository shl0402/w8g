import SwiftUI

struct WidgetBlockEditor: View {
	@Environment(\.dismiss) private var dismiss
	@Environment(SavedRouteStore.self) private var saved
	@Environment(AppSession.self) private var session
	@State private var block: JourneyWidgetBlock
	@State private var config: WidgetArrivalConfiguration
	@State private var stops: [ArrivalStop] = []
	@State private var result: ArrivalResult?
	@State private var error: String?
	@State private var loading = false
	@State private var task: Task<Void, Never>?
	@State private var generation = UUID()
	let allowedSizes: [WidgetBlockSize]
	let commit: (JourneyWidgetBlock) -> Void

	init(initial: JourneyWidgetBlock, allowedSizes: [WidgetBlockSize] = WidgetBlockSize.allCases, commit: @escaping (JourneyWidgetBlock) -> Void) {
		_block = State(initialValue: initial)
		_config = State(initialValue: initial.arrival ?? WidgetArrivalConfiguration())
		self.allowedSizes = allowedSizes
		self.commit = commit
	}
	var body: some View {
		Form {
			Section {
				Picker("Block size", selection: $block.size) {
					ForEach(allowedSizes) { Text($0.title).tag($0) }
				}
				if block.kind == .route, block.size == .expanded {
					Toggle("Map preview", isOn: Binding(get: { block.route?.showMap != false }, set: { block.route?.showMap = $0 }))
						.disabled(block.route == nil)
				}
			} header: { Text("Layout") } footer: {
				Text(block.kind == .arrivals
					? "Compact: all four estimates. Wide: more room for the stop. Large: arrival times and destinations."
					: "Compact: time summary. Wide: transport flow and transfers. Large: map preview or detailed transport flow.")
				Text("Only sizes that fit your widget are listed.")
			}
			if block.kind == .arrivals { arrivalFields }
			else {
				Section {
					let records = saved.visible(for: session.account?.id).filter { $0.journey.source != "Google Maps" }
					if records.isEmpty { Text("Save a journey first, then choose it here.") }
					ForEach(records) { route in
						Button {
							block.route = snapshot(route)
						} label: {
							HStack {
								VStack(alignment: .leading) {
									Text(route.journey.displayTitle)
									Text(route.journey.timeRange).font(.caption).foregroundStyle(.secondary)
								}
								Spacer()
								if block.route?.savedID == route.id { Image(systemName: "checkmark") }
							}
						}
					}
				} header: { Text("Choose a saved journey") } footer: { Text("Shows the saved journey’s original time, not a newly planned trip.") }
			}
			if let error { Text(error).foregroundStyle(.red) }
		}
		.navigationTitle(block.kind == .arrivals ? "Arrival block" : "Route block").navigationBarTitleDisplayMode(.inline)
		.toolbar {
			ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
			ToolbarItem(placement: .confirmationAction) {
				Button("Done") {
					if block.kind == .arrivals {
						config.route = config.route.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
						block.arrival = config
					}
					commit(block)
					dismiss()
				}.disabled(block.kind == .arrivals ? !config.isValid : block.route == nil)
			}
		}
		.onDisappear { task?.cancel() }
		.onChange(of: config.provider) { _, provider in
			invalidate()
			config.route = provider == .mtr ? "ISL" : ""
			config.stop = nil
			config.destinationCode = nil
			config.direction = provider == .mtr ? "UP" : "O"
		}
		.onChange(of: config.route) { _, _ in invalidate(); config.stop = nil; config.destinationCode = nil }
		.onChange(of: config.direction) { _, _ in
			config.destinationCode = nil
			if config.provider != .mtr { invalidate(); config.stop = nil; config.destinationCode = nil }
		}
	}
	@ViewBuilder private var arrivalFields: some View {
		Section {
			Picker("Operator", selection: $config.provider) {
				ForEach(ArrivalProvider.allCases) { Text($0.rawValue).tag($0) }
			}
			if config.provider == .mtr {
				Picker("Line", selection: $config.route) {
					ForEach(MTRStations.lines.keys.sorted(), id: \.self) { Text(MTRLineStyle.line(named: $0)?.name ?? $0).tag($0) }
				}
				Picker("Station", selection: Binding(get: { config.stop?.id ?? "" }, set: { code in
					invalidate(); config.stop = MTRStations.stops(config.route).first { $0.id == code }
				})) {
					Text("Choose station").tag("")
					ForEach(MTRStations.stops(config.route)) { Text($0.name).tag($0.id) }
				}
				Picker("Direction", selection: $config.direction) {
					Text(directionName("UP")).tag("UP")
					Text(directionName("DOWN")).tag("DOWN")
				}
				Picker("Train destination", selection: Binding(get: { config.destinationCode ?? "" }, set: { config.destinationCode = $0.isEmpty ? nil : $0 })) {
					Text("All destinations").tag("")
					ForEach(destinationChoices, id: \.self) { Text(MTRStations.name($0)).tag($0) }
				}
				Button("Check directions and arrivals") { fetch() }.disabled(config.stop == nil || loading)
			} else {
				TextField("Route number", text: $config.route).textInputAutocapitalization(.characters).autocorrectionDisabled()
				Picker("Direction", selection: $config.direction) { Text("Outbound").tag("O"); Text("Inbound").tag("I") }
				Button("Find boarding stops") { loadStops() }.disabled(config.route.isEmpty || loading)
				if let stop = config.stop { Text(stop.name).font(.subheadline) }
			}
		}
		if loading { ProgressView("Checking operator…") }
		if !stops.isEmpty {
			Section("Boarding stop") {
				ForEach(stops, id: \.identity) { stop in
					Button {
						config.stop = stop
						fetch()
					} label: {
						HStack {
							Text("\(stop.sequence). " + stop.name)
							Spacer()
							if !stop.service.isEmpty { Text("Service " + stop.service).font(.caption) }
							if config.stop == stop { Image(systemName: "checkmark") }
						}
					}
				}
			}
		}
		if let result {
			Section("Operator preview") {
				let selected = WidgetArrivalLoader.snapshot(result, configuration: config)
				ForEach(Array(selected.trains.prefix(4))) { train in
					LabeledContent("To " + train.destination, value: widgetClock(train.time))
				}
				if selected.trains.isEmpty { Text("No estimates for this direction and destination right now.") }
				if !result.message.isEmpty { Text(result.message) }
			}
		}
		Section { Text("Shows up to four arrivals supplied by the operator. Missing estimates stay blank.").font(.footnote).foregroundStyle(.secondary) }
	}
	private var destinationChoices: [String] {
		let published = WidgetArrivalConfiguration.destinations(line: config.route, direction: config.direction)
		let live = (result?.rows ?? []).filter { $0.direction == config.direction }.compactMap(\.destinationCode)
		return Set(published + live + [config.destinationCode].compactMap { $0 }).sorted { MTRStations.name($0) < MTRStations.name($1) }
	}
	private func directionName(_ value: String) -> String {
		let names = WidgetArrivalConfiguration.destinations(line: config.route, direction: value).map { MTRStations.name($0) }
		return names.isEmpty ? (value == "UP" ? "Direction 1 (UP)" : "Direction 2 (DOWN)") : "To " + names.joined(separator: " / ")
	}
	private func invalidate() {
		generation = UUID(); task?.cancel(); loading = false; error = nil; result = nil; stops = []
	}
	private func loadStops() {
		invalidate()
		let current = generation
		let captured = config
		loading = true
		task = Task {
			do {
				let found = try await ArrivalService().stops(provider: captured.provider, route: captured.route.uppercased().trimmingCharacters(in: .whitespaces), direction: captured.direction)
				guard generation == current, !Task.isCancelled else { return }
				stops = found
				if found.isEmpty { error = "No boarding stops found." }
			} catch { if generation == current, !Task.isCancelled { self.error = error.localizedDescription } }
			if generation == current { loading = false }
		}
	}
	private func fetch() {
		guard let stop = config.stop else { return }
		task?.cancel(); generation = UUID()
		let current = generation, captured = config
		loading = true; error = nil; result = nil
		task = Task {
			do {
				let fetched = try await ArrivalService().fetch(provider: captured.provider, route: captured.route.uppercased().trimmingCharacters(in: .whitespaces), stop: stop)
				guard generation == current, !Task.isCancelled else { return }
				result = fetched
			} catch { if generation == current, !Task.isCancelled { self.error = error.localizedDescription } }
			if generation == current { loading = false }
		}
	}
	private func snapshot(_ saved: SavedRoute) -> WidgetRouteSnapshot {
		let journey = saved.journey
		return WidgetRouteSnapshot(savedID: saved.id, title: journey.stops.map { JourneyText.stopName($0.name).components(separatedBy: " · ").first ?? $0.name }.joined(separator: " → "), minutes: journey.minutes,
			departure: journey.startDate, arrival: journey.endDate,
			segments: journey.displayLegs.map { leg in
				.init(label: leg.isWalking ? leg.minutes : leg.lineName,
					symbol: TransitAppearance.symbol(leg), hex: MTRLineStyle.line(named: leg.lineName)?.hex ?? leg.route?.displayColor ?? "697060")
			}, transfers: journey.transferCount, walkMeters: journey.walkDistance)
	}
}
