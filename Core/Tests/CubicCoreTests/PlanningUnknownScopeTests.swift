import Foundation
import Testing
@testable import CubicCore

@Suite struct PlanningUnknownScopeTests {
    @Test func cancelledHistoricalScopeDoesNotCreateCurrentReminders() throws {
        var workspace = Workspace(
            projects: [Project(id: "old", name: "old", deadline: PRD.at(60))],
            nodes: [Node(id: "old-node", projectID: "old", name: "old-node")],
            items: [WorkItem(id: "old-work", name: "old-work", nodeID: "old-node", projectIDs: ["old"], remainingMinutes: nil)],
            blockers: [Blocker(id: "old-wait", name: "old-wait")],
            dependencies: [Dependency(id: "old-dependency", source: .blocker("old-wait"), targetItemID: "old-work")],
            acceptances: [Acceptance(id: "old-gate", subject: .node("old-node"), name: "old-gate", state: .failed, failedAt: PRD.t)])
        try workspace.archiveCurrentWorkspace(now: PRD.t)
        let original = workspace
        let plan = try PRD.plan(workspace)
        #expect(plan.unknowns.isEmpty)
        #expect(plan.summary.risks.isEmpty)
        #expect(plan.committedDemandMinutes == 0)
        #expect(plan.projects.isEmpty)
        #expect(workspace == original)
    }

    @Test func currentWorkKeepsItsCancelledAndArchivedAncestors() throws {
        let workspace = Workspace(
            projects: [Project(id: "old", name: "old", status: .cancelled, isArchived: true),
                       Project(id: "live", name: "live", deadline: PRD.at(120))],
            nodes: [Node(id: "old-node", projectID: "old", name: "old-node", isArchived: true)],
            items: [WorkItem(id: "old-work", name: "old-work", nodeID: "old-node", projectIDs: ["old"], remainingMinutes: nil, disposition: .cancelled, isArchived: true),
                    WorkItem(id: "live-work", name: "live-work", projectIDs: ["live"], remainingMinutes: 20)],
            blockers: [Blocker(id: "old-wait", name: "old-wait", isArchived: true)],
            dependencies: [Dependency(id: "wait", source: .blocker("old-wait"), targetItemID: "old-work"),
                           Dependency(id: "node", source: .node("old-node"), targetItemID: "live-work")],
            acceptances: [Acceptance(id: "old-gate", subject: .node("old-node"), name: "old-gate", state: .failed, failedAt: PRD.t)])
        let plan = try PRD.plan(workspace)
        #expect(Set(plan.unknowns.map(\.objectID)).isSuperset(of: ["old-work", "old-wait", "old-node"]))
        #expect(plan.projects.map(\.projectID) == ["live"])
        #expect(plan.summary.risks.contains { $0.kind == .insufficientInformation && $0.itemIDs.contains("old-work") })
    }

    @Test func optionalCurrentActionKeepsUnknownPrerequisites() throws {
        let workspace = Workspace(
            items: [WorkItem(id: "optional", name: "optional", remainingMinutes: 20, description: "organized", isRequired: false)],
            blockers: [Blocker(id: "wait", name: "wait"), Blocker(id: "unrelated", name: "unrelated")],
            dependencies: [Dependency(id: "dependency", source: .blocker("wait"), targetItemID: "optional")])
        let plan = try PRD.plan(workspace)
        #expect(plan.unknowns.contains { $0.objectID == "wait" })
        #expect(!plan.unknowns.contains { $0.objectID == "unrelated" })
        #expect(plan.knownDemandMinutes == 0)
    }

    @Test func archivedCommitmentIsStillCalculated() throws {
        let workspace = Workspace(
            projects: [Project(id: "p", name: "p", deadline: PRD.at(30), isArchived: true)],
            items: [WorkItem(id: "x", name: "x", projectIDs: ["p"], remainingMinutes: 60, isArchived: true)])
        let plan = try PRD.plan(workspace, [PRD.slot(0, 30)])
        #expect(plan.committedDemandMinutes == 60)
        #expect(plan.certificates.contains { $0.projectIDs == ["p"] && $0.shortageMinutes == 30 })
    }

    @Test func capacityUncertaintySurvivesAnEmptyCurrentScope() throws {
        let workspace = Workspace(items: [WorkItem(id: "old", name: "old", remainingMinutes: nil, disposition: .cancelled, isArchived: true)])
        let plan = try PRD.plan(workspace, options: PlanningOptions(capacityVerified: false, capacityNote: "capacity unchecked"))
        #expect(plan.unknowns.map(\.objectID) == ["capacity"])
        #expect(plan.summary.risks.contains { $0.kind == .insufficientInformation && $0.itemIDs.isEmpty })
    }
}
