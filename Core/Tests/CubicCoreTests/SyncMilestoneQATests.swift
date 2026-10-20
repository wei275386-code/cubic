import Foundation
import Testing
@testable import CubicCore

// Independent M3 business counterexamples. No CloudKit/Apple account is exercised.
private enum SyncQA {
    static let t = Date(timeIntervalSince1970: 1_800_000_000.123456)
    static func at(_ m: Int) -> Date { t.addingTimeInterval(Double(m) * 60) }
    static var base: Workspace {
        Workspace(items: [WorkItem(id: "a", name: "A", remainingMinutes: 60),
                          WorkItem(id: "b", name: "B", remainingMinutes: 30),
                          WorkItem(id: "free", name: "Independent", remainingMinutes: 15)])
    }
    static func revision(_ w: Workspace, old: Workspace? = nil, id: String = "root",
                         device: String = "local", parents: [String] = []) throws -> SyncRevision {
        try .recording(workspace: w, comparedTo: old, id: id, workspaceID: "qa",
                       deviceID: device, parents: parents, createdAt: t)
    }
    static func pair(_ base: Workspace, _ left: Workspace, _ right: Workspace) throws -> [SyncRevision] {
        [try revision(base), try revision(left, old: base, id: "left", parents: ["root"]),
         try revision(right, old: base, id: "right", device: "remote", parents: ["root"])]
    }
    static func merge(_ rs: [SyncRevision]) throws -> SyncMergeResult {
        try SyncMerge.merge(revisions: rs, workspaceID: "qa")
    }
    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CubicSyncM3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func journal(_ url: URL) throws -> SyncJournal {
        try SyncJournal(directory: url, workspaceID: "qa", deviceID: "local")
    }
    static func conflict(_ r: SyncMergeResult, _ collection: String, _ field: String = "@execution") throws -> SyncConflict {
        try #require(r.conflicts.first { $0.kind == .concurrentValue && $0.paths.contains { $0.collection == collection && $0.field == field } })
    }
    static func equalDirections(_ rs: [SyncRevision]) throws {
        let x = try merge(rs), y = try merge(rs.reversed())
        #expect(x.workspace == y.workspace)
        #expect(x.planningWorkspace == y.planningWorkspace)
        #expect(x.conflicts == y.conflicts)
        #expect(x.pausedItemIDs == y.pausedItemIDs)
        #expect(x.quarantinedRecordPaths == y.quarantinedRecordPaths)
        #expect(x.projectionReviewItemIDs == y.projectionReviewItemIDs)
    }
    static func seed(_ url: URL, rs: [SyncRevision]) async throws -> SyncJournal {
        let j = try journal(url)
        try await j.ingest(rs, cursor: nil, at: t)
        return j
    }
    static func cycle() throws -> [SyncRevision] {
        var l = base, r = base
        l.dependencies = [Dependency(id: "ab", source: .item("a"), targetItemID: "b")]
        r.dependencies = [Dependency(id: "ba", source: .item("b"), targetItemID: "a")]
        return try pair(base, l, r)
    }
    static func projectionRace() throws -> [SyncRevision] {
        var w = base
        try w.completeItem(id: "a", now: at(1))
        w.dependencies = [Dependency(id: "ab", source: .item("a"), targetItemID: "b")]
        var complete = w, reopen = w
        try complete.completeItem(id: "b", now: at(2))
        try reopen.reworkItem(id: "a", remainingMinutes: nil, now: at(2))
        return try pair(w, complete, reopen)
    }
}

private actor SyncQATransport: SyncTransport {
    var account = "account-A"
    var availabilityOverride: SyncAvailability?
    var pages: [SyncPullPage] = []
    var received: [String: SyncRevision] = [:]
    var pushes: [[String]] = []
    var cursors: [Data?] = []
    var partial = false
    var failPush = false
    var switchOnPull = false
    var switchOnPush = false
    func availability() async throws -> SyncAvailability { availabilityOverride ?? .available(accountID: account) }
    func pull(cursor: Data?) async throws -> SyncPullPage {
        cursors.append(cursor)
        if switchOnPull { account = "account-B"; switchOnPull = false }
        return pages.isEmpty ? SyncPullPage(revisions: Array(received.values), cursor: Data("steady".utf8), hasMore: false) : pages.removeFirst()
    }
    func push(_ revisions: [SyncRevision]) async throws -> Set<String> {
        pushes.append(revisions.map(\.id))
        if failPush { throw SyncError.transport("deterministic network failure") }
        let accepted = partial ? Array(revisions.prefix(1)) : revisions
        for r in accepted { received[r.id] = r }
        if switchOnPush { account = "account-B"; switchOnPush = false }
        return Set(accepted.map(\.id))
    }
    func pushFailureDescription() async -> String? { "deterministic partial ack" }
    func configure(pages: [SyncPullPage] = [], partial: Bool = false, failPush: Bool = false,
                   switchOnPull: Bool = false, switchOnPush: Bool = false, availability: SyncAvailability? = nil) {
        self.pages = pages; self.partial = partial; self.failPush = failPush
        self.switchOnPull = switchOnPull; self.switchOnPush = switchOnPush
        availabilityOverride = availability
    }
    func setAccount(_ value: String) { account = value }
    func pushed() -> [[String]] { pushes }
    func pulled() -> [Data?] { cursors }
    func remoteIDs() -> Set<String> { Set(received.keys) }
}

@Suite(.serialized) struct SyncMilestoneQATests {
    @Test func identityReplayCollisionMissingParentsAndWrongWorkspace() throws {
        let root = try SyncQA.revision(SyncQA.base)
        #expect(try SyncQA.merge([root, root]).heads == ["root"])
        var altered = SyncQA.base; altered.items[0].name = "collision"
        let collision = try SyncQA.revision(altered)
        #expect(throws: SyncError.identityCollision("root")) { try SyncQA.merge([root, collision]) }
        let child = try SyncQA.revision(altered, old: SyncQA.base, id: "child", parents: ["missing"])
        #expect(throws: SyncError.missingParent("missing")) { try SyncQA.merge([root, child]) }
        #expect(throws: SyncError.wrongWorkspace("qa")) { try SyncMerge.merge(revisions: [root], workspaceID: "other") }
        let selfParent = SyncRevision(id: "loop", workspaceID: "qa", deviceID: "local", parents: ["loop"], createdAt: SyncQA.t,
                                     immutableWorkspace: .empty, currentChoiceID: nil, changes: [])
        #expect(throws: (any Error).self) { try SyncQA.merge([selfParent]) }
        #expect(try SyncCoding.decode(SyncRevision.self, from: SyncCoding.encode(root)) == root)
    }

    @Test func differentTitlesMergeWithoutExecutionConflictAndSimilarIdentityStaysSeparate() throws {
        var l = SyncQA.base, r = SyncQA.base
        l.items[0].name = "device A title"; r.items[1].name = "device B title"
        l.items.append(WorkItem(id: "similar-1", name: "same name"))
        r.items.append(WorkItem(id: "similar-2", name: "same name"))
        let rs = try SyncQA.pair(SyncQA.base, l, r), result = try SyncQA.merge(rs)
        #expect(result.conflicts.isEmpty)
        #expect(result.workspace.items.first { $0.id == "a" }?.name == "device A title")
        #expect(result.workspace.items.first { $0.id == "b" }?.name == "device B title")
        #expect(result.workspace.items.filter { $0.name == "same name" }.count == 2)
        try SyncQA.equalDirections(rs)
        // Same object's divergent title remains metadata-only; no execution suspension.
        r = SyncQA.base; r.items[0].name = "another title"
        let disputed = try SyncQA.merge(SyncQA.pair(SyncQA.base, l, r))
        #expect(disputed.conflicts.contains { $0.paths.contains { $0.field == "name" } })
        #expect(disputed.pausedItemIDs.isEmpty)
    }

    @Test func remainingAndCompletedVersusReworkAreExplicitAndRetainHistory() throws {
        var l = SyncQA.base, r = SyncQA.base
        try l.updateRemaining(itemID: "a", minutes: 20, now: SyncQA.at(1), reason: .scopeChange)
        try r.updateRemaining(itemID: "a", minutes: 45, now: SyncQA.at(1), reason: .revision)
        let rs = try SyncQA.pair(SyncQA.base, l, r), merged = try SyncQA.merge(rs)
        let conflict = try SyncQA.conflict(merged, "items")
        #expect(Set(conflict.candidates.map(\.revisionID)) == ["left", "right"])
        #expect(merged.workspace.items.first { $0.id == "a" }?.remainingMinutes != 65)
        #expect(merged.workspace.history.count == l.history.count + r.history.count)
        #expect(merged.workspace.estimateRevisions?.count == 2)
        #expect(merged.pausedItemIDs == ["a"])
        try SyncQA.equalDirections(rs)
        var base = SyncQA.base
        try base.startItem(id: "a", now: SyncQA.at(1))
        l = base; r = base
        try l.completeItem(id: "a", now: SyncQA.at(2))
        try r.reworkItem(id: "a", remainingMinutes: nil, now: SyncQA.at(2))
        let race = try SyncQA.merge(SyncQA.pair(base, l, r))
        _ = try SyncQA.conflict(race, "items")
        #expect(race.workspace.history.contains { $0.kind == .completed })
        #expect(race.workspace.history.contains { $0.kind == .reworked })
        #expect(race.workspace.workRounds?.contains { $0.round == 2 } == true)
    }

    @Test func blockerReopenAndAcceptanceGateConflictsAreExplicit() throws {
        var base = SyncQA.base
        base.blockers = [Blocker(id: "wait", name: "Quote", state: .active, triggeredAt: SyncQA.t)]
        base.dependencies = [Dependency(id: "wb", source: .blocker("wait"), targetItemID: "b")]
        base.acceptances = [Acceptance(id: "gate", subject: .item("a"), name: "Manual")]
        try base.completeItem(id: "a", now: SyncQA.at(1))
        var l = base, r = base
        try l.resolveBlocker(id: "wait", now: SyncQA.at(2))
        r.blockers[0].round = 2; r.blockers[0].triggeredAt = SyncQA.at(2)
        l.acceptances[0].state = .accepted; l.acceptances[0].acceptedAt = SyncQA.at(2)
        r.acceptances[0].state = .failed; r.acceptances[0].failedAt = SyncQA.at(2)
        l.history.append(HistoryEvent(id: "gate-pass", date: SyncQA.at(2), kind: .accepted, objectID: "gate"))
        r.history.append(HistoryEvent(id: "gate-fail", date: SyncQA.at(2), kind: .acceptanceFailed, objectID: "gate"))
        let rs = try SyncQA.pair(base, l, r), result = try SyncQA.merge(rs)
        _ = try SyncQA.conflict(result, "blockers"); _ = try SyncQA.conflict(result, "acceptances")
        #expect(result.pausedItemIDs.contains("a")); #expect(result.pausedItemIDs.contains("b"))
        #expect(!result.pausedItemIDs.contains("free"))
        #expect(result.workspace.history.contains { $0.id == "gate-pass" })
        #expect(result.workspace.history.contains { $0.id == "gate-fail" })
        try SyncQA.equalDirections(rs)
    }

    @Test func nextActionConflictResolutionBothAPIsRetainsEveryChoice() async throws {
        var l = SyncQA.base, r = SyncQA.base
        try l.chooseNextAction(itemID: "a", now: SyncQA.at(1))
        try r.chooseNextAction(itemID: "b", now: SyncQA.at(1))
        let rs = try SyncQA.pair(SyncQA.base, l, r)
        try SyncQA.equalDirections(rs)
        for viaCoordinator in [false, true] {
            let url = try SyncQA.directory(); defer { try? FileManager.default.removeItem(at: url) }
            let j = try await SyncQA.seed(url, rs: rs), before = try await j.snapshot()
            #expect(before.currentChoiceID == nil); #expect(before.planningWorkspace.currentChoiceID == nil)
            #expect(before.workspace.choices?.count == 2)
            let c = try SyncQA.conflict(before, "@sync", "currentChoiceID")
            let resolved: SyncMergeResult
            if viaCoordinator { resolved = try await SyncCoordinator(journal: j, transport: SyncQATransport()).resolve(conflictID: c.id, choosingRevisionID: "right") }
            else { resolved = try await j.resolve(conflictID: c.id, choosingRevisionID: "right") }
            #expect(resolved.currentChoiceID == r.currentChoiceID)
            #expect(resolved.workspace.choices?.count == 2); #expect(resolved.workspace.history.count == 2)
            #expect(resolved.conflicts.isEmpty)
            #expect(await j.revision(id: "left") == rs[1])
            let resolution = try #require(await j.pending().last)
            #expect(resolution.parents == ["left", "right"]); #expect(resolution.changes.count == 1)
            #expect(resolved.workspace.items.allSatisfy { $0.status == .pending && $0.started == nil })
        }
    }

    @Test func registerResolutionIsLocalAndNewConcurrencyReturns() async throws {
        var l = SyncQA.base, r = SyncQA.base
        l.items[0].remainingMinutes = 20; r.items[0].remainingMinutes = 45
        l.items[1].remainingMinutes = 10; r.items[1].remainingMinutes = 25
        let rs = try SyncQA.pair(SyncQA.base, l, r)
        for viaCoordinator in [false, true] {
            let url = try SyncQA.directory(); defer { try? FileManager.default.removeItem(at: url) }
            let j = try await SyncQA.seed(url, rs: rs), before = try await j.snapshot()
            let c = try #require(before.conflicts.first { $0.paths.contains { $0.entityID == "a" } })
            let after: SyncMergeResult
            if viaCoordinator { after = try await SyncCoordinator(journal: j, transport: SyncQATransport()).resolve(conflictID: c.id, choosingRevisionID: "right") }
            else { after = try await j.resolve(conflictID: c.id, choosingRevisionID: "right") }
            #expect(after.workspace.items.first { $0.id == "a" }?.remainingMinutes == 45)
            #expect(after.conflicts.count == before.conflicts.count - 1)
            #expect(after.pausedItemIDs == ["b"])
            #expect(await j.revision(id: "left") == rs[1])
            var delayed = SyncQA.base; delayed.items[0].remainingMinutes = 7
            try await j.ingest([SyncQA.revision(delayed, old: SyncQA.base, id: "delayed", device: "late", parents: ["root"])], cursor: nil)
            #expect(try await j.snapshot().conflicts.contains { $0.paths.contains { $0.entityID == "a" } })
        }
    }

    @Test func cycleQuarantineUnrelatedEditAndExplicitRelationshipResolutionBothAPIs() async throws {
        let rs = try SyncQA.cycle(); try SyncQA.equalDirections(rs)
        for viaCoordinator in [false, true] {
            let url = try SyncQA.directory(); defer { try? FileManager.default.removeItem(at: url) }
            let j = try await SyncQA.seed(url, rs: rs), before = try await j.snapshot()
            #expect(before.quarantinedDependencyIDs == ["ab", "ba"])
            #expect(before.workspace.dependencies.allSatisfy { $0.removedAt == nil })
            #expect(before.planningWorkspace.dependencies.allSatisfy { $0.removedAt == Date(timeIntervalSince1970: 0) })
            #expect(before.planningIsValid); #expect(before.pausedItemIDs == ["a", "b"])
            var edit = before.planningWorkspace; edit.items.firstIndex { $0.id == "free" }.map { edit.items[$0].name = "Unrelated edit works" }
            let edited = try await j.record(workspace: edit, currentChoiceID: nil)
            #expect(edited.quarantinedDependencyIDs == before.quarantinedDependencyIDs)
            #expect(edited.workspace.dependencies.allSatisfy { $0.removedAt == nil })
            #expect(edited.conflicts == before.conflicts)
            #expect(await j.pending().allSatisfy { $0.changes.allSatisfy { $0.path.collection != "dependencies" } })
            let input = edited.planningInput(PlanningInput(slots: [CapacitySlot(start: SyncQA.t, end: SyncQA.at(120))], now: SyncQA.t,
                                                        revision: PlanningRevision(capacity: "C", calendar: "K", time: "T")))
            #expect(Set(input.options.disputedItemIDs) == ["a", "b"])
            #expect(input.revision.capacity == "C" && input.revision.calendar == "K" && input.revision.time == "T")
            let plan = try Engine.plan(workspace: edited.planningWorkspace, input: input)
            #expect(plan.legacy.availableActions.contains { $0.itemID == "free" })
            let c = try #require(edited.conflicts.first { $0.kind == .dependencyCycle })
            let resolved: SyncMergeResult
            if viaCoordinator { resolved = try await SyncCoordinator(journal: j, transport: SyncQATransport()).resolveRelationships(conflictID: c.id, removingDependencyIDs: ["ba"]) }
            else { resolved = try await j.resolveRelationships(conflictID: c.id, removingDependencyIDs: ["ba"]) }
            #expect(resolved.conflicts.isEmpty); #expect(resolved.planningIsValid)
            #expect(resolved.workspace.dependencies.first { $0.id == "ab" }?.removedAt == nil)
            #expect(resolved.workspace.dependencies.first { $0.id == "ba" }?.removedAt != Date(timeIntervalSince1970: 0))
            #expect(resolved.workspace.dependencies.count == 2)
            #expect(await j.revision(id: "right") == rs[2])
        }
    }

    @Test func nodeSharedLinkCycleAndExplicitLinkRemoval() async throws {
        var base = SyncQA.base
        base.projects = [Project(id: "p", name: "P")]
        base.nodes = [Node(id: "n1", projectID: "p", name: "N1"), Node(id: "n2", projectID: "p", name: "N2")]
        var l = base, r = base
        l.workLinks = [WorkLink(id: "12", source: .node("n1"), projectID: "p", nodeID: "n2")]
        r.workLinks = [WorkLink(id: "21", source: .node("n2"), projectID: "p", nodeID: "n1")]
        let rs = try SyncQA.pair(base, l, r)
        for viaCoordinator in [false, true] {
            let url = try SyncQA.directory(); defer { try? FileManager.default.removeItem(at: url) }
            let j = try await SyncQA.seed(url, rs: rs), before = try await j.snapshot()
            #expect(before.quarantinedWorkLinkIDs == ["12", "21"])
            var edit = before.planningWorkspace; edit.items[0].name = "ordinary title"
            let edited = try await j.record(workspace: edit, currentChoiceID: nil)
            #expect(edited.workspace.workLinks?.allSatisfy { $0.removedAt == nil } == true)
            #expect(edited.quarantinedWorkLinkIDs == ["12", "21"])
            let c = try #require(edited.conflicts.first { $0.kind == .dependencyCycle })
            let after: SyncMergeResult
            if viaCoordinator { after = try await SyncCoordinator(journal: j, transport: SyncQATransport()).resolveRelationships(conflictID: c.id, removingDependencyIDs: [], removingWorkLinkIDs: ["21"]) }
            else { after = try await j.resolveRelationships(conflictID: c.id, removingDependencyIDs: [], removingWorkLinkIDs: ["21"]) }
            #expect(after.conflicts.isEmpty); #expect(after.workspace.workLinks?.count == 2)
            #expect(await j.revision(id: "right") == rs[2])
        }
    }

    @Test func differentUUIDWorkAndBlockerRoundsSemanticResolutionBothAPIs() async throws {
        var base = SyncQA.base
        base.blockers = [Blocker(id: "wait", name: "Wait")]
        base.dependencies = [Dependency(id: "wb", source: .blocker("wait"), targetItemID: "b")]
        var l = base, r = base
        l.workRounds = [WorkRound(id: "wr1", itemID: "a", round: 1, openedAt: SyncQA.t, initialMinutes: 60)]
        r.workRounds = [WorkRound(id: "wr2", itemID: "a", round: 1, openedAt: SyncQA.t, initialMinutes: 45)]
        l.blockerRounds = [BlockerRound(id: "br1", blockerID: "wait", round: 1, triggeredAt: nil)]
        r.blockerRounds = [BlockerRound(id: "br2", blockerID: "wait", round: 1, triggeredAt: nil)]
        let rs = try SyncQA.pair(base, l, r); try SyncQA.equalDirections(rs)
        for viaCoordinator in [false, true] {
            let url = try SyncQA.directory(); defer { try? FileManager.default.removeItem(at: url) }
            let j = try await SyncQA.seed(url, rs: rs)
            var result = try await j.snapshot()
            #expect(result.conflicts.filter { $0.kind == .semanticRecord }.count == 2)
            #expect(result.workspace.workRounds?.count == 2 && result.workspace.blockerRounds?.count == 2)
            var edit = result.planningWorkspace; edit.items.firstIndex { $0.id == "free" }.map { edit.items[$0].name = "still editable" }
            result = try await j.record(workspace: edit, currentChoiceID: nil)
            #expect(result.workspace.workRounds?.count == 2 && result.workspace.blockerRounds?.count == 2)
            for (collection, chosen) in [("workRounds", "wr2"), ("blockerRounds", "br2")] {
                let c = try #require(result.conflicts.first { $0.kind == .semanticRecord && $0.paths.contains { $0.collection == collection } })
                if viaCoordinator { result = try await SyncCoordinator(journal: j, transport: SyncQATransport()).resolveSemanticRecord(conflictID: c.id, choosingEntityID: chosen) }
                else { result = try await j.resolveSemanticRecord(conflictID: c.id, choosingEntityID: chosen) }
            }
            #expect(result.conflicts.isEmpty)
            #expect(result.workspace.workRounds?.count == 2 && result.workspace.blockerRounds?.count == 2)
            #expect(result.planningWorkspace.workRounds?.map(\.id) == ["wr2"])
            #expect(result.planningWorkspace.blockerRounds?.map(\.id) == ["br2"])
            #expect(await j.revision(id: "left") == rs[1])
        }
    }

    @Test func differentUUIDSessionAndEstimateCorrectionsAreSemanticAndNeverDoubleCount() async throws {
        var base = SyncQA.base
        base.workSessions = [WorkSession(id: "s0", itemID: "a", start: SyncQA.t, end: SyncQA.t, actualMinutes: 40, intervalIsExact: false)]
        base.estimateRevisions = [EstimateRevision(id: "e0", itemID: "a", date: SyncQA.t, minutes: 60)]
        var l = base, r = base
        l.workSessions.append(WorkSession(id: "s1", itemID: "a", start: SyncQA.t, end: SyncQA.t, actualMinutes: 20, intervalIsExact: false, correctsSessionID: "s0"))
        r.workSessions.append(WorkSession(id: "s2", itemID: "a", start: SyncQA.t, end: SyncQA.t, actualMinutes: 30, intervalIsExact: false, correctsSessionID: "s0"))
        l.estimateRevisions?.append(EstimateRevision(id: "e1", itemID: "a", date: SyncQA.at(1), minutes: 20, correctsRevisionID: "e0"))
        r.estimateRevisions?.append(EstimateRevision(id: "e2", itemID: "a", date: SyncQA.at(1), minutes: 30, correctsRevisionID: "e0"))
        let rs = try SyncQA.pair(base, l, r); try SyncQA.equalDirections(rs)
        for viaCoordinator in [false, true] {
            let url = try SyncQA.directory(); defer { try? FileManager.default.removeItem(at: url) }
            let j = try await SyncQA.seed(url, rs: rs); var result = try await j.snapshot()
            #expect(result.conflicts.filter { $0.kind == .semanticRecord }.count == 2)
            #expect(result.planningWorkspace.effortSummary().confirmedMinutes == 20)
            for (collection, chosen) in [("workSessions", "s2"), ("estimateRevisions", "e2")] {
                let c = try #require(result.conflicts.first { $0.kind == .semanticRecord && $0.paths.contains { $0.collection == collection } })
                if viaCoordinator { result = try await SyncCoordinator(journal: j, transport: SyncQATransport()).resolveSemanticRecord(conflictID: c.id, choosingEntityID: chosen) }
                else { result = try await j.resolveSemanticRecord(conflictID: c.id, choosingEntityID: chosen) }
            }
            #expect(result.conflicts.isEmpty); #expect(result.planningIsValid)
            #expect(result.workspace.workSessions.count == 3 && result.workspace.estimateRevisions?.count == 3)
            #expect(result.planningWorkspace.effortSummary().confirmedMinutes == 30)
            #expect(result.planningWorkspace.effectiveEstimateRevisions.map(\.id) == ["e2"])
        }
    }

    @Test func sameHistoryIDCorrectionIsExplicitAndDifferentCorrectionUUIDsAreSemantic() throws {
        var base = SyncQA.base
        base.history = [HistoryEvent(id: "h0", date: SyncQA.t, kind: .remainingUpdated, objectID: "a", minutes: 60)]
        var l = base, r = base
        l.history[0].minutes = 20; r.history[0].minutes = 30
        let edited = try SyncQA.merge(SyncQA.pair(base, l, r))
        _ = try SyncQA.conflict(edited, "history", "@fact")
        l = base; r = base
        l.history.append(HistoryEvent(id: "h1", date: SyncQA.at(1), kind: .estimateCorrected, objectID: "a", minutes: 20, correctsEventID: "h0"))
        r.history.append(HistoryEvent(id: "h2", date: SyncQA.at(1), kind: .estimateCorrected, objectID: "a", minutes: 30, correctsEventID: "h0"))
        let result = try SyncQA.merge(SyncQA.pair(base, l, r))
        #expect(result.workspace.history.count == 3)
        #expect(result.conflicts.contains { $0.kind == .semanticRecord && $0.paths.contains { $0.collection == "history" } },
                "Two distinct correction IDs for the same history event must be explicitly disputed")
    }

    @Test func deletionNewReferenceAndEffortResolutionBothAPIsPreservesFacts() async throws {
        let base = SyncQA.base; var l = base, r = base
        l.items.removeAll { $0.id == "a" }
        r.dependencies = [Dependency(id: "ab", source: .item("a"), targetItemID: "b")]
        r.workSessions = [WorkSession(id: "s", itemID: "a", start: SyncQA.t, end: SyncQA.t, actualMinutes: 40, intervalIsExact: false)]
        let rs = try SyncQA.pair(base, l, r)
        for viaCoordinator in [false, true] {
            for archive in [false, true] {
                let url = try SyncQA.directory(); defer { try? FileManager.default.removeItem(at: url) }
                let j = try await SyncQA.seed(url, rs: rs), before = try await j.snapshot()
                let c = try #require(before.conflicts.first { $0.kind == .deletionReference })
                #expect(before.workspace.items.contains { $0.id == "a" })
                let after: SyncMergeResult
                if viaCoordinator { after = try await SyncCoordinator(journal: j, transport: SyncQATransport()).resolveDeletion(conflictID: c.id, archive: archive) }
                else { after = try await j.resolveDeletion(conflictID: c.id, archive: archive) }
                #expect(after.conflicts.isEmpty); #expect(after.planningIsValid)
                #expect(after.workspace.items.first { $0.id == "a" }?.archived == archive)
                #expect(after.workspace.workSessions == r.workSessions)
                #expect(after.workspace.dependencies == r.dependencies)
                #expect(await j.revision(id: "left") == rs[1])
            }
        }
    }

    @Test func downstreamCompletionUpstreamReworkProjectionReviewAndInvariantResolutionBothAPIs() async throws {
        let rs = try SyncQA.projectionRace(); try SyncQA.equalDirections(rs)
        for viaCoordinator in [false, true] {
            let url = try SyncQA.directory(); defer { try? FileManager.default.removeItem(at: url) }
            let j = try await SyncQA.seed(url, rs: rs), before = try await j.snapshot()
            #expect(before.projectionReviewItemIDs == ["b"])
            #expect(before.workspace.items.first { $0.id == "b" }?.status == .completed)
            #expect(before.workspace.items.first { $0.id == "b" }?.needsReview == false)
            #expect(before.planningWorkspace.items.first { $0.id == "b" }?.needsReview == true)
            #expect(!before.pausedItemIDs.contains("free"))
            var edit = before.planningWorkspace; edit.items.firstIndex { $0.id == "free" }.map { edit.items[$0].name = "independent" }
            let edited = try await j.record(workspace: edit, currentChoiceID: nil)
            #expect(edited.projectionReviewItemIDs == ["b"])
            let c = try #require(edited.conflicts.first { $0.kind == .invariant && $0.affectedItemIDs.contains("b") })
            var reviewed = edited.planningWorkspace
            try reviewed.reviewItem(id: "b", now: SyncQA.at(3))
            let after: SyncMergeResult
            if viaCoordinator { after = try await SyncCoordinator(journal: j, transport: SyncQATransport()).resolveInvariant(conflictID: c.id, workspace: reviewed) }
            else { after = try await j.resolveInvariant(conflictID: c.id, workspace: reviewed) }
            #expect(after.conflicts.isEmpty); #expect(after.projectionReviewItemIDs.isEmpty)
            #expect(after.workspace.items.first { $0.id == "a" }?.status == .pending)
            #expect(after.workspace.items.first { $0.id == "a" }?.remainingMinutes == nil)
            #expect(after.workspace.items.first { $0.id == "b" }?.status == .completed)
            #expect(after.workspace.history.count == edited.workspace.history.count + 1)
            #expect(after.workspace.reviews?.count == 1)
            #expect(await j.revision(id: "left") == rs[1])
        }
    }

    @Test func repeatedRemoteHistoryNoticeAndSessionDeduplicateAndOmittedFactsSurvive() async throws {
        var remote = SyncQA.base
        remote.workSessions = [WorkSession(id: "effort", itemID: "a", start: SyncQA.t, end: SyncQA.t, actualMinutes: 40, intervalIsExact: false)]
        remote.history = [HistoryEvent(id: "notice", date: SyncQA.t, kind: .edited, objectID: "a", note: "cubic.notification.state.v1", detail: "{\"root\":\"same-risk\",\"read\":true}")]
        let root = try SyncQA.revision(remote, device: "remote")
        let url = try SyncQA.directory(); defer { try? FileManager.default.removeItem(at: url) }
        let j = try await SyncQA.seed(url, rs: [root, root])
        try await j.ingest([root, root], cursor: Data("next".utf8))
        let before = try await j.snapshot()
        #expect(before.workspace.history.count == 1 && before.workspace.workSessions.count == 1)
        #expect(before.workspace.effortSummary().confirmedMinutes == 40)
        var omitted = before.planningWorkspace; omitted.history = []; omitted.workSessions = []
        omitted.items[0].name = "title update without arrays"
        let after = try await j.record(workspace: omitted, currentChoiceID: nil)
        #expect(after.workspace.history == remote.history && after.workspace.workSessions == remote.workSessions)
        #expect(after.workspace.effortSummary().confirmedMinutes == 40)
        #expect(await j.revision(id: "root") == root)
    }

    @Test func offlineDurableReopenCrashWindowAndWriterLease() async throws {
        let url = try SyncQA.directory(); defer { try? FileManager.default.removeItem(at: url) }
        func writeAndClose() async throws -> [String] {
            let j = try SyncQA.journal(url)
            _ = try await j.bootstrap(workspace: SyncQA.base)
            var edit = SyncQA.base; edit.items[0].name = "durable offline"
            _ = try await j.record(workspace: edit, currentChoiceID: nil)
            try await j.bindAccount("account-A")
            #expect(throws: (any Error).self) { try SyncQA.journal(url) }
            return await j.pending().map(\.id)
        }
        let ids = try await writeAndClose()
        // Inject exact crash boundary: revision committed, manifest still from previous operation.
        let prior = try SyncQA.merge(try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "revision" }.map { try SyncCoding.decode(SyncRevision.self, from: Data(contentsOf: $0)) })
        var crashEdit = prior.workspace
        crashEdit.history.append(HistoryEvent(id: "crash-history", date: SyncQA.at(1), kind: .edited, objectID: "a", note: "file committed before manifest"))
        let crashed = try SyncQA.revision(crashEdit, old: prior.workspace, id: "crash", parents: prior.heads)
        let name = Data(crashed.id.utf8).map { String(format: "%02x", $0) }.joined() + ".revision"
        try SyncCoding.encode(crashed).write(to: url.appendingPathComponent(name), options: .atomic)
        let reopened = try SyncQA.journal(url)
        #expect(Set(await reopened.pending().map(\.id)) == Set(ids + ["crash"]))
        #expect(try await reopened.snapshot().workspace.history.contains { $0.id == "crash-history" })
        #expect(await reopened.boundAccountID() == "account-A")
        #expect(await reopened.pending().last?.id == "crash")
        try await reopened.acknowledge([ids[0]])
        #expect(!Set(await reopened.pending().map(\.id)).contains(ids[0]))
    }

    @Test func pullPageCursorAtomicFailureMissingParentStagingAndReplay() async throws {
        let url = try SyncQA.directory(); defer { try? FileManager.default.removeItem(at: url) }
        let j = try SyncQA.journal(url), root = try SyncQA.revision(SyncQA.base, device: "remote")
        try await j.ingest([root], cursor: Data("old".utf8))
        var edit = SyncQA.base; edit.items[0].name = "next page"
        let child = try SyncQA.revision(edit, old: SyncQA.base, id: "child", device: "remote", parents: ["root"])
        let bad = SyncRevision(id: "bad", workspaceID: "foreign", deviceID: "remote", parents: [], immutableWorkspace: .empty, currentChoiceID: nil, changes: [])
        do { try await j.ingest([child, bad], cursor: Data("unsafe".utf8)); Issue.record("wrong workspace page accepted") } catch {}
        #expect(await j.cursor() == Data("old".utf8))
        #expect(await j.revision(id: "child") == nil)
        try await j.ingest([child, child], cursor: Data("good".utf8))
        #expect(await j.cursor() == Data("good".utf8))
        #expect(try await j.snapshot().workspace.items.first { $0.id == "a" }?.name == "next page")
        let url2 = try SyncQA.directory(); defer { try? FileManager.default.removeItem(at: url2) }
        let staged = try SyncQA.journal(url2)
        try await staged.ingest([child], cursor: Data("child-page".utf8))
        let unclosed = try await staged.snapshot()
        #expect(unclosed.heads.isEmpty && unclosed.workspace.items.isEmpty)
        let stagedStatus = try await staged.syncStatus()
        #expect(stagedStatus.stagedCount == 1 && stagedStatus.missingParentIDs == ["root"])
        #expect(await staged.revision(id: "child") != nil)
        #expect(throws: SyncError.missingParent("root")) { try SyncQA.merge([child]) }
        try await staged.ingest([root], cursor: Data("parent-page".utf8))
        #expect(try await staged.snapshot().heads == ["child"])
    }

    @Test func failedManifestDoesNotAdvanceCursorAndLocalCrashFileRecovers() async throws {
        let url = try SyncQA.directory(); defer { try? FileManager.default.removeItem(at: url) }
        func injectFailure() async throws {
            let j = try SyncQA.journal(url)
            _ = try await j.bootstrap(workspace: SyncQA.base)
            try await j.ingest([], cursor: Data("safe".utf8))
            let manifest = url.appendingPathComponent("manifest.json"), bytes = try Data(contentsOf: manifest)
            try FileManager.default.removeItem(at: manifest)
            try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
            var edit = SyncQA.base
            edit.history = [HistoryEvent(id: "durable-failure", date: SyncQA.at(1), kind: .edited, objectID: "a")]
            do { _ = try await j.record(workspace: edit, currentChoiceID: nil); Issue.record("manifest failure hidden") } catch {}
            do { try await j.ingest([], cursor: Data("lost".utf8)); Issue.record("cursor persisted despite failure") } catch {}
            #expect(await j.cursor() == Data("safe".utf8))
            do { _ = try await j.snapshot(); Issue.record("unrecovered snapshot published") } catch is SyncLocalCommitFailure { }
            try FileManager.default.removeItem(at: manifest)
            try bytes.write(to: manifest, options: .atomic)
        }
        try await injectFailure()
        let reopened = try SyncQA.journal(url)
        #expect(await reopened.cursor() == Data("safe".utf8))
        #expect(try await reopened.snapshot().workspace.history.contains { $0.id == "durable-failure" })
        #expect(await reopened.pending().count == 2)
    }

    @Test func partialAckThenRetryAndNetworkFailureKeepOutboxAndFacts() async throws {
        let url = try SyncQA.directory(); defer { try? FileManager.default.removeItem(at: url) }
        let j = try SyncQA.journal(url)
        _ = try await j.bootstrap(workspace: SyncQA.base)
        var edit = SyncQA.base
        edit.history = [HistoryEvent(id: "local-history", date: SyncQA.at(1), kind: .edited, objectID: "a")]
        _ = try await j.record(workspace: edit, currentChoiceID: nil)
        try await j.bindAccount("account-A")
        let pending = await j.pending().map(\.id), fake = SyncQATransport()
        let c = SyncCoordinator(journal: j, transport: fake)
        await fake.configure(failPush: true)
        let failed = await c.refresh()
        #expect(failed.phase == .failed && failed.pendingCount == 2 && failed.lastSuccessfulSync == nil)
        #expect(await j.pending().map(\.id) == pending)
        await fake.configure(partial: true)
        let partial = await c.refresh()
        #expect(partial.phase == .failed && partial.pendingCount == 1)
        #expect(partial.message?.contains("deterministic partial ack") == true)
        #expect(await j.pending().map(\.id) == [pending[1]])
        #expect(partial.lastSuccessfulSync == nil)
        await fake.configure()
        let synced = await c.refresh()
        #expect(synced.phase == .synced && synced.pendingCount == 0)
        #expect(synced.lastSuccessfulSync != nil && synced.remoteDataAt != nil)
        #expect(await fake.remoteIDs() == Set(pending))
        #expect(try await c.snapshot().workspace.history == edit.history)
        #expect(await fake.pushed().count == 3)
    }

    @Test func paginationFullReconciliationAndDuplicateRemoteReplay() async throws {
        let url = try SyncQA.directory(); defer { try? FileManager.default.removeItem(at: url) }
        let j = try SyncQA.journal(url), fake = SyncQATransport()
        try await j.bindAccount("account-A")
        let root = try SyncQA.revision(SyncQA.base, device: "remote")
        var edit = SyncQA.base; edit.items[0].name = "remote child"
        let child = try SyncQA.revision(edit, old: SyncQA.base, id: "child", device: "remote", parents: ["root"])
        await fake.configure(pages: [SyncPullPage(revisions: [child], cursor: Data("one".utf8), hasMore: true),
                                    SyncPullPage(revisions: [root, root], cursor: Data("two".utf8), hasMore: false, needsFullReconciliation: true)])
        let result = await SyncCoordinator(journal: j, transport: fake).refresh()
        #expect(result.phase == .synced && result.pendingCount == 0)
        #expect(await fake.pulled().prefix(2).elementsEqual([nil, Data("one".utf8)]))
        #expect(await fake.pushed() == [["root", "child"]])
        #expect(try await j.snapshot().workspace.items.count == 3)
        #expect(await fake.remoteIDs() == ["root", "child"])
    }

    @Test func accountSwitchAtPullAndPushBoundariesDoesNotIngestOrAckForeignResults() async throws {
        for duringPull in [true, false] {
            let url = try SyncQA.directory(); defer { try? FileManager.default.removeItem(at: url) }
            let j = try SyncQA.journal(url), fake = SyncQATransport()
            _ = try await j.bootstrap(workspace: SyncQA.base); try await j.bindAccount("account-A")
            let ids = Set(await j.pending().map(\.id))
            var remote = SyncQA.base; remote.items[0].name = "account-B data"
            let foreign = try SyncQA.revision(remote, id: "foreign", device: "remote")
            await fake.configure(pages: duringPull ? [SyncPullPage(revisions: [foreign], cursor: Data("B".utf8), hasMore: false)] : [],
                                 switchOnPull: duringPull, switchOnPush: !duringPull)
            let status = await SyncCoordinator(journal: j, transport: fake).refresh()
            #expect(status.phase == .accountChanged)
            #expect(Set(await j.pending().map(\.id)) == ids)
            #expect(await j.revision(id: "foreign") == nil)
            #expect(await j.cursor() != Data("B".utf8))
            #expect(try await j.snapshot().workspace.items.first { $0.id == "a" }?.name == "A")
            do { try await j.bindAccount("account-B"); Issue.record("rebound existing partition") }
            catch { #expect(error as? SyncError == .accountChanged) }
            let bURL = try SyncQA.directory(); defer { try? FileManager.default.removeItem(at: bURL) }
            let b = try SyncQA.journal(bURL); try await b.bindAccount("account-B")
            #expect(try await b.snapshot().workspace.items.isEmpty)
        }
    }

    @Test func requiresSigningAndRequiresAccountPermitOfflineJournalWithoutTransportIO() async throws {
        for availability in [SyncAvailability.requiresSigning("no entitlement"), .requiresAccount("signed out")] {
            let url = try SyncQA.directory(); defer { try? FileManager.default.removeItem(at: url) }
            let j = try SyncQA.journal(url), fake = SyncQATransport()
            _ = try await j.bootstrap(workspace: SyncQA.base)
            await fake.configure(availability: availability)
            let result = await SyncCoordinator(journal: j, transport: fake).refresh()
            #expect(result.phase == (availability == .requiresSigning("no entitlement") ? .requiresSigning : .requiresAccount))
            #expect(await fake.pulled().isEmpty)
            #expect(await fake.pushed().isEmpty)
            var edit = SyncQA.base; edit.items[0].name = "offline usable"
            _ = try await j.record(workspace: edit, currentChoiceID: nil)
            #expect(await j.pending().count == 2)
        }
    }

    @Test func directCompleteMissingBaselineAndChangeReasonsSurviveJournal() async throws {
        var w = SyncQA.base
        try w.completeItem(id: "a", now: SyncQA.at(1))
        #expect(w.items[0].started == nil && w.items[0].preStartCapturedAt == nil && w.items[0].preStartMinutes == nil)
        try w.reworkItem(id: "a", remainingMinutes: nil, now: SyncQA.at(2))
        try w.updateRemaining(itemID: "a", minutes: 30, now: SyncQA.at(3), reason: .scopeChange)
        try w.chooseNextAction(itemID: "b", now: SyncQA.at(4))
        let url = try SyncQA.directory(); defer { try? FileManager.default.removeItem(at: url) }
        let j = try SyncQA.journal(url), result = try await j.bootstrap(workspace: w)
        #expect(result.workspace.history.contains { $0.kind == .completed })
        #expect(result.workspace.history.contains { $0.kind == .reworked })
        #expect(result.workspace.history.contains { $0.changeReason == .scopeChange })
        #expect(result.workspace.history.contains { $0.kind == .choiceRecorded })
        #expect(result.workspace.workRounds?.contains { $0.round == 1 && $0.completedAt != nil && $0.preStartMinutes == nil } == true)
        #expect(result.workspace.items.first { $0.id == "a" }?.preStartMinutes == nil)
        #expect(result.workspace.workSessions.isEmpty)
    }

    @Test func sameHistoryRegisterExplicitResolutionRetainsImmutableCandidates() async throws {
        var base = SyncQA.base
        base.history = [HistoryEvent(id: "h", date: SyncQA.t, kind: .edited, objectID: "a", note: "original")]
        var l = base, r = base
        l.history[0].note = "left correction"; r.history[0].note = "right correction"
        let rs = try SyncQA.pair(base, l, r)
        for viaCoordinator in [false, true] {
            let url = try SyncQA.directory(); defer { try? FileManager.default.removeItem(at: url) }
            let j = try await SyncQA.seed(url, rs: rs)
            let c = try SyncQA.conflict(await j.snapshot(), "history", "@fact")
            let after: SyncMergeResult
            if viaCoordinator { after = try await SyncCoordinator(journal: j, transport: SyncQATransport()).resolve(conflictID: c.id, choosingRevisionID: "right") }
            else { after = try await j.resolve(conflictID: c.id, choosingRevisionID: "right") }
            #expect(after.conflicts.isEmpty && after.workspace.history[0].note == "right correction")
            #expect(try await j.materialize(revisionID: "left").workspace.history.first?.note == "left correction")
            #expect(try await j.materialize(revisionID: "root").workspace.history.first?.note == "original")
        }
    }

    @Test func invalidAndStaleResolutionAPIsDoNotAppendOrChangeFacts() async throws {
        let rs = try SyncQA.cycle()
        for viaCoordinator in [false, true] {
            let url = try SyncQA.directory(); defer { try? FileManager.default.removeItem(at: url) }
            let j = try await SyncQA.seed(url, rs: rs), c = SyncCoordinator(journal: j, transport: SyncQATransport())
            let before = try await j.snapshot(), ids = await j.pending().map(\.id)
            for method in 0..<5 {
                do {
                    if viaCoordinator {
                        switch method {
                        case 0: _ = try await c.resolve(conflictID: "stale", choosingRevisionID: "missing")
                        case 1: _ = try await c.resolveRelationships(conflictID: "stale", removingDependencyIDs: ["other"])
                        case 2: _ = try await c.resolveDeletion(conflictID: "stale")
                        case 3: _ = try await c.resolveSemanticRecord(conflictID: "stale", choosingEntityID: "missing")
                        default: _ = try await c.resolveInvariant(conflictID: "stale", workspace: .empty)
                        }
                    } else {
                        switch method {
                        case 0: _ = try await j.resolve(conflictID: "stale", choosingRevisionID: "missing")
                        case 1: _ = try await j.resolveRelationships(conflictID: "stale", removingDependencyIDs: ["other"])
                        case 2: _ = try await j.resolveDeletion(conflictID: "stale")
                        case 3: _ = try await j.resolveSemanticRecord(conflictID: "stale", choosingEntityID: "missing")
                        default: _ = try await j.resolveInvariant(conflictID: "stale", workspace: .empty)
                        }
                    }
                    Issue.record("Invalid resolution API accepted: \(method), coordinator=\(viaCoordinator)")
                } catch { #expect(error as? SyncError == .staleConflict("stale")) }
                #expect(try await j.snapshot().workspace == before.workspace)
                #expect(try await j.snapshot().conflicts == before.conflicts)
                #expect(await j.pending().map(\.id) == ids)
            }
        }
    }

    @Test func perDeviceCalendarVerificationAndDataRevisionAreNotUpgradedByMerge() throws {
        let result = try SyncQA.merge([SyncQA.revision(SyncQA.base)])
        let input = PlanningInput(slots: [], now: SyncQA.t,
                                  revision: PlanningRevision(capacity: "device-B", calendar: "unavailable", time: "now"),
                                  options: PlanningOptions(capacityVerified: false, capacityNote: "second device missing calendar"))
        let projected = result.planningInput(input)
        #expect(!projected.options.capacityVerified)
        #expect(projected.options.capacityNote == "second device missing calendar")
        #expect(projected.revision.capacity == "device-B" && projected.revision.calendar == "unavailable")
    }
}
