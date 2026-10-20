import Foundation
import Testing
@testable import CubicCore

private let r2Now = Date(timeIntervalSince1970: 1_950_000_000)
private func r2Date(_ minute: Int) -> Date { r2Now.addingTimeInterval(Double(minute) * 60) }
private var r2Slots: [CapacitySlot] { [CapacitySlot(start: r2Now, end: r2Date(240), energy: .high)] }
private func r2Revision(_ value: Workspace, old: Workspace? = nil, id: String, parents: [String] = []) throws -> SyncRevision {
    try .recording(workspace: value, comparedTo: old, id: id, workspaceID: "round2", deviceID: id, parents: parents, createdAt: r2Now)
}

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

    @Test func journalActualRecordReopenAndOldArchiveCannotResurrectDeletedIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CubicR2Journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = Workspace(items: [WorkItem(id: "x", name: "Delete", remainingMinutes: 60), WorkItem(id: "keep", name: "Keep", remainingMinutes: 30)])
        func writeDeletion() async throws {
            let journal = try SyncJournal(directory: directory, workspaceID: "round2", deviceID: "local")
            _ = try await journal.bootstrap(workspace: base)
            var edited = try await journal.snapshot().planningWorkspace
            try edited.chooseNextAction(itemID: "x", now: r2Now)
            try edited.setTimeBlock(WorkTimeBlock(id: "b", itemID: "x", start: r2Date(20), end: r2Date(50)), slots: r2Slots, now: r2Now)
            _ = try await journal.record(workspace: edited, currentChoiceID: edited.currentChoiceID)
            try edited.deleteItem(id: "x", now: r2Date(1))
            let deleted = try await journal.record(workspace: edited, currentChoiceID: nil)
            #expect(deleted.planningIsValid)
            #expect(deleted.currentChoiceID == nil)
        }
        try await writeDeletion() // release the exclusive writer before reopening
        let reopened = try SyncJournal(directory: directory, workspaceID: "round2", deviceID: "local")
        let reopenedState = try await reopened.snapshot()
        #expect(reopenedState.planningIsValid)
        #expect(reopenedState.workspace.items.map(\.id) == ["keep"])
        #expect(reopenedState.workspace.timeBlocks?.isEmpty ?? true)
        // Import an old standalone snapshot as an independent causal branch.
        try await reopened.ingest([r2Revision(base, id: "old-backup")], cursor: nil, at: r2Date(2))
        let restored = try await reopened.snapshot()
        #expect(restored.planningIsValid)
        #expect(!restored.planningWorkspace.items.contains { $0.id == "x" })
        #expect(restored.currentChoiceID == nil)
        #expect(restored.workspace.deletedItems?.count == 1)
        try restored.planningWorkspace.validate()
    }

    @Test func concurrentNewReferencesChoiceAndTimeBlockCannotMakeDeletedWorkOperable() throws {
        let base = Workspace(projects: [Project(id: "p", name: "P", deadline: r2Date(240))],
                             items: [WorkItem(id: "x", name: "X", projectIDs: ["p"], remainingMinutes: 60), WorkItem(id: "y", name: "Y", projectIDs: ["p"], remainingMinutes: 30)])
        var deleted = base; try deleted.deleteItem(id: "x", now: r2Now)
        var offline = base
        try offline.setTimeBlock(WorkTimeBlock(id: "offline-block", itemID: "x", start: r2Date(20), end: r2Date(50)), slots: r2Slots, now: r2Now)
        try offline.chooseNextAction(itemID: "x", now: r2Now)
        try offline.addDependency(Dependency(id: "offline-dep", source: .item("x"), targetItemID: "y"), now: r2Now)
        try offline.addWorkLink(WorkLink(id: "offline-link", source: .item("x"), projectID: "p"), now: r2Now)
        let revisions = [try r2Revision(base, id: "root"), try r2Revision(deleted, old: base, id: "delete", parents: ["root"]),
                         try r2Revision(offline, old: base, id: "offline", parents: ["root"])]
        let forward = try SyncMerge.merge(revisions: revisions, workspaceID: "round2")
        let backward = try SyncMerge.merge(revisions: revisions.reversed(), workspaceID: "round2")
        #expect(forward.workspace == backward.workspace)
        #expect(forward.planningIsValid)
        #expect(forward.workspace.items.map(\.id) == ["y"])
        #expect(forward.currentChoiceID == nil)
        #expect(forward.planningWorkspace.currentNextAction == nil)
        #expect(forward.planningWorkspace.dependencies.first?.isActive == false)
        #expect(forward.planningWorkspace.workLinks?.first?.removedAt != nil)
        #expect(forward.planningWorkspace.timeBlocks?.isEmpty ?? true)
        #expect(forward.rawValues[SyncPath(collection: "dependencies", entityID: "offline-dep", field: "@execution")] != nil, "Original offline delta stays in audit")
        try forward.planningWorkspace.validate()
        _ = try Engine.plan(workspace: forward.planningWorkspace, input: forward.planningInput(PlanningInput(slots: r2Slots, now: r2Now)))
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

    @Test func timeBlockCreateMoveRemoveJournalSyncAndSharedCapacity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CubicR2TimeBlock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = Workspace(projects: [Project(id: "p", name: "P", deadline: r2Date(240)), Project(id: "q", name: "Q", deadline: r2Date(240))],
                             items: [WorkItem(id: "shared", name: "Shared", projectIDs: ["p", "q"], remainingMinutes: 60)])
        func writeAndMove() async throws {
            let j = try SyncJournal(directory: directory, workspaceID: "round2", deviceID: "local")
            _ = try await j.bootstrap(workspace: base)
            var w = base
            try w.setTimeBlock(WorkTimeBlock(id: "block", itemID: "shared", start: r2Date(30), end: r2Date(90)), slots: r2Slots, now: r2Now)
            let created = try await j.record(workspace: w, currentChoiceID: nil)
            #expect(created.planningIsValid && created.workspace.timeBlocks?.count == 1)
            let plan = try Engine.plan(workspace: created.planningWorkspace, input: PlanningInput(slots: r2Slots, now: r2Now))
            #expect(plan.witness.allocations.count == 1)
            #expect(plan.knownDemandMinutes == 60 && plan.committedDemandMinutes == 60)
            #expect(plan.legacy.capacityMinutes == 180)
            #expect(plan.projects.allSatisfy { $0.knownDemandMinutes == 60 })
            try w.setTimeBlock(WorkTimeBlock(id: "block", itemID: "shared", start: r2Date(60), end: r2Date(120)), slots: r2Slots, now: r2Now)
            let moved = try await j.record(workspace: w, currentChoiceID: nil)
            #expect(moved.planningIsValid)
            #expect(moved.workspace.timeBlocks?.count == 1 && moved.workspace.timeBlocks?.first?.start == r2Date(60))
            #expect(moved.workspace.items.first?.remainingMinutes == 60 && moved.workspace.workSessions.isEmpty)
        }
        try await writeAndMove()
        func removeAfterReopen() async throws {
            let j = try SyncJournal(directory: directory, workspaceID: "round2", deviceID: "local")
            var w = try await j.snapshot().planningWorkspace
            #expect(w.timeBlocks?.first?.start == r2Date(60))
            try w.removeTimeBlock(id: "block", now: r2Date(1))
            let removed = try await j.record(workspace: w, currentChoiceID: nil)
            #expect(removed.planningIsValid && (removed.workspace.timeBlocks?.isEmpty ?? true))
        }
        try await removeAfterReopen()
        let final = try SyncJournal(directory: directory, workspaceID: "round2", deviceID: "local")
        let result = try await final.snapshot()
        #expect(result.planningWorkspace.timeBlocks?.isEmpty ?? true)
        #expect(result.workspace.history.filter { $0.kind == .timeBlockChanged }.count == 3)
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
