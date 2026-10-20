import Foundation
import Testing
@testable import CubicCore

@Suite struct UXSimplificationTests {
    @Test func actionVisibilityHonorsProjectArchiveAndKeepsSharedAndIndependentWork() throws {
        var w = Workspace(projects: [Project(id: "old", name: "Archived", isArchived: true), Project(id: "current", name: "Current")], items: [
            WorkItem(id: "old-only", name: "Old", projectIDs: ["old"], remainingMinutes: 30),
            WorkItem(id: "shared", name: "Shared", projectIDs: ["old", "current"], remainingMinutes: 30),
            WorkItem(id: "current-only", name: "Current", projectIDs: ["current"], remainingMinutes: 30),
            WorkItem(id: "independent", name: "Independent", remainingMinutes: 30, description: "Organized"),
            WorkItem(id: "inbox", name: "Inbox"),
            WorkItem(id: "archived", name: "Archived item", projectIDs: ["current"], remainingMinutes: 30, isArchived: true),
            WorkItem(id: "cancelled", name: "Cancelled", projectIDs: ["current"], remainingMinutes: 30, disposition: .cancelled),
            WorkItem(id: "deferred", name: "Deferred", projectIDs: ["current"], remainingMinutes: 30, disposition: .deferred),
            WorkItem(id: "done", name: "Done", projectIDs: ["current"], remainingMinutes: 0, status: .completed, completedAt: PRD.t)])
        func visible(_ workspace: Workspace) -> Set<String> {
            Set(PlanningDisplay.actionItems(workspace: workspace) { Set($0.projectIDs) }.map(\.id))
        }
        #expect(visible(w) == ["shared", "current-only", "independent"])
        let items = w.items
        try w.setProjectArchived(id: "current", archived: true, now: PRD.t)
        #expect(visible(w) == ["independent"])
        #expect(w.items == items)
        try w.setProjectArchived(id: "old", archived: false, now: PRD.at(1))
        #expect(visible(w) == ["old-only", "shared", "independent"])
        #expect(w.items == items)
    }

    @Test func actionVisibilityUsesFullRelatedScopeEvenWithoutDirectProjectIDs() {
        let w = Workspace(projects: [Project(id: "old", name: "Archived", isArchived: true), Project(id: "current", name: "Current")], items: [
            WorkItem(id: "node-member", name: "Node member", remainingMinutes: 30),
            WorkItem(id: "linked", name: "Shared link", remainingMinutes: 30),
            WorkItem(id: "prerequisite", name: "Prerequisite", remainingMinutes: 30)])
        let related: [String: Set<String>] = ["node-member": ["old"], "linked": ["old", "current"], "prerequisite": ["old"]]
        #expect(PlanningDisplay.actionItems(workspace: w) { related[$0.id] ?? [] }.map(\.id) == ["linked"])
    }

    @Test func defaultEstimateIsCurrentIdempotentAndLeavesInboxUnconfigured() throws {
        var w = Workspace(items: [
            WorkItem(id: "inbox", name: "title only"),
            WorkItem(id: "work", name: "organized", remainingMinutes: nil, initialMinutes: 45, status: .inProgress, started: PRD.t,
                     description: "organized", preStartMinutes: 40, preStartCapturedAt: PRD.t),
            WorkItem(id: "zero", name: "zero", remainingMinutes: 0, description: "organized")])
        try w.applyDefaultRemainingEstimates(now: PRD.at(2))
        #expect(w.items[0].remainingMinutes == nil)
        #expect(w.items[1].remainingMinutes == 60)
        #expect(w.items[1].initialMinutes == 45 && w.items[1].preStartMinutes == 40)
        #expect(w.items[2].remainingMinutes == 0)
        let once = w
        try w.applyDefaultRemainingEstimates(now: PRD.at(3))
        #expect(w == once)
        let plan = try PRD.plan(Workspace(items: [w.items[0]]))
        #expect(plan.unknowns.isEmpty && plan.knownDemandMinutes == 0)
    }
    @Test func organizationStartsDefaultEstimatePolicy() throws {
        var w = Workspace(items: [WorkItem(id: "inbox", name: "title")])
        var item = w.items[0]; item.description = "now organized"
        try w.updateItem(item, now: PRD.t)
        try w.applyDefaultRemainingEstimates(now: PRD.t)
        #expect(w.items[0].remainingMinutes == 60)
        #expect(!w.items[0].isPendingInboxOrganization)
    }
    @Test func effortCountsRecordedAmountsEvenWhenIntervalsOverlapWithoutConfirmation() throws {
        var w = Workspace(items: [WorkItem(id: "a", name: "a"), WorkItem(id: "b", name: "b")])
        try w.recordWork(itemID: "a", start: PRD.t, end: PRD.at(60), actualMinutes: 60)
        try w.recordWork(itemID: "b", start: PRD.at(30), end: PRD.at(90), actualMinutes: 60)
        #expect(w.effortSummary().confirmedMinutes == 120)
        #expect(w.effortSummary().unresolvedSessionIDs.count == 2)
        #expect(w.items.allSatisfy { $0.effortRecordingComplete == nil })
    }
    @Test func overviewGroupsSameWorkAndKeepsAllRiskSourcesWithStableIdentity() {
        let capacity = Risk(kind: .provenCapacityShortfall, projectID: "p", itemIDs: ["a"], shortageMinutes: 30, message: "capacity")
        let energy = Risk(kind: .energyConstraint, projectID: "p", itemIDs: ["a"], shortageMinutes: 45, message: "energy")
        let first = PlanningDisplay.overviewRisks([capacity, energy])
        #expect(first.count == 1 && first[0].risks == [capacity, energy])
        #expect(first[0].primary.shortageMinutes == 45)
        var changed = energy; changed.shortageMinutes = 46
        #expect(PlanningDisplay.overviewRisks([capacity, changed])[0].id == first[0].id)
        let unknowns = PlanningDisplay.overviewUnknowns([
            PlanningUnknown(objectID: "a", message: "remaining"), PlanningUnknown(objectID: "a", message: "review"),
            PlanningUnknown(objectID: "a", message: "remaining")])
        #expect(unknowns == [PlanningUnknown(objectID: "a", message: "remaining\nreview")])
    }
}
