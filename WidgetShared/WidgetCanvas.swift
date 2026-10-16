import SwiftUI

struct JourneyWidgetCanvas: View {
	let design: JourneyWidgetDesign
	var arrivals: [UUID: WidgetArrivalSnapshot] = [:]
	var date = Date()
	var links = false
	var selectBlock: ((UUID) -> Void)?

	var body: some View {
		GeometryReader { geometry in
			let columns = CGFloat(design.size.columns)
			let rows = CGFloat(design.size.rows)
			let gap: CGFloat = 10
			let width = (geometry.size.width - gap * (columns - 1)) / columns
			let height = (geometry.size.height - gap * (rows - 1)) / rows
			ZStack(alignment: .topLeading) {
				ForEach(WidgetGrid.placements(for: design) ?? []) { placement in
					if let block = design.blocks.first(where: { $0.id == placement.id }) {
						blockView(block)
							.frame(width: width * CGFloat(placement.columns) + gap * CGFloat(placement.columns - 1),
								height: height * CGFloat(placement.rows) + gap * CGFloat(placement.rows - 1))
							.offset(x: CGFloat(placement.column) * (width + gap), y: CGFloat(placement.row) * (height + gap))
					}
				}
				if design.blocks.isEmpty {
					Text("Empty widget")
						.foregroundStyle(.secondary)
						.frame(width: geometry.size.width, height: geometry.size.height)
				}
			}
		}
	}

	@ViewBuilder private func blockView(_ block: JourneyWidgetBlock) -> some View {
		if let selectBlock {
			Button { selectBlock(block.id) } label: { tile(block) }
				.buttonStyle(.plain).accessibilityLabel("Edit " + block.title)
		} else if links {
			Link(destination: URL(string: "w8g://widgets/\(design.id.uuidString)/\(block.id.uuidString)")!) { tile(block) }
		} else { tile(block) }
	}
	private func tile(_ block: JourneyWidgetBlock) -> some View {
		Group {
			if block.kind == .arrivals {
				WidgetArrivalTile(configuration: block.arrival, snapshot: arrivals[block.id], size: block.size, date: date)
			} else {
				WidgetRouteTile(route: block.route, size: block.size)
			}
		}
		.padding(6)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.contentShape(Rectangle())
	}
}

private struct WidgetArrivalTile: View {
	let configuration: WidgetArrivalConfiguration?
	let snapshot: WidgetArrivalSnapshot?
	let size: WidgetBlockSize
	let date: Date
	private var trains: [WidgetArrivalSnapshot.Train] { snapshot?.upcoming(at: date) ?? [] }
	private var accent: Color {
		widgetColor(configuration?.provider == .mtr ? MTRLineStyle.line(named: configuration?.route ?? "")?.hex ?? "0860A8" : configuration?.provider == .kmb ? "B92327" : "956800")
	}
	var body: some View {
		if size != .expanded, Set(trains.map(\.destination)).count > 1 {
			VStack(alignment: .leading, spacing: 2) {
				heading
				ForEach(Array(trains.enumerated()), id: \.element.id) { index, train in
					HStack(spacing: 4) {
						Text(train.destination).font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.8)
						Spacer(minLength: 0)
						Text(minutes(train)).font(.system(size: index == 0 ? 22 : 11, weight: index == 0 ? .bold : .regular)).monospacedDigit()
					}.foregroundStyle(index == 0 ? Color.primary : Color.secondary)
				}
				Spacer(minLength: 0)
				freshness
			}
		} else if size == .wide {
			HStack(spacing: 12) {
				VStack(alignment: .leading, spacing: 5) { heading; Spacer(minLength: 0); freshness }
					.frame(maxWidth: .infinity, alignment: .leading)
				VStack(alignment: .leading, spacing: 5) { next; remaining }
					.frame(maxWidth: .infinity, alignment: .leading)
			}
		} else {
			VStack(alignment: .leading, spacing: size == .expanded ? 12 : 3) {
				heading
				Spacer(minLength: 0)
				next
				if size == .expanded, Set(trains.map(\.destination)).count > 1, let train = trains.first {
					Text("To " + train.destination).font(.subheadline).lineLimit(1)
				}
				remaining
				Spacer(minLength: 0)
				freshness
			}
		}
	}
	private var heading: some View {
		VStack(alignment: .leading, spacing: 2) {
			Label(size == .compact ? (configuration.map { $0.route + " · " + $0.title } ?? "Next arrivals") : configuration?.title ?? "Next arrivals", systemImage: configuration?.provider == .mtr ? "tram.fill" : "bus.fill")
				.font(.system(size: size == .expanded ? 20 : 14, weight: .semibold))
				.foregroundStyle(accent).lineLimit(2)
			if size != .compact {
				Text(configuration?.subtitle ?? "Choose a stop").font(.caption).foregroundStyle(.secondary).lineLimit(1)
			}
			if Set(trains.map(\.destination)).count <= 1 {
				Text(configuration?.destinationName.map { "To " + $0 } ?? trains.first.map { "To " + $0.destination } ?? "Next arrivals")
					.font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
			}
		}
	}
	private var next: some View {
		Group {
			if let train = trains.first {
				Text(minutes(train)).font(.system(size: size == .expanded ? 46 : 30, weight: .bold, design: .rounded))
			} else {
				Text(snapshot == nil ? "—" : "No estimates").font(.headline)
			}
		}.monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
	}
	@ViewBuilder private var remaining: some View {
		if size == .expanded {
			ForEach(1..<4, id: \.self) { index in
				HStack {
					VStack(alignment: .leading) {
						Text(trains.count > index ? minutes(trains[index]) : "—")
						if trains.count > index, Set(trains.map(\.destination)).count > 1 {
							Text(trains[index].destination).font(.caption2).lineLimit(1)
						}
					}
					Spacer()
					if trains.count > index { Text(widgetClock(trains[index].time)) }
				}.font(.subheadline).foregroundStyle(.secondary)
			}
		} else {
			Text((1..<4).map { trains.count > $0 ? String(max(0, Int(ceil(trains[$0].time.timeIntervalSince(date) / 60)))) : "—" }.joined(separator: " · ") + " min")
				.font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
		}
	}
	private var freshness: some View {
		VStack(alignment: .leading, spacing: 1) {
			if let message = snapshot?.message, !message.isEmpty {
				Text(message).lineLimit(1)
			}
			Text(snapshot?.updated.map { (snapshot?.isStale(at: date) == true ? "Outdated · " : "Updated ") + widgetClock($0) } ?? "Not updated")
		}.font(.system(size: 9)).foregroundStyle(.secondary)
	}
	private func minutes(_ train: WidgetArrivalSnapshot.Train) -> String {
		let value = max(0, Int(ceil(train.time.timeIntervalSince(date) / 60)))
		return value == 0 ? "Due" : "\(value) min"
	}
}

private struct WidgetRouteTile: View {
	let route: WidgetRouteSnapshot?
	let size: WidgetBlockSize
	private var mapImage: UIImage? {
		guard size == .expanded, route?.showMap != false, let name = route?.mapImageName,
			let url = try? WidgetRouteImageStorage.url(named: name) else { return nil }
		return UIImage(contentsOfFile: url.path)
	}
	var body: some View {
		VStack(alignment: .leading, spacing: size == .expanded ? 8 : 4) {
			Label(route?.title ?? "Choose saved route", systemImage: "arrow.triangle.turn.up.right.diamond")
				.font(.system(size: size == .expanded ? 18 : 14, weight: .semibold)).lineLimit(2)
			if let route {
				HStack(alignment: .firstTextBaseline) {
					Text("\(route.minutes) min").font(.system(size: size == .expanded ? 32 : 27, weight: .bold, design: .rounded))
					if size != .compact { Spacer(minLength: 4); times(route) }
				}
				if size == .compact { times(route) }
				if size == .expanded, let image = mapImage {
					// Fit the whole bitmap so its MapLibre/OpenStreetMap attribution is never cropped.
					Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
						.frame(maxWidth: .infinity, maxHeight: 126)
						.clipShape(RoundedRectangle(cornerRadius: 10))
						.accessibilityLabel("Saved route map preview")
					flow(route)
				} else if size == .expanded {
					ForEach(Array(route.segments.prefix(5))) { segment in
						Label(segment.label, systemImage: segment.symbol).font(.subheadline).foregroundStyle(widgetColor(segment.hex)).lineLimit(1)
					}
					if route.segments.count > 5 { Text("+ \(route.segments.count - 5) more legs").font(.caption).foregroundStyle(.secondary) }
					if route.showMap != false { Text("Map preview unavailable").font(.caption2).foregroundStyle(.secondary) }
				} else if size == .wide { flow(route) }
				if size != .compact {
					HStack(spacing: 10) {
						if let count = route.transfers { Label("\(count) transfers", systemImage: "arrow.triangle.swap") }
						if let metres = route.walkMeters { Label("\(Int(metres.rounded())) m", systemImage: "figure.walk") }
					}.font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
				}
			}
			Spacer(minLength: 0)
			Text(route?.departure.map { "Saved plan · " + widgetDay($0) } ?? "Saved journey")
				.font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
		}
	}
	@ViewBuilder private func times(_ route: WidgetRouteSnapshot) -> some View {
		if let departure = route.departure, let arrival = route.arrival {
			Text(widgetClock(departure) + "–" + widgetClock(arrival)).font(.caption).monospacedDigit().lineLimit(1)
		}
	}
	private func flow(_ route: WidgetRouteSnapshot) -> some View {
		HStack(spacing: 4) {
			ForEach(Array(route.segments.prefix(4).enumerated()), id: \.element.id) { index, segment in
				if index > 0 { Image(systemName: "chevron.right").font(.system(size: 7)).foregroundStyle(.secondary) }
				Label(segment.label, systemImage: segment.symbol).font(.system(size: 10)).lineLimit(1)
					.foregroundStyle(widgetColor(segment.hex))
			}
			if route.segments.count > 4 { Text("+\(route.segments.count - 4)").font(.caption2).foregroundStyle(.secondary) }
		}
	}
}

private func widgetColor(_ hex: String) -> Color {
	let rgb = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x30342D
	return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
}
func widgetClock(_ date: Date) -> String { widgetDate(date, format: "HH:mm") }
private func widgetDay(_ date: Date) -> String { widgetDate(date, format: "d MMM") }
private func widgetDate(_ date: Date, format: String) -> String {
	let f = DateFormatter()
	f.locale = Locale(identifier: "en_HK")
	f.timeZone = TimeZone(identifier: "Asia/Hong_Kong")
	f.dateFormat = format
	return f.string(from: date)
}
