import SwiftUI

struct MultiStopJourneyDetail: View {
    let journey: Journey
    let hasChanges: Bool
    let onUpdate: (Journey) -> Void
    @State private var alternativeTrip: TripChoice?

    private struct TripChoice: Identifiable {
        let id: String
        let index: Int
    }

    var body: some View {
        let trips = journey.pointToPointJourneys
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    Text(journey.displayTitle)
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    SaveJourneyButton(journey: journey)
                }
                JourneyTimingView(journey: journey)
                if hasChanges {
                    Text("Journey updated. Save to keep this version.")
                        .font(.caption).foregroundStyle(AppTheme.secondaryText)
                }
                if trips.isEmpty {
                    Text("This older journey has no separate trip details. Plan it again to see each trip.")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.secondaryText)
                    NavigationLink("View saved journey details") {
                        RouteDetailContent(journey: journey, showsSave: false)
                            .navigationTitle("Journey details")
                            .navigationBarTitleDisplayMode(.inline)
                    }
                } else {
                    ForEach(trips) { trip in
                        VStack(spacing: 16) {
                            if let index = trips.firstIndex(where: { $0.id == trip.id }), index > 0 {
                                HStack(spacing: 12) {
                                    Rectangle().fill(Color.gray.opacity(0.25)).frame(height: 1)
                                    Text("Stay \(journey.stayMinutes(at: index)) min")
                                        .font(.caption)
                                        .foregroundStyle(AppTheme.secondaryText)
                                        .fixedSize(horizontal: true, vertical: false)
                                    Rectangle().fill(Color.gray.opacity(0.25)).frame(height: 1)
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("Stay \(journey.stayMinutes(at: index)) minutes at \(journey.stops[index].name)")
                            }
                        VStack(alignment: .leading, spacing: 0) {
                            NavigationLink {
                                RouteDetailContent(journey: trip, showsSave: false)
                                    .navigationTitle("Journey details")
                                    .navigationBarTitleDisplayMode(.inline)
                            } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(alignment: .top, spacing: 12) {
                                        Text(trip.displayTitle)
                                            .font(.subheadline.weight(.semibold))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(AppTheme.secondaryText)
                                    }
                                    JourneyFlowView(journey: trip)
                                    JourneyTimingView(journey: trip)
                                }
                                .padding(16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.background, in: RoundedRectangle(cornerRadius: 16))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens this point-to-point trip")
                            if let index = trips.firstIndex(where: { $0.id == trip.id }) {
                                if index > 0, let previousEnd = trips[index - 1].endDate,
                                    let start = trip.startDate,
                                    start.timeIntervalSince(previousEnd) - Double(journey.stayMinutes(at: index) * 60) >= 60 {
                                    Label("Wait \(Int(start.timeIntervalSince(previousEnd) / 60) - journey.stayMinutes(at: index)) min before this trip", systemImage: "clock")
                                        .font(.caption).foregroundStyle(AppTheme.secondaryText)
                                        .padding(.horizontal, 16)
                                }
                                if index == 0, journey.stayMinutes(at: index) > 0 {
                                    Label("Stay \(journey.stayMinutes(at: index)) min at " + trip.stops[0].name, systemImage: "pause.circle")
                                        .font(.caption).foregroundStyle(AppTheme.secondaryText)
                                        .padding(.horizontal, 16)
                                }
                                Button {
                                    alternativeTrip = TripChoice(id: trip.id, index: index)
                                } label: {
                                    Label("Choose another route", systemImage: "arrow.triangle.branch")
                                        .font(.subheadline)
                                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 4)
                            }
                        }
                        .background(.background, in: RoundedRectangle(cornerRadius: 16))
                        }
                    }
                }
                if journey.stayMinutes(at: journey.stops.count - 1) > 0 {
                    Label("Final stay: \(journey.stayMinutes(at: journey.stops.count - 1)) min", systemImage: "pause.circle")
                        .font(.subheadline)
                }
                JourneyTimetableFooter(journey: journey)
            }
            .padding(20)
        }
        .background(AppTheme.background)
        .foregroundStyle(AppTheme.ink)
        .sheet(item: $alternativeTrip) { choice in
            TripAlternativesView(journey: journey, tripIndex: choice.index, onUpdate: onUpdate)
        }
    }
}
