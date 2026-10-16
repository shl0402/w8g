import SwiftUI
import WidgetKit
import AppIntents

struct ArrivalBlockEntity: AppEntity {
	static var typeDisplayRepresentation: TypeDisplayRepresentation = "Arrival block"
	static var defaultQuery = ArrivalBlockQuery()
	var id: String
	var name: String
	var subtitle: String
	var displayRepresentation: DisplayRepresentation {
		DisplayRepresentation(title: "\(name)", subtitle: "\(subtitle)")
	}
	init(_ choice: WidgetArrivalChoice) {
		id = choice.id
		name = choice.designName + " · " + (choice.block.arrival?.route ?? "") + " · " + choice.block.title
		subtitle = choice.block.arrival?.destinationName.map { "To " + $0 } ?? choice.block.arrival?.direction ?? ""
	}
}

struct ArrivalBlockQuery: EntityQuery {
	func entities(for identifiers: [String]) async throws -> [ArrivalBlockEntity] {
		try available().filter { identifiers.contains($0.id) }
	}
	func suggestedEntities() async throws -> [ArrivalBlockEntity] { try available() }
	func defaultResult() async throws -> ArrivalBlockEntity? { try available().first }
	private func available() throws -> [ArrivalBlockEntity] {
		WidgetArrivalChoice.available(in: try WidgetDesignStorage.load()).map(ArrivalBlockEntity.init)
	}
}

struct LockScreenArrivalIntent: WidgetConfigurationIntent {
	static var title: LocalizedStringResource = "Next arrivals"
	static var description = IntentDescription("Choose an arrival block saved in w8g → Profile → Widgets.")
	@Parameter(title: "Arrival block") var block: ArrivalBlockEntity?
}

struct LockScreenArrivalEntry: TimelineEntry {
	var date: Date
	var configuration: WidgetArrivalConfiguration?
	var snapshot: WidgetArrivalSnapshot?
	var message = "Save an arrival block in w8g"
	var designID: String?
	var blockID: String?
	var url = URL(string: "w8g://widgets")!
}

struct LockScreenArrivalProvider: AppIntentTimelineProvider {
	func placeholder(in context: Context) -> LockScreenArrivalEntry { .init(date: Date()) }
	func snapshot(for configuration: LockScreenArrivalIntent, in context: Context) async -> LockScreenArrivalEntry {
		await entry(configuration, fetch: !context.isPreview)
	}
	func timeline(for configuration: LockScreenArrivalIntent, in context: Context) async -> Timeline<LockScreenArrivalEntry> {
		let first = await entry(configuration, fetch: true)
		let entries = WidgetTimelineDates.make(now: first.date, snapshots: [first.snapshot].compactMap { $0 }).map { date in
			var value = first
			value.date = date
			return value
		}
		return Timeline(entries: entries, policy: .after(first.date.addingTimeInterval(300)))
	}
	private func entry(_ intent: LockScreenArrivalIntent, fetch: Bool) async -> LockScreenArrivalEntry {
		let now = Date()
		do {
			let designs = try WidgetDesignStorage.load()
			guard let selected = WidgetArrivalChoice.resolve(selectedID: intent.block?.id, in: designs) else {
				return .init(date: now, message: intent.block == nil
					? "Save an arrival block in w8g"
					: "Saved block removed. Choose another.")
			}
			let block = selected.block
			// Fetch only the selected arrival block, not every block in its saved design.
			let single = JourneyWidgetDesign(size: .small, blocks: [block])
			let snapshots = fetch ? await WidgetArrivalLoader.load(single, preferRecentCache: true) : [:]
			return .init(date: now, configuration: block.arrival, snapshot: snapshots[block.id],
				designID: selected.designID.uuidString, blockID: block.id.uuidString,
				url: URL(string: "w8g://widgets/" + selected.id)!)
		} catch {
			// Protected storage may be unavailable before the first unlock after a restart.
			return .init(date: now, message: "Open w8g to load saved arrivals")
		}
	}
}

struct LockScreenArrivalsWidget: Widget {
	var body: some WidgetConfiguration {
		AppIntentConfiguration(kind: "W8gLockScreenArrivals", intent: LockScreenArrivalIntent.self, provider: LockScreenArrivalProvider()) { entry in
			HStack(alignment: .top, spacing: 2) {
				LockScreenArrivalView(configuration: entry.configuration, snapshot: entry.snapshot, date: entry.date, emptyMessage: entry.message)
				if let designID = entry.designID, let blockID = entry.blockID {
					Button(intent: RefreshWidgetArrivalsIntent(designID: designID, blockID: blockID)) {
						Image(systemName: "arrow.clockwise").font(.system(size: 11)).frame(width: 24, height: 24)
					}.buttonStyle(.plain).accessibilityLabel("Refresh arrivals")
				}
			}
				.containerBackground(.clear, for: .widget)
				.widgetURL(entry.url)
		}
		.configurationDisplayName("Next arrivals")
		.description("Next arrival and three following estimates, from a saved arrival block.")
		.supportedFamilies([.accessoryRectangular])
	}
}
