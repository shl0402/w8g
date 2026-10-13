import SwiftUI

struct StayTimePicker: View {
    @Binding var minutes: Int

    var body: some View {
        HStack(spacing: 0) {
            Picker("Hours", selection: Binding(
                get: { minutes / 60 },
                set: { minutes = min(720, $0 * 60 + minutes % 60) }
            )) {
                ForEach(0...12, id: \.self) { Text("\($0) hr").tag($0) }
            }
            Picker("Minutes", selection: Binding(
                get: { minutes % 60 },
                set: { minutes = min(720, minutes / 60 * 60 + $0) }
            )) {
                ForEach(0..<(minutes / 60 == 12 ? 1 : 60), id: \.self) { Text("\($0) min").tag($0) }
            }
        }
        .pickerStyle(.wheel)
        .frame(height: 150)
    }
}

struct StopStaySettings: View {
    let planner: RoutePlannerModel
    let visit: RouteVisit
    @Environment(\.dismiss) private var dismiss
    @State private var usesDefault: Bool
    @State private var minutes: Int

    init(planner: RoutePlannerModel, visit: RouteVisit) {
        self.planner = planner
        self.visit = visit
        // Local draft: Cancel discards the picker changes.
        _usesDefault = State(initialValue: visit.stayMinutes == nil)
        _minutes = State(initialValue: planner.stayMinutes(for: visit))
    }

    var body: some View {
        NavigationStack {
            Form {
                Text(visit.place.name).font(.headline)
                Toggle("Use default (\(planner.defaultStayMinutes) min)", isOn: $usesDefault)
                if !usesDefault { StayTimePicker(minutes: $minutes) }
                Text("Stay here after arrival before starting the next trip.")
                    .font(.footnote)
            }
            .navigationTitle("Stay time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        planner.setStayMinutes(usesDefault ? nil : minutes, for: visit.id)
                        dismiss()
                    }
                }
            }
        }
        .tint(AppTheme.ink)
        .presentationDetents([.medium, .large])
    }
}
