import Foundation

// MTR's own journey-planner palette, checked 1 October 2026:
// https://www.mtr.com.hk/en/customer/css/common.css (.farec-rdetail-from-to .line*)
// Kept locally so saved journeys use the same colours without a server connection.
enum MTRLineStyle {
    struct Line {
        let name: String
        let hex: String
    }

    static let lines: [String: Line] = [
        "AEL": Line(name: "Airport Express", hex: "1C7670"),
        "TWL": Line(name: "Tsuen Wan Line", hex: "FF0000"),
        "KTL": Line(name: "Kwun Tong Line", hex: "1A9431"),
        "ISL": Line(name: "Island Line", hex: "0860A8"),
        "TCL": Line(name: "Tung Chung Line", hex: "FE7F1D"),
        "TKL": Line(name: "Tseung Kwan O Line", hex: "6B208B"),
        "DRL": Line(name: "Disneyland Resort Line", hex: "F550A6"),
        "EAL": Line(name: "East Rail Line", hex: "5EB6E4"),
        "SIL": Line(name: "South Island Line", hex: "B5BD00"),
        "TML": Line(name: "Tuen Ma Line", hex: "923011")
    ]

    static func line(named value: String) -> Line? {
        let first = value.components(separatedBy: "→").first ?? value
        let clean = first.trimmingCharacters(in: .whitespacesAndNewlines)
        if let line = lines[clean.uppercased()] { return line }
        return lines.values.first { $0.name.caseInsensitiveCompare(clean) == .orderedSame }
    }

    static func fullNames(_ text: String) -> String {
        lines.reduce(text) { result, entry in
            result.replacingOccurrences(
                of: "\\b" + entry.key + "(?:\\s+line)?\\b",
                with: entry.value.name, options: [.regularExpression, .caseInsensitive]
            )
        }
    }
}
