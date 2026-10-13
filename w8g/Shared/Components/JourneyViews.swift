//
//  JourneyViews.swift
//  w8g
//
//  Created by Samuel on 29/9/2026.
//

import Foundation
import SwiftUI

struct JourneyBadge: View {
    let leg: JourneyLeg
    var line: String? = nil
    var fullLineNames = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: TransitAppearance.symbol(leg))
            Text(leg.isWalking ? leg.minutes : displayLine)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .foregroundStyle(TransitAppearance.badgeText(leg, line: line))
        .background(
            TransitAppearance.badgeBackground(leg, line: line),
            in: RoundedRectangle(cornerRadius: 5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            (leg.isWalking ? "Walk" : TransitAppearance.name(leg)) + " "
                + (leg.isWalking ? leg.minutes + " minutes" : displayLine)
        )
    }

    private var displayLine: String {
        let text = line ?? leg.lineName
        return fullLineNames && ["SUBWAY", "RAIL"].contains(leg.mode) ? MTRLineStyle.fullNames(text) : text
    }
}

private struct JourneyWaitBadge: View {
    let seconds: Double

    private var minutes: String {
        seconds < 60
            ? "<1"
            : ceil(seconds / 60).formatted(
                .number.precision(.fractionLength(0))
            )
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "clock")
            Text(minutes)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .foregroundStyle(AppTheme.secondaryText)
        .background(
            AppTheme.ink.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Wait approximately " + minutes + " minutes")
    }
}

private struct JourneyToken: Identifiable {
    enum Content {
        case travel(JourneyLeg, String?)
        case wait(Double)
    }

    let id: String
    let content: Content
}

struct JourneyFlowView: View {
    let journey: Journey
    var fullLineNames = false

    private var tokens: [JourneyToken] {
        journey.displayLegs.enumerated().flatMap { index, leg in
            let prefix = "\(journey.id)-\(index)"
            var items: [JourneyToken] = []

            // Only show positive waiting times supplied by the server.
            if let seconds = leg.waitBeforeSeconds,
                seconds.isFinite,
                seconds > 0
            {
                items.append(
                    JourneyToken(
                        id: prefix + "-wait",
                        content: .wait(seconds)
                    )
                )
            }

            let names = leg.isWalking
                ? [""]
                : leg.lineName.components(separatedBy: "→")

            for (part, name) in names.enumerated() {
                let line = leg.isWalking
                    ? nil
                    : name.trimmingCharacters(in: .whitespaces)

                items.append(
                    JourneyToken(
                        id: prefix + "-\(part)",
                        content: .travel(leg, line)
                    )
                )
            }

            return items
        }
    }

    var body: some View {
        let items = tokens

        JourneyFlowLayout(spacing: 2) {
            ForEach(items) { token in
                // Keep the arrow with its following badge when wrapping.
                HStack(spacing: 2) {
                    if token.id != items.first?.id {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(AppTheme.secondaryText)
                            .accessibilityHidden(true)
                    }

                    switch token.content {
                    case .travel(let leg, let line):
                        JourneyBadge(leg: leg, line: line, fullLineNames: fullLineNames)

                    case .wait(let seconds):
                        JourneyWaitBadge(seconds: seconds)
                    }
                }
            }
        }
    }
}

// Wrap badges at the available width; no clipped transport names or nested horizontal scrolling.
private struct JourneyFlowLayout: Layout {
    let spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 300, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        let width = max(1, width)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var row: CGFloat = 0
        var points: [CGPoint] = []
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width {
                x = 0
                y += row + spacing
                row = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            row = max(row, size.height)
        }
        return (CGSize(width: width, height: y + row), points)
    }
}

struct RouteOptionCard: View {
    let journey: Journey
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 0) {
                    Text("\(journey.minutes)").font(.title2.bold()).monospacedDigit()
                    Text("min").font(.caption)
                }
                .frame(minWidth: 42)
                VStack(alignment: .leading, spacing: 8) {
                    Text(journey.timeRange).font(.subheadline.weight(.semibold)).monospacedDigit()
                    JourneyFlowView(journey: journey)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .background(
                selected ? AppTheme.ink.opacity(0.07) : AppTheme.background,
                in: RoundedRectangle(cornerRadius: 16)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16).strokeBorder(
                    selected ? AppTheme.ink : .clear, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens journey details and shows this route on the map")
    }
}

// These collections are immutable server responses. Prefix + original position remains stable
// for the lifetime of this journey, even if two consecutive stops share a name.
private struct JourneyDetailItem<Value>: Identifiable {
    let id: String
    let position: Int
    let value: Value
}

private func detailItems<Value>(_ values: [Value], prefix: String) -> [JourneyDetailItem<Value>] {
    values.enumerated().map {
        JourneyDetailItem(id: prefix + "-\($0.offset)", position: $0.offset, value: $0.element)
    }
}

struct RouteDetailView: View {
    // An editable draft is intentionally seeded once for this detail presentation.
    @State private var journey: Journey
    @State private var hasChanges = false
    private let onUpdate: (Journey) -> Void
    @Environment(\.dismiss) private var dismiss

    init(journey: Journey, onUpdate: @escaping (Journey) -> Void = { _ in }) {
        _journey = State(initialValue: journey)
        self.onUpdate = onUpdate
    }

    var body: some View {
        NavigationStack {
            Group {
                if journey.stops.count > 2 {
                    MultiStopJourneyDetail(journey: journey, hasChanges: hasChanges) { updated in
                        journey = updated
                        hasChanges = true
                        onUpdate(updated)
                    }
                } else {
                    RouteDetailContent(journey: journey)
                }
            }
            .navigationTitle(journey.stops.count > 2 ? "Journey trips" : "Journey details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(AppTheme.ink)
    }
}

struct RouteDetailContent: View {
    let journey: Journey
    var showsSave = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 12) {
                    Text(journey.displayTitle).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                    if showsSave { SaveJourneyButton(journey: journey) }
                }
                JourneyFlowView(journey: journey, fullLineNames: true)
                JourneyTimingView(journey: journey)
                Text("\(journey.transferCount) transfers · \(Int(journey.walkDistance ?? 0)) m walking")
                    .font(.subheadline).foregroundStyle(AppTheme.secondaryText)
                ForEach(detailItems(journey.displayLegs, prefix: journey.id)) { item in
                    VStack(alignment: .leading, spacing: 12) {
                        if item.position > 0,
                           journey.displayLegs[item.position - 1].transitLeg == true,
                           item.value.transitLeg == true {
                            Label("Change at " + MTRJourneySections.stopName(item.value.from.name),
                                  systemImage: "arrow.triangle.swap")
                                .font(.subheadline.weight(.semibold))
                        }
                        JourneyLegTimeline(leg: item.value)
                    }
                }
                Text("The map follows server route geometry; rail segments can be schematic.").font(
                    .caption
                ).foregroundStyle(AppTheme.secondaryText)
                if let source = journey.source {
                    Text(source).font(.caption).foregroundStyle(AppTheme.secondaryText)
                }
                JourneyTimetableFooter(journey: journey)
            }
            .padding(20)
        }
        .background(AppTheme.background)
        .foregroundStyle(AppTheme.ink)
    }
}
