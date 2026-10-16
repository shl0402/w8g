import SwiftUI

// Shared with the in-app preview. Lock Screen widgets use the system's monochrome styling.
struct LockScreenArrivalView: View {
	var configuration: WidgetArrivalConfiguration?
	var snapshot: WidgetArrivalSnapshot?
	var date = Date()
	var emptyMessage = "Save an arrival block in w8g"
	private var trains: [WidgetArrivalSnapshot.Train] { snapshot?.upcoming(at: date) ?? [] }

	var body: some View {
		VStack(alignment: .leading, spacing: 1) {
			if let configuration {
				Label(configuration.route + " · " + configuration.title,
					systemImage: configuration.provider == .mtr ? "tram.fill" : "bus.fill")
					.font(.system(size: 11, weight: .semibold)).lineLimit(1)
				if Set(trains.map(\.destination)).count > 1 {
					ForEach(Array(trains.enumerated()), id: \.element.id) { index, train in
						HStack(spacing: 2) {
							Text(train.destination).font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.8)
							Spacer(minLength: 0)
							Text(minutes(train) + "m").font(.system(size: index == 0 ? 16 : 10, weight: index == 0 ? .bold : .regular)).monospacedDigit()
						}.foregroundStyle(index == 0 ? Color.primary : Color.secondary)
					}
				} else {
					HStack(alignment: .firstTextBaseline, spacing: 5) {
						Text(trains.first.map { minutes($0) } ?? "—")
							.font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
						Text("min").font(.caption2)
						Spacer(minLength: 0)
						Text((1..<4).map { trains.count > $0 ? minutes(trains[$0]) : "—" }.joined(separator: " · "))
							.font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
					}.lineLimit(1).minimumScaleFactor(0.8)
				}
				Text(status).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
			} else {
				Label("Next arrivals", systemImage: "tram.fill").font(.headline)
				Text(emptyMessage).font(.caption2).foregroundStyle(.secondary)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
	}
	private var status: String {
		guard let snapshot else { return "Not updated" }
		guard let updated = snapshot.updated else { return "Unable to update" }
		if snapshot.isStale(at: date) { return "Outdated · " + widgetClock(updated) }
		if trains.isEmpty { return configuration?.destinationName.map { "To " + $0 + " · No estimates" } ?? "No estimates · " + widgetClock(updated) }
		let destination = Set(trains.map(\.destination)).count > 1 ? "Updated" : "To " + (configuration?.destinationName ?? trains.first?.destination ?? "")
		return destination + " · " + widgetClock(updated)
	}
	private func minutes(_ train: WidgetArrivalSnapshot.Train) -> String {
		String(max(0, Int(ceil(train.time.timeIntervalSince(date) / 60))))
	}
}
