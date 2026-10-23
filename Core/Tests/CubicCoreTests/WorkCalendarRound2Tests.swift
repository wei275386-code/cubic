import Foundation
import Testing
@testable import CubicCore

private let r2Now = Date(timeIntervalSince1970: 1_950_000_000)
private func r2Date(_ minute: Int) -> Date { r2Now.addingTimeInterval(Double(minute) * 60) }
private var r2Slots: [CapacitySlot] { [CapacitySlot(start: r2Now, end: r2Date(240), energy: .high)] }

@Suite(.serialized) struct WorkCalendarRound2Tests {
    @Test func deletingMemberInvalidatesSharedNodeReferencesAndDownstreamResults() throws {
        var w = Workspace(
            projects: [Project(id: "p", name: "Source", status: .completed, completedAt: r2Date(-1)),
                       Project(id: "q", name: "Node consumer", status: .completed, completedAt: r2Date(-1))],
            nodes: [Node(id: "n", projectID: "p", name: "Source node", completedAt: r2Date(-2)),
                    Node(id: "shared", projectID: "q", name: "Shared node", completedAt: r2Date(-2))],
            items: [WorkItem(id: "source", name: "Source", nodeID: "n", projectIDs: ["p"], remainingMinutes: 0, status: .completed, completedAt: r2Date(-3)),
                    WorkItem(id: "down", name: "Downstream", projectIDs: ["q"], remainingMinutes: 0, status: .completed, completedAt: r2Date(-1))],
            dependencies: [Dependency(id: "node-down", source: .node("shared"), targetItemID: "down")],
            acceptances: [Acceptance(id: "n-gate", subject: .node("n"), name: "Source gate", state: .accepted, acceptedAt: r2Date(-2)),
                          Acceptance(id: "s-gate", subject: .node("shared"), name: "Shared gate", state: .accepted, acceptedAt: r2Date(-2))],
            workLinks: [WorkLink(id: "node-link", source: .node("n"), projectID: "q", nodeID: "shared")])
        try w.validate()
        try w.deleteItem(id: "source", now: r2Now)
        #expect(w.nodes.allSatisfy { $0.completedAt == nil })
        #expect(w.projects.allSatisfy { $0.effectiveStatus == .active })
        #expect(w.acceptances.allSatisfy { $0.state == .pending })
        #expect(w.items.first?.needsReview == true)
        #expect(w.workLinks?.first?.removedAt == nil, "A node reference stays, but its old result is invalidated")
        #expect(w.acceptanceResults?.count == 2)
    }

    @Test func changedContinuousRequirementAndReducedEstimateDegradePinnedBlock() throws {
        var w = Workspace(projects: [Project(id: "p", name: "P", deadline: r2Date(240))],
                          items: [WorkItem(id: "x", name: "X", projectIDs: ["p"], remainingMinutes: 60)])
        try w.setTimeBlock(WorkTimeBlock(id: "b", itemID: "x", start: r2Date(30), end: r2Date(60)), slots: r2Slots, now: r2Now)
        var continuous = w
        continuous.items[0].requiresContinuous = true; continuous.items[0].continuousMinutes = 60
        let invalidContinuous = try Engine.plan(workspace: continuous, input: PlanningInput(slots: r2Slots, now: r2Now))
        #expect(invalidContinuous.unknowns.contains { $0.objectID == "x" && $0.message.contains("时间块") })
        #expect(invalidContinuous.feasibility != .feasible)
        var estimate = w
        try estimate.updateRemaining(itemID: "x", minutes: 15, now: r2Now)
        let invalidEstimate = try Engine.plan(workspace: estimate, input: PlanningInput(slots: r2Slots, now: r2Now))
        #expect(invalidEstimate.unknowns.contains { $0.objectID == "x" && $0.message.contains("时间块") })
        #expect(invalidEstimate.legacy.capacityMinutes == 240)
        #expect(estimate.items[0].remainingMinutes == 15 && estimate.workSessions.isEmpty)
        let expired = try Engine.plan(workspace: w, input: PlanningInput(slots: r2Slots, now: r2Date(90)))
        #expect(expired.knownDemandMinutes == 60)
        #expect(!expired.witness.allocations.contains { $0.start == r2Date(30) })
        #expect(w.workSessions.isEmpty)
    }

    @Test func timeBlockCreateMoveRemoveStoreReopenAndSharedCapacity() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CubicR2TimeBlock-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let base = Workspace(projects: [Project(id: "p", name: "P", deadline: r2Date(240)), Project(id: "q", name: "Q", deadline: r2Date(240))],
                             items: [WorkItem(id: "shared", name: "Shared", projectIDs: ["p", "q"], remainingMinutes: 60)])
        do {
            let store = try WorkspaceStore(url: url, deviceID: "local")
            var w = base
            try w.setTimeBlock(WorkTimeBlock(id: "block", itemID: "shared", start: r2Date(30), end: r2Date(90)), slots: r2Slots, now: r2Now)
            let created = try await store.save(workspace: w).workspace
            #expect(created.timeBlocks?.count == 1)
            let plan = try Engine.plan(workspace: created, input: PlanningInput(slots: r2Slots, now: r2Now))
            #expect(plan.witness.allocations.count == 1)
            #expect(plan.knownDemandMinutes == 60 && plan.committedDemandMinutes == 60)
            #expect(plan.legacy.capacityMinutes == 180)
            #expect(plan.projects.allSatisfy { $0.knownDemandMinutes == 60 })
            try w.setTimeBlock(WorkTimeBlock(id: "block", itemID: "shared", start: r2Date(60), end: r2Date(120)), slots: r2Slots, now: r2Now)
            let moved = try await store.save(workspace: w).workspace
            #expect(moved.timeBlocks?.count == 1 && moved.timeBlocks?.first?.start == r2Date(60))
            #expect(moved.items.first?.remainingMinutes == 60 && moved.workSessions.isEmpty)
        }
        do {
            let store = try WorkspaceStore(url: url, deviceID: "local")
            var w = await store.document.workspace
            #expect(w.timeBlocks?.first?.start == r2Date(60))
            try w.removeTimeBlock(id: "block", now: r2Date(1))
            let removed = try await store.save(workspace: w).workspace
            #expect(removed.timeBlocks?.isEmpty ?? true)
        }
        let result = try await WorkspaceStore(url: url, deviceID: "local").document.workspace
        #expect(result.timeBlocks?.isEmpty ?? true)
        #expect(result.history.filter { $0.kind == .timeBlockChanged }.count == 3)
    }

    @Test func blockedWorkAndFailedBlockUpdateLeaveOriginalDraftUntouched() throws {
        var w = Workspace(items: [WorkItem(id: "x", name: "X", remainingMinutes: 60), WorkItem(id: "down", name: "Blocked", remainingMinutes: 30)],
                          blockers: [Blocker(id: "wait", name: "Waiting")],
                          dependencies: [Dependency(id: "wait-down", source: .blocker("wait"), targetItemID: "down")])
        try w.setTimeBlock(WorkTimeBlock(id: "b", itemID: "x", start: r2Date(30), end: r2Date(60)), slots: r2Slots, now: r2Now)
        let before = w
        #expect(throws: CoreError.self) { try w.setTimeBlock(WorkTimeBlock(id: "blocked", itemID: "down", start: r2Date(90), end: r2Date(120)), slots: r2Slots, now: r2Now) }
        #expect(w == before)
        #expect(throws: CoreError.self) { try w.setTimeBlock(WorkTimeBlock(id: "b", itemID: "x", start: r2Date(220), end: r2Date(250)), slots: r2Slots, now: r2Now) }
        #expect(w == before)
        #expect(throws: CoreError.self) { try w.setTimeBlock(WorkTimeBlock(id: "b", itemID: "down", start: r2Date(90), end: r2Date(120)), slots: r2Slots, now: r2Now) }
        #expect(w == before)
    }

    @Test func completedDeferredCancelledAndArchivedBlocksDoNotGhostReserveCapacity() throws {
        let base = Workspace(items: [WorkItem(id: "x", name: "X", remainingMinutes: 60)])
        for state in ["completed", "deferred", "cancelled", "archived"] {
            var w = base
            try w.setTimeBlock(WorkTimeBlock(id: "b", itemID: "x", start: r2Date(30), end: r2Date(60)), slots: r2Slots, now: r2Now)
            switch state {
            case "completed": try w.completeItem(id: "x", now: r2Now)
            case "deferred": try w.setItemDisposition(id: "x", disposition: .deferred, now: r2Now)
            case "cancelled": try w.setItemDisposition(id: "x", disposition: .cancelled, now: r2Now)
            default: try w.setArchived(.item("x"), archived: true, now: r2Now)
            }
            let planned = try CalendarPlanning(workspace: w, input: PlanningInput(slots: r2Slots, now: r2Now))
            #expect(planned.blocks.isEmpty)
            #expect(planned.reductions.isEmpty)
            #expect(w.workSessions.isEmpty)
        }
    }
}
