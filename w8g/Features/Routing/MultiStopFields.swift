import SwiftUI

struct MultiStopFields: View {
    let planner: RoutePlannerModel
    let search: (RouteSearchField) -> Void
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight = 60.0

    var body: some View {
        if !planner.visits.isEmpty {
            // Native reordering moves the neighbouring rows during the drag.
            // The model receives the final order when the user releases it.
            List {
                ForEach(planner.visits) { visit in
                    MultiStopRow(visit: visit, planner: planner, search: search)
                        .frame(height: rowHeight)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .moveDisabled(planner.isWaiting)
                }
                .onMove { offsets, destination in
                    planner.moveVisits(fromOffsets: offsets, toOffset: destination)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
            .environment(\.defaultMinListRowHeight, rowHeight)
            .frame(height: rowHeight * Double(min(planner.visits.count, 3)))
        }
        if planner.visits.count < 8 {
            Button { search(.addStop) } label: {
                Label("Add a stop", systemImage: "plus")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct MultiStopRow: View {
    let visit: RouteVisit
    let planner: RoutePlannerModel
    let search: (RouteSearchField) -> Void
    @State private var showingStaySettings = false

    var body: some View {
        HStack(spacing: 6) {
            Button { search(.visit(visit.id)) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(visit.place.name).font(.subheadline).lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Change stop: " + visit.place.name)
            .accessibilityAction(named: Text("Move earlier")) {
                planner.moveVisit(visit.id, by: -1)
            }
            .accessibilityAction(named: Text("Move later")) {
                planner.moveVisit(visit.id, by: 1)
            }
            Button { showingStaySettings = true } label: {
                Text("Stay \(planner.stayMinutes(for: visit)) min").font(.caption)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stay time for " + visit.place.name)
            Menu {
                Button("Stay time", systemImage: "pause.circle") { showingStaySettings = true }
                Button("Change location", systemImage: "mappin.and.ellipse") { search(.visit(visit.id)) }
                Button("Use default stay time", systemImage: "arrow.uturn.backward") {
                    planner.setStayMinutes(nil, for: visit.id)
                }
                Button("Remove stop", systemImage: "trash", role: .destructive) {
                    planner.removeVisit(visit.id)
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 36, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Options for " + visit.place.name)
        }
        .sheet(isPresented: $showingStaySettings) {
            StopStaySettings(planner: planner, visit: visit)
        }
    }
}
