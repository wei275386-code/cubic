import Foundation
import Testing
@testable import CubicCore

struct ProjectHierarchyEditingTests {
    private let now = Date(timeIntervalSince1970: 1_791_000_000)
    private func legacy() -> Workspace {
        Workspace(projects: [Project(id: "p", name: "年支出复盘")],
                  nodes: [Node(id: "n", projectID: "p", name: "支出分类")],
                  items: [WorkItem(id: "a", name: "消费分类校对", nodeID: "n", projectIDs: ["p"], remainingMinutes: 60),
                          WorkItem(id: "b", name: "标签化", nodeID: "n", projectIDs: ["p"], remainingMinutes: 30),
                          WorkItem(id: "c", name: "统计", nodeID: "n", projectIDs: ["p"], remainingMinutes: 20)])
    }
    @Test func backfillMatchesVisibleOrderAndRemovalSurvivesReload() throws {
        var workspace = legacy()
        try workspace.initializeSequentialDependencies(projectID: "p", now: now)
        #expect(workspace.dependencies.map(\.targetItemID) == ["b", "c"])
        #expect(workspace.dependencies.map(\.source) == [.item("a"), .item("b")])
        #expect(!workspace.reasons(for: "b").isEmpty)
        let edge = try #require(workspace.dependencies.first)
        try workspace.removeDependency(id: edge.id, now: now.addingTimeInterval(1))
        let restored = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(workspace))
        workspace = restored
        let before = workspace
        try workspace.initializeSequentialDependencies(projectID: "p", now: now.addingTimeInterval(2))
        #expect(workspace == before)
        #expect(workspace.dependencies.first?.removedAt != nil)
    }
    @Test func predecessorCandidatesOmitArchivedProjectNodesAndWork() throws {
        var workspace = Workspace(
            projects: [Project(id: "p1", name: "项目1"), Project(id: "live", name: "进行中")],
            nodes: [Node(id: "old-node", projectID: "p1", name: "旧节点"),
                    Node(id: "live-node", projectID: "live", name: "新节点"),
                    Node(id: "archived-node", projectID: "live", name: "已归档节点", isArchived: true)],
            items: [WorkItem(id: "old-work", name: "旧工作", nodeID: "old-node", projectIDs: ["p1"], remainingMinutes: 30),
                    WorkItem(id: "direct-old", name: "旧直属", projectIDs: ["p1"], remainingMinutes: 20),
                    WorkItem(id: "shared-home-old", name: "挂在旧节点", nodeID: "old-node", projectIDs: ["p1", "live"], remainingMinutes: 10),
                    WorkItem(id: "live-work", name: "新工作", nodeID: "live-node", projectIDs: ["live", "p1"], remainingMinutes: 25),
                    WorkItem(id: "independent", name: "独立工作", remainingMinutes: 15),
                    WorkItem(id: "archived-work", name: "已归档工作", nodeID: "live-node", projectIDs: ["live"], remainingMinutes: 5, isArchived: true),
                    WorkItem(id: "target", name: "当前工作", nodeID: "live-node", projectIDs: ["live"], remainingMinutes: 40)])
        try workspace.setProjectArchived(id: "p1", archived: true, now: now)
        #expect(workspace.nodes.first { $0.id == "old-node" }?.archived == false)
        #expect(workspace.items.first { $0.id == "old-work" }?.archived == false)
        #expect(workspace.predecessorNodeCandidates().map(\.id) == ["live-node"])
        #expect(workspace.predecessorItemCandidates(excluding: "target").map(\.id) == ["live-work", "independent"])
        #expect(workspace.predecessorNodeCandidates(keeping: "old-node").map(\.id) == ["old-node", "live-node"])
        #expect(workspace.predecessorItemCandidates(excluding: "target", keeping: "old-work").map(\.id) == ["old-work", "live-work", "independent"])
        try workspace.setProjectArchived(id: "p1", archived: false, now: now.addingTimeInterval(1))
        #expect(workspace.predecessorNodeCandidates().map(\.id) == ["old-node", "live-node"])
        #expect(workspace.predecessorItemCandidates(excluding: "target").map(\.id) == ["old-work", "direct-old", "shared-home-old", "live-work", "independent"])
    }
    @Test func predecessorWorkOffersFollowProjectThenNodeAndExplainCycles() throws {
        var workspace = Workspace(
            projects: [Project(id: "p", name: "年支出复盘"), Project(id: "q", name: "家庭财务整理")],
            nodes: [Node(id: "n1", projectID: "p", name: "支出分类", structureOrder: 1),
                    Node(id: "n2", projectID: "p", name: "账单整理", structureOrder: 2),
                    Node(id: "m", projectID: "q", name: "数据准备", structureOrder: 1)],
            items: [WorkItem(id: "a", name: "消费分类校对", nodeID: "n1", projectIDs: ["p"], remainingMinutes: 30, structureOrder: 1),
                    WorkItem(id: "b", name: "标签化", nodeID: "n1", projectIDs: ["p"], remainingMinutes: 45, structureOrder: 2),
                    WorkItem(id: "c", name: "核对账单", nodeID: "n2", projectIDs: ["p"], remainingMinutes: 20, structureOrder: 1),
                    WorkItem(id: "d", name: "直属整理", projectIDs: ["p"], remainingMinutes: 10),
                    WorkItem(id: "e", name: "导出消费记录", nodeID: "m", projectIDs: ["q"], remainingMinutes: 15, structureOrder: 1),
                    WorkItem(id: "shared", name: "共享核对", nodeID: "m", projectIDs: ["q", "p"], remainingMinutes: 12, structureOrder: 2)])
        try workspace.addDependency(Dependency(id: "a-before-b", source: .item("a"), targetItemID: "b"), now: now)
        let offers = workspace.predecessorWorkOffers(for: "b", inProject: "p")
        #expect(offers.map(\.itemID) == ["a", "c", "shared", "d", "e"])
        #expect(offers.map(\.affiliation) == [
            "-＞支出分类-＞年支出复盘",
            "-＞账单整理-＞年支出复盘",
            "-＞数据准备-＞家庭财务整理",
            "-＞直属工作-＞年支出复盘",
            "-＞数据准备-＞家庭财务整理"
        ])
        #expect(offers.first { $0.itemID == "a" }?.cycleReason == nil)
        let reverse = try #require(workspace.predecessorWorkOffers(for: "a", inProject: "p").first { $0.itemID == "b" })
        #expect(reverse.cycleReason == "会互相等待：标签化 → 消费分类校对 → 标签化")
        try workspace.setProjectArchived(id: "q", archived: true, now: now.addingTimeInterval(1))
        let hidden = workspace.predecessorWorkOffers(for: "b", inProject: "p")
        #expect(hidden.map(\.itemID) == ["a", "c", "d"])
        let kept = workspace.predecessorWorkOffers(for: "b", inProject: "p", keeping: ["e"])
        #expect(kept.first { $0.itemID == "e" }?.name == "导出消费记录（已归档）")
        #expect(kept.first { $0.itemID == "e" }?.keptDespiteArchive == true)
    }
    @Test func addingWorkAppendsAfterLegacyMembersAndUsesLastAsPredecessor() throws {
        var workspace = legacy()
        try workspace.addItem(WorkItem(id: "d", name: "结论", nodeID: "n", projectIDs: ["p"], remainingMinutes: 15), now: now)
        #expect(workspace.projectStructure(projectID: "p").membersByNode["n"]?.map(\.id) == ["a", "b", "c", "d"])
        #expect(workspace.dependencies.last?.source == .item("c"))
        #expect(workspace.dependencies.last?.targetItemID == "d")
        let projected = try SyncDocument.workspace(SyncDocument(workspace, choice: nil).values)
        #expect(projected.projectStructure(projectID: "p").membersByNode["n"]?.map(\.id) == ["a", "b", "c", "d"])
        #expect(projected.nodes.first?.sequentialDependenciesInitialized == true)
    }
    @Test func markdownCreatesOnlySiblingDependenciesAndRespectsSourceOrder() throws {
        var workspace = Workspace.empty
        let id = try workspace.addMarkdownProject("年支出复盘\n- 支出分类\n  - 消费分类校对, 60min\n  - 标签化, 30min\n- 结论\n  - 写总结", now: now)
        #expect(workspace.dependencies.count == 1)
        #expect(workspace.dependencies.first?.source == .item(workspace.items[0].id))
        #expect(workspace.dependencies.first?.targetItemID == workspace.items[1].id)
        workspace.items.reverse()
        let node = try #require(workspace.nodes.first)
        #expect(workspace.projectStructure(projectID: id).membersByNode[node.id]?.map(\.name) == ["消费分类校对", "标签化"])
    }
    @Test func explicitGraphAndRemovedEdgesRemainAuthoritative() throws {
        var workspace = legacy()
        workspace.dependencies = [Dependency(id: "reverse", source: .item("b"), targetItemID: "a"),
                                  Dependency(id: "removed", source: .item("a"), targetItemID: "c", removedAt: now)]
        try workspace.initializeSequentialDependencies(projectID: "p", now: now)
        #expect(workspace.dependencies.count == 2, "Do not create a cycle or undo a deliberate removal")
        try workspace.validate()
    }
    @Test func movingWorkRepairsOnlyItsGeneratedSequence() throws {
        var workspace = legacy()
        try workspace.initializeSequentialDependencies(projectID: "p", now: now)
        try workspace.addNode(Node(id: "n2", projectID: "p", name: "总结"), now: now)
        try workspace.addItem(WorkItem(id: "d", name: "准备总结", nodeID: "n2", projectIDs: ["p"], remainingMinutes: 20), now: now)
        var moved = workspace.items[1]
        moved.nodeID = "n2"
        try workspace.updateItem(moved, now: now.addingTimeInterval(1))
        let active = workspace.dependencies.filter(\.isActive)
        #expect(active.count == 2)
        #expect(active.contains { $0.source == .item("a") && $0.targetItemID == "c" })
        #expect(active.contains { $0.source == .item("d") && $0.targetItemID == "b" })
        #expect(workspace.projectStructure(projectID: "p").membersByNode["n2"]?.map(\.id) == ["d", "b"])
        try workspace.validate()
    }
    @Test func durationChangesRecordTimestampAndValuesBeforeAndAfterStarting() throws {
        var workspace = legacy()
        try workspace.updateRemaining(itemID: "a", minutes: 90, now: now, reason: .revision)
        try workspace.startItem(id: "a", now: now.addingTimeInterval(10))
        try workspace.updateRemaining(itemID: "a", minutes: 45, now: now.addingTimeInterval(20), reason: .revision)
        let changes = workspace.estimateRevisions ?? []
        #expect(changes.map(\.minutes) == [90, 45])
        #expect(changes.map(\.previousMinutes) == [60, 90])
        #expect(changes.map(\.date) == [now, now.addingTimeInterval(20)])
        #expect(changes.allSatisfy { $0.reason == .revision })
    }
}
