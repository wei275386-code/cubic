import Foundation
import Testing
@testable import CubicCore

@Suite struct PlanningUnknownScopeQATests {
    @Test func removedHistoricalRelationshipDoesNotKeepCancelledUnknownInCurrentOptionalAction() throws {
        var workspace = Workspace(
            items: [WorkItem(id: "old", name: "Old", remainingMinutes: nil, disposition: .cancelled, isArchived: true),
                    WorkItem(id: "optional", name: "Current optional", remainingMinutes: 20, description: "Organized", isRequired: false)],
            dependencies: [Dependency(id: "past-edge", source: .item("old"), targetItemID: "optional", removedAt: PRD.t)])
        try workspace.validate()
        let original = workspace
        let current = try PRD.plan(workspace)
        #expect(!current.unknowns.contains { $0.objectID == "old" })
        #expect(current.legacy.availableActions.contains { $0.itemID == "optional" })
        #expect(workspace == original)
        workspace.dependencies[0].removedAt = nil
        let reconnected = try PRD.plan(workspace)
        #expect(reconnected.unknowns.contains { $0.objectID == "old" })
        #expect(!reconnected.legacy.availableActions.contains { $0.itemID == "optional" })
    }

    @Test func currentUndatedProjectReminderSurvivesButCancelledProjectReminderDoesNot() throws {
        let workspace = Workspace(
            projects: [Project(id: "live", name: "Live without deadline"),
                       Project(id: "old", name: "Cancelled without deadline", status: .cancelled, isArchived: true)],
            items: [WorkItem(id: "work", name: "Work", projectIDs: ["live"], remainingMinutes: 10),
                    WorkItem(id: "old-work", name: "Old", projectIDs: ["old"], remainingMinutes: nil, disposition: .cancelled, isArchived: true)])
        let plan = try PRD.plan(workspace)
        #expect(plan.unknowns.contains { $0.objectID == "live" })
        #expect(!plan.unknowns.contains { $0.objectID == "old" || $0.objectID == "old-work" })
        #expect(plan.projects.map(\.projectID) == ["live"])
        #expect(plan.knownDemandMinutes == 10)
    }
}
