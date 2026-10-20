import Foundation
import Testing
@testable import CubicCore

// Prepared for root's post-fix milestone trigger. This file has NOT been run in prep.
private enum SyncRegressionFixture {
    static let t = Date(timeIntervalSince1970: 1_800_000_000.123456)
    static func at(_ minutes: Int) -> Date { t.addingTimeInterval(Double(minutes) * 60) }
    static var base: Workspace {
        Workspace(items: [WorkItem(id: "a", name: "A", remainingMinutes: 60),
                          WorkItem(id: "b", name: "B", remainingMinutes: 30),
                          WorkItem(id: "free", name: "Independent", remainingMinutes: 15)])
    }
    static func revision(_ w: Workspace, old: Workspace? = nil, id: String,
                         parents: [String] = [], device: String = "remote") throws -> SyncRevision {
        try .recording(workspace: w, comparedTo: old, id: id, workspaceID: "regression",
                       deviceID: device, parents: parents, createdAt: t)
    }
    static func directory() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("CubicSyncRegression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func journal(_ d: URL) throws -> SyncJournal {
        try SyncJournal(directory: d, workspaceID: "regression", deviceID: "local")
    }
    static func seed(_ d: URL, _ rs: [SyncRevision]) async throws -> SyncJournal {
        let j = try journal(d)
        try await j.ingest(rs, cursor: nil, at: t)
        return j
    }
    static func session(_ id: String, target: String? = nil, minutes: Int, item: String = "a") -> WorkSession {
        WorkSession(id: id, itemID: item, start: t, end: t, actualMinutes: minutes,
                    intervalIsExact: false, correctsSessionID: target)
    }
    static func correctionBranches() throws -> [SyncRevision] {
        var w = base
        w.workSessions = [session("s0", minutes: 40), session("sf", minutes: 7, item: "free")]
        w.estimateRevisions = [EstimateRevision(id: "e0", itemID: "a", date: t, minutes: 60)]
        var revisions = [try revision(w, id: "root")]
        // Both branches are individually valid, with four levels of corrections each.
        for branch in ["a", "z"] {
            var current = w, parent = "root"
            for depth in 1...4 {
                let previous = current, prefix = "\(branch)\(depth)"
                let minutes = (branch == "a" ? 10 : 30) + depth
                current.workSessions.append(session("\(prefix)-s", target: depth == 1 ? "s0" : "\(branch)\(depth - 1)-s", minutes: minutes))
                current.estimateRevisions?.append(EstimateRevision(id: "\(prefix)-e", itemID: "a", date: at(depth), minutes: minutes,
                    correctsRevisionID: depth == 1 ? "e0" : "\(branch)\(depth - 1)-e"))
                let id = "\(branch)-revision-\(depth)"
                revisions.append(try revision(current, old: previous, id: id, parents: [parent], device: branch))
                parent = id
            }
        }
        return revisions
    }
    static func choiceRevisions() throws -> [SyncRevision] {
        let w = base; var l = w, r = w
        l.choices = [NextActionChoice(id: "choose-a", itemID: "a", date: at(1))]; l.currentChoiceID = "choose-a"
        r.choices = [NextActionChoice(id: "choose-b", itemID: "b", date: at(1))]; r.currentChoiceID = "choose-b"
        l.history = [HistoryEvent(id: "choice-left", date: at(1), kind: .choiceRecorded, objectID: "a")]
        r.history = [HistoryEvent(id: "choice-right", date: at(1), kind: .choiceRecorded, objectID: "b")]
        return [try revision(w, id: "root"), try revision(l, old: w, id: "left", parents: ["root"]),
                try revision(r, old: w, id: "right", parents: ["root"])]
    }
    static func cycleAndReview() throws -> [SyncRevision] {
        var w = base
        w.items += [WorkItem(id: "x", name: "X", remainingMinutes: 10), WorkItem(id: "y", name: "Y", remainingMinutes: 10)]
        try w.completeItem(id: "a", now: at(1))
        w.dependencies = [Dependency(id: "ab", source: .item("a"), targetItemID: "b")]
        var l = w, r = w
        try l.completeItem(id: "b", now: at(2))
        l.dependencies.append(Dependency(id: "xy", source: .item("x"), targetItemID: "y"))
        try r.reworkItem(id: "a", remainingMinutes: nil, now: at(2))
        r.dependencies.append(Dependency(id: "yx", source: .item("y"), targetItemID: "x"))
        return [try revision(w, id: "root"), try revision(l, old: w, id: "left", parents: ["root"]),
                try revision(r, old: w, id: "right", parents: ["root"])]
    }
    static func choiceConflict(_ result: SyncMergeResult) throws -> SyncConflict {
        try #require(result.conflicts.first { $0.paths.contains { $0.collection == "@sync" && $0.field == "currentChoiceID" } })
    }
    static func bytes(in d: URL, revisionsOnly: Bool) throws -> Int {
        let files = try FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        return try files.reduce(0) { total, file in
            if revisionsOnly && file.pathExtension != "revision" { return total }
            let v = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            return total + (v.isRegularFile == true ? v.fileSize ?? 0 : 0)
        }
    }
}

private actor SyncRegressionPagedTransport: SyncTransport {
    let first: SyncPullPage
    private var calls = 0
    private var pushes = 0
    private var cursors: [Data?] = []
    init(first: SyncPullPage) { self.first = first }
    func availability() async throws -> SyncAvailability { .available(accountID: "A") }
    func pull(cursor: Data?) async throws -> SyncPullPage {
        cursors.append(cursor); calls += 1
        if calls == 1 { return first }
        throw SyncError.transport("regression second page offline")
    }
    func push(_ revisions: [SyncRevision]) async throws -> Set<String> { pushes += 1; return Set(revisions.map(\.id)) }
    func observedCursors() -> [Data?] { cursors }
    func pushCount() -> Int { pushes }
}

@Suite(.serialized) struct SyncRegressionTests {
    @Test func missingParentFirstPageSecondPageFailureRestartAndPromotionAllowIndependentEdits() async throws {
        let d = try SyncRegressionFixture.directory(); defer { try? FileManager.default.removeItem(at: d) }
        let base = SyncRegressionFixture.base
        var p = base; p.items[0].name = "parent remote title"
        var c = p; c.items[1].name = "child remote title"
        let root = try SyncRegressionFixture.revision(base, id: "root")
        let parent = try SyncRegressionFixture.revision(p, old: base, id: "parent", parents: ["root"])
        let child = try SyncRegressionFixture.revision(c, old: p, id: "child", parents: ["parent"])
        let pageToken = Data("first-page-committed".utf8)
        func firstOpen() async throws -> Set<String> {
            let j = try await SyncRegressionFixture.seed(d, [root]); try await j.bindAccount("A")
            let fake = SyncRegressionPagedTransport(first: SyncPullPage(revisions: [child], cursor: pageToken, hasMore: true))
            let coordinator = SyncCoordinator(journal: j, transport: fake)
            let status = await coordinator.refresh()
            #expect(status.phase == .failed)
            #expect(status.message?.contains("regression second page offline") == true)
            #expect(await j.cursor() == pageToken)
            #expect(await fake.observedCursors().elementsEqual([nil, pageToken]))
            #expect(await fake.pushCount() == 0)
            let usable = try await j.snapshot()
            #expect(usable.planningIsValid && usable.heads == ["root"])
            #expect(usable.workspace.items.first { $0.id == "b" }?.name == "B")
            #expect(await j.revision(id: "child") != nil) // durable staging, not prematurely materialized
            var edit = usable.planningWorkspace
            edit.items.firstIndex { $0.id == "free" }.map { edit.items[$0].name = "offline before restart" }
            let saved = try await coordinator.record(workspace: edit, currentChoiceID: nil)
            #expect(saved.workspace.items.first { $0.id == "free" }?.name == "offline before restart")
            let pending = await j.pending()
            #expect(!pending.isEmpty && pending.allSatisfy { !$0.parents.contains("child") })
            return Set(pending.map(\.id))
        }
        let beforeRestartIDs = try await firstOpen()
        let reopened = try SyncRegressionFixture.journal(d)
        #expect(await reopened.cursor() == pageToken)
        #expect(await reopened.revision(id: "child") != nil)
        #expect(beforeRestartIDs.isSubset(of: Set(await reopened.pending().map(\.id))))
        var edit = try await reopened.snapshot().planningWorkspace
        #expect(edit.items.first { $0.id == "free" }?.name == "offline before restart")
        edit.items.firstIndex { $0.id == "free" }.map { edit.items[$0].name = "offline after restart" }
        _ = try await reopened.record(workspace: edit, currentChoiceID: nil)
        try await reopened.ingest([parent], cursor: Data("second-page".utf8), at: SyncRegressionFixture.at(5))
        let promoted = try await reopened.snapshot()
        #expect(promoted.planningIsValid && promoted.conflicts.isEmpty && promoted.heads.contains("child"))
        #expect(promoted.workspace.items.first { $0.id == "a" }?.name == "parent remote title")
        #expect(promoted.workspace.items.first { $0.id == "b" }?.name == "child remote title")
        #expect(promoted.workspace.items.first { $0.id == "free" }?.name == "offline after restart")
        #expect(await reopened.pending().count == 2)
        let historical = try await reopened.materialize(revisionID: "child")
        #expect(historical.workspace.items.first { $0.id == "free" }?.name == "Independent")
        #expect(historical.workspace.items.first { $0.id == "b" }?.name == "child remote title")
    }

    @Test func parallelCorrectionLongBranchesRemainLocallyValidAndResolveWholeBranch() async throws {
        let rs = try SyncRegressionFixture.correctionBranches()
        let forward = try SyncMerge.merge(revisions: rs, workspaceID: "regression")
        let reverse = try SyncMerge.merge(revisions: rs.reversed(), workspaceID: "regression")
        #expect(forward.workspace == reverse.workspace && forward.planningWorkspace == reverse.planningWorkspace)
        #expect(forward.conflicts == reverse.conflicts)
        for viaCoordinator in [false, true] {
            for selectedBranch in ["a", "z"] {
                let d = try SyncRegressionFixture.directory(); defer { try? FileManager.default.removeItem(at: d) }
                let j = try await SyncRegressionFixture.seed(d, rs)
                var result = try await j.snapshot()
                #expect(result.planningIsValid)
                #expect(result.workspace.workSessions.count == 10 && result.workspace.estimateRevisions?.count == 9)
                #expect(result.conflicts.filter { $0.kind == .semanticRecord }.count == 2)
                #expect(!result.pausedItemIDs.contains("free"))
                #expect(result.planningWorkspace.effortSummary(itemIDs: ["free"]).confirmedMinutes == 7)
                #expect([21, 41].contains(result.planningWorkspace.effortSummary().confirmedMinutes))
                try result.planningWorkspace.validate() // no dangling descendant corrections
                var edit = result.planningWorkspace
                edit.items.firstIndex { $0.id == "free" }.map { edit.items[$0].name = "unrelated branch remains editable" }
                result = try await j.record(workspace: edit, currentChoiceID: nil)
                #expect(result.workspace.workSessions.count == 10 && result.workspace.estimateRevisions?.count == 9)
                for (collection, suffix) in [("workSessions", "s"), ("estimateRevisions", "e")] {
                    let conflict = try #require(result.conflicts.first { $0.kind == .semanticRecord && $0.paths.contains { $0.collection == collection } })
                    let chosen = "\(selectedBranch)1-\(suffix)"
                    if viaCoordinator {
                        result = try await SyncCoordinator(journal: j, transport: SyncRegressionPagedTransport(first: SyncPullPage(revisions: [], cursor: nil, hasMore: false)))
                            .resolveSemanticRecord(conflictID: conflict.id, choosingEntityID: chosen)
                    } else { result = try await j.resolveSemanticRecord(conflictID: conflict.id, choosingEntityID: chosen) }
                    #expect(result.planningIsValid)
                }
                #expect(result.conflicts.isEmpty && result.pausedItemIDs.isEmpty)
                #expect(result.workspace.workSessions.count == 10 && result.workspace.estimateRevisions?.count == 9)
                #expect(Set(result.planningWorkspace.effectiveWorkSessions.map(\.id)) == ["\(selectedBranch)4-s", "sf"])
                #expect(result.planningWorkspace.effectiveEstimateRevisions.map(\.id) == ["\(selectedBranch)4-e"])
                #expect(result.planningWorkspace.effortSummary().confirmedMinutes == (selectedBranch == "a" ? 21 : 41))
                for r in rs { #expect(await j.revision(id: r.id) != nil) }
            }
        }
    }

    @Test func choiceNilProjectionUnrelatedTitleAndEffortDoNotClearDispute() async throws {
        let rs = try SyncRegressionFixture.choiceRevisions()
        for viaCoordinator in [false, true] {
            let d = try SyncRegressionFixture.directory(); defer { try? FileManager.default.removeItem(at: d) }
            let j = try await SyncRegressionFixture.seed(d, rs)
            let coordinator = SyncCoordinator(journal: j, transport: SyncRegressionPagedTransport(first: SyncPullPage(revisions: [], cursor: nil, hasMore: false)))
            let before = try await j.snapshot(), conflict = try SyncRegressionFixture.choiceConflict(before)
            #expect(before.currentChoiceID == nil && before.planningWorkspace.currentChoiceID == nil)
            var edit = before.planningWorkspace
            edit.items.firstIndex { $0.id == "free" }.map { edit.items[$0].name = "independent title edit" }
            var after: SyncMergeResult
            if viaCoordinator { after = try await coordinator.record(workspace: edit, currentChoiceID: nil) }
            else { after = try await j.record(workspace: edit, currentChoiceID: nil) }
            #expect(after.currentChoiceID == nil && after.planningWorkspace.currentChoiceID == nil)
            #expect(try SyncRegressionFixture.choiceConflict(after) == conflict)
            #expect(after.workspace.choices?.count == 2 && after.workspace.history.count == 2)
            #expect(await j.pending().allSatisfy { $0.changes.allSatisfy { $0.path.collection != "@sync" } })
            edit = after.planningWorkspace
            edit.workSessions.append(SyncRegressionFixture.session("free-effort", minutes: 7, item: "free"))
            if viaCoordinator { after = try await coordinator.record(workspace: edit, currentChoiceID: nil) }
            else { after = try await j.record(workspace: edit, currentChoiceID: nil) }
            #expect(try SyncRegressionFixture.choiceConflict(after) == conflict)
            #expect(after.workspace.effortSummary(itemIDs: ["free"]).confirmedMinutes == 7)
            #expect(after.workspace.items.first { $0.id == "free" }?.name == "independent title edit")
            if viaCoordinator { after = try await coordinator.resolve(conflictID: conflict.id, choosingRevisionID: "right") }
            else { after = try await j.resolve(conflictID: conflict.id, choosingRevisionID: "right") }
            #expect(after.currentChoiceID == "choose-b" && after.conflicts.isEmpty)
            #expect(after.workspace.choices?.count == 2 && after.workspace.workSessions.count == 1)
        }
    }

    @Test func cycleAndConcurrentSourceReviewResolveOnlyReviewWithoutChangingQuarantine() async throws {
        let rs = try SyncRegressionFixture.cycleAndReview()
        for viaCoordinator in [false, true] {
            let d = try SyncRegressionFixture.directory(); defer { try? FileManager.default.removeItem(at: d) }
            let j = try await SyncRegressionFixture.seed(d, rs), before = try await j.snapshot()
            #expect(before.quarantinedDependencyIDs == ["xy", "yx"] && before.projectionReviewItemIDs == ["b"])
            let cycle = try #require(before.conflicts.first { $0.kind == .dependencyCycle })
            let review = try #require(before.conflicts.first { $0.kind == .invariant && $0.affectedItemIDs.contains("b") })
            var repaired = before.planningWorkspace
            try repaired.reviewItem(id: "b", now: SyncRegressionFixture.at(3))
            let after: SyncMergeResult
            if viaCoordinator {
                after = try await SyncCoordinator(journal: j, transport: SyncRegressionPagedTransport(first: SyncPullPage(revisions: [], cursor: nil, hasMore: false)))
                    .resolveInvariant(conflictID: review.id, workspace: repaired)
            } else { after = try await j.resolveInvariant(conflictID: review.id, workspace: repaired) }
            #expect(after.planningIsValid && after.projectionReviewItemIDs.isEmpty)
            #expect(after.quarantinedDependencyIDs == before.quarantinedDependencyIDs)
            #expect(after.workspace.dependencies == before.workspace.dependencies)
            #expect(after.planningWorkspace.dependencies == before.planningWorkspace.dependencies)
            #expect(after.conflicts.contains(cycle) && !after.conflicts.contains { $0.id == review.id })
            #expect(after.pausedItemIDs == ["x", "y"])
            #expect(after.workspace.items.first { $0.id == "a" }?.status == .pending)
            #expect(after.workspace.items.first { $0.id == "b" }?.status == .completed)
            #expect(after.workspace.reviews?.count == 1 && after.workspace.history.count == before.workspace.history.count + 1)
            #expect(await j.pending().allSatisfy { $0.changes.allSatisfy { $0.path.collection != "dependencies" } })
        }
    }

    @Test func historyParallelCorrectionsLongBranchesRemainExplicitAndResolvable() async throws {
        var base = SyncRegressionFixture.base
        base.history = [HistoryEvent(id: "h0", date: SyncRegressionFixture.t, kind: .remainingUpdated, objectID: "a", minutes: 60)]
        var rs = [try SyncRegressionFixture.revision(base, id: "root")]
        for branch in ["a", "z"] {
            var w = base, parent = "root"
            for depth in 1...3 {
                let old = w, id = "\(branch)-history-\(depth)"
                w.history.append(HistoryEvent(id: id, date: SyncRegressionFixture.at(depth), kind: .estimateCorrected,
                    objectID: "a", note: "cubic.baseline.correction.v1", minutes: (branch == "a" ? 10 : 30) + depth,
                    correctsEventID: depth == 1 ? "h0" : "\(branch)-history-\(depth - 1)"))
                let revisionID = "\(branch)-op-\(depth)"
                rs.append(try SyncRegressionFixture.revision(w, old: old, id: revisionID, parents: [parent], device: branch))
                parent = revisionID
            }
        }
        let d = try SyncRegressionFixture.directory(); defer { try? FileManager.default.removeItem(at: d) }
        let j = try await SyncRegressionFixture.seed(d, rs), before = try await j.snapshot()
        #expect(before.planningIsValid && before.workspace.history.count == 7)
        let conflict = try #require(before.conflicts.first { $0.kind == .semanticRecord && $0.paths.contains { $0.collection == "history" } })
        let after = try await j.resolveSemanticRecord(conflictID: conflict.id, choosingEntityID: "z-history-1")
        #expect(after.planningIsValid && after.conflicts.isEmpty && after.workspace.history.count == 7)
        #expect(!after.planningWorkspace.history.contains { $0.id.hasPrefix("a-history-") })
        #expect(Set(after.planningWorkspace.history.map(\.id)) == ["h0", "z-history-1", "z-history-2", "z-history-3"])
    }

    @Test func archiveRoundTripPreservesAllConflictsIdentityAndUnionWithoutAccountConfiguration() async throws {
        let sourceDir = try SyncRegressionFixture.directory(), targetDir = try SyncRegressionFixture.directory()
        defer { try? FileManager.default.removeItem(at: sourceDir); try? FileManager.default.removeItem(at: targetDir) }
        let rs = try SyncRegressionFixture.cycleAndReview()
        let source = try await SyncRegressionFixture.seed(sourceDir, rs)
        try await source.bindAccount("source-A"); try await source.ingest([], cursor: Data("source-token".utf8))
        let original = try await source.snapshot(), archive = try await source.exportArchive()
        #expect(archive.formatVersion == 1 && archive.workspaceID == "regression")
        #expect(Set(archive.revisions.map(\.id)) == Set(rs.map(\.id)))
        let bytes = try SyncCoding.encode(archive)
        let object = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(Set(object.keys) == ["formatVersion", "workspaceID", "revisions", "stagedRevisionIDs", "missingParentIDs"])
        let entries = try #require(object["revisions"] as? [[String: Any]])
        #expect(entries.allSatisfy { Set($0.keys) == ["id", "parents", "createdAt", "changes"] })
        let decoded = try SyncCoding.decode(SyncArchive.self, from: bytes)
        #expect(decoded == archive)
        let target = try SyncRegressionFixture.journal(targetDir)
        try await target.bindAccount("target-B"); try await target.ingest([], cursor: Data("target-token".utf8))
        let restored = try await target.restoreArchive(decoded)
        #expect(restored.workspace == original.workspace && restored.planningWorkspace == original.planningWorkspace)
        #expect(restored.conflicts == original.conflicts && restored.quarantinedDependencyIDs == original.quarantinedDependencyIDs)
        #expect(restored.projectionReviewItemIDs == original.projectionReviewItemIDs)
        #expect(await target.boundAccountID() == "target-B")
        #expect(await target.cursor() != Data("source-token".utf8))
        #expect(Set(await target.pending().map(\.id)) == Set(rs.map(\.id)))
        var local = restored.planningWorkspace
        local.items.firstIndex { $0.id == "free" }.map { local.items[$0].name = "target local fact" }
        _ = try await target.record(workspace: local, currentChoiceID: nil)
        let unionBefore = try await target.exportArchive(), pendingBefore = Set(await target.pending().map(\.id))
        let repeated = try await target.restoreArchive(decoded)
        #expect(try await target.exportArchive() == unionBefore)
        #expect(Set(await target.pending().map(\.id)) == pendingBefore)
        #expect(repeated.workspace.items.first { $0.id == "free" }?.name == "target local fact")
        #expect(repeated.conflicts == original.conflicts)
        let historic = try await target.materialize(revisionID: "left")
        #expect(historic.workspace.items.first { $0.id == "b" }?.status == .completed)
        #expect(historic.workspace.dependencies.contains { $0.id == "xy" && $0.removedAt == nil })
        #expect(!historic.workspace.dependencies.contains { $0.id == "yx" })
    }

    @Test func archiveCarriesDeclaredStagingAcrossRestoreRestartAndParentPromotion() async throws {
        let sourceDir = try SyncRegressionFixture.directory(), targetDir = try SyncRegressionFixture.directory()
        defer { try? FileManager.default.removeItem(at: sourceDir); try? FileManager.default.removeItem(at: targetDir) }
        let base = SyncRegressionFixture.base
        let root = try SyncRegressionFixture.revision(base, id: "root")
        var p = base; p.items[0].name = "archive parent"
        var c = p; c.items[1].name = "archive child"
        let parent = try SyncRegressionFixture.revision(p, old: base, id: "parent", parents: ["root"])
        let child = try SyncRegressionFixture.revision(c, old: p, id: "child", parents: ["parent"])
        let source = try await SyncRegressionFixture.seed(sourceDir, [root, child])
        let archive = try await source.exportArchive()
        #expect(archive.stagedRevisionIDs == ["child"] && archive.missingParentIDs == ["parent"])
        func restoreThenClose() async throws {
            let target = try SyncRegressionFixture.journal(targetDir)
            let restored = try await target.restoreArchive(archive)
            #expect(restored.planningIsValid && restored.heads == ["root"])
            #expect(await target.revision(id: "child") != nil)
            var edit = restored.planningWorkspace
            edit.items.firstIndex { $0.id == "free" }.map { edit.items[$0].name = "restored offline edit" }
            _ = try await target.record(workspace: edit, currentChoiceID: nil)
        }
        try await restoreThenClose()
        let reopened = try SyncRegressionFixture.journal(targetDir)
        let staged = try await reopened.exportArchive()
        #expect(staged.stagedRevisionIDs == ["child"] && staged.missingParentIDs == ["parent"])
        try await reopened.ingest([parent], cursor: nil)
        let promoted = try await reopened.snapshot(), completeArchive = try await reopened.exportArchive()
        #expect(completeArchive.stagedRevisionIDs.isEmpty && completeArchive.missingParentIDs.isEmpty)
        #expect(promoted.workspace.items.first { $0.id == "a" }?.name == "archive parent")
        #expect(promoted.workspace.items.first { $0.id == "b" }?.name == "archive child")
        #expect(promoted.workspace.items.first { $0.id == "free" }?.name == "restored offline edit")
    }

    @Test func archivePreservesChoiceCandidatesAndSemanticEffectiveResolutionOperations() async throws {
        for semantic in [false, true] {
            let sourceDir = try SyncRegressionFixture.directory(), targetDir = try SyncRegressionFixture.directory()
            defer { try? FileManager.default.removeItem(at: sourceDir); try? FileManager.default.removeItem(at: targetDir) }
            let revisions = try semantic ? SyncRegressionFixture.correctionBranches() : SyncRegressionFixture.choiceRevisions()
            let source = try await SyncRegressionFixture.seed(sourceDir, revisions), target = try SyncRegressionFixture.journal(targetDir)
            let disputed = try await source.snapshot(), unresolvedArchive = try await source.exportArchive()
            let restoredDispute = try await target.restoreArchive(unresolvedArchive)
            #expect(restoredDispute.workspace == disputed.workspace && restoredDispute.conflicts == disputed.conflicts)
            #expect(restoredDispute.planningWorkspace == disputed.planningWorkspace)
            var resolved = disputed
            if semantic {
                for (collection, entity) in [("workSessions", "z1-s"), ("estimateRevisions", "z1-e")] {
                    let conflict = try #require(resolved.conflicts.first { $0.kind == .semanticRecord && $0.paths.contains { $0.collection == collection } })
                    resolved = try await source.resolveSemanticRecord(conflictID: conflict.id, choosingEntityID: entity)
                }
            } else {
                resolved = try await source.resolve(conflictID: SyncRegressionFixture.choiceConflict(disputed).id, choosingRevisionID: "right")
            }
            let resolvedArchive = try await source.exportArchive()
            #expect(resolvedArchive.revisions.count > unresolvedArchive.revisions.count)
            if semantic { #expect(resolvedArchive.revisions.contains { $0.changes.contains { $0.path.field == "@effective" } }) }
            let imported = try await target.restoreArchive(resolvedArchive)
            #expect(imported.conflicts.isEmpty && imported.planningIsValid)
            #expect(imported.workspace == resolved.workspace && imported.planningWorkspace == resolved.planningWorkspace)
            #expect(imported.currentChoiceID == resolved.currentChoiceID)
            if semantic {
                #expect(imported.workspace.workSessions.count == 10)
                #expect(imported.planningWorkspace.effortSummary().confirmedMinutes == 41)
            } else { #expect(imported.workspace.choices?.count == 2 && imported.currentChoiceID == "choose-b") }
            // Importing an older, unresolved backup must not erase causal resolution operations.
            let replayedOld = try await target.restoreArchive(unresolvedArchive)
            #expect(replayedOld.conflicts.isEmpty && replayedOld.planningWorkspace == resolved.planningWorkspace)
        }
    }

    @Test func invalidArchiveMissingParentsCycleAndIdentityReuseRejectWithoutOverwrite() async throws {
        let d = try SyncRegressionFixture.directory(); defer { try? FileManager.default.removeItem(at: d) }
        let j = try await SyncRegressionFixture.seed(d, [SyncRegressionFixture.revision(SyncRegressionFixture.base, id: "root")])
        let before = try await j.exportArchive(), state = try await j.snapshot(), pending = await j.pending().map(\.id)
        let unclosed = SyncArchiveRevision(id: "child", parents: ["absent"], createdAt: SyncRegressionFixture.t, changes: [])
        let one = SyncArchiveRevision(id: "cycle1", parents: ["cycle2"], createdAt: SyncRegressionFixture.t, changes: [])
        let two = SyncArchiveRevision(id: "cycle2", parents: ["cycle1"], createdAt: SyncRegressionFixture.t, changes: [])
        let reused = SyncArchiveRevision(id: "root", parents: [], createdAt: SyncRegressionFixture.t,
            changes: [SyncChange(path: SyncPath(collection: "items", entityID: "a", field: "name"), value: .string("forged"))])
        for malformed in [SyncArchive(workspaceID: "regression", revisions: [unclosed]),
                          SyncArchive(workspaceID: "regression", revisions: [one, two]),
                          SyncArchive(workspaceID: "regression", revisions: [reused]),
                          SyncArchive(workspaceID: "different", revisions: before.revisions)] {
            do { _ = try await j.restoreArchive(malformed); Issue.record("Malformed archive accepted") } catch {}
            #expect(try await j.exportArchive() == before)
            #expect(try await j.snapshot().workspace == state.workspace)
            #expect(await j.pending().map(\.id) == pending)
        }
    }

    @Test func literalLegacyFormatOneSurvivesDeltaReplayReopenAndMaterialize() async throws {
        // Literal old wire format: intentionally not generated by the new revision encoder.
        let oldJSON = #"""
        {"formatVersion":1,"id":"legacy-root","workspaceID":"regression","deviceID":"legacy-device","parents":[],"createdAt":800000000.123456,
         "immutableWorkspace":{"schemaVersion":1,"projects":[],"nodes":[],"items":[{"id":"free","name":"Legacy","projectIDs":[],"remainingMinutes":15,"energy":"normal","requiresContinuous":false,"status":"pending","needsReview":false}],"blockers":[],"dependencies":[],"acceptances":[],"history":[],"decisions":[],"workSessions":[]},
         "changes":[{"path":{"collection":"@workspace","entityID":"workspace","field":"schemaVersion"},"value":1},{"path":{"collection":"@sync","entityID":"workspace","field":"currentChoiceID"},"value":null},
         {"path":{"collection":"items","entityID":"free","field":"@exists"},"value":true},{"path":{"collection":"items","entityID":"free","field":"name"},"value":"Legacy"},
         {"path":{"collection":"items","entityID":"free","field":"energy"},"value":"normal"},{"path":{"collection":"items","entityID":"free","field":"requiresContinuous"},"value":false},
         {"path":{"collection":"items","entityID":"free","field":"@execution"},"value":{"projectIDs":[],"remainingMinutes":15,"status":"pending","needsReview":false}},{"path":{"collection":"items","entityID":"free","field":"@deadline"},"value":{}}]}
        """#
        let legacy = try SyncCoding.decode(SyncRevision.self, from: Data(oldJSON.utf8))
        #expect(legacy.formatVersion == 1 && legacy.immutableWorkspace.items.first?.name == "Legacy")
        #expect(try SyncCoding.decode(SyncRevision.self, from: SyncCoding.encode(legacy)) == legacy)
        let modernSameOperation = SyncRevision(id: legacy.id, workspaceID: legacy.workspaceID, deviceID: "restore-device",
            parents: legacy.parents, createdAt: legacy.createdAt, changes: legacy.changes)
        #expect(modernSameOperation.formatVersion == 2 && modernSameOperation.hasSameOperation(as: legacy))
        let merged = try SyncMerge.merge(revisions: [legacy, modernSameOperation], workspaceID: "regression")
        #expect(merged.conflicts.isEmpty && merged.heads == ["legacy-root"])
        let d = try SyncRegressionFixture.directory(); defer { try? FileManager.default.removeItem(at: d) }
        func loadAndClose() async throws -> String {
            let j = try await SyncRegressionFixture.seed(d, [legacy, modernSameOperation])
            var edit = try await j.snapshot().planningWorkspace; edit.items[0].name = "modern title"
            _ = try await j.record(workspace: edit, currentChoiceID: nil)
            return try #require(await j.pending().last?.id)
        }
        let latestID = try await loadAndClose(), reopened = try SyncRegressionFixture.journal(d)
        #expect(try await reopened.snapshot().workspace.items[0].name == "modern title")
        #expect(try await reopened.materialize(revisionID: "legacy-root").workspace.items[0].name == "Legacy")
        #expect(try await reopened.materialize(revisionID: latestID).workspace.items[0].name == "modern title")
        #expect(try await reopened.exportArchive().revisions.count == 2)
    }

    @Test func oneMiBHistoryFiftySmallTitleEditsPersistIncrementalRevisionBytes() async throws {
        let d = try SyncRegressionFixture.directory(); defer { try? FileManager.default.removeItem(at: d) }
        let payload = String(repeating: "H", count: 1_048_576)
        var w = SyncRegressionFixture.base
        w.history = [HistoryEvent(id: "large-history", date: SyncRegressionFixture.t, kind: .edited, objectID: "a", detail: payload)]
        let j = try SyncRegressionFixture.journal(d)
        _ = try await j.bootstrap(workspace: w)
        let initialRevisionBytes = try SyncRegressionFixture.bytes(in: d, revisionsOnly: true)
        for i in 1...50 {
            w.items[0].name = "small title \(i)"
            _ = try await j.record(workspace: w, currentChoiceID: nil)
        }
        let allIDs = try await j.exportArchive().revisions.map(\.id)
        var operations: [SyncRevision] = []
        for id in allIDs { operations.append(try #require(await j.revision(id: id))) }
        #expect(try await j.syncStatus().pendingCount == 51)
        let totalRevisionBytes = try SyncRegressionFixture.bytes(in: d, revisionsOnly: true)
        let totalDirectoryBytes = try SyncRegressionFixture.bytes(in: d, revisionsOnly: false)
        let wireBytes = try operations.reduce(0) { try $0 + SyncCoding.encode($1).count }
        print("SYNC_REGRESSION_BYTES history_bytes=1048576 title_edits=50 revisions=\(operations.count) bootstrap_revision_bytes=\(initialRevisionBytes) total_revision_bytes=\(totalRevisionBytes) directory_bytes=\(totalDirectoryBytes) wire_bytes=\(wireBytes)")
        #expect(initialRevisionBytes >= payload.utf8.count)
        #expect(operations.count == 51 && operations.allSatisfy { $0.formatVersion == 2 })
        // A generous bounded guard for small deltas; far below 50 MiB of repeated snapshots.
        #expect(totalRevisionBytes <= initialRevisionBytes + 50 * 16_384)
        #expect(totalDirectoryBytes <= initialRevisionBytes + 50 * 16_384 + 524_288)
        #expect(wireBytes <= initialRevisionBytes + 50 * 16_384)
        for operation in operations {
            let object = try #require(try JSONSerialization.jsonObject(with: SyncCoding.encode(operation)) as? [String: Any])
            #expect(object["immutableWorkspace"] == nil)
            if !operation.parents.isEmpty {
                #expect(operation.changes.count == 1 && operation.changes[0].path.field == "name")
                #expect(try SyncCoding.encode(operation).count < 16_384)
            }
        }
        let lastID = try #require(try await j.snapshot().heads.first)
        let materialized = try await j.materialize(revisionID: lastID)
        #expect(materialized.workspace.history.first { $0.id == "large-history" }?.detail == payload)
        #expect(materialized.workspace.items.first { $0.id == "a" }?.name == "small title 50")
    }
}
