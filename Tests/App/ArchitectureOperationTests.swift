import XCTest
import CubicCore

actor TestGate {
    private var entered = false
    private var open = false
    private var entrance: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        entered = true
        let arrivals = entrance; entrance = []; arrivals.forEach { $0.resume() }
        if !open { await withCheckedContinuation { waiters.append($0) } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entrance.append($0) } }
    }
    func release() { open = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
}

actor FakeCalendarIO: CalendarBridgeIO {
    var events: [String: CalendarBridgeEvent] = [:]
    var writeCount = 0
    var removeCount = 0
    var failWrite = false
    var failAfterSave = false
    var writeGate: TestGate?
    func requestAccess() -> Bool { true }
    func catalog(discover: Bool) -> (authorized: Bool, calendars: [CalendarBridgeCalendar], sources: [CalendarBridgeSource]) {
        (true, [try! resolveCalendar("one"), try! resolveCalendar("two")], [])
    }
    func resolveCalendar(_ id: String) throws -> CalendarBridgeCalendar {
        .init(id: id, title: "Test", sourceID: "source", sourceName: "Local")
    }
    func createCalendar(sourceID: String) -> String { "one" }
    func read(calendarID: String, from: Date, to: Date, cachedIDs: [String]) -> [CalendarBridgeEvent] { Array(events.values) }
    func refetch(eventID: String, calendarID: String) throws -> CalendarBridgeEvent {
        guard let e = events[eventID] else { throw Failure.injected }
        return e
    }
    func write(block: WorkTimeBlock, calendarID: String, existing: CalendarBridgeEvent?, title: String) async throws -> CalendarBridgeEvent {
        writeCount += 1
        if let writeGate { await writeGate.hold() }
        if failWrite { failWrite = false; throw Failure.injected }
        let event = CalendarBridgeEvent(id: existing?.id ?? UUID().uuidString, title: title,
            start: block.start, end: block.end, allDay: false, blockID: block.id, busy: true, recurring: false)
        events[event.id] = event
        if failAfterSave { failAfterSave = false; throw Failure.injected }
        return event
    }
    func remove(eventID: String, calendarID: String, expectedBlockID: String) throws {
        guard events[eventID]?.blockID == expectedBlockID else { throw Failure.injected }
        events[eventID] = nil; removeCount += 1
    }
    func seed(_ event: CalendarBridgeEvent) { events[event.id] = event }
    func suspendWrite(_ gate: TestGate) { writeGate = gate }
    func setFailure(afterSave: Bool = false) { if afterSave { failAfterSave = true } else { failWrite = true } }
    func counts() -> (writes: Int, removes: Int, events: Int) { (writeCount, removeCount, events.count) }
    func allEvents() -> [CalendarBridgeEvent] { Array(events.values) }
    enum Failure: Error { case injected }
}

@MainActor final class CalendarTestState {
    var workspace: Workspace
    var storageReady = true
    var version = 0
    let slots: [CapacitySlot]
    init(workspace: Workspace, now: Date) {
        self.workspace = workspace
        slots = [.init(start: now, end: now.addingTimeInterval(5 * 3600), energy: .normal)]
    }
    func context() -> CalendarBridgeContext {
        .init(workspace: workspace, slots: slots, externalBusy: [], storageReady: storageReady, sourceRevision: String(version))
    }
}

@MainActor final class ConfirmationTestState {
    var current: SyncMergeResult
    var latest: PlanningTrialResult
    var commits = 0
    var active = true
    init(current: SyncMergeResult, latest: PlanningTrialResult) { self.current = current; self.latest = latest }
}

@MainActor final class ArchitectureOperationTests: XCTestCase {
    let now = Date()
    var base: Workspace { Workspace(items: [WorkItem(id: "a", name: "A", remainingMinutes: 60)]) }
    func journal() throws -> SyncJournal {
        try SyncJournal(directory: FileManager.default.temporaryDirectory.appendingPathComponent("architecture-\(UUID())"), workspaceID: "test", deviceID: "device")
    }

    func testSessionOperations() async throws {
        let now = self.now
        let j = try journal(), directory = await j.directory; defer { try? FileManager.default.removeItem(at: directory) }
        let projection = try await j.bootstrap(workspace: base)
        let session = WorkspaceSession(journal: j, cacheProjection: { _ in throw FakeCalendarIO.Failure.injected })
        var edit = base; edit.items[0].name = "Changed"
        let token = WorkspaceWriteToken(sessionID: session.id, heads: projection.heads)
        let saved = try await session.submit(edit, basedOn: token, now: now)
        guard case .committed(let result, let cacheIssue) = saved else { return XCTFail("cache failure denied commit") }
        XCTAssertTrue(result.workspace.items[0].name == "Changed" && cacheIssue != nil, "cache failure preserves fact")
        do { _ = try await session.submit(base, basedOn: token); XCTFail("stale heads accepted") } catch is CoreError {}
        let other = WorkspaceSession(journal: j, cacheProjection: { _ in })
        do { _ = try await other.submit(base, basedOn: token); XCTFail("foreign session accepted") } catch is CoreError {}
        // Cache suspension is a real actor reentrancy boundary, not a sleep-based race.
        let gate = TestGate(), serial = WorkspaceSession(journal: j, cacheProjection: { _ in await gate.hold() })
        let current = try await j.snapshot()
        var candidate = current.planningWorkspace; candidate.items[0].name = "Serialized"
        let submission = Task { try await serial.submit(candidate, basedOn: .init(sessionID: serial.id, heads: current.heads)) }
        await gate.waitUntilEntered()
        do { _ = try await serial.submit(candidate, basedOn: .init(sessionID: serial.id, heads: current.heads)); XCTFail("parallel cache submit accepted") } catch is CoreError {}
        await gate.release(); _ = try await submission.value
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertTrue(files.filter { $0.pathExtension == "revision" }.count == 3, "no duplicate operation")
    }

    func testConfirmationOperations() async throws {
        let now = self.now
        let j = try journal(), directory = await j.directory; defer { try? FileManager.default.removeItem(at: directory) }
        let current = try await j.bootstrap(workspace: base)
        let session = WorkspaceSession(journal: j, cacheProjection: { _ in })
        let input = PlanningInput(slots: [.init(start: now, end: now.addingTimeInterval(7200), energy: .normal)], now: now)
        let request = PlanningTrialRequest(itemID: "a", minutes: 30)
        let displayed = try Engine.trial(workspace: base, request: request, input: input)
        let state = ConfirmationTestState(current: current, latest: displayed)
        let operation = PlanningChoiceConfirmation(calculate: { _ in state.latest }, sourceIsCurrent: { _ in state.active }, commit: { result, note in
            state.commits += 1
            var candidate = state.current.planningWorkspace
            let scenario = result.scenario ?? result.baseline
            let trial = TrialResult(selections: [.init(itemID: "a", minutes: 30)], allocations: result.allocations, unallocatedMinutes: result.unallocatedMinutes ?? 0, snapshot: scenario.legacy, planning: result)
            try candidate.chooseNextAction(itemID: "a", now: now, trial: trial, dataVersion: "test", impactWasVerified: true, note: note)
            candidate.history.append(HistoryEvent(date: now, kind: .choiceRecorded, objectID: candidate.currentChoiceID!, detail: String(decoding: try SyncCoding.encode(result), as: UTF8.self)))
            let outcome = try await session.submit(candidate, basedOn: .init(sessionID: session.id, heads: state.current.heads))
            if case .committed(let projection, _) = outcome { state.current = projection }
            return outcome
        }, recover: { receipt in try await session.recover(receipt) })
        // Different displayed minutes must redisplay the production operation without saving.
        state.latest = try Engine.trial(workspace: base, request: request, input: PlanningInput(slots: input.slots, now: now.addingTimeInterval(120)))
        let presentation = UUID()
        guard case .redisplay = await operation.confirm(presentationID: presentation, displayed: displayed, request: request, note: "", isCurrent: { true }) else { return XCTFail("changed effect not redisplayed") }
        XCTAssertTrue(state.commits == 0, "redisplay has no choice")
        let refreshed = state.latest
        let confirmed = await operation.confirm(presentationID: presentation, displayed: refreshed, request: request, note: "reason", isCurrent: { true })
        guard case .confirmed = confirmed else { return XCTFail("complete confirmation failed") }
        XCTAssertTrue((state.current.workspace.choices ?? []).count == 1, "one choice through real journal")
        let evidence = state.current.workspace.history.first(where: { $0.detail != nil })!.detail!
        XCTAssertTrue(try SyncCoding.decode(PlanningTrialResult.self, from: Data(evidence.utf8)) == refreshed, "precise latest source preserved")
        _ = await operation.confirm(presentationID: presentation, displayed: refreshed, request: request, note: "repeat", isCurrent: { true })
        XCTAssertTrue(state.commits == 1, "completed presentation dedup")
        state.active = false
        _ = await operation.confirm(presentationID: UUID(), displayed: refreshed, request: request, note: "", isCurrent: { true })
        XCTAssertTrue(state.commits == 1, "stale source never saved")
        state.active = true
        _ = await operation.confirm(presentationID: UUID(), displayed: refreshed, request: request, note: "", isCurrent: { false })
        XCTAssertTrue(state.commits == 1, "departed presentation never saved")
        // Cancellation and duplicate requests while calculation is suspended.
        let gate = TestGate()
        let suspended = PlanningChoiceConfirmation(calculate: { _ in await gate.hold(); return displayed }, sourceIsCurrent: { _ in true }, commit: { _, _ in state.commits += 1; return .committed(state.current, cacheIssue: nil) }, recover: { _ in nil })
        let id = UUID(), task = Task { await suspended.confirm(presentationID: id, displayed: displayed, request: request, note: "", isCurrent: { true }) }
        await gate.waitUntilEntered()
        _ = await suspended.confirm(presentationID: id, displayed: displayed, request: request, note: "duplicate", isCurrent: { true })
        task.cancel(); await gate.release(); _ = await task.value
        XCTAssertTrue(state.commits == 1, "duplicate in-flight and pre-commit cancellation produce no choice")
        // A failed manifest settles the same receipt, never recalculates/reissues the choice.
        let manifest = directory.appendingPathComponent("manifest.json")
        try FileManager.default.removeItem(at: manifest); try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        let recoveryPresentation = UUID()
        guard case .recoveryRequired = await operation.confirm(presentationID: recoveryPresentation, displayed: state.latest, request: request, note: "recovery", isCurrent: { true }) else { return XCTFail("partial choice not classified") }
        XCTAssertTrue(state.commits == 2, "original choice submitted once")
        try FileManager.default.removeItem(at: manifest)
        guard case .confirmed = await operation.confirm(presentationID: recoveryPresentation, displayed: state.latest, request: request, note: "replay", isCurrent: { true }) else { return XCTFail("original choice not settled") }
        XCTAssertTrue(state.commits == 2, "recovery never replays commit closure")
        let condition1 = try await (j.snapshot().workspace.choices ?? []).count == 2
        XCTAssertTrue(condition1, "exactly two distinct choices")
    }

    func bridge(_ state: CalendarTestState, io: FakeCalendarIO, defaults: UserDefaults,
                       apply: (@MainActor (WorkTimeBlock, WorkTimeBlock?, String?) async throws -> Void)? = nil) -> CalendarBridge {
        let now = self.now
        return CalendarBridge(workspaceID: "test", defaults: defaults, context: { state.context() }, applyExternal: apply ?? { block, _, _ in
            try state.workspace.setTimeBlock(block, slots: state.slots, now: now); state.version += 1
        }, removeBlock: { id in state.workspace.timeBlocks?.removeAll { $0.id == id }; state.version += 1 },
        isContextCurrent: { $0 == String(state.version) }, eventStore: io)
    }

    func testBridgeOperations() async throws {
        let now = self.now
        let suite = "architecture-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = CalendarTestState(workspace: base, now: now), io = FakeCalendarIO()
        let b = bridge(state, io: io, defaults: defaults)
        try await b.bind(calendarID: "one")
        let block = WorkTimeBlock(id: "block", itemID: "a", start: now.addingTimeInterval(3600.123456), end: now.addingTimeInterval(5400.654321))
        state.workspace.timeBlocks = [block]; state.version += 1
        await b.refresh()
        let events = await io.allEvents()
        XCTAssertTrue(events.count == 1 && events[0].start == block.start && events[0].end == block.end, "Bridge preserves exact dates")
        await b.refresh();
        let condition2 = await io.counts().writes == 1
        XCTAssertTrue(condition2, "unchanged Bridge no extra SDK save")
        state.workspace.timeBlocks = []; state.version += 1
        await b.refresh();
        let condition3 = await io.counts().events == 0
        XCTAssertTrue(condition3, "removed domain block cleans owned event")
        state.workspace.timeBlocks = [block]; state.version += 1
        await io.setFailure(); await b.refresh()
        XCTAssertTrue(b.status.pendingCount == 1, "SDK failure remains pending")
        await b.refresh();
        let condition4 = await io.counts().events == 1
        XCTAssertTrue(condition4, "SDK failure retry has one event")
        state.workspace.timeBlocks = []; state.version += 1; await b.refresh()
        state.workspace.timeBlocks = [block]; state.version += 1
        await io.setFailure(afterSave: true); await b.refresh()
        await b.refresh();
        let condition5 = await io.counts().events == 1
        XCTAssertTrue(condition5, "saved marker rescanned after refetch failure")
        state.workspace.timeBlocks = []; state.version += 1; await b.refresh()
        let gate = TestGate(); await io.suspendWrite(gate)
        state.workspace.timeBlocks = [block]; state.version += 1
        let refreshing = Task { await b.refresh() }
        await gate.waitUntilEntered()
        state.workspace.timeBlocks = []; state.version += 1
        await gate.release(); await refreshing.value
        await b.refresh();
        let condition6 = await io.counts().events == 0
        XCTAssertTrue(condition6, "same-binding late write keeps cleanup receipt")
        // Association + real journal manifest failure: retain original Event, pause writes, recover and mark it.
        let j = try journal(), directory = await j.directory; defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await j.bootstrap(workspace: base)
        let state2 = CalendarTestState(workspace: base, now: now), io2 = FakeCalendarIO()
        let original = CalendarBridgeEvent(id: "original", title: "External", start: block.start, end: block.end, allDay: false, blockID: nil, busy: true, recurring: false)
        await io2.seed(original)
        var receipt: SyncLocalCommitReceipt?
        let b2 = bridge(state2, io: io2, defaults: defaults, apply: { block, _, _ in
            var candidate = state2.workspace
            try candidate.setTimeBlock(block, slots: state2.slots, now: now)
            do { _ = try await j.record(workspace: candidate, currentChoiceID: nil) }
            catch let failure as SyncLocalCommitFailure { receipt = failure.receipt; state2.storageReady = false; throw failure }
        })
        try await b2.bind(calendarID: "one")
        let manifest = directory.appendingPathComponent("manifest.json")
        try FileManager.default.removeItem(at: manifest); try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        do { try await b2.associate(eventID: "original", itemID: "a"); XCTFail("partial association hidden") } catch is SyncLocalCommitFailure { }
        await b2.refresh();
        let condition7 = await io2.counts().writes == 0
        XCTAssertTrue(condition7, "unresolved association cannot reconcile")
        try FileManager.default.removeItem(at: manifest)
        guard case .committed(let recovered) = try await j.recoverLocalCommit(receipt!) else { return XCTFail("association recovery failed") }
        state2.workspace = recovered.planningWorkspace; state2.storageReady = true; state2.version += 1
        await b2.refresh()
        let associated = await io2.allEvents()
        XCTAssertTrue(associated.count == 1 && associated[0].id == "original" && associated[0].blockID != nil, "recovered association updates original Event")
        // Invalidation is terminal, including a write already issued to the SDK.
        let gate3 = TestGate(), io3 = FakeCalendarIO(), state3 = CalendarTestState(workspace: base, now: now)
        let b3 = bridge(state3, io: io3, defaults: defaults)
        try await b3.bind(calendarID: "two")
        await io3.suspendWrite(gate3); state3.workspace.timeBlocks = [block]; state3.version += 1
        let late = Task { await b3.refresh() }; await gate3.waitUntilEntered(); b3.invalidate()
        await gate3.release(); await late.value
        await b3.refresh(); let counts3 = await io3.counts(); XCTAssertTrue(counts3.writes == 1 && counts3.removes == 0, "invalidated bridge issues no further I/O or cross-binding cleanup")
    }
}
