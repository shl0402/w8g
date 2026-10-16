import Foundation
import CryptoKit

struct WidgetStorageError: LocalizedError {
	let message: String
	var errorDescription: String? { message }
}

enum WidgetDesignStorage {
	static let group = "group.pithon.w8g.widgets"
	struct Archive: Codable { var version = 1; var designs: [JourneyWidgetDesign] }
	static func file() throws -> URL {
		guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
			throw WidgetStorageError(message: "Widget sharing is unavailable. Enable the w8g App Group for both targets in Xcode Signing & Capabilities.")
		}
		return container.appendingPathComponent("widget-designs-v1.json")
	}
	static func load(from url: URL? = nil) throws -> [JourneyWidgetDesign] {
		let url = try url ?? file()
		guard FileManager.default.fileExists(atPath: url.path) else { return [] }
		let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url))
		guard archive.version == 1 else { throw WidgetStorageError(message: "Update w8g to open these widget designs.") }
		return archive.designs
	}
	static func save(_ designs: [JourneyWidgetDesign], to url: URL? = nil) throws {
		guard designs.allSatisfy(\.isValid), Set(designs.map(\.id)).count == designs.count else {
			throw WidgetStorageError(message: "Choose content for each block and make sure it fits.")
		}
		let url = try url ?? file()
		try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		let data = try JSONEncoder().encode(Archive(designs: designs))
		try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
	}
}

// Cache keys include operator, service, stop and direction. Never reuse another
// block's arrivals merely because it has the same route number or UUID.
enum WidgetArrivalCache {
	struct Record: Codable {
		var configuration: WidgetArrivalConfiguration
		var snapshot: WidgetArrivalSnapshot
		var fetched: Date
		func isRecent(at date: Date) -> Bool {
			(0..<30).contains(date.timeIntervalSince(fetched))
		}
	}
	static func file(for config: WidgetArrivalConfiguration, directory: URL? = nil) throws -> URL {
		let encoder = JSONEncoder()
		encoder.outputFormatting = .sortedKeys
		let name = SHA256.hash(data: try encoder.encode(config)).map { String(format: "%02x", $0) }.joined()
		let directory = try directory ?? WidgetDesignStorage.file().deletingLastPathComponent()
		return directory.appendingPathComponent("arrival-" + name + ".json")
	}
	static func load(_ config: WidgetArrivalConfiguration, directory: URL? = nil) -> Record? {
		guard let file = try? file(for: config, directory: directory),
			let data = try? Data(contentsOf: file),
			let record = try? JSONDecoder().decode(Record.self, from: data),
			record.configuration == config else { return nil }
		return record
	}
	static func save(_ snapshot: WidgetArrivalSnapshot, for config: WidgetArrivalConfiguration,
		at date: Date = Date(), directory: URL? = nil) throws {
		let file = try file(for: config, directory: directory)
		try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
		let data = try JSONEncoder().encode(Record(configuration: config, snapshot: snapshot, fetched: date))
		try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
	}
}

// The extension reads a bounded bitmap; it never starts a MapLibre renderer.
enum WidgetRouteImageStorage {
	static func url(named name: String) throws -> URL {
		guard name.count == 64, name.allSatisfy({ "0123456789abcdef".contains($0) }) else {
			throw WidgetStorageError(message: "Invalid route preview.")
		}
		return try WidgetDesignStorage.file().deletingLastPathComponent().appendingPathComponent("route-" + name + ".png")
	}
	static func save(_ data: Data) throws -> String {
		let name = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
		let file = try url(named: name)
		try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
		if !FileManager.default.fileExists(atPath: file.path) {
			try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
		}
		return name
	}
}
