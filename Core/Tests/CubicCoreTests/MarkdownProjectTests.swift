import Foundation
import Testing
@testable import CubicCore

struct MarkdownProjectTests {
    private let zone = TimeZone(identifier: "Asia/Singapore")!
    private var now: Date { ISO8601DateFormatter().date(from: "2026-10-07T10:00:00Z")! }
    private let sample = """
    家庭财务复盘, 10.10
    - 支出分类
        - 大额消费校对, 2h
        - 标签化, 2h
        - 数据分布统计, 1h
    - 复盘
        - 具体调整目标, 2h
    """

    @Test func userExampleCreatesOrderedStructureAndInitialEstimateFacts() throws {
        var workspace = Workspace.empty
        let id = try workspace.addMarkdownProject(sample, now: now, timeZone: zone)
        let project = try #require(workspace.projects.first)
        #expect(project.name == "家庭财务复盘")
        #expect(project.deadline == ISO8601DateFormatter().date(from: "2026-10-10T16:00:00Z")!.addingTimeInterval(-0.001))
        #expect(project.deadlineTimeZoneID == zone.identifier && project.deadlineIsDateOnly == true)
        #expect(workspace.nodes.map(\.name) == ["支出分类", "复盘"])
        #expect(workspace.items.map(\.name) == ["大额消费校对", "标签化", "数据分布统计", "具体调整目标"])
        #expect(workspace.items.map(\.remainingMinutes) == [120, 120, 60, 120])
        #expect(workspace.items.last?.nodeID == workspace.nodes.last?.id)
        #expect(workspace.items.allSatisfy { $0.projectIDs == [id] && $0.status == .pending && $0.initialMinutes == $0.remainingMinutes && $0.initialEstimateEventID != nil })
        #expect(workspace.history.filter { $0.kind == .created }.count == 7)
        #expect(workspace.dependencies.count == 2)
        #expect(workspace.estimateRevisions?.count == 4)
        try workspace.validate()
    }

    @Test func markdownVariantsAndParametersPreserveNamesAndOrder() throws {
        let text = "```markdown\r\n# 项目，2027/01/03\r\n\r\n1. 节点一\r\n\t+ 第一项，1.5H，2026-10-12\r\n\t* 第二项, 30min\r\n2) 空节点\r\n```"
        let draft = try MarkdownProjectParser.parse(text, now: now, timeZone: zone)
        #expect(draft.name == "项目")
        #expect(draft.nodes.map(\.name) == ["节点一", "空节点"])
        #expect(draft.nodes[0].works.map(\.estimatedMinutes) == [90, 30])
        #expect(draft.nodes[0].works[0].deadline != nil)
        #expect(draft.nodes[0].line == 4 && draft.nodes[0].works[0].line == 5)
        let commas = try MarkdownProjectParser.parse("项目, 特别说明\n- 节点\n  - 沟通, 客户反馈, 45分钟", now: now, timeZone: zone)
        #expect(commas.name == "项目, 特别说明")
        #expect(commas.nodes[0].works[0].name == "沟通, 客户反馈")
        #expect(commas.nodes[0].works[0].estimatedMinutes == 45)
        let mixedBranches = try MarkdownProjectParser.parse("项目\n- 节点一\n  - 第一项\n- 节点二\n    - 第二项", now: now, timeZone: zone)
        #expect(mixedBranches.nodes.map { $0.works.count } == [1, 1])
    }

    @Test func missingEstimateDefaultsToOneHourAndEmptyNodesRemainNodes() throws {
        let draft = try MarkdownProjectParser.parse("项目\n  - 空节点\n  - 有工作\n    - 未估计\n    - 零耗时, 0h", now: now, timeZone: zone)
        #expect(draft.nodes[0].works.isEmpty)
        #expect(draft.nodes[1].works.map(\.estimatedMinutes) == [60, 0])
        #expect(draft.deadline == nil)
        let titleOnly = try MarkdownProjectParser.parse("仅项目名称", now: now, timeZone: zone)
        #expect(titleOnly.nodes.isEmpty)
    }

    @Test func yearIsExplicitAndTimeZoneControlsDateOnlyEnd() throws {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let draft = try MarkdownProjectParser.parse("项目, 01.01", now: now, timeZone: tokyo)
        #expect(draft.deadline == ISO8601DateFormatter().date(from: "2026-01-01T15:00:00Z")!.addingTimeInterval(-0.001))
        #expect(try MarkdownProjectParser.parse("项目, 2028-02-29", now: now, timeZone: zone).deadline != nil)
    }

    @Test(arguments: [
        ("项目, 02.30", 1), ("项目, 2026-02-29", 1), ("项目, 13.01", 1),
        ("项目, 10.10, 10.11", 1), ("项目, 2h", 1),
        ("项目\n- 节点\n  - 工作, -2h", 3), ("项目\n- 节点\n  - 工作, 0.001h", 3),
        ("项目\n- 节点\n  - 工作, 999999999999999999999h", 3),
        ("项目\n- 节点\n  - 工作, 1h, 30min", 3),
        ("项目\n- 节点, 10.10", 2), ("项目\n- 节点, 2h", 2),
        ("项目\n- 节点\n  - 工作\n    - 超深工作", 4),
        ("项目\n  - 节点\n- 不一致的节点", 3), ("项目\n普通正文", 2),
        ("项目\n-", 2), ("- 缺少项目名称", 1), ("```md\n项目", 1), ("", 0)
    ])
    func invalidInputHasLineNumberAndNeverPartiallyCreates(_ text: String, _ line: Int) throws {
        var workspace = Workspace(projects: [Project(id: "existing", name: "保留")])
        let original = workspace
        do {
            try workspace.addMarkdownProject(text, now: now, timeZone: zone)
            Issue.record("应拒绝无效输入：\(text)")
        } catch let error as MarkdownProjectError {
            #expect(error.line == line)
            #expect(!error.message.isEmpty)
        }
        #expect(workspace == original)
    }

    @Test func sourceOrderSurvivesStorage() throws {
        var workspace = Workspace.empty
        let id = try workspace.addMarkdownProject(sample, now: now, timeZone: zone)
        // Force IDs to sort against source order to catch accidental ID-order projection.
        let nodeIDs = workspace.nodes.map(\.id)
        for i in workspace.nodes.indices {
            let replacement = "node-\(workspace.nodes.count - i)"
            workspace.nodes[i].id = replacement
            for j in workspace.history.indices where workspace.history[j].objectID == nodeIDs[i] { workspace.history[j].objectID = replacement }
            for j in workspace.items.indices where workspace.items[j].nodeID == nodeIDs[i] { workspace.items[j].nodeID = replacement }
            for j in workspace.nodes.indices where workspace.nodes[j].sequentialPredecessorNodeID == nodeIDs[i] {
                workspace.nodes[j].sequentialPredecessorNodeID = replacement
            }
        }
        // Renaming item IDs would also require renaming immutable estimate/history facts.
        workspace.items.reverse()
        let restored = try persistedCopy(workspace)
        let structure = restored.projectStructure(projectID: id)
        #expect(structure.nodes.map(\.name) == ["支出分类", "复盘"])
        #expect(structure.membersByNode[structure.nodes[0].id]?.map(\.name) == ["大额消费校对", "标签化", "数据分布统计"])
        #expect(structure.membersByNode[structure.nodes[1].id]?.map(\.name) == ["具体调整目标"])
        #expect(restored.items.map(\.structureOrder) == workspace.items.map(\.structureOrder))
    }
}
