import Foundation

@main struct WidgetChecks {
	@MainActor static func main() async throws {
		func require(_ condition: @autoclosure () -> Bool, _ message: String) {
			precondition(condition(), message)
		}
		func arrival(_ size: WidgetBlockSize = .compact) -> JourneyWidgetBlock {
			.init(kind: .arrivals, size: size, arrival: .init())
		}
		let small = JourneyWidgetDesign(size: .small, blocks: [arrival()])
		require(small.isValid, "Small arrival fits")
		require(!small.canFit(arrival()), "Small cannot overfill")
		let rectangle = JourneyWidgetDesign(size: .medium, blocks: [arrival(), arrival()])
		require(rectangle.isValid, "Two compact blocks fit rectangle")
		require(!rectangle.canFit(arrival()), "Rectangle cannot overfill")
		let mixed = JourneyWidgetDesign(size: .large, blocks: [arrival(.wide), arrival(), arrival()])
		require(mixed.isValid, "Wide + two compact fit large")
		let placements = WidgetGrid.placements(for: mixed)!
		require(placements[0].row == 0 && placements[1].row == 1 && placements[2].column == 1, "Mixed positions")
		let reordered = JourneyWidgetDesign(size: .large, blocks: [arrival(), arrival(.wide), arrival()])
		require(reordered.isValid, "Packing finds remaining spaces on reorder")
		require(WidgetGrid.placements(for: JourneyWidgetDesign(size: .small, blocks: [arrival(.wide)])) == nil, "Cannot crop wide block")
		require(JourneyWidgetDesign(size: .large, blocks: [arrival(.expanded)]).isValid, "Expanded fits")
		require(!JourneyWidgetDesign(blocks: [.init(kind: .route)]).isValid, "Route must be configured")
		// Regression: a placed Lock Screen widget with no intent selection must not
		// remain on the setup placeholder when usable arrival blocks are saved.
		let defaultChoice = WidgetArrivalChoice.resolve(selectedID: nil, in: [small, rectangle])
		require(defaultChoice?.block.id == small.blocks[0].id, "Unconfigured widget loads first saved arrival")
		let chosenID = rectangle.id.uuidString + "/" + rectangle.blocks[1].id.uuidString
		require(WidgetArrivalChoice.resolve(selectedID: chosenID, in: [small, rectangle])?.block.id == rectangle.blocks[1].id, "Explicit arrival selection wins")
		require(WidgetArrivalChoice.resolve(selectedID: chosenID, in: [small]) == nil, "Deleted selection never changes station silently")
		require(WidgetArrivalChoice.resolve(selectedID: "bad-id", in: [small]) == nil, "Invalid selection is reported")
		require(WidgetArrivalChoice.resolve(selectedID: nil, in: []) == nil, "No designs remains unconfigured")
		var invalidConfig = WidgetArrivalConfiguration()
		invalidConfig.stop = nil
		let unavailable = JourneyWidgetDesign(blocks: [.init(kind: .route), .init(kind: .arrivals, arrival: invalidConfig)])
		require(WidgetArrivalChoice.available(in: [unavailable]).isEmpty, "Route and incomplete arrival blocks are skipped")
		require(WidgetArrivalChoice.resolve(selectedID: nil, in: [unavailable, small])?.block.id == small.blocks[0].id, "Default skips unusable blocks")
		let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
		defer { try? FileManager.default.removeItem(at: path) }
		try WidgetDesignStorage.save([small, rectangle, mixed], to: path)
		let loaded = try WidgetDesignStorage.load(from: path)
		require(loaded == [small, rectangle, mixed], "Layouts and IDs survive relaunch")
		require(WidgetArrivalChoice.resolve(selectedID: nil, in: loaded)?.id == defaultChoice?.id, "Default is stable across saved data reloads")
		let original = try Data(contentsOf: path)
		do {
			try WidgetDesignStorage.save([JourneyWidgetDesign()], to: path)
			preconditionFailure("Invalid design accepted")
		} catch { }
		let preserved = try Data(contentsOf: path)
		require(preserved == original, "Invalid saves preserve existing layouts")
		try WidgetDesignStorage.save([], to: path)
		let empty = try WidgetDesignStorage.load(from: path)
		require(empty.isEmpty, "Deletion persists")
		let now = Date()
		let result = ArrivalResult(rows: [
			.init(time: now.addingTimeInterval(180), destination: "Chai Wan", detail: "", direction: "UP"),
			.init(time: now.addingTimeInterval(60), destination: "Kennedy Town", detail: "", direction: "DOWN"),
			.init(time: now.addingTimeInterval(480), destination: "Chai Wan", detail: "", direction: "UP"),
			.init(time: nil, destination: "Chai Wan", detail: "", direction: "UP")
		], updated: now, message: "")
		let snapshot = WidgetArrivalLoader.snapshot(result, configuration: .init())
		require(snapshot.trains.count == 2, "No fake fourth arrival and no opposite direction")
		require(snapshot.upcoming(at: now.addingTimeInterval(200)).count == 1, "Expired prediction removed")
		require(!snapshot.isStale(at: now) && snapshot.isStale(at: now.addingTimeInterval(121)), "Age does not reset when countdown changes")
		let raw: [String: Any] = ["status": 1, "curr_time": "2026-10-15 08:00:00", "data": ["ISL-HKU": ["UP": [["time": "2026-10-15 08:03:00", "dest": "CHW", "plat": "1"]], "DOWN": [["time": "2026-10-15 08:02:00", "dest": "KET", "plat": "2"]]]]]
		let parsed = ArrivalService.mtrResult(raw, line: "ISL", station: "HKU")
		require(parsed.rows.map(\.direction) == ["UP", "DOWN"], "Parser retains direction")
		let failed = ArrivalService(request: { _ in throw APIError(message: "Offline") })
		let failedSnapshots = await WidgetArrivalLoader.load(small, service: failed)
		require(failedSnapshots.values.first?.trains.isEmpty == true, "Offline never fabricates arrivals")
		let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: cache) }
		let config = WidgetArrivalConfiguration()
		try WidgetArrivalCache.save(snapshot, for: config, at: now, directory: cache)
		let record = WidgetArrivalCache.load(config, directory: cache)!
		require(record.isRecent(at: now.addingTimeInterval(29)), "Recent fetch is shared across widget reloads")
		require(!record.isRecent(at: now.addingTimeInterval(31)), "Cache cannot stop later operator fetches")
		var opposite = config; opposite.direction = "DOWN"
		require(WidgetArrivalCache.load(opposite, directory: cache) == nil, "Opposite direction never uses same cache")
		let fallback = await WidgetArrivalLoader.load(small, service: failed, cacheDirectory: cache)
		require(fallback.values.first?.trains == snapshot.trains, "Network failure preserves last predictions")
		require(fallback.values.first?.updated == snapshot.updated, "Failure never advances source timestamp")
		require(fallback.values.first?.refreshFailed == true, "Failure is visible")
		let reused = await WidgetArrivalLoader.load(small, service: failed, preferRecentCache: true, cacheDirectory: cache)
		require(reused == fallback, "Timeline reuses manual refresh outcome including errors")
		let oldRoute = Data(#"{"savedID":"one","title":"HKU → Central","minutes":12,"segments":[]}"#.utf8)
		let legacy = try JSONDecoder().decode(WidgetRouteSnapshot.self, from: oldRoute)
		require(legacy.mapImageName == nil && legacy.transfers == nil, "Existing saved widget designs decode without map metadata")
		do { _ = try WidgetRouteImageStorage.url(named: "../private"); preconditionFailure("Unsafe path accepted") } catch { }
		let late = WidgetArrivalSnapshot(trains: [.init(time: now.addingTimeInterval(7200), destination: "Test")], updated: now)
		let dates = WidgetTimelineDates.make(now: now, snapshots: [late])
		require(dates.count == 62 && late.upcoming(at: dates.last!).isEmpty, "Delayed background refresh cannot leave an arrival frozen forever")
		var branch = WidgetArrivalConfiguration()
		branch.route = "TKL"
		branch.stop = MTRStations.stops("TKL").first { $0.id == "TIK" }
		let branchResult = ArrivalResult(rows: zip([3, 6, 9, 12], ["POA", "POA", "LHP", "POA"]).map { minutes, code in
			ArrivalRow(time: now.addingTimeInterval(Double(minutes) * 60), destination: MTRStations.name(code), detail: "", direction: "UP", destinationCode: code)
		}, updated: now, message: "")
		require(WidgetArrivalLoader.snapshot(branchResult, configuration: branch).trains.count == 4, "All destinations keeps four original trains")
		branch.destinationCode = "LHP"
		let lohas = WidgetArrivalLoader.snapshot(branchResult, configuration: branch)
		require(lohas.trains.count == 1 && lohas.trains[0].time == now.addingTimeInterval(540), "LOHAS filter shows only the nine-minute train")
		branch.destinationCode = "POA"
		let polam = WidgetArrivalLoader.snapshot(branchResult, configuration: branch)
		require(polam.trains.map(\.time) == [3,6,12].map { now.addingTimeInterval(Double($0) * 60) }, "Po Lam filter keeps 3, 6, 12 in order")
		branch.destinationCode = "NOP"
		require(WidgetArrivalLoader.snapshot(branchResult, configuration: branch).trains.isEmpty, "Absent destination never falls back to other trains")
		branch.destinationCode = "LHP"
		try WidgetArrivalCache.save(lohas, for: branch, directory: cache)
		branch.destinationCode = "POA"
		require(WidgetArrivalCache.load(branch, directory: cache) == nil, "Different destination cannot reuse cached arrivals")
		let legacyConfig = try JSONDecoder().decode(WidgetArrivalConfiguration.self, from: JSONEncoder().encode(config))
		require(legacyConfig.destinationCode == nil, "Existing widget config defaults to all destinations")
		require(parsed.rows.first?.destinationCode == "CHW", "Parser retains operator destination code")
		require(WidgetArrivalConfiguration.destinations(line: "TKL", direction: "UP").contains("LHP"), "Can select LOHAS even when no upcoming train is returned")
		print("Widget checks passed: capacity, packing, persistence, deletion, direction, stale and offline states")
	}
}
