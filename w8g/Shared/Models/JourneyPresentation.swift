import Foundation

// Presentation only: keep the original names and route data unchanged for sharing/routing.
enum JourneyText {
	static func plain(_ value: String) -> String {
		var text = value
		for (entity, replacement) in [("&nbsp;", " "), ("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">") ] {
			text = text.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
		}
		text = text.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
		return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	static func stopName(_ value: String, operators: [String] = []) -> String {
		let variants = value.components(separatedBy: "|").filter { !plain($0).isEmpty }
		let preferred = variants.first { variant in
			operators.contains { variant.uppercased().hasPrefix("[" + $0.uppercased() + "]") }
		} ?? variants.first ?? value
		let withoutProvider = preferred.replacingOccurrences(
			of: "^\\s*\\[(?:(?:KMB|CTB|NWFB|NLB|LWB|GMB|MTR|LRT|LRTFeeder|DB|PI|TRAM|FERRY)(?:\\+|\\s)*)+\\]\\s*",
			with: "", options: [.regularExpression, .caseInsensitive]
		)
		// Joint-operation stop labels sometimes repeat the name on either side of a BR.
		let firstLine = withoutProvider.replacingOccurrences(
			of: "(?i)<br\\s*/?>|&lt;br\\s*/?&gt;", with: "|", options: .regularExpression
		).components(separatedBy: "|").first ?? withoutProvider
		let name = plain(firstLine).trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
		return name.isEmpty ? "Stop" : name
	}
}

extension Journey {
	var displayTitle: String { stops.map { JourneyText.stopName($0.name) }.joined(separator: " → ") }
	var waitingBeforeLeaving: Int {
		guard let requested = JourneyTime.parse(departure), let startDate else { return 0 }
		return max(0, Int((startDate.timeIntervalSince(requested) / 60).rounded()))
	}
}

// Same text envelope as the prototype. It includes only the chosen journey, never account data.
enum RouteShareCode {
	struct Envelope: Encodable {
		let version = 1
		let route: Journey
	}

	static func encode(_ journey: Journey) throws -> String {
		let data = try JSONEncoder().encode(Envelope(route: journey))
		guard data.count <= 1_000_000 else {
			throw ShareError.tooLarge
		}
		return "W8G1:" + data.base64EncodedString()
			.replacingOccurrences(of: "+", with: "-")
			.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: "=", with: "")
	}

	enum ShareError: LocalizedError {
		case tooLarge
		var errorDescription: String? { "This route is too large for a text share code (maximum 1 MB)." }
	}
}
