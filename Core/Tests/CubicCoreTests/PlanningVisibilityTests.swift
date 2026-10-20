import Foundation
import Testing
@testable import CubicCore

@Suite struct PlanningVisibilityTests {
    private func visibility(_ w: Workspace) -> PlanningDisplay.PlanningVisibility {
        PlanningDisplay.PlanningVisibility(workspace: w) { Set($0.projectIDs) }
    }
    private func workspace() -> Workspace {
        Workspace(projects: [Project(id: "old", name: "Old", deadline: PRD.at(60), isArchived: true), PRD.project("live", 60)], items: [
            WorkItem(id: "old-work", name: "Old work", projectIDs: ["old"], remainingMinutes: 90),
            WorkItem(id: "shared", name: "Shared", projectIDs: ["old", "live"], remainingMinutes: 30),
            WorkItem(id: "live-work", name: "Live work", projectIDs: ["live"], remainingMinutes: 30)])
    }
    @Test func archivedRisksHideBeforeAggregationAndSharedConflictRetainsItsBound() {
        let w = workspace(), scope = visibility(w)
        let oldProject = Risk(kind: .conditionalUnlock, projectID: "old", itemIDs: ["shared"], message: "conditions")
        let oldGlobal = Risk(kind: .sharedResourceConflict, itemIDs: ["old-work"], shortageMinutes: 90, message: "cause")
        let liveGlobal = Risk(kind: .sharedResourceConflict, itemIDs: ["live-work"], shortageMinutes: 20, message: "cause")
        let mixed = Risk(kind: .sharedResourceConflict, itemIDs: ["old-work", "shared"], shortageMinutes: 30, message: "cause")
        let input = [oldProject, oldGlobal, liveGlobal, mixed]
        let rows = scope.risks(input, certificates: [], unknowns: [])
        #expect(rows.count == 1)
        #expect(rows[0].itemIDs == ["live-work", "shared"])
        #expect(rows[0].shortageMinutes == 30)
        #expect(PlanningDisplay.riskKey(rows[0]) == PlanningDisplay.riskKey(mixed))
        #expect(input[1].shortageMinutes == 90 && input[3].itemIDs == ["old-work", "shared"])
    }
    @Test func missingInformationKeepsCapacityAndOnlyVisibleSubjects() {
        let scope = visibility(workspace())
        let old = PlanningUnknown(objectID: "old-work", message: "unknown")
        let live = PlanningUnknown(objectID: "shared", message: "unknown")
        let capacity = PlanningUnknown(objectID: "capacity", message: "Calendar unverified")
        let risk = Risk(kind: .insufficientInformation, itemIDs: ["old-work", "shared"], message: "unknown")
        #expect(scope.unknowns([old, live, capacity]) == [live, capacity])
        #expect(scope.risks([risk], certificates: [], unknowns: [old]).isEmpty)
        let rows = scope.risks([risk], certificates: [], unknowns: [capacity])
        #expect(rows.count == 1 && rows[0].itemIDs == ["shared"])
    }
    @Test func emptyCompetitionDoesNotResurfaceWhenAllProjectsAreArchived() {
        let w = Workspace(projects: [Project(id: "old", name: "Old", isArchived: true)])
        let risk = Risk(kind: .sharedResourceConflict, message: "Unverified competition")
        #expect(visibility(w).risks([risk], certificates: [], unknowns: []).isEmpty)
    }
    @Test func archiveRestoreUsesCurrentVisibilityWithUnchangedEngineSnapshot() throws {
        var w = workspace()
        let plan = try PRD.plan(w, [PRD.slot(0, 60)])
        #expect(plan.legacy.risks.contains { $0.projectID == "old" })
        #expect(!visibility(w).risks(plan.legacy.risks, certificates: plan.certificates, unknowns: plan.unknowns).contains { $0.projectID == "old" })
        try w.setProjectArchived(id: "old", archived: false, now: PRD.t)
        #expect(visibility(w).risks(plan.legacy.risks, certificates: plan.certificates, unknowns: plan.unknowns).contains { $0.projectID == "old" })
        try w.setProjectArchived(id: "old", archived: true, now: PRD.at(1))
        #expect(try PRD.plan(w, [PRD.slot(0, 60)]).committedDemandMinutes == plan.committedDemandMinutes)
    }
    @Test func sharedEmptyNodesAndTheirWaitsAndGatesKeepVisibleUnknowns() {
        let w = Workspace(projects: [Project(id: "old", name: "Old", isArchived: true), Project(id: "live", name: "Live")], nodes: [
            Node(id: "hidden", projectID: "old", name: "Hidden", blockerIDs: ["hidden-wait"]),
            Node(id: "shared-node", projectID: "old", name: "Shared", blockerIDs: ["shared-wait"]),
            Node(id: "live-node", projectID: "live", name: "Live")], blockers: [
                Blocker(id: "hidden-wait", name: "Hidden wait"), Blocker(id: "shared-wait", name: "Shared wait")], acceptances: [
                Acceptance(id: "hidden-gate", subject: .node("hidden"), name: "Hidden gate"),
                Acceptance(id: "shared-gate", subject: .node("shared-node"), name: "Shared gate")], workLinks: [
                    WorkLink(source: .node("shared-node"), projectID: "live", nodeID: "live-node")])
        let scope = visibility(w)
        #expect(scope.objectIDs.isSuperset(of: ["live", "live-node", "shared-node", "shared-wait", "shared-gate", "capacity"]))
        #expect(scope.objectIDs.isDisjoint(with: ["old", "hidden", "hidden-wait", "hidden-gate"]))
    }
    @Test func emptyLaborProofUsesProjectScopeAndArchivedEvidenceIsHidden() throws {
        let w = workspace(), scope = visibility(w)
        let plan = try PRD.plan(w, [PRD.slot(0, 60)])
        let proof = try #require(plan.certificates.first)
        var archived = proof; archived.projectIDs = ["old", "other-archived"]; archived.itemIDs = []
        var live = archived; live.projectIDs = ["old", "live"]
        let risk = Risk(kind: .sharedResourceConflict, message: archived.message)
        #expect(scope.risks([risk], certificates: [archived], unknowns: []).isEmpty)
        #expect(scope.risks([risk], certificates: [live], unknowns: []).count == 1)
        #expect(scope.certificates([archived, live]) == [live])
        #expect(scope.certificates(plan.certificates).allSatisfy { $0.projectIDs != ["old"] })
    }
}
