import SwiftUI
import UIKit

struct SavedRouteShareSheet: View {
	let journey: Journey
	@Environment(\.dismiss) private var dismiss
	@State private var code: String?
	@State private var message: String?
	@State private var copied = false
	@State private var showingActivity = false

	var body: some View {
		NavigationStack {
			ScrollView {
			VStack(alignment: .leading, spacing: 20) {
				Text(journey.displayTitle).font(.headline)
				JourneyFlowView(journey: journey)
				Text("Share this route and its saved directions as a text code.")
					.font(.subheadline).foregroundStyle(AppTheme.secondaryText)
				if let code {
					Button {
						UIPasteboard.general.string = code
						copied = true
					} label: {
						Label(copied ? "Copied" : "Copy route code", systemImage: copied ? "checkmark" : "doc.on.doc")
							.frame(maxWidth: .infinity, minHeight: 44)
					}
					.buttonStyle(.bordered)
					Button { showingActivity = true } label: {
						Label("Share to another app", systemImage: "square.and.arrow.up")
							.frame(maxWidth: .infinity, minHeight: 44)
					}
					.buttonStyle(.borderedProminent).tint(AppTheme.ink).foregroundStyle(.white)
				} else if let message {
					Text(message).foregroundStyle(.red)
				} else {
					ProgressView("Preparing route code…")
				}
				Text("Map downloads and account details are not included. Times remain a saved timetable snapshot.")
					.font(.caption).foregroundStyle(AppTheme.secondaryText)
			}.padding(20)
			}
			.background(AppTheme.background)
			.navigationTitle("Share route")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
		}
		.tint(AppTheme.ink)
		.presentationDetents([.medium, .large])
		.sheet(isPresented: $showingActivity) {
			if let code { RouteActivityView(code: code) }
		}
		.task {
			do { code = try RouteShareCode.encode(journey) }
			catch { message = error.localizedDescription }
		}
	}
}

// Explicit sheet ownership avoids ShareLink presenting behind an existing sheet on iOS 17.
private struct RouteActivityView: UIViewControllerRepresentable {
	let code: String
	func makeUIViewController(context: Context) -> UIActivityViewController {
		UIActivityViewController(activityItems: [code], applicationActivities: nil)
	}
	func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}
