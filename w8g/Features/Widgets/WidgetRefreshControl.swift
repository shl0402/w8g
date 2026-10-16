import SwiftUI

struct WidgetRefreshControl: View {
	var title = "Refresh preview"
	let busy: Bool
	let checked: Date?
	let failed: Bool
	let action: () -> Void
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			Button(action: action) {
				HStack(spacing: 10) {
					if busy { ProgressView().controlSize(.small) }
					else { Image(systemName: "arrow.clockwise") }
					Text(busy ? "Refreshing…" : title)
					Spacer()
				}
				.frame(minHeight: 44).contentShape(Rectangle())
			}.disabled(busy)
			if !busy, let checked {
				Label(failed ? "Some previews could not update. Tap to retry." : "Preview refreshed · " + checked.formatted(date: .omitted, time: .shortened),
					systemImage: failed ? "exclamationmark.circle" : "checkmark.circle.fill")
					.font(.caption).foregroundStyle(failed ? Color.secondary : Color.green)
			}
		}
		.animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: busy)
		.sensoryFeedback(.success, trigger: checked) { _, _ in !failed }
	}
}

@MainActor
enum WidgetRoutePreviewBuilder {
	static func prepare(_ design: JourneyWidgetDesign, records: [SavedRoute], online: Bool) async -> JourneyWidgetDesign {
		var updated = design
		for index in updated.blocks.indices {
			guard var route = updated.blocks[index].route,
				let saved = records.first(where: { $0.id == route.savedID && $0.pending != .delete }),
				saved.journey.source != "Google Maps" else { continue }
			route.transfers = saved.journey.transferCount
			route.walkMeters = saved.journey.walkDistance
			if updated.blocks[index].size == .expanded, route.showMap != false {
				let preview = SavedRoutePreviewModel()
				preview.load(saved, online: online, scale: 2)
				do {
					while preview.isLoading { try await Task.sleep(for: .milliseconds(100)) }
					try Task.checkCancellation()
				} catch { preview.cancel(); return design }
				if let image = preview.image {
					let format = UIGraphicsImageRendererFormat()
					format.scale = 2
					let bitmap = UIGraphicsImageRenderer(size: CGSize(width: 360, height: 180), format: format).image { _ in
						image.draw(in: CGRect(x: 0, y: 0, width: 360, height: 180))
					}
					if let data = bitmap.pngData(), let name = try? WidgetRouteImageStorage.save(data) {
					route.mapImageName = name
					}
				}
			}
			updated.blocks[index].route = route
		}
		return updated
	}
}
