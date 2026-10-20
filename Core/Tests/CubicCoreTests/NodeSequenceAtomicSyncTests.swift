import Foundation
import Testing
@testable import CubicCore

@Suite(.serialized) struct NodeSequenceAtomicSyncTests {
    private let t = Date(timeIntervalSince1970: 1_791_500_000)
    private let wid = "atomic-sequence-qa"
    private let sequence = SyncPath(collection: "projects", entityID: "p", field: SyncDocument.nodeSequence)
    private func base(chained: Bool = true) -> Workspace {
        var nodes = ["a", "b", "c"].enumerated().map { Node(id: $0.element, projectID: "p", name: $0.element, structureOrder: $0.offset + 1) }
        for i in nodes.indices { nodes[i].sequentialDependenciesInitialized = true; nodes[i].sequentialPredecessorNodeID = chained && i > 0 ? nodes[i - 1].id : nil }
        return Workspace(projects: [Project(id: "p", name: "P"), Project(id: "q", name: "Q")], nodes: nodes,
                         items: nodes.map { WorkItem(id: "i-" + $0.id, name: $0.name, nodeID: $0.id, projectIDs: ["p"], remainingMinutes: 10) })
    }
    private func pair(_ root: Workspace, _ left: Workspace, _ right: Workspace) throws -> [SyncRevision] {
        try root.validate(); try left.validate(); try right.validate()
        return [try SyncRevision.recording(workspace: root, id: "root", workspaceID: wid, deviceID: "root", parents: [], createdAt: t),
                try SyncRevision.recording(workspace: left, comparedTo: root, id: "left", workspaceID: wid, deviceID: "L", parents: ["root"], createdAt: t),
                try SyncRevision.recording(workspace: right, comparedTo: root, id: "right", workspaceID: wid, deviceID: "R", parents: ["root"], createdAt: t)]
    }
    private func journal(_ rs: [SyncRevision], at url: URL) async throws -> SyncJournal {
        let j = try SyncJournal(directory: url, workspaceID: wid, deviceID: "resolver")
        try await j.ingest(rs, cursor: nil); return j
    }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("AtomicSequenceQA-\(UUID().uuidString)") }
    private func assertChain(_ w: Workspace, project: String = "p", ids: [String]) {
        let nodes = w.projectStructure(projectID: project).nodes
        #expect(nodes.map(\.id) == ids)
        #expect(nodes.map(\.sequentialPredecessorNodeID) == ids.indices.map { $0 == 0 ? nil : ids[$0 - 1] })
        #expect(Set(nodes.compactMap(\.structureOrder)).count == nodes.count)
    }
    /// Construct the actual old per-node wire layout, not a new document mislabeled legacy.
    private func legacy(_ w: Workspace) throws -> SyncRevision {
        var values = try SyncDocument(w, choice: nil).values
        values = values.filter { $0.key.field != SyncDocument.nodeSequence }
        for node in w.nodes {
            if let order = node.structureOrder { values[SyncPath(collection: "nodes", entityID: node.id, field: "structureOrder")] = .number(Double(order)) }
            let path = SyncPath(collection: "nodes", entityID: node.id, field: SyncDocument.execution)
            var group = values[path]?.object ?? [:]
            if let pred = node.sequentialPredecessorNodeID { group["sequentialPredecessorNodeID"] = .string(pred) }
            values[path] = .object(group)
        }
        return SyncRevision(id: "legacy", workspaceID: wid, deviceID: "old", parents: [], createdAt: t,
                            changes: values.map { SyncChange(path: $0.key, value: $0.value) })
    }

    @Test(arguments: ["outcome", "required", "name", "noop", "reorder"])
    func legacyJournalMigratesOnlyActualSequenceOrExecutionEdits(edit: String) async throws {
        let root = base(), rs = [try legacy(root)], url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let j = try await journal(rs, at: url)
        let before = try await j.snapshot()
        #expect(before.rawValues[sequence] == nil)
        #expect(before.workspace.nodes == root.nodes)
        var w = before.planningWorkspace
        switch edit {
        case "outcome": w.nodes[1].outcome = "交付物"
        case "required": w.nodes[1].isRequired = false
        case "name": w.nodes[1].name = "新名称"
        case "reorder": try w.reorderProjectNodes(projectID: "p", orderedNodeIDs: ["c", "a", "b"], now: t)
        default: break
        }
        let after = try await j.record(workspace: w, currentChoiceID: nil)
        #expect(after.workspace.projectStructure(projectID: "p").nodes == w.projectStructure(projectID: "p").nodes)
        #expect(after.conflicts.isEmpty && after.planningIsValid)
        let archive = try await j.exportArchive()
        #expect(archive.revisions.count == (edit == "noop" ? 1 : 2))
        let writes = archive.revisions.filter { $0.id != "legacy" }.flatMap(\.changes)
        #expect(writes.filter { $0.path == sequence }.count == (["outcome", "required", "reorder"].contains(edit) ? 1 : 0))
        if edit == "name" { #expect(writes.map(\.path) == [SyncPath(collection: "nodes", entityID: "b", field: "name")]) }
        if edit == "noop" { #expect(writes.isEmpty) }
        let roundtrip = try SyncDocument.workspace(after.rawValues)
        #expect(roundtrip.nodes == after.workspace.nodes)
        try roundtrip.validate()
        // A second no-op must not add a migration or replay the old predecessor.
        _ = try await j.record(workspace: after.planningWorkspace, currentChoiceID: nil)
        #expect(try await j.exportArchive().revisions.count == archive.revisions.count)
    }

    @Test func legacyUnmanagedNilIsPreservedWhenExecutionSeedsRegister() async throws {
        var root = base(chained: false)
        root.nodes[2].sequentialPredecessorNodeID = "b"
        let url = directory(); defer { try? FileManager.default.removeItem(at: url) }
        let j = try await journal([try legacy(root)], at: url)
        var w = try await j.snapshot().planningWorkspace; w.nodes[1].outcome = "changed"
        let after = try await j.record(workspace: w, currentChoiceID: nil)
        #expect(after.workspace.projectStructure(projectID: "p").nodes.map(\.sequentialPredecessorNodeID) == [nil, nil, "b"])
        #expect(after.rawValues[sequence] != nil)
        try after.workspace.validate()
    }

    @Test(arguments: [false, true]) func concurrentAddsOrAddReorderKeepEveryNodeAfterEitherResolution(reorder: Bool) async throws {
        let root = base(); var left = root, right = root
        try left.addNode(Node(id: "d", projectID: "p", name: "D"), now: t)
        try left.addItem(WorkItem(id: "i-d", name: "D work", nodeID: "d", projectIDs: ["p"], remainingMinutes: 10), now: t)
        if reorder { try right.reorderProjectNodes(projectID: "p", orderedNodeIDs: ["c", "a", "b"], now: t) }
        else {
            try right.addNode(Node(id: "e", projectID: "p", name: "E"), now: t)
            try right.addItem(WorkItem(id: "i-e", name: "E work", nodeID: "e", projectIDs: ["p"], remainingMinutes: 10), now: t)
        }
        let rs = try pair(root, left, right)
        let merged = try SyncMerge.merge(revisions: rs, workspaceID: wid)
        let reverse = try SyncMerge.merge(revisions: rs.reversed(), workspaceID: wid)
        #expect(merged.workspace == reverse.workspace && merged.conflicts == reverse.conflicts)
        #expect(merged.conflicts.count == 1 && merged.conflicts.first?.paths == [sequence])
        #expect(Set(merged.workspace.nodes.map(\.id)) == Set(reorder ? ["a", "b", "c", "d"] : ["a", "b", "c", "d", "e"]))
        let tentative = merged.workspace.projectStructure(projectID: "p").nodes.map(\.id)
        assertChain(merged.workspace, ids: tentative)
        for chosen in ["left", "right"] {
            let url = directory(); defer { try? FileManager.default.removeItem(at: url) }
            let j = try await journal(rs, at: url), before = try await j.snapshot()
            let after = try await j.resolve(conflictID: #require(before.conflicts.first).id, choosingRevisionID: chosen)
            let expected = reorder ? (chosen == "left" ? ["a", "b", "c", "d"] : ["c", "a", "b", "d"]) : (chosen == "left" ? ["a", "b", "c", "d", "e"] : ["a", "b", "c", "e", "d"])
            assertChain(after.workspace, ids: expected)
            #expect(after.workspace.items.count == (reorder ? 4 : 5))
            #expect(after.conflicts.isEmpty && after.pausedItemIDs.isEmpty && after.planningIsValid)
            try after.workspace.validate()
            #expect(try SyncDocument.workspace(after.rawValues).nodes == after.workspace.nodes)
            let repository = try SQLiteWorkspaceRepository(url: url.appendingPathComponent("roundtrip.sqlite"))
            try repository.save(after.workspace)
            #expect(try repository.load() == after.workspace)
            #expect(try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(after.workspace)) == after.workspace)
        }
    }

    @Test func concurrentMoveAndReorderBridgeOnlyRemainingProjectMembers() async throws {
        var root = base(); try root.addNode(Node(id: "q-tail", projectID: "q", name: "Q tail"), now: t)
        var left = root, right = root
        try left.moveNode(id: "b", projectID: "q", now: t)
        try right.reorderProjectNodes(projectID: "p", orderedNodeIDs: ["b", "c", "a"], now: t)
        let rs = try pair(root, left, right), merged = try SyncMerge.merge(revisions: rs, workspaceID: wid)
        #expect(merged.conflicts.count == 1 && merged.conflicts.first?.paths == [sequence])
        #expect(Set(merged.workspace.nodes.map(\.id)) == Set(root.nodes.map(\.id)))
        for chosen in ["left", "right"] {
            let url = directory(); defer { try? FileManager.default.removeItem(at: url) }
            let j = try await journal(rs, at: url), before = try await j.snapshot()
            let after = try await j.resolve(conflictID: #require(before.conflicts.first).id, choosingRevisionID: chosen)
            assertChain(after.workspace, ids: chosen == "left" ? ["a", "c"] : ["c", "a"])
            assertChain(after.workspace, project: "q", ids: ["q-tail", "b"])
            #expect(after.workspace.items.first { $0.id == "i-b" }?.projectIDs == ["q"])
            #expect(after.conflicts.isEmpty && after.pausedItemIDs.isEmpty && after.planningIsValid)
            try after.workspace.validate()
        }
    }

    @Test func concurrentMembershipChoicesRetainNodesAndSelectedProjectChain() async throws {
        var root = base()
        root.projects.append(Project(id: "r", name: "R"))
        try root.addNode(Node(id: "q-tail", projectID: "q", name: "Q tail"), now: t)
        try root.addNode(Node(id: "r-tail", projectID: "r", name: "R tail"), now: t)
        var left = root, right = root
        try left.moveNode(id: "b", projectID: "q", now: t)
        try right.moveNode(id: "b", projectID: "r", now: t)
        let rs = try pair(root, left, right)
        for chosen in ["left", "right"] {
            let url = directory(); defer { try? FileManager.default.removeItem(at: url) }
            let j = try await journal(rs, at: url)
            var current = try await j.snapshot()
            #expect(Set(current.workspace.nodes.map(\.id)) == Set(root.nodes.map(\.id)))
            #expect(current.conflicts.contains { $0.paths.contains(SyncPath(collection: "nodes", entityID: "b", field: SyncDocument.execution)) })
            // Both node and member work have explicit membership candidates. Resolve both
            // actual concurrentValue paths; do not hide a cross-register invariant.
            let ids = current.conflicts.filter { $0.kind == .concurrentValue }.map(\.id)
            #expect(ids.count == 2)
            for id in ids { current = try await j.resolve(conflictID: id, choosingRevisionID: chosen) }
            assertChain(current.workspace, ids: ["a", "c"])
            assertChain(current.workspace, project: "q", ids: chosen == "left" ? ["q-tail", "b"] : ["q-tail"])
            assertChain(current.workspace, project: "r", ids: chosen == "right" ? ["r-tail", "b"] : ["r-tail"])
            #expect(Set(current.workspace.nodes.map(\.id)) == Set(root.nodes.map(\.id)))
            #expect(current.conflicts.isEmpty && current.pausedItemIDs.isEmpty && current.planningIsValid)
            try current.workspace.validate()
        }
    }

    @Test func completionRacingSequenceChangeReviewsConsumedSourceAndKeepsFacts() throws {
        var root = base(); try root.completeItem(id: "i-a", now: t)
        var left = root, right = root
        try left.startItem(id: "i-b", now: t.addingTimeInterval(1))
        try left.completeItem(id: "i-b", now: t.addingTimeInterval(2))
        try right.reorderProjectNodes(projectID: "p", orderedNodeIDs: ["b", "a", "c"], now: t.addingTimeInterval(3))
        let rs = try pair(root, left, right), merged = try SyncMerge.merge(revisions: rs, workspaceID: wid)
        #expect(merged.workspace.items.first { $0.id == "i-b" }?.status == .completed)
        #expect(merged.planningWorkspace.items.first { $0.id == "i-b" }?.needsReview == true)
        #expect(merged.pausedItemIDs.contains("i-b"))
        #expect(merged.conflicts.contains { $0.kind == .invariant && $0.affectedItemIDs.contains("i-b") })
        #expect(merged.workspace.workRounds?.sorted { $0.id < $1.id } == left.workRounds?.sorted { $0.id < $1.id })
        let source = try #require(merged.workspace.workRounds?.first { $0.itemID == "i-b" }?.sources?.first)
        #expect(source.source == .node("a") && source.nodeID == "b")
        try merged.workspace.validate(); try merged.planningWorkspace.validate()
        assertChain(merged.workspace, ids: ["b", "a", "c"])
    }

    @Test(arguments: [false, true]) func concurrentSequenceAndRelationCycleCanRemoveManualRelation(shared: Bool) async throws {
        var root = base(); root.nodes.removeLast(); root.items.removeLast()
        var left = root, right = root
        try left.reorderProjectNodes(projectID: "p", orderedNodeIDs: ["b", "a"], now: t)
        if shared { right.workLinks = [WorkLink(id: "manual-link", source: .node("a"), projectID: "p", nodeID: "b")] }
        else { right.dependencies = [Dependency(id: "manual-edge", source: .item("i-a"), targetItemID: "i-b")] }
        let rs = try pair(root, left, right), url = directory(); defer { try? FileManager.default.removeItem(at: url) }
        let j = try await journal(rs, at: url), before = try await j.snapshot()
        let conflict = try #require(before.conflicts.first { $0.kind == .dependencyCycle })
        #expect(before.pausedItemIDs == Set(["i-a", "i-b"]))
        let after = try await j.resolveRelationships(conflictID: conflict.id, removingDependencyIDs: shared ? [] : ["manual-edge"], removingWorkLinkIDs: shared ? ["manual-link"] : [])
        #expect(after.conflicts.isEmpty && after.pausedItemIDs.isEmpty && after.planningIsValid)
        assertChain(after.workspace, ids: ["b", "a"])
        try after.workspace.validate()
    }

    @Test(arguments: ["name", "importance"])
    func otherProjectFieldsDoNotSeedEmptyNodesOrPauseExternalWork(field: String) throws {
        var root = base()
        root.items = [WorkItem(id: "external", name: "共享下游", projectIDs: ["q"], remainingMinutes: 10)]
        root.dependencies = [Dependency(id: "shared", source: .node("c"), targetItemID: "external")]
        var left = root, right = root
        if field == "name" { left.projects[0].name = "Left name"; right.projects[0].name = "Right name" }
        else { left.projects[0].importance = 1; right.projects[0].importance = 2 }
        let rs = try pair(root, left, right)
        let merged = try SyncMerge.merge(revisions: rs, workspaceID: wid)
        #expect(merged.conflicts.count == 1)
        #expect(merged.conflicts.first?.paths == [SyncPath(collection: "projects", entityID: "p", field: field)])
        #expect(merged.pausedItemIDs.isEmpty, "Only the sequence register adds project node seeds; other project fields keep their prior scope")
        #expect(merged.planningIsValid)
        assertChain(merged.workspace, ids: ["a", "b", "c"])
        try merged.workspace.validate()
    }

    @Test func sequenceConflictOnEmptyNodesPausesSharedDownstream() throws {
        var root = base(); root.items = [WorkItem(id: "external", name: "共享下游", projectIDs: ["q"], remainingMinutes: 10)]
        root.dependencies = [Dependency(id: "shared", source: .node("c"), targetItemID: "external")]
        var left = root, right = root
        try left.reorderProjectNodes(projectID: "p", orderedNodeIDs: ["b", "a", "c"], now: t)
        try right.reorderProjectNodes(projectID: "p", orderedNodeIDs: ["c", "b", "a"], now: t)
        let merged = try SyncMerge.merge(revisions: pair(root, left, right), workspaceID: wid)
        #expect(merged.conflicts.count == 1 && merged.conflicts.first?.paths == [sequence])
        #expect(merged.pausedItemIDs == ["external"], "Project sequence conflicts must seed node vertices even if no project member work exists")
    }
}
