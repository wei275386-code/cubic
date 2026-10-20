import XCTest
import CubicCore

private actor AdapterGate {
    private var entered = false
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        entered = true
        if !open { await withCheckedContinuation { waiters.append($0) } }
    }
    func waitUntilEntered() async throws {
        for _ in 0..<1000 {
            if entered { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw GateFailure.notReached
    }
    private enum GateFailure: Error { case notReached }
    func release() { open = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
}

private actor AdapterCalendarIO: CalendarBridgeIO {
    var events: [String: CalendarBridgeEvent] = [:]
    var writes = 0
    var removes = 0
    func requestAccess() -> Bool { true }
    func catalog(discover: Bool) -> (authorized: Bool, calendars: [CalendarBridgeCalendar], sources: [CalendarBridgeSource]) {
        (true, [resolveCalendar("one")], [])
    }
    func resolveCalendar(_ id: String) -> CalendarBridgeCalendar { .init(id: id, title: "Test", sourceID: "local", sourceName: "Local") }
    func createCalendar(sourceID: String) -> String { "one" }
    func read(calendarID: String, from: Date, to: Date, cachedIDs: [String]) -> [CalendarBridgeEvent] { Array(events.values) }
    func refetch(eventID: String, calendarID: String) throws -> CalendarBridgeEvent { try XCTUnwrap(events[eventID]) }
    func write(block: WorkTimeBlock, calendarID: String, existing: CalendarBridgeEvent?, title: String) -> CalendarBridgeEvent {
        writes += 1
        let event = CalendarBridgeEvent(id: existing?.id ?? UUID().uuidString, title: title, start: block.start, end: block.end,
            allDay: false, blockID: block.id, busy: true, recurring: false)
        events[event.id] = event; return event
    }
    func remove(eventID: String, calendarID: String, expectedBlockID: String) throws {
        XCTAssertEqual(events[eventID]?.blockID, expectedBlockID); events[eventID] = nil; removes += 1
    }
    func seed(_ event: CalendarBridgeEvent) { events[event.id] = event }
    func values() -> [CalendarBridgeEvent] { Array(events.values) }
    func counts() -> (Int, Int) { (writes, removes) }
}

@MainActor final class AppModelArchitectureTests: XCTestCase {
    private var base: Workspace { Workspace(items: [WorkItem(id: "a", name: "A", remainingMinutes: 60), WorkItem(id: "b", name: "B", remainingMinutes: 60)]) }
    private func fixture() throws -> (URL, UserDefaults, SyncJournal) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CubicAppAdapter-\(UUID())")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: directory.lastPathComponent))
        defaults.set("adapter-local", forKey: "cubic.sync.deviceID")
        return (directory, defaults, try SyncJournal(directory: directory.appendingPathComponent("journal"), workspaceID: "cubic.primary", deviceID: "adapter-local"))
    }
    private func clean(_ directory: URL, _ defaults: UserDefaults) {
        defaults.removePersistentDomain(forName: directory.lastPathComponent)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    }

    func testRemoteIngestDuringCacheSavePublishesCurrentCanonicalAndBlocksSwitch() async throws {
        let (dir, defaults, journal) = try fixture(); defer { clean(dir, defaults) }
        let initial = try await journal.bootstrap(workspace: base), gate = AdapterGate()
        let model = try await AppModel(testDirectory: dir, journal: journal, projection: initial, defaults: defaults,
                                      beforeCacheSave: { _ in await gate.hold() })
        let save = Task { await model.mutate { $0.items[0].description = "local detail" } }
        try await gate.waitUntilEntered()
        let switchedWhileSaving = await model.prepareSync(accountID: "partition-B", importLocal: false, transportKind: "local")
        XCTAssertFalse(switchedWhileSaving)
        var remote = base; remote.items[0].name = "remote title"
        let revision = try SyncRevision.recording(workspace: remote, comparedTo: base, id: "remote", workspaceID: "cubic.primary",
            deviceID: "adapter-remote", parents: initial.heads)
        try await journal.ingest([revision], cursor: nil)
        await gate.release()
        let saved = await save.value; XCTAssertTrue(saved)
        let canonical = try await journal.snapshot()
        XCTAssertEqual(model.workspace, canonical.planningWorkspace)
        XCTAssertEqual(model.workspace.items[0].name, "remote title")
        XCTAssertEqual(model.workspace.items[0].description, "local detail")
        let cache = try SQLiteWorkspaceRepository(url: dir.appendingPathComponent("workspace.sqlite"))
        XCTAssertEqual(try cache.load(), canonical.planningWorkspace)
        let oldController = try XCTUnwrap(model.cloudSync)
        let switched = await model.prepareSync(accountID: "partition-B", importLocal: false, transportKind: "local")
        XCTAssertTrue(switched); XCTAssertEqual(model.workspace, .empty)
        await oldController.refresh()
        XCTAssertEqual(model.workspace, .empty, "Retired controller must not publish into the new partition")
    }

    func testReadinessCancellationAndDepartedHostNeverApplyDraft() async throws {
        let (dir, defaults, journal) = try fixture(); defer { clean(dir, defaults) }
        let initial = try await journal.bootstrap(workspace: base), gate = AdapterGate()
        let model = try await AppModel(testDirectory: dir, journal: journal, projection: initial, defaults: defaults,
                                      beforeCacheSave: { _ in await gate.hold() })
        let host = UUID(); model.enterMessagePage(host)
        let first = Task { await model.mutate { $0.items[0].name = "first" } }
        try await gate.waitUntilEntered()
        var calls = 0, cancelledStarted = false, departedStarted = false
        let cancelled = Task { cancelledStarted = true; return await model.mutateWhenReady { calls += 1; $0.items[0].name = "cancelled" } }
        let departed = Task { departedStarted = true; return await model.mutateWhenReady { calls += 1; $0.items[0].name = "departed" } }
        // Each task registers its readiness wait before it yields MainActor back to this test.
        while !cancelledStarted || !departedStarted { await Task.yield() }
        cancelled.cancel(); model.leaveMessagePage(host)
        await gate.release()
        let a = await first.value, b = await cancelled.value, c = await departed.value
        XCTAssertTrue(a); XCTAssertFalse(b); XCTAssertFalse(c); XCTAssertEqual(calls, 0)
        XCTAssertEqual(model.workspace.items[0].name, "first")
        let revisions = try await journal.exportArchive().revisions
        XCTAssertEqual(revisions.count, 2)
    }

    func testRealConfirmationKeepsPreciseEvidenceAndRecoversOriginalChoiceOnReopen() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CubicChoiceAdapter-\(UUID())")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: dir.lastPathComponent)); defer { clean(dir, defaults) }
        let directory = dir.appendingPathComponent("journal")
        let (choiceID, detail, heads) = try await saveChoices(directory: directory, dir: dir, defaults: defaults)
        for _ in 0..<10 { await Task.yield() } // Drain queued publication tasks before reacquiring the writer lease.
        // Reopening the actual journal proves durable identity/evidence, independent of observable state.
        let reopened = try SyncJournal(directory: directory, workspaceID: "cubic.primary", deviceID: "adapter-local")
        let projection = try await reopened.snapshot()
        XCTAssertEqual(projection.heads, heads)
        XCTAssertEqual(projection.workspace.choices?.count, 2)
        XCTAssertEqual(projection.workspace.currentChoiceID, choiceID)
        XCTAssertTrue(projection.workspace.history.contains { $0.objectID == choiceID && $0.detail == detail })
    }

    private func saveChoices(directory: URL, dir: URL, defaults: UserDefaults) async throws -> (String, String, [String]) {
        let journal = try SyncJournal(directory: directory, workspaceID: "cubic.primary", deviceID: "adapter-local")
        let initial = try await journal.bootstrap(workspace: base)
        let model = try await AppModel(testDirectory: dir, journal: journal, projection: initial, defaults: defaults)
        let start = Date().addingTimeInterval(3600)
        let calculated = await model.planningTrial(itemID: "a", minutes: 30, start: start)
        var displayed = try XCTUnwrap(calculated)
        let presentation = UUID()
        var outcome = await model.confirmDisplayedTrial(presentationID: presentation, displayed: displayed, request: displayed.request, note: "first", isCurrent: { true })
        if case .redisplay(let latest) = outcome {
            displayed = latest
            outcome = await model.confirmDisplayedTrial(presentationID: presentation, displayed: displayed, request: displayed.request, note: "first", isCurrent: { true })
        }
        guard case .confirmed = outcome else { XCTFail("Actual adapter did not confirm"); throw AdapterFailure.unexpected }
        XCTAssertEqual(model.workspace.choices?.count, 1)
        let firstID = try XCTUnwrap(model.workspace.currentChoiceID)
        let firstDetail = try XCTUnwrap(model.workspace.history.first { $0.objectID == firstID && $0.detail != nil }?.detail)
        let precise = try SyncCoding.decode(PlanningTrialResult.self, from: Data(firstDetail.utf8))
        XCTAssertEqual(precise.request, displayed.request)
        XCTAssertEqual(precise.source.input.revision.workspace, displayed.source.input.revision.workspace)
        XCTAssertGreaterThanOrEqual(precise.source.input.now, displayed.source.input.now)
        XCTAssertEqual(precise.request.minutes, 30)
        let reproduced = try Engine.trial(workspace: base, request: precise.request, input: precise.source.input)
        XCTAssertEqual(precise, reproduced, "Saved latest evidence preserves full precision and the complete Engine result")
        _ = await model.confirmDisplayedTrial(presentationID: presentation, displayed: displayed, request: displayed.request, note: "duplicate", isCurrent: { true })
        XCTAssertEqual(model.workspace.choices?.count, 1)
        let manifest = directory.appendingPathComponent("manifest.json")
        try FileManager.default.removeItem(at: manifest); try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        let recalculated = await model.planningTrial(itemID: "a", minutes: 30, start: start)
        let next = try XCTUnwrap(recalculated), second = UUID()
        var pending = await model.confirmDisplayedTrial(presentationID: second, displayed: next, request: next.request, note: "original", isCurrent: { true })
        if case .redisplay(let latest) = pending {
            pending = await model.confirmDisplayedTrial(presentationID: second, displayed: latest, request: latest.request, note: "original", isCurrent: { true })
        }
        guard case .recoveryRequired = pending else { XCTFail("Partial choice lost receipt"); throw AdapterFailure.unexpected }
        XCTAssertEqual(model.workspace.choices?.count, 1)
        try FileManager.default.removeItem(at: manifest)
        let recovered = await model.confirmDisplayedTrial(presentationID: second, displayed: next, request: next.request, note: "do not replay", isCurrent: { true })
        guard case .confirmed = recovered else { XCTFail("Exact choice recovery failed"); throw AdapterFailure.unexpected }
        XCTAssertEqual(model.workspace.choices?.count, 2)
        let result = try await journal.snapshot(), id = try XCTUnwrap(result.workspace.currentChoiceID)
        let detail = try XCTUnwrap(result.workspace.history.first { $0.objectID == id && $0.detail != nil }?.detail)
        let evidence = try SyncCoding.decode(PlanningTrialResult.self, from: Data(detail.utf8))
        XCTAssertEqual(evidence.request.minutes, 30)
        XCTAssertTrue(result.workspace.choices?.contains { $0.id == id && $0.note == "original" } == true)
        await model.cloudSync?.retire()
        return (id, detail, result.heads)
    }

    func testCommittedInvalidCalendarAssociationRetainsOriginalEventUntilResolution() async throws {
        let (dir, defaults, journal) = try fixture(); defer { clean(dir, defaults) }
        let initial = try await journal.bootstrap(workspace: base), gate = AdapterGate(), io = AdapterCalendarIO()
        let model = try await AppModel(testDirectory: dir, journal: journal, projection: initial, defaults: defaults,
                                      beforeCacheSave: { _ in await gate.hold() })
        let start = Date().addingTimeInterval(3600), end = start.addingTimeInterval(1800)
        await io.seed(.init(id: "original", title: "External", start: start, end: end, allDay: false, blockID: nil, busy: true, recurring: false))
        model.ensureCalendarBridge(eventStore: io)
        let bridge = try XCTUnwrap(model.calendarBridge); try await bridge.bind(calendarID: "one")
        let association = Task {
            do { try await bridge.associate(eventID: "original", itemID: "a") }
            catch { print("ASSOCIATION RESULT: \(error)"); throw error }
        }
        try await gate.waitUntilEntered()
        // Both edits are individually legal. Their concurrently merged blocks overlap: a real cross-register invariant.
        var remote = base; remote.timeBlocks = [WorkTimeBlock(id: "remote-block", itemID: "b", start: start, end: end)]
        try remote.validate()
        let revision = try SyncRevision.recording(workspace: remote, comparedTo: base, id: "remote", workspaceID: "cubic.primary",
            deviceID: "adapter-remote", parents: initial.heads)
        try await journal.ingest([revision], cursor: nil)
        let invalid = try await journal.snapshot(); XCTAssertFalse(invalid.planningIsValid)
        await gate.release()
        do { try await association.value; XCTFail("Expected committed/unavailable projection result") }
        catch is WorkspaceCommittedProjectionUnavailable { }
        XCTAssertFalse(model.canVerifyPlanning)
        await bridge.refresh()
        let paused = await io.counts(); XCTAssertEqual(paused.0, 0); XCTAssertEqual(paused.1, 0)
        XCTAssertEqual(invalid.workspace.timeBlocks?.count, 2, "Durable association fact must remain")
        var remoteFixed = remote; remoteFixed.timeBlocks = []
        let repair = try SyncRevision.recording(workspace: remoteFixed, comparedTo: remote, id: "remote-fixed", workspaceID: "cubic.primary",
            deviceID: "adapter-remote", parents: [revision.id])
        try await journal.ingest([repair], cursor: nil)
        let resolved = try await journal.snapshot()
        XCTAssertTrue(resolved.planningIsValid)
        await model.publishCanonicalProjection(resolved)
        await bridge.refresh()
        let events = await io.values()
        XCTAssertEqual(events.count, 1); XCTAssertEqual(events.first?.id, "original")
        XCTAssertEqual(events.first?.blockID, resolved.workspace.timeBlocks?.first?.id)
        XCTAssertEqual(bridge.status.phase, .ready)
        let finalCounts = await io.counts(); XCTAssertEqual(finalCounts.0, 1); XCTAssertEqual(finalCounts.1, 0)
    }
    private enum AdapterFailure: Error { case unexpected }
}
