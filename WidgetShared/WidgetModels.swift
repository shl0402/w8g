import Foundation

enum JourneyWidgetSize: String, Codable, CaseIterable, Identifiable {
	case small, medium, large
	var id: String { rawValue }
	var title: String { switch self { case .small: "Small square"; case .medium: "Rectangle"; case .large: "Large square" } }
	var columns: Int { self == .small ? 1 : 2 }
	var rows: Int { self == .large ? 2 : 1 }
	var capacity: Int { columns * rows }
}

enum WidgetBlockSize: String, Codable, CaseIterable, Identifiable {
	case compact, wide, expanded
	var id: String { rawValue }
	var title: String { switch self { case .compact: "Compact · 1 space"; case .wide: "Wide · 2 spaces"; case .expanded: "Large · 4 spaces" } }
	var columns: Int { self == .compact ? 1 : 2 }
	var rows: Int { self == .expanded ? 2 : 1 }
	var area: Int { columns * rows }
}

struct WidgetArrivalConfiguration: Codable, Equatable {
	var provider: ArrivalProvider = .mtr
	var route = "ISL"
	var stop: ArrivalStop? = MTRStations.stops("ISL").first { $0.id == "HKU" }
	var direction = "UP"
	// nil preserves existing designs: show all destinations in the selected direction.
	var destinationCode: String?
	var destinationName: String? { destinationCode.map { MTRStations.name($0) } }
	static func destinations(line: String, direction: String) -> [String] {
		// MTR Next Train Data Dictionary v1.7, pp. 8–9. Live responses may add short workings.
		let terminals: [String: [String]] = [
			"AEL:UP": ["AIR", "AWE"], "AEL:DOWN": ["HOK"],
			"TCL:UP": ["TUC"], "TCL:DOWN": ["HOK"],
			"TML:UP": ["TUM"], "TML:DOWN": ["WKS"],
			"TKL:UP": ["POA", "LHP"], "TKL:DOWN": ["TIK", "NOP"],
			"EAL:UP": ["LMC", "LOW", "SHS", "TAP", "RAC", "FOT", "SHT"],
			"EAL:DOWN": ["ADM", "HUH", "MKK"],
			"SIL:UP": ["SOH"], "SIL:DOWN": ["ADM"],
			"TWL:UP": ["TSW"], "TWL:DOWN": ["CEN"],
			"ISL:UP": ["CHW"], "ISL:DOWN": ["KET"],
			"KTL:UP": ["TIK"], "KTL:DOWN": ["WHA"],
			"DRL:UP": ["SUN"], "DRL:DOWN": ["DIS"]
		]
		return terminals[line + ":" + direction] ?? []
	}
	var isValid: Bool {
		guard let stop else { return false }
		if provider == .mtr {
			return MTRStations.stops(route).contains { $0.id == stop.id }
				&& ["UP", "DOWN"].contains(direction)
				&& (destinationCode == nil || MTRStations.stops(route).contains { $0.id == destinationCode })
		}
		return route.range(of: "^[A-Z0-9]{1,8}$", options: .regularExpression) != nil
			&& ["O", "I"].contains(stop.direction) && stop.sequence > 0
			&& !stop.id.isEmpty && (provider != .kmb || !stop.service.isEmpty)
	}
	var title: String { stop?.name ?? "Choose boarding stop" }
	var subtitle: String { provider == .mtr ? MTRLineStyle.line(named: route)?.name ?? route : provider.rawValue + " · " + route }
}

// Only the explicitly chosen route's presentation is shared with the extension, never login/API keys.
struct WidgetRouteSnapshot: Codable, Equatable {
	struct Segment: Codable, Identifiable, Equatable {
		var id = UUID()
		var label: String
		var symbol: String
		var hex: String
	}
	var savedID: String
	var title: String
	var minutes: Int
	var departure: Date?
	var arrival: Date?
	var segments: [Segment]
	var transfers: Int?
	var walkMeters: Double?
	var mapImageName: String?
	var showMap: Bool?
}

struct JourneyWidgetBlock: Codable, Identifiable, Equatable {
	enum Kind: String, Codable { case arrivals, route }
	var id = UUID()
	var kind: Kind
	var size: WidgetBlockSize = .compact
	var arrival: WidgetArrivalConfiguration?
	var route: WidgetRouteSnapshot?
	var title: String { kind == .arrivals ? arrival?.title ?? "Next arrivals" : route?.title ?? "Saved route" }
	var isConfigured: Bool { kind == .arrivals ? arrival?.isValid == true : route != nil }
}

struct JourneyWidgetDesign: Codable, Identifiable, Equatable {
	var id = UUID()
	var name = "My widget"
	var size: JourneyWidgetSize = .medium
	var blocks: [JourneyWidgetBlock] = []
	var usedSpaces: Int { blocks.reduce(0) { $0 + $1.size.area } }
	var isValid: Bool {
		!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
			&& !blocks.isEmpty && blocks.allSatisfy(\.isConfigured)
			&& WidgetGrid.placements(for: self) != nil
	}
	func canFit(_ block: JourneyWidgetBlock, replacing id: UUID? = nil) -> Bool {
		var candidate = self
		if let id, let index = candidate.blocks.firstIndex(where: { $0.id == id }) {
			candidate.blocks[index] = block
		} else { candidate.blocks.append(block) }
		return WidgetGrid.placements(for: candidate) != nil
	}
}

struct WidgetPlacement: Identifiable, Equatable {
	var id: UUID
	var column: Int
	var row: Int
	var columns: Int
	var rows: Int
}

enum WidgetGrid {
	// First-fit placement follows the user's block order. Never crop or silently drop a block.
	static func placements(for design: JourneyWidgetDesign) -> [WidgetPlacement]? {
		var occupied = Set<Int>()
		var result: [WidgetPlacement] = []
		for block in design.blocks {
			let width = block.size.columns, height = block.size.rows
			guard width <= design.size.columns, height <= design.size.rows else { return nil }
			var found: WidgetPlacement?
			for row in 0...(design.size.rows - height) {
				for column in 0...(design.size.columns - width) where found == nil {
					let cells = (row..<(row + height)).flatMap { r in
						(column..<(column + width)).map { r * design.size.columns + $0 }
					}
					if cells.allSatisfy({ !occupied.contains($0) }) {
						occupied.formUnion(cells)
						found = WidgetPlacement(id: block.id, column: column, row: row, columns: width, rows: height)
					}
				}
				if found != nil { break }
			}
			guard let found else { return nil }
			result.append(found)
		}
		return result
	}
}

struct WidgetArrivalSnapshot: Codable, Equatable {
	struct Train: Codable, Equatable, Identifiable {
		var id: String { String(time.timeIntervalSince1970) + ":" + destination }
		var time: Date
		var destination: String
	}
	var trains: [Train] = []
	var updated: Date?
	var message = ""
	var refreshFailed: Bool?
	func upcoming(at date: Date) -> [Train] { Array(trains.filter { $0.time >= date }.prefix(4)) }
	func isStale(at date: Date) -> Bool { updated.map { date.timeIntervalSince($0) > 120 } ?? true }
}

// An unconfigured Lock Screen widget can use saved content immediately. Once the
// user selects a block explicitly, never silently replace it with another stop.
struct WidgetArrivalChoice: Identifiable {
	let designID: UUID
	let designName: String
	let block: JourneyWidgetBlock
	var id: String { designID.uuidString + "/" + block.id.uuidString }

	static func available(in designs: [JourneyWidgetDesign]) -> [Self] {
		designs.flatMap { design in
			design.blocks.filter { $0.kind == .arrivals && $0.isConfigured }.map {
				Self(designID: design.id, designName: design.name, block: $0)
			}
		}
	}
	static func resolve(selectedID: String?, in designs: [JourneyWidgetDesign]) -> Self? {
		let choices = available(in: designs)
		guard let selectedID else { return choices.first }
		return choices.first { $0.id == selectedID }
	}
}

// Keep countdowns moving if iOS postpones the next network refresh. The final
// entry removes every prediction, rather than freezing a future arrival forever.
enum WidgetTimelineDates {
	static func make(now: Date, snapshots: [WidgetArrivalSnapshot]) -> [Date] {
		let dates = (0...60).map { now.addingTimeInterval(Double($0) * 60) }
		let expiry = snapshots.flatMap(\.trains).map(\.time).max()?.addingTimeInterval(1) ?? now
		return dates + [max(now.addingTimeInterval(3660), expiry)]
	}
}
