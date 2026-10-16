import Foundation

// A suggestion seeds controls; only the operator's validated stop IDs are used in requests.
struct ArrivalSelection {
	var provider: ArrivalProvider?
	var line = ""
	var station = ""
	var route = ""

	init(query: String = "", leg: JourneyLeg? = nil) {
		let text = query.lowercased()
		let operatorText =
			((leg?.route?.operatorIds ?? []).joined(separator: " ") + " "
			+ (leg?.route?.operatorName ?? "") + " " + query).lowercased()
		let isKMB =
			operatorText.contains("kmb") || operatorText.contains("lwb")
			|| operatorText.contains("kowloon motor") || operatorText.contains("long win")
		let isCitybus = operatorText.contains("citybus") || operatorText.contains("ctb")
		let lineName = leg?.lineName ?? ""
		if let code = MTRLineStyle.lines.keys.sorted().first(where: {
			$0 == lineName.uppercased()
				|| MTRLineStyle.lines[$0]!.name.caseInsensitiveCompare(lineName)
					== .orderedSame
		}), leg?.mode == "RAIL" || leg?.mode == "SUBWAY" {
			provider = .mtr
			line = code
		} else if isKMB != isCitybus {
			provider = isCitybus ? .citybus : .kmb
		} else if text.contains("mtr") || operatorText.contains("mtr") {
			provider = .mtr
		}
		if leg == nil {
			if let code = MTRLineStyle.lines.keys.sorted().first(where: {
				text.contains(MTRLineStyle.lines[$0]!.name.lowercased())
					|| text.range(
						of: "\\b" + $0.lowercased() + "\\b",
						options: .regularExpression) != nil
			}) {
				line = code
				provider = .mtr
			}
		}
		if provider == .mtr
			|| (provider == nil && leg == nil && !isKMB && !isCitybus && !text.contains("minibus")
				&& !text.contains("ferry") && !text.contains("tram"))
		{
			let stationText = (leg?.from.name ?? query).lowercased()
			let candidates = MTRStations.lines.keys.flatMap { MTRStations.stops($0) }.sorted {
				$0.name.count > $1.name.count
			}
			if let match = candidates.first(where: {
				stationText.range(
					of: "\\b"
						+ NSRegularExpression.escapedPattern(
							for: $0.name.lowercased()) + "\\b",
					options: .regularExpression) != nil
			}) {
				provider = .mtr
				let lines = MTRStations.lines.keys.filter {
					MTRStations.stops($0).contains { $0.id == match.id }
				}
				if line.isEmpty && lines.count == 1 { line = lines[0] }
				if MTRStations.stops(line).contains(where: { $0.id == match.id }) {
					station = match.id
				}
			}
		}
		if provider == .kmb || provider == .citybus || leg?.mode == "BUS" {
			let source = leg?.lineName ?? query
			if let range = source.range(
				of: "\\b[A-Za-z]{0,2}[0-9]{1,3}[A-Za-z]{0,2}\\b", options: .regularExpression)
			{
				route = String(source[range]).uppercased()
			}
		}
	}
}
