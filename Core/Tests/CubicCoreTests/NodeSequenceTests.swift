import Foundation
import Testing
@testable import CubicCore

@Suite(.serialized) struct NodeSequenceTests {
    private let t = Date(timeIntervalSince1970: 1_791_500_000)
    private func base(_ ids: [String] = ["a", "b", "c"], chained: Bool = true) -> Workspace {
        var nodes = ids.enumerated().map { Node(id: $0.element, projectID: "p", name: "节点\($0.element)", structureOrder: $0.offset + 1) }
        for i in nodes.indices {
            nodes[i].sequentialDependenciesInitialized = true
            if chained, i > 0 { nodes[i].sequentialPredecessorNodeID = nodes[i - 1].id }
        }
        return Workspace(projects: [Project(id: "p", name: "P"), Project(id: "q", name: "Q")], nodes: nodes,
                         items: ids.map { WorkItem(id: "i-" + $0, name: "工作" + $0, nodeID: $0, projectIDs: ["p"], remainingMinutes: 10) })
    }
    private func predecessors(_ w: Workspace, _ project: String = "p") -> [String?] {
        w.projectStructure(projectID: project).nodes.map(\.sequentialPredecessorNodeID)
    }
    private func reject(_ w: inout Workspace, ids: [String]) {
        let before = w
        #expect(throws: CoreError.self) { try w.reorderProjectNodes(projectID: "p", orderedNodeIDs: ids, now: t) }
        #expect(w == before, "Rejected commands must preserve the complete workspace")
    }

    @Test func addUsesVisibleTailAndIsolatesProjects() throws {
        var w = Workspace(projects: [Project(id: "p", name: "P"), Project(id: "q", name: "Q")])
        for (id, p) in [("z", "p"), ("a", "p"), ("foreign", "q"), ("archived", "p")] {
            try w.addNode(Node(id: id, projectID: p, name: id), now: t)
        }
        try w.setArchived(.node("archived"), archived: true, now: t)
        try w.addNode(Node(id: "last", projectID: "p", name: "末尾", structureOrder: -10), now: t)
        #expect(w.projectStructure(projectID: "p").nodes.map(\.id) == ["z", "a", "last"])
        #expect(predecessors(w) == [nil, "z", "a"])
        #expect(predecessors(w, "q") == [nil])
        #expect(w.nodes.last?.structureOrder == 4)
        #expect(w.dependencies.isEmpty, "Node defaults are derived, not stored per work")
    }

    @Test func legacyDecodeQueriesAndAddDoNotBackfillOldNodes() throws {
        var w = base(chained: false)
        let data = try JSONEncoder().encode(w)
        w = try JSONDecoder().decode(Workspace.self, from: data)
        let before = w
        _ = DomainIndex(w); _ = w.projectStructure(projectID: "p")
        #expect(w == before && predecessors(w) == [nil, nil, nil])
        try w.addNode(Node(id: "d", projectID: "p", name: "D"), now: t)
        #expect(predecessors(w) == [nil, nil, nil, "c"])
        try w.reorderProjectNodes(projectID: "p", orderedNodeIDs: ["a", "b", "c", "d"], now: t)
        #expect(predecessors(w) == [nil, "a", "b", "c"])
    }

    @Test func everyMemberIncludesOptionalWorkIsBlockedForAllExecutionCommands() throws {
        var w = base(["a", "b"])
        w.items.append(WorkItem(id: "optional", name: "可选", nodeID: "b", projectIDs: ["p"], remainingMinutes: 5, isRequired: false))
        for id in ["i-b", "optional"] {
            let edges = w.unsatisfiedItemDependencies(itemID: id)
            #expect(edges.count == 1 && edges.first?.source == .node("a"))
            let before = w
            #expect(throws: CoreError.self) { try w.startItem(id: id, now: t) }
            #expect(throws: CoreError.self) { try w.completeItem(id: id, now: t) }
            #expect(throws: CoreError.self) { try w.recordWork(itemID: id, start: t, end: t.addingTimeInterval(60), actualMinutes: 1) }
            #expect(throws: CoreError.self) { try w.recordApproximateWork(itemID: id, occurredOn: t, recordedAt: t, actualMinutes: 1, remaining: .unchanged) }
            #expect(w == before)
        }
    }

    @Test func requiredWorkAndAcceptanceReleaseDownstreamAndPlanningMatches() throws {
        var w = base(["a", "b"])
        w.items.append(WorkItem(id: "optional", name: "可选", nodeID: "a", projectIDs: ["p"], remainingMinutes: 5, isRequired: false))
        w.acceptances = [Acceptance(id: "gate", subject: .node("a"), name: "交付验收")]
        try w.completeItem(id: "i-a", now: t)
        #expect(!w.sourceSatisfied(.node("a")))
        #expect(throws: CoreError.self) { try w.startItem(id: "i-b", now: t) }
        try w.accept(id: "gate", now: t.addingTimeInterval(1))
        #expect(w.sourceSatisfied(.node("a")))
        #expect(w.unsatisfiedItemDependencies(itemID: "i-b").isEmpty)
        #expect(w.items.last?.status == .pending, "Optional predecessor work does not gate the node")
        let graph = try PlanningGraph(workspace: w, input: PlanningInput(slots: [], now: t.addingTimeInterval(2)))
        #expect(graph.vertices["item:i-b"]?.predecessors.contains("node:a") == true)
        try w.startItem(id: "i-b", now: t.addingTimeInterval(2))
    }

    @Test func reorderChangesOrderAndChainButPreservesAllManualRelations() throws {
        var w = base()
        w.blockers = [Blocker(id: "wait", name: "等待")]
        w.nodes[1].blockerIDs = ["wait"]
        w.items.append(WorkItem(id: "direct", name: "直属", projectIDs: ["q"], remainingMinutes: 10))
        w.dependencies = [Dependency(id: "manual", source: .item("direct"), targetItemID: "i-b"),
                          Dependency(id: "removed", source: .item("i-a"), targetItemID: "i-c", removedAt: t)]
        w.workLinks = [WorkLink(id: "shared", source: .item("direct"), projectID: "p", nodeID: "b")]
        let dependencies = w.dependencies, links = w.workLinks, blockers = w.blockers
        try w.reorderProjectNodes(projectID: "p", orderedNodeIDs: ["c", "b", "a"], now: t)
        #expect(w.projectStructure(projectID: "p").nodes.map(\.id) == ["c", "b", "a"])
        #expect(predecessors(w) == [nil, "c", "b"])
        #expect(w.dependencies == dependencies && w.workLinks == links && w.blockers == blockers)
        #expect(w.nodes.first { $0.id == "b" }?.blockerIDs == ["wait"])
        let before = w
        try w.reorderProjectNodes(projectID: "p", orderedNodeIDs: ["c", "b", "a"], now: t.addingTimeInterval(1))
        #expect(w == before, "Unchanged reorder cannot add history or modify results")
    }

    @Test func cycleRollsBackResultsHistoryAndEveryObject() throws {
        var w = base(["a", "b"])
        w.dependencies = [Dependency(id: "manual", source: .item("i-a"), targetItemID: "i-b")]
        try w.completeItem(id: "i-a", now: t)
        try w.completeItem(id: "i-b", now: t.addingTimeInterval(1))
        try w.completeNode(id: "a", now: t.addingTimeInterval(2))
        try w.completeNode(id: "b", now: t.addingTimeInterval(3))
        try w.completeProject(id: "p", now: t.addingTimeInterval(4))
        let before = w
        do {
            try w.reorderProjectNodes(projectID: "p", orderedNodeIDs: ["b", "a"], now: t.addingTimeInterval(5))
            Issue.record("Expected node/manual edge cycle")
        } catch CoreError.cycle { }
        #expect(w == before)
    }

    @Test func duplicateCrossProjectMissingAndUnknownListsAreRejected() throws {
        var w = base()
        w.nodes.append(Node(id: "foreign", projectID: "q", name: "foreign"))
        for ids in [["a", "a", "c"], ["a", "b", "foreign"], ["a", "b"], ["a", "b", "unknown"], ["a", "b", "c", "c"]] {
            reject(&w, ids: ids)
        }
    }

    @Test func archiveKeepsExistingGateUntilExplicitReorder() throws {
        var w = base()
        try w.setArchived(.node("b"), archived: true, now: t)
        #expect(w.nodes.first { $0.id == "c" }?.sequentialPredecessorNodeID == "b")
        #expect(!w.unsatisfiedItemDependencies(itemID: "i-c").isEmpty)
        reject(&w, ids: ["a", "b", "c"])
        try w.reorderProjectNodes(projectID: "p", orderedNodeIDs: ["a", "c"], now: t)
        #expect(predecessors(w) == [nil, "a"])
        #expect(w.nodes.first { $0.id == "b" }?.sequentialPredecessorNodeID == nil)
    }

    @Test func jsonSQLiteAndSyncDocumentPreserveSequence() throws {
        var w = base()
        try w.reorderProjectNodes(projectID: "p", orderedNodeIDs: ["c", "a", "b"], now: t)
        let decoded = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(w))
        #expect(decoded == w)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NodeSequenceQA-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("qa.sqlite")
        try SQLiteWorkspaceRepository(url: url).save(w)
        #expect(try SQLiteWorkspaceRepository(url: url).load() == w)
        let sync = try SyncDocument.workspace(SyncDocument(w, choice: nil).values)
        // SyncDocument canonicalizes collection array order; compare facts by identity.
        #expect(sync.nodes.sorted { $0.id < $1.id } == w.nodes.sorted { $0.id < $1.id })
        #expect(sync.items.sorted { $0.id < $1.id } == w.items.sorted { $0.id < $1.id })
        #expect(sync.history.sorted { $0.id < $1.id } == w.history.sorted { $0.id < $1.id })
        #expect(predecessors(sync) == [nil, "c", "a"])
    }

    @Test func markdownAndBothTemplateRemapsUseNewNodeIdentities() throws {
        var w = Workspace.empty
        let projectID = try w.addMarkdownProject("QA 顺序\n- 第一节点\n  - 第一工作, 10min\n- 第二节点\n  - 第二工作, 10min\n- 第三节点\n  - 第三工作, 10min", now: t)
        let original = w.projectStructure(projectID: projectID).nodes
        #expect(original.map(\.sequentialPredecessorNodeID) == [nil, original[0].id, original[1].id])
        let templateID = try w.saveProjectTemplate(projectID: projectID, title: "顺序模板", now: t)
        let payload = try #require(w.projectTemplate(id: templateID)?.payload)
        #expect(Set(payload.nodes.map(\.id)).isDisjoint(with: Set(original.map(\.id))))
        #expect(payload.nodes.map(\.sequentialPredecessorNodeID) == [nil, payload.nodes[0].id, payload.nodes[1].id])
        let instanceID = try w.instantiateProjectTemplate(templateID: templateID, deadline: t.addingTimeInterval(86400), timeZoneID: "UTC", dateOnly: false, now: t)
        let instance = w.projectStructure(projectID: instanceID).nodes
        #expect(Set(instance.map(\.id)).isDisjoint(with: Set(payload.nodes.map(\.id) + original.map(\.id))))
        #expect(instance.map(\.sequentialPredecessorNodeID) == [nil, instance[0].id, instance[1].id])
        try w.validate()
    }

    @Test func moveRepairsSourceAndAppendsToTargetAndPreservesManualEdges() throws {
        var w = base()
        try w.addNode(Node(id: "target", projectID: "q", name: "目标"), now: t)
        w.dependencies = [Dependency(id: "manual", source: .item("i-a"), targetItemID: "i-b")]
        let edges = w.dependencies
        try w.moveNode(id: "b", projectID: "q", now: t)
        #expect(w.projectStructure(projectID: "p").nodes.map(\.id) == ["a", "c"])
        #expect(predecessors(w) == [nil, "a"])
        #expect(w.projectStructure(projectID: "q").nodes.map(\.id) == ["target", "b"])
        #expect(predecessors(w, "q") == [nil, "target"])
        #expect(w.items.first { $0.id == "i-b" }?.projectIDs == ["q"] && w.dependencies == edges)
        let before = w
        try w.moveNode(id: "b", projectID: "q", now: t)
        #expect(w == before)
    }

    @Test func reorderInvalidatesDownstreamButKeepsWorkFactsAndSourceSnapshots() throws {
        var w = base()
        w.acceptances = [Acceptance(id: "gate-b", subject: .node("b"), name: "B 验收"),
                         Acceptance(id: "gate-c", subject: .node("c"), name: "C 验收")]
        try w.completeItem(id: "i-a", now: t)
        try w.recordWork(itemID: "i-b", start: t.addingTimeInterval(60), end: t.addingTimeInterval(120), actualMinutes: 1)
        try w.completeItem(id: "i-b", now: t.addingTimeInterval(121))
        try w.accept(id: "gate-b", now: t.addingTimeInterval(121))
        try w.startItem(id: "i-c", now: t.addingTimeInterval(122))
        try w.completeItem(id: "i-c", now: t.addingTimeInterval(123))
        try w.accept(id: "gate-c", now: t.addingTimeInterval(123))
        try w.completeNode(id: "b", now: t.addingTimeInterval(124))
        try w.completeProject(id: "p", now: t.addingTimeInterval(125))
        let oldRounds = w.workRounds, oldSessions = w.workSessions, oldHistory = w.history
        let source = try #require(w.workRounds?.first { $0.itemID == "i-b" }?.sources?.first)
        #expect(source.source == .node("a") && source.nodeID == "b" && source.sourceRound == 1)
        #expect(nodeSequenceDependencyParts(source.dependencyID)?.predecessorID == "a")
        try w.reorderProjectNodes(projectID: "p", orderedNodeIDs: ["b", "a", "c"], now: t.addingTimeInterval(126))
        #expect(w.items.allSatisfy { $0.status == .completed && $0.completedAt != nil && $0.needsReview })
        #expect(w.workRounds == oldRounds && w.workSessions == oldSessions)
        #expect(Array(w.history.prefix(oldHistory.count)) == oldHistory)
        #expect(w.nodes.first { $0.id == "b" }?.completedAt == nil && w.projects[0].effectiveStatus == .active)
        #expect(w.acceptances.allSatisfy { $0.state == .pending && $0.acceptedAt == nil })
        #expect(Set((w.acceptanceResults ?? []).map(\.acceptanceID)) == Set(["gate-b", "gate-c"]))
        #expect(DomainIndex(w).sourcesUsed(for: "i-c").first?.source == .node("a"))
    }

    @Test func changedEmptyNodeStillInvalidatesNodeToNodeDownstream() throws {
        var w = base()
        w.items.removeAll { $0.nodeID == "b" }
        w.items[1].status = .completed; w.items[1].completedAt = t; w.items[1].remainingMinutes = 0
        try w.reorderProjectNodes(projectID: "p", orderedNodeIDs: ["b", "a", "c"], now: t)
        #expect(w.items.first { $0.id == "i-c" }?.needsReview == true)
        #expect(w.items.first { $0.id == "i-a" }?.needsReview == false)
    }

    @Test func movingMemberToSuccessorRepairsDefaultsBeforeValidation() throws {
        var w = base(["a"])
        try w.addItem(WorkItem(id: "middle", name: "中间工作", nodeID: "a", projectIDs: ["p"], remainingMinutes: 10), now: t)
        try w.addItem(WorkItem(id: "tail", name: "末尾工作", nodeID: "a", projectIDs: ["p"], remainingMinutes: 10), now: t)
        try w.addNode(Node(id: "b", projectID: "p", name: "后继节点"), now: t)
        try w.addItem(WorkItem(id: "i-b", name: "后继首工作", nodeID: "b", projectIDs: ["p"], remainingMinutes: 10), now: t)
        var moved = try #require(w.items.first { $0.id == "middle" }); moved.nodeID = "b"
        // Prove the intended final graph is valid, independent of the command's intermediate state.
        var expected = w
        expected.items[expected.items.firstIndex { $0.id == "middle" }!] = moved
        for i in expected.dependencies.indices where expected.dependencies[i].targetItemID == "middle" || expected.dependencies[i].source == .item("middle") {
            expected.dependencies[i].removedAt = t.addingTimeInterval(1)
        }
        expected.dependencies.append(Dependency(id: "expected-source", source: .item("i-a"), targetItemID: "tail"))
        expected.dependencies.append(Dependency(id: "expected-target", source: .item("i-b"), targetItemID: "middle"))
        try expected.validate()
        try w.updateItem(moved, now: t.addingTimeInterval(1))
        let active = w.dependencies.filter(\.isActive)
        #expect(active.contains { $0.source == .item("i-a") && $0.targetItemID == "tail" })
        #expect(active.contains { $0.source == .item("i-b") && $0.targetItemID == "middle" })
        try w.validate()
    }

    @Test func concurrentReordersKeepAtomicOrderAndResolveEitherWholeBranch() async throws {
        var root = base(["z", "y", "x"])
        root.items.append(WorkItem(id: "shared-downstream", name: "共享下游", projectIDs: ["q"], remainingMinutes: 10))
        root.items.append(WorkItem(id: "free", name: "独立", projectIDs: ["q"], remainingMinutes: 10))
        root.dependencies = [Dependency(id: "shared", source: .node("x"), targetItemID: "shared-downstream")]
        var left = root, right = root
        try left.reorderProjectNodes(projectID: "p", orderedNodeIDs: ["y", "z", "x"], now: t)
        try right.reorderProjectNodes(projectID: "p", orderedNodeIDs: ["z", "x", "y"], now: t)
        let r0 = try SyncRevision.recording(workspace: root, id: "root", workspaceID: "concurrent-order", deviceID: "qa", parents: [], createdAt: t)
        let a = try SyncRevision.recording(workspace: left, comparedTo: root, id: "left", workspaceID: "concurrent-order", deviceID: "a", parents: [r0.id], createdAt: t)
        let b = try SyncRevision.recording(workspace: right, comparedTo: root, id: "right", workspaceID: "concurrent-order", deviceID: "b", parents: [r0.id], createdAt: t)
        let merged = try SyncMerge.merge(revisions: [r0, a, b], workspaceID: "concurrent-order")
        let reverse = try SyncMerge.merge(revisions: [b, r0, a], workspaceID: "concurrent-order")
        #expect(merged.workspace == reverse.workspace && merged.conflicts == reverse.conflicts && merged.pausedItemIDs == reverse.pausedItemIDs)
        #expect(merged.conflicts.count == 1)
        #expect(merged.conflicts.first?.paths == [SyncPath(collection: "projects", entityID: "p", field: SyncDocument.nodeSequence)])
        let nodes = merged.workspace.projectStructure(projectID: "p").nodes
        #expect([left, right].contains { $0.projectStructure(projectID: "p").nodes == nodes })
        #expect(nodes.map(\.sequentialPredecessorNodeID) == [nil, nodes[0].id, nodes[1].id])
        #expect(merged.pausedItemIDs == Set(["i-x", "i-y", "i-z", "shared-downstream"]))
        try merged.workspace.validate()
        for (chosen, expected) in [("left", left), ("right", right)] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NodeSequenceConcurrentQA-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let journal = try SyncJournal(directory: directory, workspaceID: "concurrent-order", deviceID: "resolver")
            try await journal.ingest([r0, a, b], cursor: nil)
            let before = try await journal.snapshot()
            let conflict = try #require(before.conflicts.first)
            let resolved = try await journal.resolve(conflictID: conflict.id, choosingRevisionID: chosen)
            #expect(resolved.workspace.projectStructure(projectID: "p").nodes == expected.projectStructure(projectID: "p").nodes)
            #expect(resolved.conflicts.isEmpty && resolved.pausedItemIDs.isEmpty && resolved.planningIsValid)
            try resolved.workspace.validate()
            print("ATOMIC SEQUENCE resolved=\(chosen) order=\(resolved.workspace.projectStructure(projectID: "p").nodes.map(\.id)) conflicts=0 paused=0 planningValid=true")
        }
    }

    @Test(arguments: ["forward", "reorder", "independent-order"]) func syncSemanticConflictFollowsReorderedNodeGraphRegardlessOfStorageOrder(mode: String) throws {
        var root = base()
        let reversed = mode != "forward"
        if reversed { try root.reorderProjectNodes(projectID: "p", orderedNodeIDs: ["c", "b", "a"], now: t) }
        if mode == "independent-order" {
            // Legacy/imported structureOrder can differ from the managed chain. The domain accepts
            // such imported/merged facts; graph propagation must not rely on this order.
            for i in root.nodes.indices { root.nodes[i].structureOrder = i + 1 }
        }
        let sourceID = reversed ? "c" : "a"
        root.nodes[root.nodes.firstIndex { $0.id == sourceID }!].blockerIDs = ["wait"]
        root.blockers = [Blocker(id: "wait", name: "等待", state: .resolved, triggeredAt: t, resolvedAt: t)]
        root.dependencies = [Dependency(id: "wait-work", source: .blocker("wait"), targetItemID: "i-" + sourceID)]
        var left = root, right = root
        left.blockerRounds = [BlockerRound(id: "left-round", blockerID: "wait", round: 1, triggeredAt: t, resolvedAt: t)]
        right.blockerRounds = [BlockerRound(id: "right-round", blockerID: "wait", round: 1, triggeredAt: t, expectedDurationMinutes: 20, resolvedAt: t)]
        let r0 = try SyncRevision.recording(workspace: root, id: "root", workspaceID: "sequence", deviceID: "qa", parents: [], createdAt: t)
        let a = try SyncRevision.recording(workspace: left, comparedTo: root, id: "left", workspaceID: "sequence", deviceID: "a", parents: [r0.id], createdAt: t)
        let b = try SyncRevision.recording(workspace: right, comparedTo: root, id: "right", workspaceID: "sequence", deviceID: "b", parents: [r0.id], createdAt: t)
        let merged = try SyncMerge.merge(revisions: [r0, a, b], workspaceID: "sequence")
        print("NODE SEQUENCE SYNC mode=\(mode) conflict paths=\(merged.conflicts.map(\.paths)) paused=\(merged.pausedItemIDs.sorted())")
        #expect(merged.conflicts.contains { $0.kind == .semanticRecord })
        #expect(merged.pausedItemIDs == Set(["i-a", "i-b", "i-c"]), "All downstream members must pause even when reordered opposite to their storage order")
    }

    @Test func scale1000NodesAndWorksIndexedGraphReorderAndSyncMerge() throws {
        func scale(_ n: Int) throws -> (Double, Double, Double) {
            var w = base((0..<n).map { "n\($0)" })
            let start = Date()
            let graph = DomainIndex(w)
            #expect(graph.incoming.count == n - 1)
            #expect(graph.invalidationClosure(of: [.node("n0")]).itemIDs.count == n - 1)
            let indexed = Date().timeIntervalSince(start)
            let reorderStart = Date()
            try w.reorderProjectNodes(projectID: "p", orderedNodeIDs: Array(w.nodes.map(\.id).reversed()), now: t)
            let reorder = Date().timeIntervalSince(reorderStart)
            let revision = try SyncRevision.recording(workspace: w, id: "root", workspaceID: "scale", deviceID: "qa", parents: [], createdAt: t)
            let mergeStart = Date()
            let result = try SyncMerge.merge(revisions: [revision], workspaceID: "scale")
            let merge = Date().timeIntervalSince(mergeStart)
            #expect(result.planningIsValid && result.workspace.nodes.count == n && result.workspace.items.count == n)
            return (indexed, reorder, merge)
        }
        let small = try scale(250), large = try scale(1000)
        print("NODE SEQUENCE PERF debug/macOS nodes/works=250 index=\(small.0) reorder=\(small.1) merge=\(small.2); nodes/works=1000 index=\(large.0) reorder=\(large.1) merge=\(large.2)")
        #expect(large.0 < max(0.25, small.0 * 10))
        #expect(large.1 < max(2, small.1 * 10))
        #expect(large.2 < max(5, small.2 * 10))
    }
}
