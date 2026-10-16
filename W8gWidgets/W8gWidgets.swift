import SwiftUI
import WidgetKit
import AppIntents

struct WidgetDesignEntity: AppEntity {
	static var typeDisplayRepresentation: TypeDisplayRepresentation = "Widget design"
	static var defaultQuery = WidgetDesignQuery()
	var id: String
	var name: String
	var size: String
	var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)", subtitle: "\(size)") }
	init(_ design: JourneyWidgetDesign) { id = design.id.uuidString; name = design.name; size = design.size.title }
}
struct WidgetDesignQuery: EntityQuery {
	func entities(for identifiers: [String]) async throws -> [WidgetDesignEntity] {
		try WidgetDesignStorage.load().filter { identifiers.contains($0.id.uuidString) }.map(WidgetDesignEntity.init)
	}
	func suggestedEntities() async throws -> [WidgetDesignEntity] { try WidgetDesignStorage.load().map(WidgetDesignEntity.init) }
}
struct WidgetDesignIntent: WidgetConfigurationIntent {
	static var title: LocalizedStringResource = "Choose design"
	static var description = IntentDescription("Create designs in w8g → Profile → Widgets, then choose one of the same size here.")
	@Parameter(title: "Design") var design: WidgetDesignEntity?
}
struct JourneyWidgetEntry: TimelineEntry {
	var date: Date
	var design: JourneyWidgetDesign?
	var arrivals: [UUID: WidgetArrivalSnapshot] = [:]
	var message = "Create a design in w8g → Profile → Widgets."
}
struct JourneyWidgetProvider: AppIntentTimelineProvider {
	func placeholder(in context: Context) -> JourneyWidgetEntry { .init(date: Date(), design: nil) }
	func snapshot(for configuration: WidgetDesignIntent, in context: Context) async -> JourneyWidgetEntry {
		await entry(configuration, context: context, fetch: !context.isPreview)
	}
	func timeline(for configuration: WidgetDesignIntent, in context: Context) async -> Timeline<JourneyWidgetEntry> {
		let first = await entry(configuration, context: context, fetch: true)
		// Countdown entries reuse the same prediction and retain its original timestamp.
		// They are not new network updates. Expired predictions disappear.
		let entries = WidgetTimelineDates.make(now: first.date, snapshots: Array(first.arrivals.values)).map { date in
			var value = first
			value.date = date
			return value
		}
		return Timeline(entries: entries, policy: .after(first.date.addingTimeInterval(300)))
	}
	private func entry(_ configuration: WidgetDesignIntent, context: Context, fetch: Bool) async -> JourneyWidgetEntry {
		let now = Date()
		do {
			let all = try WidgetDesignStorage.load()
			let size: JourneyWidgetSize = context.family == .systemSmall ? .small : context.family == .systemMedium ? .medium : .large
			let design: JourneyWidgetDesign?
			if let selected = configuration.design {
				design = all.first { $0.id.uuidString == selected.id }
			} else { design = all.first { $0.size == size } }
			guard let design else { return .init(date: now, design: nil, message: "Choose a saved \(size.title.lowercased()) design in Edit Widget.") }
			guard design.size == size, design.isValid else { return .init(date: now, design: nil, message: "This design needs \(design.size.title.lowercased()). Change the widget size or choose another design.") }
			let arrivals = fetch ? await WidgetArrivalLoader.load(design, preferRecentCache: true) : [:]
			return .init(date: now, design: design, arrivals: arrivals)
		} catch { return .init(date: now, design: nil, message: "Open w8g to check widget setup.") }
	}
}
struct JourneyWidgetView: View {
	let entry: JourneyWidgetEntry
	var body: some View {
		Group {
			if let design = entry.design {
				VStack(spacing: 2) {
					if design.blocks.contains(where: { $0.kind == .arrivals }) {
						HStack {
							Text("Next arrivals").font(.system(size: 9)).foregroundStyle(.secondary)
							Spacer()
							Button(intent: RefreshWidgetArrivalsIntent(designID: design.id.uuidString)) {
								Image(systemName: "arrow.clockwise").font(.system(size: 12)).frame(width: 28, height: 24)
							}.buttonStyle(.plain).accessibilityLabel("Refresh arrivals")
						}
					}
					JourneyWidgetCanvas(design: design, arrivals: entry.arrivals, date: entry.date, links: design.size != .small)
				}
			} else {
				VStack(alignment: .leading, spacing: 8) {
					Text("w8g").font(.title2.bold())
					Text(entry.message).font(.caption).foregroundStyle(.secondary)
				}
			}
		}
		.padding(10)
		.containerBackground(.background, for: .widget)
		.widgetURL(URL(string: entry.design.map { "w8g://widgets/\($0.id.uuidString)/\($0.blocks.first?.id.uuidString ?? "")" } ?? "w8g://widgets"))
	}
}
struct W8gWidgets: Widget {
	var body: some WidgetConfiguration {
		AppIntentConfiguration(kind: "W8gJourneyBoard", intent: WidgetDesignIntent.self, provider: JourneyWidgetProvider()) { JourneyWidgetView(entry: $0) }
		.configurationDisplayName("Your journey board")
		.description("Combine arrivals and saved journeys. Design your layout in w8g Settings.")
		.supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
		.contentMarginsDisabled()
	}
}

@main
struct W8gWidgetBundle: WidgetBundle {
	var body: some Widget {
		W8gWidgets()
		LockScreenArrivalsWidget()
	}
}
