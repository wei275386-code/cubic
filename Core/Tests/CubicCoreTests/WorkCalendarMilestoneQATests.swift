import Foundation
import Testing
@testable import CubicCore

private let wcNow = Date(timeIntervalSince1970: 1_900_000_000)
private func wcDate(_ minutes: Int) -> Date { wcNow.addingTimeInterval(Double(minutes) * 60) }
private func wcSlot(_ start: Int = 0, _ end: Int = 240, energy: Energy = .normal) -> CapacitySlot {
    CapacitySlot(start: wcDate(start), end: wcDate(end), energy: energy)
}

private func assertTimeBlockRejected(_ original: Workspace, _ block: WorkTimeBlock, slots: [CapacitySlot], busy: [BusyInterval] = [], sourceLocation: SourceLocation = #_sourceLocation) {
    var draft = original
    #expect(throws: (any Error).self, sourceLocation: sourceLocation) { try draft.setTimeBlock(block, slots: slots, busy: busy, now: wcNow) }
    #expect(draft == original, sourceLocation: sourceLocation)
}

@Suite(.serialized) struct WorkCalendarMilestoneQATests {
    @Test func deleteItemAtomicallyRemovesOperableIdentityAndKeepsHistoryAcrossStorage() throws {
        var workspace = Workspace(
            projects: [Project(id: "p", name: "Primary", deadline: wcDate(240), status: .completed, completedAt: wcDate(-20)),
                       Project(id: "q", name: "Shared", deadline: wcDate(240))],
            nodes: [Node(id: "n", projectID: "p", name: "Delivery", completedAt: wcDate(-10))],
            items: [WorkItem(id: "delete-me", name: "QA delete", nodeID: "n", projectIDs: ["p", "q"], remainingMinutes: 60),
                    WorkItem(id: "downstream", name: "Downstream", projectIDs: ["p"], remainingMinutes: 0, status: .completed, completedAt: wcDate(-5)),
                    WorkItem(id: "other", name: "Other", projectIDs: ["q"], remainingMinutes: 30)],
            blockers: [Blocker(id: "follow", name: "Follow", followUpItemID: "delete-me")],
            dependencies: [Dependency(id: "dep", source: .item("delete-me"), targetItemID: "downstream", createdAt: wcDate(-30), effectiveAt: wcDate(-30))],
            acceptances: [Acceptance(id: "gate", subject: .item("delete-me"), name: "Gate", state: .failed, failedAt: wcDate(-15), candidateItemIDs: ["delete-me", "other"])],
            workSessions: [WorkSession(id: "session", itemID: "delete-me", start: wcDate(-120), end: wcDate(-90), actualMinutes: 30)],
            workLinks: [WorkLink(id: "link", source: .item("delete-me"), projectID: "q")],
            reviews: [ReviewRecord(id: "review", itemID: "delete-me", date: wcDate(-80), outcome: .stillValid)],
            choices: [NextActionChoice(id: "choice", itemID: "delete-me", date: wcDate(-1), displayedItemIDs: ["delete-me", "other"])],
            currentChoiceID: "choice",
            timeBlocks: [WorkTimeBlock(id: "block", itemID: "delete-me", start: wcDate(30), end: wcDate(90))]
        )
        try workspace.validate()
        let before = workspace
        #expect(throws: (any Error).self) { try workspace.deleteItem(id: "missing", now: wcNow) }
        #expect(workspace == before)

        try workspace.deleteItem(id: "delete-me", now: wcNow)
        try workspace.validate()
        #expect(workspace.items.map(\.id).sorted() == ["downstream", "other"])
        #expect(workspace.deletedItems?.map(\.id) == ["delete-me"])
        #expect(workspace.workSessions.map(\.itemID) == ["delete-me"])
        #expect(workspace.reviews?.map(\.itemID) == ["delete-me"])
        #expect(workspace.dependencies.first?.removedAt == wcNow)
        #expect(workspace.acceptances.first?.removedAt == wcNow)
        #expect(workspace.acceptances.first?.candidateItemIDs == ["other"])
        #expect(workspace.workLinks?.first?.removedAt == wcNow)
        #expect(workspace.blockers.first?.followUpItemID == nil)
        #expect(workspace.currentChoiceID == nil)
        #expect(workspace.timeBlocks?.isEmpty == true)
        #expect(workspace.items.first { $0.id == "downstream" }?.needsReview == true)
        #expect(workspace.projects.first { $0.id == "p" }?.effectiveStatus == .active)
        #expect(workspace.projects.first { $0.id == "p" }?.completedAt == nil)
        #expect(workspace.history.contains { $0.kind == .deleted && $0.objectID == "delete-me" })
        let availableIDs = try Engine.availableActions(workspace: workspace, slots: [wcSlot()], now: wcNow).map(\.itemID)
        #expect(!availableIDs.contains("delete-me"))
        #expect(throws: (any Error).self) { try workspace.startItem(id: "delete-me", now: wcNow) }
        #expect(throws: (any Error).self) { try workspace.copyItem(id: "delete-me", projectID: "p", now: wcNow) }
        #expect(throws: (any Error).self) { try workspace.updateItem(WorkItem(id: "delete-me", name: "Zombie"), now: wcNow) }
        #expect(throws: (any Error).self) { try workspace.chooseNextAction(itemID: "delete-me", now: wcNow) }
        #expect(throws: (any Error).self) { try workspace.reworkItem(id: "delete-me", remainingMinutes: 10, now: wcNow) }

        #expect(try persistedCopy(workspace) == workspace)

        let legacyJSON = #"{"schemaVersion":1,"projects":[],"nodes":[],"items":[],"blockers":[],"dependencies":[],"acceptances":[],"history":[],"decisions":[],"workSessions":[]}"#
        let legacy = try JSONDecoder().decode(Workspace.self, from: Data(legacyJSON.utf8))
        #expect(legacy.deletedItems == nil && legacy.timeBlocks == nil)
        try legacy.validate()
    }

    @Test func timeBlockValidationIsAtomicAndCoversCalendarConstraints() throws {
        var base = Workspace(projects: [Project(id: "p", name: "P", deadline: wcDate(300))],
                             items: [WorkItem(id: "task", name: "Task", projectIDs: ["p"], remainingMinutes: 60),
                                     WorkItem(id: "low", name: "Low", projectIDs: ["p"], remainingMinutes: 30, energy: .low),
                                     WorkItem(id: "continuous", name: "Continuous", projectIDs: ["p"], remainingMinutes: 60, requiresContinuous: true),
                                     WorkItem(id: "unknown", name: "Unknown", projectIDs: ["p"], remainingMinutes: nil)])
        let slots = [wcSlot(0, 180)]
        let valid = WorkTimeBlock(id: "valid", itemID: "task", start: wcDate(30), end: wcDate(60))
        try base.setTimeBlock(valid, slots: slots, now: wcNow)
        #expect(base.timeBlocks == [valid])
        #expect(base.workSessions.isEmpty)
        #expect(base.items.first { $0.id == "task" }?.remainingMinutes == 60)
        let afterValid = base

        assertTimeBlockRejected(afterValid, WorkTimeBlock(id: "past", itemID: "task", start: wcDate(-10), end: wcDate(10)), slots: slots)
        assertTimeBlockRejected(afterValid, WorkTimeBlock(id: "empty", itemID: "task", start: wcDate(90), end: wcDate(90)), slots: slots)
        assertTimeBlockRejected(afterValid, WorkTimeBlock(id: "overlap", itemID: "low", start: wcDate(45), end: wcDate(75)), slots: slots)
        assertTimeBlockRejected(afterValid, WorkTimeBlock(id: "busy", itemID: "task", start: wcDate(90), end: wcDate(120)), slots: slots, busy: [BusyInterval(start: wcDate(100), end: wcDate(110))])
        assertTimeBlockRejected(afterValid, WorkTimeBlock(id: "energy", itemID: "task", start: wcDate(90), end: wcDate(120)), slots: [wcSlot(90, 120, energy: .low)])
        assertTimeBlockRejected(afterValid, WorkTimeBlock(id: "too-much", itemID: "task", start: wcDate(90), end: wcDate(130)), slots: slots)
        assertTimeBlockRejected(afterValid, WorkTimeBlock(id: "unknown", itemID: "unknown", start: wcDate(90), end: wcDate(120)), slots: slots)
        assertTimeBlockRejected(afterValid, WorkTimeBlock(id: "continuous", itemID: "continuous", start: wcDate(90), end: wcDate(120)), slots: slots)

        for mutation in ["completed", "cancelled", "deferred", "archived", "deleted"] {
            var draft = Workspace(projects: [Project(id: "p", name: "P")], items: [WorkItem(id: "x", name: "X", projectIDs: ["p"], remainingMinutes: 30)])
            switch mutation {
            case "completed": try draft.completeItem(id: "x", now: wcNow)
            case "cancelled": try draft.setItemDisposition(id: "x", disposition: .cancelled, now: wcNow)
            case "deferred": try draft.setItemDisposition(id: "x", disposition: .deferred, now: wcNow)
            case "archived": try draft.setArchived(.item("x"), archived: true, now: wcNow)
            case "deleted": try draft.deleteItem(id: "x", now: wcNow)
            default: break
            }
            let before = draft
            #expect(throws: (any Error).self) { try draft.setTimeBlock(WorkTimeBlock(id: mutation, itemID: "x", start: wcDate(10), end: wcDate(20)), slots: slots, now: wcNow) }
            #expect(draft == before)
        }

        try base.removeTimeBlock(id: "valid", now: wcNow)
        #expect(base.timeBlocks?.isEmpty == true)
        #expect(base.history.filter { $0.kind == .timeBlockChanged }.count == 2)
    }

    @Test func fixedCalendarBlocksReserveCapacityWithoutInventingProgressOrOverlappingTrials() throws {
        var workspace = Workspace(
            projects: [Project(id: "p", name: "P", deadline: wcDate(180), planningCompleteness: .complete)],
            items: [WorkItem(id: "a", name: "A", projectIDs: ["p"], remainingMinutes: 60),
                    WorkItem(id: "b", name: "B after A", projectIDs: ["p"], remainingMinutes: 30),
                    WorkItem(id: "c", name: "Independent C", projectIDs: ["p"], remainingMinutes: 30)],
            dependencies: [Dependency(id: "a-b", source: .item("a"), targetItemID: "b", createdAt: wcNow, effectiveAt: wcNow)]
        )
        try workspace.setTimeBlock(WorkTimeBlock(id: "fixed", itemID: "a", start: wcDate(30), end: wcDate(60)), slots: [wcSlot(0, 180)], now: wcNow)
        let plan = try Engine.plan(workspace: workspace, input: PlanningInput(slots: [wcSlot(0, 180)], now: wcNow))
        #expect(workspace.workSessions.isEmpty)
        #expect(workspace.items.first { $0.id == "a" }?.remainingMinutes == 60)
        let aAllocations = plan.witness.allocations.filter { $0.itemID == "a" }
        #expect(aAllocations.contains { $0.start == wcDate(30) && $0.end == wcDate(60) })
        #expect(aAllocations.allSatisfy { $0.end <= wcDate(30) || $0.start >= wcDate(30) })
        #expect(aAllocations.filter { $0.start < wcDate(60) && $0.end > wcDate(30) }.count == 1)
        #expect(aAllocations.filter { $0.start >= wcDate(60) }.reduce(0) { $0 + Int($1.end.timeIntervalSince($1.start) / 60) } == 30)
        #expect(plan.witness.eventTimes["item:a"].map { $0 >= wcDate(60) } == true)
        #expect(plan.witness.allocations.filter { $0.itemID == "b" }.allSatisfy { $0.start >= wcDate(60) })

        let single = try Engine.trial(workspace: workspace, request: PlanningTrialRequest(itemID: "a", minutes: 30, start: wcNow), input: PlanningInput(slots: [wcSlot(0, 180)], now: wcNow))
        #expect(single.allocations.allSatisfy { $0.start >= wcDate(60) })

        var invalidCondition = workspace
        try invalidCondition.setItemDisposition(id: "a", disposition: .deferred, now: wcDate(1))
        let degraded = try Engine.plan(workspace: invalidCondition, input: PlanningInput(slots: [wcSlot(0, 180)], now: wcNow))
        #expect(degraded.unknowns.contains { $0.objectID == "a" && $0.message.contains("时间块") })
        #expect(!degraded.witness.allocations.contains { $0.itemID == "a" && $0.start == wcDate(30) && $0.end == wcDate(60) })
    }

    @Test func thousandItemDeleteAndPlanningWithBlocksStayBounded() throws {
        let count = 1_200
        let blockCount = 240
        var workspace = Workspace(projects: [Project(id: "p", name: "Scale", deadline: wcDate(count + 600), planningCompleteness: .complete)],
                                  items: (0..<count).map { WorkItem(id: "item-\($0)", name: "Task \($0)", projectIDs: ["p"], remainingMinutes: 1) })
        workspace.timeBlocks = (0..<blockCount).map { WorkTimeBlock(id: "block-\($0)", itemID: "item-\($0)", start: wcDate($0 * 2), end: wcDate($0 * 2 + 1)) }
        try workspace.validate()
        let slots = [CapacitySlot(start: wcNow, end: wcDate(count + 600))]
        let planStart = Date()
        let plan = try Engine.plan(workspace: workspace, input: PlanningInput(slots: slots, now: wcNow))
        let planSeconds = Date().timeIntervalSince(planStart)
        let deleteStart = Date()
        try workspace.deleteItem(id: "item-10", now: wcNow)
        let deleteSeconds = Date().timeIntervalSince(deleteStart)
        print("WORK-CALENDAR-QA performance items=\(count) blocks=\(blockCount) plan_seconds=\(planSeconds) delete_seconds=\(deleteSeconds) allocations=\(plan.witness.allocations.count)")
        #expect(plan.witness.allocations.count >= count)
        #expect(workspace.timeBlocks?.contains { $0.itemID == "item-10" } == false)
        #expect(deleteSeconds < 2.0)
        #expect(planSeconds < 5.0)
    }
}
