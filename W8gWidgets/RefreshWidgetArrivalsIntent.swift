import AppIntents
import WidgetKit

struct RefreshWidgetArrivalsIntent: AppIntent {
	static var title: LocalizedStringResource = "Refresh arrivals"
	static var description = IntentDescription("Check the operator for updated arrival estimates.")
	static var openAppWhenRun = false
	@Parameter(title: "Design ID") var designID: String
	@Parameter(title: "Block ID") var blockID: String
	init() { }
	init(designID: String, blockID: String = "") { self.designID = designID; self.blockID = blockID }
	@MainActor func perform() async throws -> some IntentResult {
		if var design = try WidgetDesignStorage.load().first(where: { $0.id.uuidString == designID }) {
			if !blockID.isEmpty { design.blocks = design.blocks.filter { $0.id.uuidString == blockID } }
			_ = await WidgetArrivalLoader.load(design)
		}
		WidgetCenter.shared.reloadAllTimelines()
		return .result()
	}
}
