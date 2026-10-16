import SwiftUI
import WidgetKit

struct WidgetOpenRequest: Identifiable {
	let id = UUID()
	let url: URL
}

struct WidgetDestinationView: View {
	let request: WidgetOpenRequest
	@Environment(\.dismiss) private var dismiss
	@Environment(SavedRouteStore.self) private var saved
	@State private var design: JourneyWidgetDesign?
	@State private var arrivals: [UUID: WidgetArrivalSnapshot] = [:]
	@State private var error: String?
	@State private var refresh = 0
	@State private var refreshing = false
	@State private var checked: Date?
	@State private var refreshFailed = false
	var body: some View {
		NavigationStack {
			Group {
				if let design {
					ScrollView {
						JourneyWidgetCanvas(design: design, arrivals: arrivals)
							.padding(12).aspectRatio(design.size == .medium ? 2 : 1, contentMode: .fit)
							.frame(maxWidth: design.size == .small ? 190 : 400)
							.background(.background, in: RoundedRectangle(cornerRadius: 24)).padding()
						WidgetRefreshControl(title: "Refresh arrivals", busy: refreshing, checked: checked, failed: refreshFailed) { refreshing = true; refresh += 1 }.padding(.horizontal)
						ForEach(design.blocks) { block in
							if block.kind == .arrivals, let snapshot = arrivals[block.id] {
								VStack(alignment: .leading, spacing: 12) {
									Text(block.title).font(.headline)
									ForEach(snapshot.upcoming(at: Date())) { train in
										HStack { Text("To " + train.destination); Spacer(); Text(widgetClock(train.time)).monospacedDigit() }
									}
								}.padding()
							}
							if let id = block.route?.savedID, let record = saved.records.first(where: { $0.id == id && $0.pending != .delete }) {
								NavigationLink("View " + record.journey.displayTitle) { RouteDetailView(journey: record.journey) }.padding()
							}
						}
						NavigationLink { WidgetEditorView(initial: design) } label: {
							Label("Edit widget", systemImage: "pencil")
						}.padding()
					}
					.onAppear { refresh += 1 }
				} else if let error { ContentUnavailableView("Widget unavailable", systemImage: "square.grid.2x2", description: Text(error)) }
				else { WidgetSettingsView() }
			}
			.navigationTitle(design?.name ?? "Widgets").navigationBarTitleDisplayMode(.inline)
			.toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
		}
		.task(id: refresh) {
			do {
				let components = request.url.pathComponents.filter { $0 != "/" }
				guard let id = components.first else { return }
				guard let found = try WidgetDesignStorage.load().first(where: { $0.id.uuidString == id }) else {
					error = "This design was removed. Choose another design on your Home Screen."; return
				}
				design = found
				refreshing = true
				let result = await WidgetArrivalLoader.load(found)
				guard !Task.isCancelled else { return }
				arrivals = result
				refreshFailed = result.values.contains { $0.refreshFailed == true }
				checked = Date(); refreshing = false
				WidgetCenter.shared.reloadAllTimelines()
			} catch { if !Task.isCancelled { self.error = error.localizedDescription; refreshing = false } }
		}
	}
}
