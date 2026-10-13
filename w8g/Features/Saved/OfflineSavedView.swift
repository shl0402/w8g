import SwiftUI

struct OfflineSavedView: View {
	@Environment(AppSession.self) private var session
	@Environment(SavedRouteStore.self) private var saved
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@State private var opened: SavedRoute?
	@State private var removing: SavedRoute?
	@State private var sharing: SavedRoute?
	@State private var removalError: String?

	private var owner: String? { session.account?.id }
	private var online: Bool { owner != nil }
	private var flip: AnyTransition {
		reduceMotion ? .opacity : .asymmetric(
			insertion: .modifier(active: SavedPageTurn(angle: 180), identity: SavedPageTurn(angle: 0)),
			removal: .modifier(active: SavedPageTurn(angle: -180), identity: SavedPageTurn(angle: 0))
		)
	}

	var body: some View {
		ZStack {
			if let route = opened {
				SavedJourneyMapView(
					route: route, online: online,
					canRemove: !saved.isSyncing && saved.storageError == nil,
					share: { sharing = route }, remove: { removing = route }
				)
					.transition(flip)
			} else {
				routeList.transition(flip)
			}
		}
		.background(AppTheme.background)
		.animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.45), value: opened?.id)
		.navigationTitle(opened == nil ? "Saved" : "Saved journey")
		.navigationBarTitleDisplayMode(opened == nil ? .large : .inline)
		.navigationBarBackButtonHidden(opened != nil)
		.toolbar {
			if opened != nil {
				ToolbarItem(placement: .topBarLeading) {
					Button { opened = nil } label: { Label("Saved", systemImage: "chevron.left") }
				}
			}
		}
		.task(id: owner) {
			opened = nil
			if let owner { await saved.synchronise(owner: owner) }
		}
		.sheet(item: $sharing) { route in SavedRouteShareSheet(journey: route.journey) }
		.confirmationDialog("Remove this route?", isPresented: Binding(
			get: { removing != nil }, set: { if !$0 { removing = nil } }
		), titleVisibility: .visible) {
			if let route = removing {
				Button("Remove", role: .destructive) {
					saved.remove(route, online: online)
					removing = nil
					if saved.visible(for: owner).contains(where: { $0.id == route.id }) {
						removalError = saved.storageError ?? saved.errorMessage ?? "Could not remove this route. Please try again."
					} else {
						if opened?.id == route.id { opened = nil }
						if let owner { Task { await saved.synchronise(owner: owner) } }
					}
				}
			}
			Button("Cancel", role: .cancel) { removing = nil }
		}
		.alert("Could not remove route", isPresented: Binding(
			get: { removalError != nil }, set: { if !$0 { removalError = nil } }
		)) {
			Button("OK", role: .cancel) { removalError = nil }
		} message: { Text(removalError ?? "Please try again.") }
	}

	private var routeList: some View {
		ScrollView {
			LazyVStack(alignment: .leading, spacing: 18) {
				Text(online ? "Ready whenever you need them." : "Downloaded on this iPhone")
					.foregroundStyle(AppTheme.secondaryText)
				if let message = saved.storageError ?? saved.errorMessage {
					Text(message).font(.footnote).foregroundStyle(.red)
				}
				if saved.skippedRows > 0, online {
					Text("Some older saved records could not be read. They remain in your account.").font(.footnote)
				}
				NavigationLink { OfflineMapsView() } label: {
					Label("Offline maps", systemImage: "arrow.down.circle").frame(minHeight: 44)
				}
				let routes = saved.visible(for: owner)
				if routes.isEmpty {
					ContentUnavailableView("No saved routes yet", systemImage: "bookmark",
						description: Text("Open a journey's details and tap the bookmark to save it."))
				}
				ForEach(routes) { route in
					SavedRouteCard(route: route, online: online, canRemove: !saved.isSyncing,
						open: { opened = route }, share: { sharing = route }, remove: { removing = route })
				}
			}.padding(20)
		}
		.refreshable { if let owner { await saved.synchronise(owner: owner) } }
	}
}

private struct SavedRouteCard: View {
	let route: SavedRoute
	let online: Bool
	let canRemove: Bool
	let open: () -> Void
	let share: () -> Void
	let remove: () -> Void

	var body: some View {
		Button(action: open) {
			VStack(alignment: .leading, spacing: 12) {
				SavedRoutePreview(route: route, online: online, allowsRetry: false)
					.allowsHitTesting(false).accessibilityHidden(true)
				VStack(alignment: .leading, spacing: 12) {
					Text(route.journey.displayTitle).font(.headline)
					JourneyFlowView(journey: route.journey)
					JourneyTimingView(journey: route.journey)
				}.padding(.horizontal, 16).padding(.bottom, 58)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityHint("Opens the saved route map and journey details")
		.overlay(alignment: .bottomTrailing) {
			HStack(spacing: 4) {
				Button(action: share) {
					Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
				}.accessibilityLabel("Share saved route")
				Button(role: .destructive, action: remove) {
					Image(systemName: "trash").frame(width: 44, height: 44)
				}.foregroundStyle(.red).disabled(!canRemove).accessibilityLabel("Remove saved route")
			}.buttonStyle(.plain).padding(8)
		}
		.background(.background, in: RoundedRectangle(cornerRadius: 18))
		.clipShape(RoundedRectangle(cornerRadius: 18))
	}
}

// Switch faces at the halfway point, so text never appears mirrored.
private struct SavedPageTurn: AnimatableModifier {
	var angle: Double
	var animatableData: Double {
		get { angle }
		set { angle = newValue }
	}
	func body(content: Content) -> some View {
		content.opacity(abs(angle) < 90 ? 1 : 0)
			.rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.3)
	}
}
