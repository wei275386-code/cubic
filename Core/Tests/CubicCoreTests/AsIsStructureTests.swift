import Foundation
import Testing
@testable import CubicCore

@Suite struct AsIsStructureTests {
    @Test func legacyScopeFlagsDoNotBlockDeliveryOrPlanning() throws {
        for completeness in [PlanningCompleteness?.none, .some(.incomplete)] {
            var workspace = Workspace(
                projects: [Project(id: "p", name: "p", deadline: PRD.at(120), planningCompleteness: completeness)],
                nodes: [Node(id: "n", projectID: "p", name: "n", planningCompleteness: completeness)],
                items: [WorkItem(id: "x", name: "x", nodeID: "n", projectIDs: ["p"], remainingMinutes: 20)],
                acceptances: [Acceptance(id: "g", subject: .node("n"), name: "g")])
            let plan = try PRD.plan(workspace)
            #expect(plan.projects.first?.scopeComplete == true)
            #expect(plan.projects.first?.totalDemandMinutes == 20)
            #expect(!plan.unknowns.contains { $0.objectID == "p" || $0.objectID == "n" })
            #expect(!workspace.nodeCompletionIssues(id: "n").contains { $0.contains("范围") })
            // Actual work and acceptance still gate delivery.
            #expect(throws: CoreError.self) { try workspace.completeNode(id: "n", now: PRD.at(1)) }
            try workspace.completeItem(id: "x", now: PRD.at(2))
            #expect(throws: CoreError.self) { try workspace.completeNode(id: "n", now: PRD.at(3)) }
            try workspace.accept(id: "g", now: PRD.at(4))
            try workspace.completeNode(id: "n", now: PRD.at(5))
            try workspace.completeProject(id: "p", now: PRD.at(6))
            #expect(workspace.projects[0].effectiveStatus == .completed)
        }
    }

    @Test func addingAndRemovingRequirementsAutomaticallyChangesShortfall() throws {
        var workspace = Workspace(projects: [Project(id: "p", name: "p", deadline: PRD.at(60))],
            items: [WorkItem(id: "x", name: "x", projectIDs: ["p"], remainingMinutes: 30)])
        #expect(try PRD.plan(workspace, [PRD.slot(0, 60)]).projects.first?.feasibility == .feasible)
        try workspace.addItem(WorkItem(id: "y", name: "y", projectIDs: ["p"], remainingMinutes: 60), now: PRD.t)
        let added = try PRD.plan(workspace, [PRD.slot(0, 60)])
        #expect(added.certificates.contains { $0.projectIDs == ["p"] && $0.shortageMinutes == 30 })
        var removed = workspace.items.first { $0.id == "y" }!
        removed.isRequired = false
        try workspace.updateItem(removed, now: PRD.t)
        let reduced = try PRD.plan(workspace, [PRD.slot(0, 60)])
        #expect(reduced.projects.first?.totalDemandMinutes == 30)
        #expect(reduced.projects.first?.feasibility == .feasible)
        #expect(reduced.certificates.isEmpty)
    }

    @Test func newRequiredWorkReopensDeliveredNodeAndProjectWithoutScopeConfirmation() throws {
        var workspace = Workspace(projects: [Project(id: "p", name: "p", deadline: PRD.at(120))],
            nodes: [Node(id: "n", projectID: "p", name: "n")],
            items: [WorkItem(id: "x", name: "x", nodeID: "n", projectIDs: ["p"], remainingMinutes: 20)],
            acceptances: [Acceptance(id: "g", subject: .node("n"), name: "g")])
        try workspace.completeItem(id: "x", now: PRD.at(1))
        try workspace.accept(id: "g", now: PRD.at(2))
        try workspace.completeNode(id: "n", now: PRD.at(3))
        try workspace.completeProject(id: "p", now: PRD.at(4))
        try workspace.addItem(WorkItem(id: "y", name: "y", nodeID: "n", projectIDs: ["p"], remainingMinutes: 10), now: PRD.at(5))
        #expect(workspace.projects[0].effectiveStatus == .active)
        #expect(workspace.nodes[0].completedAt == nil)
        #expect(!workspace.sourceSatisfied(.node("n")))
        #expect(workspace.acceptances[0].state == .pending)
        #expect(!workspace.projectCompletionIssues(id: "p").contains { $0.contains("范围") })
        try workspace.completeItem(id: "y", now: PRD.at(6))
        try workspace.accept(id: "g", now: PRD.at(7))
        try workspace.completeNode(id: "n", now: PRD.at(8))
        try workspace.completeProject(id: "p", now: PRD.at(9))
    }

    /// 已定决策：无显式验收条件的节点不再被排期当作信息缺口（由 unknown 翻 feasible）。
    @Test func defaultAcceptanceNodeIsNotPlanningUnknown() throws {
        var workspace = Workspace(
            projects: [Project(id: "p", name: "p", deadline: PRD.at(60))],
            nodes: [Node(id: "n", projectID: "p", name: "n")],
            items: [WorkItem(id: "x", name: "x", nodeID: "n", projectIDs: ["p"], remainingMinutes: 30)])
        let plan = try PRD.plan(workspace, [PRD.slot(0, 60)])
        #expect(!plan.unknowns.contains { $0.objectID == "n" })
        #expect(plan.projects.first?.feasibility == .feasible)
        #expect(plan.projects.first?.totalDemandMinutes == 30)
        try workspace.completeItem(id: "x", now: PRD.at(1))
        #expect(workspace.sourceSatisfied(.node("n")))
    }

    /// 旧数据重新解释检测：只认旧版明确的“非必需”条件，避免对全新用户误报。
    @Test func acceptanceReinterpretationNoticeOnlyForLegacyOptionalConditions() {
        // 新语义下“有成员工作、无验收条件”是常态，不触发迁移提示。
        let defaultNode = Workspace(projects: [Project(id: "p", name: "p")],
            nodes: [Node(id: "n", projectID: "p", name: "n")],
            items: [WorkItem(id: "x", name: "x", nodeID: "n", projectIDs: ["p"], remainingMinutes: 10)])
        #expect(!defaultNode.needsAcceptanceReinterpretationNotice)
        let emptyNode = Workspace(projects: [Project(id: "p", name: "p")], nodes: [Node(id: "n", projectID: "p", name: "n")])
        #expect(!emptyNode.needsAcceptanceReinterpretationNotice)
        let explicit = Workspace(projects: [Project(id: "p", name: "p")],
            nodes: [Node(id: "n", projectID: "p", name: "n")],
            items: [WorkItem(id: "x", name: "x", nodeID: "n", projectIDs: ["p"], remainingMinutes: 10)],
            acceptances: [Acceptance(id: "g", subject: .node("n"), name: "g")])
        #expect(!explicit.needsAcceptanceReinterpretationNotice)
        var optional = explicit
        optional.acceptances[0].isRequired = false
        #expect(optional.needsAcceptanceReinterpretationNotice)
    }

    /// 边界：空节点 + 显式验收条件时，人工验收可背书完成（只有默认模式才要求成员工作）。
    @Test func emptyNodeWithExplicitAcceptanceCanComplete() throws {
        var workspace = Workspace(projects: [Project(id: "p", name: "p")], nodes: [Node(id: "n", projectID: "p", name: "n")])
        try workspace.addAcceptance(Acceptance(id: "g", subject: .node("n"), name: "g"), now: PRD.t)
        #expect(workspace.nodeCompletionIssues(id: "n").contains { $0.contains("必需验收未通过") })
        try workspace.accept(id: "g", now: PRD.at(1))
        #expect(workspace.nodeCompletionIssues(id: "n").isEmpty)
        try workspace.completeNode(id: "n", now: PRD.at(2))
        #expect(workspace.sourceSatisfied(.node("n")))
    }

    /// B1 回归：空节点（无必需成员、无验收条件）不得在排期中被当作已知/可行。
    @Test func emptyNodeIsPlanningUnknownNotFeasible() throws {
        let workspace = Workspace(projects: [Project(id: "p", name: "p", deadline: PRD.at(60))],
            nodes: [Node(id: "n", projectID: "p", name: "n")])
        let plan = try PRD.plan(workspace, [PRD.slot(0, 60)])
        #expect(plan.unknowns.contains { $0.objectID == "n" })
        #expect(plan.projects.first?.feasibility != .feasible)
    }

    /// B2 回归：把遗留“非必需”字段迁移为必需不得触发 reopen/resetGates。
    @Test func migratingLegacyOptionalFlagDoesNotReopenNode() throws {
        var w = Workspace(projects: [Project(id: "p", name: "p")], nodes: [Node(id: "n", projectID: "p", name: "n")],
            items: [WorkItem(id: "a", name: "a", nodeID: "n", projectIDs: ["p"], remainingMinutes: 10)],
            acceptances: [Acceptance(id: "g1", subject: .node("n"), name: "g1")])
        try w.completeItem(id: "a", now: PRD.at(1))
        try w.accept(id: "g1", now: PRD.at(2))
        try w.completeNode(id: "n", now: PRD.at(3))
        // 追加一条遗留“非必需”条件（addAcceptance 本身是范围变化，会 reopen），再完成节点。
        try w.addAcceptance(Acceptance(id: "g2", subject: .node("n"), name: "g2", isRequired: false), now: PRD.at(4))
        try w.accept(id: "g1", now: PRD.at(5))
        try w.accept(id: "g2", now: PRD.at(6))
        try w.completeNode(id: "n", now: PRD.at(7))
        #expect(w.sourceSatisfied(.node("n")))
        let before = w
        var g2 = w.acceptances.first { $0.id == "g2" }!
        g2.isRequired = true // 打开编辑器并保存：仅字段迁移，名称不变
        try w.updateAcceptance(g2, now: PRD.at(8))
        #expect(w.sourceSatisfied(.node("n")))
        #expect(w.nodes[0].completedAt == before.nodes[0].completedAt)
        #expect(w.acceptances.first { $0.id == "g1" }?.state == .accepted)
    }
}
