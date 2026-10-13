import SwiftUI

struct JourneyTimingView: View {
	let journey: Journey

	var body: some View {
		VStack(alignment: .leading, spacing: 5) {
			ViewThatFits(in: .horizontal) {
				HStack(alignment: .top, spacing: 24) { timingColumns }
				VStack(alignment: .leading, spacing: 10) { timingColumns }
			}
			if journey.waitingBeforeLeaving > 0 {
				Text("Includes \(journey.waitingBeforeLeaving) min before leaving")
					.font(.caption).foregroundStyle(AppTheme.secondaryText)
			}
		}
	}

	@ViewBuilder private var timingColumns: some View {
		column(journey.stayMinutes(at: 0) > 0 ? "Start" : "Leave", value: journey.startDate.map { JourneyTime.clock($0) } ?? "—")
		column(journey.stayMinutes(at: journey.stops.count - 1) > 0 ? "Finish" : "Arrive", value: arrival)
		column("Total", value: "\(journey.minutes) min")
	}

	private var arrival: String {
		guard let end = journey.endDate else { return "—" }
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = JourneyTime.zone
		let days = journey.startDate.map {
			calendar.dateComponents([.day], from: calendar.startOfDay(for: $0), to: calendar.startOfDay(for: end)).day ?? 0
		} ?? 0
		return JourneyTime.clock(end) + (days > 0 ? " (+\(days)d)" : "")
	}

	private func column(_ title: String, value: String) -> some View {
		VStack(alignment: .leading, spacing: 3) {
			Text(title).font(.caption).foregroundStyle(AppTheme.secondaryText)
			Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
		}.fixedSize(horizontal: true, vertical: false)
	}
}

struct JourneyTimetableFooter: View {
	let journey: Journey
	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Divider()
			Text("Timetable estimates, not live arrivals. Check service hours before travelling; saved times may differ on another day.")
				.font(.caption).foregroundStyle(AppTheme.secondaryText)
			if let note = journey.availability?.text,
				let warning = note.range(of: "Warning:") {
				Text(String(note[warning.lowerBound...]))
					.font(.caption).foregroundStyle(AppTheme.secondaryText)
			}
			if journey.legs.contains(where: { $0.transitLeg == true }) {
				NavigationLink { OperatorArrivalsDestination(journey: journey) } label: {
					Label("Check arrival estimates", systemImage: "clock.arrow.circlepath")
						.font(.subheadline).frame(minHeight: 44)
				}
			}
		}
	}
}

// Destination reserved for the next operator-API feature. Never present saved times as live ETAs.
private struct OperatorArrivalsDestination: View {
	let journey: Journey
	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 18) {
				Label("Operator arrivals", systemImage: "clock.arrow.circlepath").font(.title2.bold())
				Text("Live arrival checking will be connected here in a future step.")
				Text("This screen does not fetch live estimates yet.")
					.font(.footnote).foregroundStyle(AppTheme.secondaryText)
				JourneyFlowView(journey: journey)
			}.padding(20)
		}
		.background(AppTheme.background)
		.navigationTitle("Arrival estimates")
		.navigationBarTitleDisplayMode(.inline)
	}
}
