import Foundation
import Testing
@testable import CubicCore

// R3/R4/R5 prep only. Do not run before the next root milestone trigger.
private enum SyncReviewFixture {
    static let workspaceID = "review-regression"
    static let t = Date(timeIntervalSince1970: 1_800_000_000.123456)
    static var base: Workspace {
        Workspace(items: [WorkItem(id: "a", name: "A", remainingMinutes: 15),
                          WorkItem(id: "b", name: "B", remainingMinutes: 15),
                          WorkItem(id: "free", name: "Independent", remainingMinutes: 15)])
    }
    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CubicSyncReview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func journal(_ url: URL) throws -> SyncJournal {
        try SyncJournal(directory: url, workspaceID: workspaceID, deviceID: "local")
    }
    static func revision(_ workspace: Workspace, old: Workspace? = nil, id: String,
                         parents: [String] = [], device: String = "remote") throws -> SyncRevision {
        try .recording(workspace: workspace, comparedTo: old, id: id, workspaceID: workspaceID,
                       deviceID: device, parents: parents, createdAt: t)
    }
    static func archive(_ revisions: [SyncRevision]) -> SyncArchive {
        SyncArchive(workspaceID: workspaceID, revisions: revisions.map {
            SyncArchiveRevision(id: $0.id, parents: $0.parents, createdAt: $0.createdAt, changes: $0.changes)
        })
    }
    static func diskRevisions(_ url: URL) throws -> [SyncRevision] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "revision" }
            .map { try SyncCoding.decode(SyncRevision.self, from: Data(contentsOf: $0)) }
    }
    static func blockManifest(_ url: URL) throws -> Data {
        let manifest = url.appendingPathComponent("manifest.json")
        let bytes = try Data(contentsOf: manifest)
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        return bytes
    }
    static func unblockManifest(_ url: URL, bytes: Data) throws {
        let manifest = url.appendingPathComponent("manifest.json")
        try FileManager.default.removeItem(at: manifest)
        try bytes.write(to: manifest, options: .atomic)
    }
    static func gatedBranches(history: Bool, shared: Bool) throws -> [SyncRevision] {
        var workspace = Workspace(
            projects: [Project(id: "p", name: "P"), Project(id: "q", name: "Q")],
            nodes: [Node(id: "gate", projectID: "p", name: "Gate", blockerIDs: ["blocker"]),
                    Node(id: "shared", projectID: "q", name: "Shared"),
                    Node(id: "relay", projectID: "q", name: "Relay")],
            items: [WorkItem(id: "downstream", name: "D", remainingMinutes: 15),
                    WorkItem(id: "tail", name: "E", remainingMinutes: 15),
                    WorkItem(id: "free", name: "Independent", remainingMinutes: 15)],
            blockers: [Blocker(id: "blocker", name: "B", state: .resolved, triggeredAt: t, resolvedAt: t)],
            dependencies: [Dependency(id: "gate-d", source: .node("gate"), targetItemID: "downstream"),
                           Dependency(id: "d-e", source: .item("downstream"), targetItemID: "tail")])
        if shared {
            workspace.items.append(WorkItem(id: "shared-downstream", name: "Shared D", remainingMinutes: 15))
            workspace.workLinks = [WorkLink(id: "gate-shared", source: .node("gate"), projectID: "q", nodeID: "shared"),
                                   WorkLink(id: "shared-relay", source: .node("shared"), projectID: "q", nodeID: "relay")]
            workspace.dependencies.append(Dependency(id: "shared-d", source: .node("relay"), targetItemID: "shared-downstream"))
        }
        if history {
            workspace.history = [HistoryEvent(id: "h0", date: t, kind: .blockerResolved, objectID: "blocker", note: "original")]
        }
        try workspace.validate()
        var left = workspace, right = workspace
        if history {
            left.history.append(HistoryEvent(id: "h-a", date: t, kind: .blockerResolved, objectID: "blocker", note: "A", correctsEventID: "h0"))
            right.history.append(HistoryEvent(id: "h-z", date: t, kind: .blockerResolved, objectID: "blocker", note: "Z", correctsEventID: "h0"))
        } else {
            left.blockerRounds = [BlockerRound(id: "round-a", blockerID: "blocker", round: 1, triggeredAt: t, resolvedAt: t)]
            right.blockerRounds = [BlockerRound(id: "round-z", blockerID: "blocker", round: 1, triggeredAt: t, expectedDurationMinutes: 20, resolvedAt: t)]
        }
        try left.validate(); try right.validate()
        return [try revision(workspace, id: "root"),
                try revision(left, old: workspace, id: "left", parents: ["root"], device: "A"),
                try revision(right, old: workspace, id: "right", parents: ["root"], device: "Z")]
    }
}

private actor SyncReviewReconciliationTransport: SyncTransport {
    let postPush: Bool
    let token: Data
    private var pulls = 0
    private var offered: Set<String> = []
    init(postPush: Bool, token: Data) { self.postPush = postPush; self.token = token }
    func availability() async throws -> SyncAvailability { .available(accountID: "A") }
    func pull(cursor: Data?) async throws -> SyncPullPage {
        pulls += 1
        let reconcile = postPush ? pulls == 2 : pulls == 1
        return SyncPullPage(revisions: [], cursor: reconcile ? token : cursor, hasMore: false,
                            needsFullReconciliation: reconcile)
    }
    func push(_ revisions: [SyncRevision]) async throws -> Set<String> {
        offered.formUnion(revisions.map(\.id))
        // Leave recovery responsibility unacknowledged and durable for reopen assertions.
        throw SyncError.transport("review fake leaves reconciliation unacknowledged")
    }
    func offeredIDs() -> Set<String> { offered }
}

@Suite(.serialized) struct SyncReviewRegressionTests {
    @Test(arguments: [false, true])
    func failedRestoreThenSameActorRestoreRetainsEveryOutboxResponsibility(retrySameArchive: Bool) async throws {
        let directory = try SyncReviewFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = SyncReviewFixture.base
        let root = try SyncReviewFixture.revision(base, id: "root")
        var a = base; a.items[0].name = "Archive A fact"
        var b = base; b.items[1].name = "Archive B fact"
        let a1 = try SyncReviewFixture.revision(a, old: base, id: "A1", parents: ["root"])
        let b1 = try SyncReviewFixture.revision(b, old: base, id: "B1", parents: ["root"])
        let archiveA = SyncReviewFixture.archive([root, a1])
        let archiveB = SyncReviewFixture.archive([root, b1])
        func restoreOnOneActorThenClose() async throws {
            let journal = try SyncReviewFixture.journal(directory)
            try await journal.bindAccount("A")
            try await journal.ingest([root], cursor: nil)
            try await journal.acknowledge(["root"])
            #expect(await journal.pending().isEmpty)
            let manifestBytes = try SyncReviewFixture.blockManifest(directory)
            do { _ = try await journal.restoreArchive(archiveA); Issue.record("restore A manifest failure was hidden") }
            catch {}
            let persistedA = try #require(SyncReviewFixture.diskRevisions(directory).first { $0.id == "A1" })
            #expect(persistedA.hasSameOperation(as: a1))
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("restore-intent.json").path))
            try SyncReviewFixture.unblockManifest(directory, bytes: manifestBytes)
            // Deliberately keep this actor alive: reopening here would miss the R3 counterexample.
            _ = try await journal.restoreArchive(retrySameArchive ? archiveA : archiveB)
            let expected: Set<String> = retrySameArchive ? ["root", "A1"] : ["root", "A1", "B1"]
            #expect(Set(try await journal.exportArchive().revisions.map(\.id)) == expected)
            #expect(expected.isSubset(of: Set(await journal.pending().map(\.id))))
        }
        try await restoreOnOneActorThenClose()
        func reopenAndAckOnlyBThenClose() async throws {
            let reopened = try SyncReviewFixture.journal(directory)
            #expect(await reopened.boundAccountID() == "A")
            let expected: Set<String> = retrySameArchive ? ["root", "A1"] : ["root", "A1", "B1"]
            #expect(Set(try await reopened.exportArchive().revisions.map(\.id)) == expected)
            #expect(expected.isSubset(of: Set(await reopened.pending().map(\.id))))
            try await reopened.acknowledge(retrySameArchive ? ["root"] : ["root", "B1"])
            #expect(await reopened.pending().map(\.id) == ["A1"])
            #expect(try await reopened.syncStatus().pendingCount == 1)
            let result = try await reopened.snapshot()
            #expect(result.conflicts.isEmpty && result.planningIsValid)
            #expect(result.workspace.items.first { $0.id == "a" }?.name == "Archive A fact")
            if !retrySameArchive { #expect(result.workspace.items.first { $0.id == "b" }?.name == "Archive B fact") }
            #expect(try await reopened.materialize(revisionID: "A1").workspace == a)
            if !retrySameArchive { #expect(try await reopened.materialize(revisionID: "B1").workspace == b) }
        }
        try await reopenAndAckOnlyBThenClose()
        let reopenedAfterAck = try SyncReviewFixture.journal(directory)
        #expect(await reopenedAfterAck.pending().map(\.id) == ["A1"])
        #expect(try await reopenedAfterAck.syncStatus().pendingCount == 1)
    }

    @Test(arguments: [false, true])
    func reconciliationPageCursorAndRecoveryOutboxHaveOneAtomicCommit(includeStaged: Bool) async throws {
        let directory = try SyncReviewFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = SyncReviewFixture.base, oldToken = Data("old-expired-token".utf8), newToken = Data("new-scan-token".utf8)
        let root = try SyncReviewFixture.revision(base, id: "root")
        var remote = base; remote.items[1].name = "Remote page fact"
        let page = try SyncReviewFixture.revision(remote, old: base, id: "page", parents: ["root"])
        var childWorkspace = base; childWorkspace.items[2].name = "Staged fact"
        let child = try SyncReviewFixture.revision(childWorkspace, old: base, id: "child", parents: ["missing-parent"])
        let incoming = includeStaged ? [page, child] : [page]
        func faultAndRetryOnOneActorThenClose() async throws -> Set<String> {
            let journal = try SyncReviewFixture.journal(directory)
            try await journal.ingest([root], cursor: oldToken, at: SyncReviewFixture.t)
            var local = base; local.items[0].name = "Previously uploaded local fact"
            _ = try await journal.record(workspace: local, currentChoiceID: nil)
            let oldIDs = Set(await journal.pending().map(\.id)).union(["root"])
            try await journal.acknowledge(oldIDs)
            #expect(try await journal.syncStatus().pendingCount == 0)
            let oldRemoteAt = try await journal.syncStatus().remoteDataAt
            let manifestBytes = try SyncReviewFixture.blockManifest(directory)
            // Fault the single public ingest transaction, not a timing race between two actor calls.
            do {
                try await journal.ingest(incoming, cursor: newToken, at: SyncReviewFixture.t.addingTimeInterval(60),
                                         needsFullReconciliation: true)
                Issue.record("reconciliation manifest failure was hidden")
            } catch {}
            #expect(await journal.cursor() == oldToken)
            #expect(try await journal.syncStatus().pendingCount == 0)
            #expect(try await journal.syncStatus().remoteDataAt == oldRemoteAt)
            #expect(oldIDs.isSubset(of: Set(try SyncReviewFixture.diskRevisions(directory).map(\.id))))
            #expect(Set(incoming.map(\.id)).isSubset(of: Set(try SyncReviewFixture.diskRevisions(directory).map(\.id))))
            try SyncReviewFixture.unblockManifest(directory, bytes: manifestBytes)
            try await journal.ingest(incoming, cursor: newToken, at: SyncReviewFixture.t.addingTimeInterval(60),
                                     needsFullReconciliation: true)
            let allIDs = oldIDs.union(incoming.map(\.id))
            #expect(await journal.cursor() == newToken)
            #expect(try await journal.syncStatus().pendingCount == allIDs.count)
            #expect(Set(try await journal.exportArchive().revisions.map(\.id)) == allIDs)
            return allIDs
        }
        let allIDs = try await faultAndRetryOnOneActorThenClose()
        let reopened = try SyncReviewFixture.journal(directory)
        #expect(await reopened.cursor() == newToken)
        #expect(try await reopened.syncStatus().pendingCount == allIDs.count)
        let closedIDs = allIDs.subtracting(includeStaged ? ["child"] : [])
        #expect(Set(await reopened.pending().map(\.id)) == closedIDs)
        let result = try await reopened.snapshot()
        #expect(result.planningIsValid && result.conflicts.isEmpty)
        #expect(result.workspace.items.first { $0.id == "a" }?.name == "Previously uploaded local fact")
        #expect(result.workspace.items.first { $0.id == "b" }?.name == "Remote page fact")
        try await reopened.acknowledge(closedIDs)
        #expect(try await reopened.syncStatus().pendingCount == (includeStaged ? 1 : 0))
        if includeStaged {
            #expect(try await reopened.syncStatus().missingParentIDs == ["missing-parent"])
            #expect(await reopened.pending().isEmpty)
            let parent = try SyncReviewFixture.revision(base, old: base, id: "missing-parent", parents: ["root"])
            try await reopened.ingest([parent], cursor: newToken)
            #expect(await reopened.pending().map(\.id) == ["child"])
            #expect(try await reopened.snapshot().workspace.items.first { $0.id == "free" }?.name == "Staged fact")
        }
    }

    @Test(arguments: [false, true])
    func coordinatorPropagatesRecoveryOnBothPullPathsAndReopenKeepsIt(postPush: Bool) async throws {
        let directory = try SyncReviewFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let token = Data("reconcile-new-token".utf8)
        func refreshAndClose() async throws {
            let journal = try SyncReviewFixture.journal(directory)
            try await journal.ingest([SyncReviewFixture.revision(SyncReviewFixture.base, id: "root")], cursor: Data("expired".utf8))
            try await journal.acknowledge(["root"])
            try await journal.bindAccount("A")
            let fake = SyncReviewReconciliationTransport(postPush: postPush, token: token)
            let status = await SyncCoordinator(journal: journal, transport: fake).refresh()
            #expect(status.phase == (postPush ? .pending : .failed))
            #expect(status.pendingCount == 1 && status.phase != .synced)
            #expect(await journal.cursor() == token)
            #expect(await journal.pending().map(\.id) == ["root"])
            #expect(await fake.offeredIDs() == (postPush ? [] : ["root"]))
        }
        try await refreshAndClose()
        let reopened = try SyncReviewFixture.journal(directory)
        #expect(await reopened.cursor() == token)
        #expect(await reopened.pending().map(\.id) == ["root"])
        #expect(try await reopened.exportArchive().revisions.map(\.id) == ["root"])
    }

    @Test(arguments: [false, true], [false, true])
    func blockerSemanticDisputeTraversesNodeGateAndItemClosureWithoutPausingFree(history: Bool, shared: Bool) async throws {
        let revisions = try SyncReviewFixture.gatedBranches(history: history, shared: shared)
        let forward = try SyncMerge.merge(revisions: revisions, workspaceID: SyncReviewFixture.workspaceID)
        let reverse = try SyncMerge.merge(revisions: Array(revisions.reversed()), workspaceID: SyncReviewFixture.workspaceID)
        #expect(forward.workspace == reverse.workspace && forward.conflicts == reverse.conflicts)
        #expect(forward.pausedItemIDs == reverse.pausedItemIDs && forward.planningIsValid)
        let collection = history ? "history" : "blockerRounds"
        let conflict = try #require(forward.conflicts.first { $0.kind == .semanticRecord && $0.paths.contains { $0.collection == collection } })
        let expected: Set<String> = shared ? ["downstream", "tail", "shared-downstream"] : ["downstream", "tail"]
        #expect(Set(conflict.affectedItemIDs) == expected)
        #expect(forward.pausedItemIDs == expected)
        #expect(!forward.pausedItemIDs.contains("free"))
        #expect(!forward.workspace.dependencies.contains { $0.source == .blocker("blocker") })
        #expect(forward.conflicts.count == 1) // isolate semantic scope; no other execution conflict can mask it
        let directory = try SyncReviewFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try SyncReviewFixture.journal(directory)
        try await journal.ingest(revisions, cursor: nil)
        let before = try await journal.exportArchive()
        let resolved = try await journal.resolveSemanticRecord(conflictID: conflict.id, choosingEntityID: history ? "h-z" : "round-z")
        #expect(resolved.conflicts.isEmpty && resolved.pausedItemIDs.isEmpty && resolved.planningIsValid)
        if history {
            #expect(Set(resolved.workspace.history.map(\.id)) == ["h0", "h-a", "h-z"])
            #expect(Set(resolved.planningWorkspace.history.map(\.id)) == ["h0", "h-z"])
        } else {
            #expect(Set((resolved.workspace.blockerRounds ?? []).map(\.id)) == ["round-a", "round-z"])
            #expect((resolved.planningWorkspace.blockerRounds ?? []).map(\.id) == ["round-z"])
        }
        #expect(Set(before.revisions.map(\.id)).isSubset(of: Set(try await journal.exportArchive().revisions.map(\.id))))
    }
}
