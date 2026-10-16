import Foundation

@MainActor
enum WidgetArrivalLoader {
	static func load(_ design: JourneyWidgetDesign, service: ArrivalService? = nil, preferRecentCache: Bool = false, cacheDirectory: URL? = nil) async -> [UUID: WidgetArrivalSnapshot] {
		let service = service ?? ArrivalService()
		return await withTaskGroup(of: (UUID, WidgetArrivalSnapshot).self) { group in
			for block in design.blocks {
				guard block.kind == .arrivals, let config = block.arrival, config.isValid, let stop = config.stop else { continue }
				group.addTask { @MainActor in
					let cached = WidgetArrivalCache.load(config, directory: cacheDirectory)
					if preferRecentCache, let cached, cached.isRecent(at: Date()) { return (block.id, cached.snapshot) }
					do {
						try Task.checkCancellation()
						let result = try await service.fetch(provider: config.provider, route: config.route, stop: stop)
						try Task.checkCancellation()
						let value = snapshot(result, configuration: config)
						try? WidgetArrivalCache.save(value, for: config, directory: cacheDirectory)
						return (block.id, value)
					} catch {
						var value = cached?.snapshot ?? WidgetArrivalSnapshot()
						value.message = "Unable to update"
						value.refreshFailed = true
						if !Task.isCancelled { try? WidgetArrivalCache.save(value, for: config, directory: cacheDirectory) }
						return (block.id, value)
					}
				}
			}
			var snapshots: [UUID: WidgetArrivalSnapshot] = [:]
			for await (id, snapshot) in group { snapshots[id] = snapshot }
			return snapshots
		}
	}
	static func snapshot(_ result: ArrivalResult, configuration: WidgetArrivalConfiguration) -> WidgetArrivalSnapshot {
		let trains = result.rows.filter {
			configuration.provider != .mtr || ($0.direction == configuration.direction
				&& (configuration.destinationCode == nil || $0.destinationCode == configuration.destinationCode))
		}
			.compactMap { row -> WidgetArrivalSnapshot.Train? in
				guard let time = row.time else { return nil }
				return .init(time: time, destination: row.destination)
			}.sorted { $0.time < $1.time }
		return .init(trains: trains, updated: result.updated, message: result.message)
	}
}
