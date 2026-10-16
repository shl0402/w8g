import SwiftUI
import WidgetKit
import UniformTypeIdentifiers

struct WidgetSettingsView: View {
	@State private var designs: [JourneyWidgetDesign] = []
	@State private var editing: JourneyWidgetDesign?
	@State private var error: String?
	@State private var delete: JourneyWidgetDesign?
	@State private var showHelp = false
	@State private var loaded = false

	var body: some View {
		List {
			Section {
				Button { editing = JourneyWidgetDesign() } label: { Label("Create widget", systemImage: "plus") }
					.disabled(!loaded)
			} footer: { Text("Combine next arrivals and saved routes. Layouts stay on this iPhone.") }
			if let error { Text(error).foregroundStyle(.red) }
			ForEach(designs) { design in
				Section {
					NavigationLink { WidgetEditorView(initial: design) } label: {
						VStack(alignment: .leading, spacing: 5) {
							Text(design.name).font(.headline)
							Text("\(design.size.title) · \(design.blocks.count) blocks").font(.caption).foregroundStyle(.secondary)
						}
						.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
						.contentShape(Rectangle())
					}
					.swipeActions { Button("Remove", role: .destructive) { delete = design } }
				}
			}
			Section { Button("Add to Home or Lock Screen") { showHelp = true } }
		}
		.navigationTitle("Widgets")
		.onAppear { load() }
		.sheet(item: $editing, onDismiss: load) { design in
			NavigationStack { WidgetEditorView(initial: design, isNew: true) }
		}
		.alert("Remove this widget design?", isPresented: Binding(get: { delete != nil }, set: { if !$0 { delete = nil } })) {
			Button("Remove", role: .destructive) {
				do {
					try WidgetDesignStorage.save(designs.filter { $0.id != delete?.id })
					WidgetCenter.shared.reloadAllTimelines()
					delete = nil
					load()
				} catch { self.error = error.localizedDescription }
			}
			Button("Cancel", role: .cancel) { delete = nil }
		} message: { Text("Any Home Screen widget using this design will ask you to choose another.") }
		.sheet(isPresented: $showHelp) { WidgetInstallHelp() }
	}
	private func load() {
		do { designs = try WidgetDesignStorage.load(); loaded = true; error = nil
			WidgetCenter.shared.reloadTimelines(ofKind: "W8gLockScreenArrivals") }
		catch { self.error = error.localizedDescription; loaded = false }
	}
}

private struct WidgetInstallHelp: View {
	@Environment(\.dismiss) private var dismiss
	var body: some View {
		NavigationStack {
			List {
				Text("1. Save your design here.")
				Text("2. Touch and hold your Home Screen, then choose Edit → Add Widget (or + on iOS 17).")
				Text("3. Find w8g and add the same size as your design.")
				Text("4. Hold the widget → Edit Widget → Design, then choose its name.")
				Text("For the Lock Screen: hold the Lock Screen → Customise → Lock Screen → Add Widgets → w8g → Next arrivals. It uses your first saved arrival block automatically. Tap the added widget while customising to choose another.")
				Text("Arrival updates are managed by iOS. Check the update time before travelling.").font(.footnote).foregroundStyle(.secondary)
			}
			.navigationTitle("Add your widget").navigationBarTitleDisplayMode(.inline)
			.toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
		}
		.presentationDetents([.medium, .large])
	}
}

struct WidgetEditorView: View {
	@Environment(SavedRouteStore.self) private var saved
	@Environment(AppSession.self) private var session
	@State private var refreshing = false
	@State private var checked: Date?
	@State private var refreshFailed = false
	@Environment(\.dismiss) private var dismiss
	@State private var design: JourneyWidgetDesign
	@State private var selected: JourneyWidgetBlock?
	@State private var snapshots: [UUID: WidgetArrivalSnapshot] = [:]
	@State private var error: String?
	@State private var showHelp = false
	@State private var dragged: UUID?
	@State private var refresh = 0
	let isNew: Bool
	init(initial: JourneyWidgetDesign, isNew: Bool = false) {
		_design = State(initialValue: initial)
		self.isNew = isNew
	}

	var body: some View {
		List {
			Section {
				TextField("Widget name", text: $design.name)
				Picker("Size", selection: sizeBinding) {
					ForEach(JourneyWidgetSize.allCases) { size in
						Text(size.title).tag(size)
					}
				}
			}
			Section {
				JourneyWidgetCanvas(design: design, arrivals: snapshots, selectBlock: { id in selected = design.blocks.first { $0.id == id } })
					.padding(12)
					.aspectRatio(design.size == .medium ? 2 : 1, contentMode: .fit)
					.frame(maxWidth: design.size == .small ? 180 : 360)
					.background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 24))
					.overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(.gray.opacity(0.2)).allowsHitTesting(false) }
					.frame(maxWidth: .infinity)
					.listRowBackground(Color.clear)
			} header: { Text("Preview · \(design.usedSpaces)/\(design.size.capacity) spaces") }
			if design.blocks.contains(where: { $0.kind == .arrivals }) {
				Section("Lock Screen preview") {
					ForEach(design.blocks.filter { $0.kind == .arrivals }) { block in
						Button { selected = block } label: {
							LockScreenArrivalView(configuration: block.arrival, snapshot: snapshots[block.id])
								.frame(width: 170, height: 76)
								.padding(12)
								.foregroundStyle(.white)
								.background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
						}.buttonStyle(.plain)
						.accessibilityLabel("Edit Lock Screen arrivals for " + block.title)
					}
				}
			}
			Section {
				ForEach(design.blocks) { block in
					HStack {
						Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
						Button { selected = block } label: {
							VStack(alignment: .leading) {
								Text(block.title).lineLimit(2)
								Text((block.kind == .arrivals ? "Next arrivals · " : "Saved route · ") + block.size.title).font(.caption).foregroundStyle(.secondary)
							}.frame(maxWidth: .infinity, alignment: .leading)
						}.buttonStyle(.plain)
						Menu {
							ForEach(WidgetBlockSize.allCases) { size in
								Button(size.title) { resize(block, to: size) }.disabled(!fits(block, size))
							}
							Button("Remove", role: .destructive) { design.blocks.removeAll { $0.id == block.id } }
						} label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
						.accessibilityLabel("Size or remove " + block.title)
					}
					.onDrag { dragged = block.id; return NSItemProvider(object: block.id.uuidString as NSString) }
					.onDrop(of: [UTType.text], delegate: WidgetBlockDrop(target: block.id, blocks: $design.blocks, dragged: $dragged, size: design.size))
				}
				.onMove { source, target in
					var next = design
					next.blocks.move(fromOffsets: source, toOffset: target)
					if WidgetGrid.placements(for: next) != nil { design = next }
				}
				Menu {
					Button("Next arrivals", systemImage: "tram.fill") { add(.arrivals) }
					Button("Saved route", systemImage: "bookmark") { add(.route) }
				} label: { Label("Add block", systemImage: "plus") }
				.disabled(design.usedSpaces >= design.size.capacity)
			} header: { Text("Blocks") } footer: { Text("Hold a block to reorder. Use … to change how much space it occupies.") }
			if let error { Text(error).foregroundStyle(.red) }
			Section {
				WidgetRefreshControl(busy: refreshing, checked: checked, failed: refreshFailed) { refreshing = true; refresh += 1 }
			} footer: { Text("Arrivals come directly from the operator. Home and Lock Screen background updates are scheduled by iOS; use the widget’s refresh icon for a fresh check.") }
		}
		.navigationTitle("Design widget").navigationBarTitleDisplayMode(.inline)
		.navigationBarBackButtonHidden()
		.toolbar {
			ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
			ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!design.isValid || refreshing) }
		}
		.sheet(item: $selected) { block in
			NavigationStack {
				WidgetBlockEditor(initial: block, allowedSizes: WidgetBlockSize.allCases.filter { fits(block, $0) }) { updated in
					if let index = design.blocks.firstIndex(where: { $0.id == updated.id }) { design.blocks[index] = updated }
					refresh += 1
				}
			}
		}
		.sheet(isPresented: $showHelp, onDismiss: { dismiss() }) { WidgetInstallHelp() }
		.task(id: refresh) {
			refreshing = true
			let captured = design
			let result = await WidgetArrivalLoader.load(captured)
			guard !Task.isCancelled else { return }
			snapshots = result
			let prepared = await WidgetRoutePreviewBuilder.prepare(captured, records: saved.visible(for: session.account?.id), online: session.account != nil || session.isGuest)
			guard !Task.isCancelled else { return }
			for block in prepared.blocks {
				if let index = design.blocks.firstIndex(where: { $0.id == block.id && $0.route?.savedID == block.route?.savedID }) {
					design.blocks[index].route = block.route
				}
			}
			refreshFailed = result.values.contains { $0.refreshFailed == true }
				|| prepared.blocks.contains { $0.kind == .route && $0.size == .expanded && $0.route?.showMap != false && $0.route?.mapImageName == nil }
			checked = Date()
			refreshing = false
			WidgetCenter.shared.reloadAllTimelines()
		}
	}
	private var sizeBinding: Binding<JourneyWidgetSize> {
		Binding(get: { design.size }, set: { size in
			var candidate = design
			candidate.size = size
			guard WidgetGrid.placements(for: candidate) != nil else {
				error = "Remove or shrink a block before choosing this size."
				return
			}
			design = candidate
			error = nil
		})
	}
	private func fits(_ block: JourneyWidgetBlock, _ size: WidgetBlockSize) -> Bool {
		var candidate = block; candidate.size = size
		return design.canFit(candidate, replacing: block.id)
	}
	private func resize(_ block: JourneyWidgetBlock, to size: WidgetBlockSize) {
		guard fits(block, size), let index = design.blocks.firstIndex(where: { $0.id == block.id }) else { return }
		design.blocks[index].size = size
		refresh += 1
	}
	private func add(_ kind: JourneyWidgetBlock.Kind) {
		let block = JourneyWidgetBlock(kind: kind, arrival: kind == .arrivals ? WidgetArrivalConfiguration() : nil)
		guard design.canFit(block) else { return }
		design.blocks.append(block)
		selected = block
	}
	private func save() {
		do {
			var all = try WidgetDesignStorage.load()
			design.name = design.name.trimmingCharacters(in: .whitespacesAndNewlines)
			if let index = all.firstIndex(where: { $0.id == design.id }) { all[index] = design }
			else { all.append(design) }
			try WidgetDesignStorage.save(all)
			WidgetCenter.shared.reloadAllTimelines()
			if isNew { showHelp = true }
			else { dismiss() }
		} catch { self.error = error.localizedDescription }
	}
}

private struct WidgetBlockDrop: DropDelegate {
	let target: UUID
	@Binding var blocks: [JourneyWidgetBlock]
	@Binding var dragged: UUID?
	let size: JourneyWidgetSize
	func dropEntered(info: DropInfo) {
		guard let dragged, dragged != target,
			let from = blocks.firstIndex(where: { $0.id == dragged }), let to = blocks.firstIndex(where: { $0.id == target }) else { return }
		var candidate = blocks
		candidate.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
		let design = JourneyWidgetDesign(size: size, blocks: candidate)
		if WidgetGrid.placements(for: design) != nil { withAnimation { blocks = candidate } }
	}
	func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
	func performDrop(info: DropInfo) -> Bool { dragged = nil; return true }
}
