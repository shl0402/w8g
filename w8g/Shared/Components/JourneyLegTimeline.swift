import SwiftUI

// The stop list belongs to one immutable leg; expanding it never starts a new request.
struct JourneyLegTimeline: View {
    let leg: JourneyLeg
    @State private var expanded = false

    private var color: Color { TransitAppearance.color(leg) }
    private var operators: [String] { leg.route?.operatorIds ?? [] }
    // The API supplies both endpoints in stopCalls. They are shown as cards below.
    private var calls: [JourneyLeg.StopCall] { leg.stopCalls ?? [] }
    private var middleStops: [TimelineStop] {
        guard calls.count >= 2 else { return [] }
        return calls.dropFirst().dropLast().enumerated().map {
            TimelineStop(id: $0.offset, name: stopName($0.element.stopLocation.name))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TimelineRow(color: color, first: true, endpoint: true) {
                VStack(alignment: .leading, spacing: 8) {
                    stopHeading(leg.from.name, time: leg.start?.scheduledTime)
                    if leg.transitLeg == true {
                        NavigationLink { ArrivalsView(leg: leg) } label: {
                            Label("Next arrivals", systemImage: "clock.arrow.circlepath").font(.subheadline).frame(minHeight: 44)
                        }
                    }
                    Label(TransitAppearance.detailName(leg), systemImage: TransitAppearance.symbol(leg))
                        .font(.subheadline.weight(.semibold))
                    if !leg.isWalking, let headsign = leg.headsign, !headsign.isEmpty {
                        Text(MTRLineStyle.fullNames(JourneyText.plain(headsign)))
                            .font(.subheadline).foregroundStyle(AppTheme.secondaryText)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 14))
            }
            TimelineRow(color: color) {
                VStack(alignment: .leading, spacing: 8) {
                    if let seconds = leg.waitBeforeSeconds, seconds >= 60 {
                        Label("Wait about \(Int(ceil(seconds / 60))) min before departure", systemImage: "clock")
                            .font(.footnote).foregroundStyle(AppTheme.secondaryText)
                    }
                    if !leg.isWalking {
                        if calls.count >= 2 {
                            Button { expanded.toggle() } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                        .font(.caption.weight(.semibold))
                                    Text("Ride \(calls.count - 1) \(calls.count == 2 ? "stop" : "stops") · \(leg.minutes) min")
                                        .font(.subheadline.weight(.semibold))
                                }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                            .accessibilityHint("Shows or hides intermediate stops")
                            .disabled(middleStops.isEmpty)
                        } else {
                            Text("Ride · \(leg.minutes) min").font(.subheadline.weight(.semibold))
                            Text("Intermediate stops unavailable").font(.caption).foregroundStyle(AppTheme.secondaryText)
                        }
                    } else {
                        Label("Walk \(leg.minutes) min · \(Int(leg.distance ?? 0)) m", systemImage: "figure.walk")
                            .font(.subheadline)
                        if let steps = leg.steps, !steps.isEmpty {
                            DisclosureGroup("Walking directions") {
                                ForEach(timelineItems(steps)) { item in
                                    Text((item.value.relativeDirection ?? "Continue")
                                        .replacingOccurrences(of: "_", with: " ").capitalized
                                        + " · " + (item.value.bogusName == true ? "Path" : JourneyText.plain(item.value.streetName ?? "Path"))
                                        + " · \(Int(item.value.distance ?? 0)) m")
                                        .font(.footnote).padding(.vertical, 4)
                                }
                            }
                        }
                    }
                    if let instructions = leg.journeyInstructions {
                        ForEach(timelineItems(instructions)) { item in
                            Label(MTRLineStyle.fullNames(JourneyText.plain(item.value.text)), systemImage: "arrow.triangle.swap")
                                .font(.footnote)
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
            }
            if expanded {
                ForEach(middleStops) { stop in
                    TimelineRow(color: color, station: true) {
                        Text(stop.name).font(.subheadline)
                            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                            .padding(.horizontal, 8)
                    }
                }
            }
            TimelineRow(color: color, last: true, endpoint: true) {
                stopHeading(leg.to.name, time: leg.end?.scheduledTime)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private func stopName(_ name: String) -> String {
        let clean = JourneyText.stopName(name, operators: operators)
        return ["SUBWAY", "RAIL"].contains(leg.mode) ? MTRJourneySections.stopName(clean) : clean
    }

    private func stopHeading(_ name: String, time: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(stopName(name)).font(.headline)
            if let date = JourneyTime.parse(time) {
                Text(JourneyTime.clock(date)).font(.caption).monospacedDigit()
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
    }
}

private struct TimelineStop: Identifiable {
    let id: Int // Position in this immutable leg preserves repeated stop names on loop routes.
    let name: String
}
private struct TimelineItem<Value>: Identifiable {
    let id: Int
    let value: Value
}
private func timelineItems<Value>(_ values: [Value]) -> [TimelineItem<Value>] {
    values.enumerated().map { TimelineItem(id: $0.offset, value: $0.element) }
}

private struct TimelineRow<Content: View>: View {
    let color: Color
    var first = false
    var last = false
    var endpoint = false
    var station = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Color.clear.frame(width: 24)
            content().padding(.vertical, 6)
        }
        .background(alignment: .leading) {
            GeometryReader { geometry in
                Path { path in
                    path.move(to: CGPoint(x: 12, y: first ? 28 : 0))
                    path.addLine(to: CGPoint(x: 12, y: last ? 28 : geometry.size.height))
                }.stroke(color, lineWidth: 4)
            }.allowsHitTesting(false).accessibilityHidden(true)
        }
        .overlay(alignment: .topLeading) {
            if endpoint || station {
                Circle().fill(.background)
                    .overlay { Circle().stroke(color, lineWidth: endpoint ? 3 : 2) }
                    .frame(width: endpoint ? 20 : 10, height: endpoint ? 20 : 10)
                    .frame(width: 24, height: 20)
                    .padding(.top, 18)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
}
