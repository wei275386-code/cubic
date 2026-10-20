import Foundation
import Testing
@testable import CubicCore

private let origin = Date(timeIntervalSince1970: 1_800_000_000)
private func date(_ minutes: Int) -> Date { origin.addingTimeInterval(Double(minutes) * 60) }
private func slots(_ minutes: Int = 90) -> [CapacitySlot] { [CapacitySlot(start: origin, end: date(minutes))] }

@Test func abcGoldenTrialAndElapsedActualWork() throws {
    var workspace = Workspace.demo(now: origin)
    let original = workspace
    let trial = try Engine.trial(workspace: workspace, selections: [TrialSelection(itemID: "item-a", minutes: 60)], slots: slots(), now: origin)
    #expect(workspace == original)
    #expect(trial.unallocatedMinutes == 0)
    #expect(trial.snapshot.capacityMinutes == 30)
    #expect(trial.snapshot.projects.first { $0.projectID == "project-b" }?.shortageMinutes == 30)
    #expect(trial.snapshot.itemStates.first { $0.itemID == "item-c" }?.isBlocked == true)
    #expect(trial.snapshot.risks.contains { $0.kind == .conditionalUnlock && $0.itemIDs.contains("item-c") })
    try workspace.recordDecision(trial, now: origin, note: "先做 A")
    #expect(workspace.items == original.items)
    try workspace.recordWork(itemID: "item-a", start: origin, end: date(40), actualMinutes: 40, remainingMinutes: 40)
    let after = try Engine.evaluate(workspace: workspace, slots: slots(), now: date(40))
    #expect(workspace.items.first { $0.id == "item-a" }?.remainingMinutes == 40)
    #expect(after.capacityMinutes == 50)
    #expect(after.projects.first { $0.projectID == "project-b" }?.shortageMinutes == 10)
    #expect(after.itemStates.first { $0.itemID == "item-c" }?.isBlocked == true)
    #expect(workspace.workSessions.count == 1)
    #expect(workspace.decisions.count == 1)
}

@Test func actualEffortAndUnknownRemainingAreIndependent() throws {
    var workspace = Workspace.demo(now: origin)
    try workspace.recordWork(itemID: "item-a", start: origin, end: date(10), actualMinutes: 10, remainingMinutes: 60)
    #expect(workspace.items[0].remainingMinutes == 60)
    try workspace.recordWork(itemID: "item-a", start: date(10), end: date(20), actualMinutes: 8, remainingMinutes: nil)
    #expect(workspace.items[0].remainingMinutes == nil)
    #expect(workspace.items[0].initialMinutes == 60)
    let result = try Engine.evaluate(workspace: workspace, slots: slots(), now: date(20))
    #expect(result.availableActions.first { $0.itemID == "item-a" }?.canFit == nil)
    #expect(result.risks.contains { $0.kind == .insufficientInformation })
}

@Test func gateAndReworkPreserveHistoryAndInvalidateStartedAndPendingDownstream() throws {
    var workspace = Workspace.demo(now: origin)
    try workspace.addItem(WorkItem(id: "item-d", name: "未开工下游", projectIDs: ["project-c"], remainingMinutes: 5), now: origin)
    try workspace.addDependency(Dependency(id: "a-d", source: .item("item-a"), targetItemID: "item-d"), now: origin)
    try workspace.addAcceptance(Acceptance(id: "gate-a", subject: .item("item-a"), name: "人工确认 A"), now: origin)
    try workspace.startItem(id: "item-a", now: origin)
    try workspace.completeItem(id: "item-a", now: date(1))
    // PRD AC014: item completion releases item edges before its gate.
    try workspace.startItem(id: "item-c", now: date(1))
    try workspace.accept(id: "gate-a", now: date(2))
    try workspace.completeItem(id: "item-c", now: date(4))
    let historyBefore = workspace.history
    try workspace.reworkItem(id: "item-a", remainingMinutes: 20, now: date(5), note: "验收发现返工")
    #expect(workspace.history.starts(with: historyBefore))
    #expect(workspace.items.first { $0.id == "item-c" }?.status == .completed)
    #expect(workspace.items.first { $0.id == "item-c" }?.needsReview == true)
    #expect(workspace.items.first { $0.id == "item-d" }?.status == .pending)
    #expect(workspace.items.first { $0.id == "item-d" }?.needsReview == false)
    #expect(workspace.acceptances[0].state == .pending)
    // PRD AC067: stillValid confirms the old downstream result without repairing upstream.
    try workspace.reviewItem(id: "item-c", now: date(6))
    #expect(!workspace.sourceSatisfied(.item("item-a")))
    try workspace.completeItem(id: "item-a", now: date(7))
    #expect(workspace.sourceSatisfied(.item("item-c")))
    try workspace.accept(id: "gate-a", now: date(8))
    #expect(workspace.items.first { $0.id == "item-c" }?.needsReview == false)
    let states = try Engine.evaluate(workspace: workspace, slots: slots(), now: date(9)).itemStates
    #expect(states.first { $0.itemID == "item-d" }?.isBlocked == false)
}

@Test func nodeCycleAndMembershipCycleRejectAtomically() throws {
    var workspace = Workspace.demo(now: origin)
    let before = workspace
    #expect(throws: CoreError.self) {
        try workspace.addDependency(Dependency(source: .node("node-c"), targetItemID: "item-a"), now: origin)
    }
    #expect(workspace == before)
    #expect(throws: CoreError.self) {
        try workspace.addDependency(Dependency(source: .node("node-a"), targetItemID: "item-a"), now: origin)
    }
    var emptyNodeWorkspace = Workspace(projects: [Project(id: "p", name: "项目")],
                                       nodes: [Node(id: "n", projectID: "p", name: "空节点")],
                                       items: [WorkItem(id: "x", name: "任务", projectIDs: ["p"])],
                                       dependencies: [Dependency(id: "n-x", source: .node("n"), targetItemID: "x")])
    let old = emptyNodeWorkspace
    #expect(throws: CoreError.self) {
        try emptyNodeWorkspace.addItem(WorkItem(id: "y", name: "新增成员", nodeID: "n", projectIDs: ["p"]), now: origin)
        try emptyNodeWorkspace.addDependency(Dependency(source: .item("x"), targetItemID: "y"), now: origin)
    }
    // The first command is valid, the failing second command keeps that member.
    #expect(emptyNodeWorkspace.items.count == old.items.count + 1)
    #expect(emptyNodeWorkspace.dependencies.count == old.dependencies.count)
}

@Test func blockerNeedsActualTriggerAndResolveDespiteExpectedDate() throws {
    var workspace = Workspace.demo(now: origin)
    try workspace.addBlocker(Blocker(id: "external", name: "等待外部材料", expectedResolution: date(5)), now: origin)
    try workspace.addDependency(Dependency(source: .blocker("external"), targetItemID: "item-b"), now: origin)
    // PRD AC021/023: inactive means not initiated, never satisfied.
    #expect(throws: CoreError.self) { try workspace.startItem(id: "item-b", now: origin) }
    try workspace.triggerBlocker(id: "external", now: date(1))
    let result = try Engine.evaluate(workspace: workspace, slots: slots(), now: date(20))
    #expect(result.itemStates.first { $0.itemID == "item-b" }?.isBlocked == true)
    #expect(workspace.blockers[0].state == .active)
    #expect(workspace.items.first { $0.id == "item-b" }?.needsReview == false)
    try workspace.resolveBlocker(id: "external", now: date(21))
    #expect(workspace.items.first { $0.id == "item-b" }?.needsReview == false)
    try workspace.startItem(id: "item-b", now: date(22))
    #expect(workspace.blockers[0].triggeredAt == date(1))
    #expect(workspace.blockers[0].resolvedAt == date(21))
}

@Test func overlappingBusyAndSlotsCountResourceOnceAndClipPast() throws {
    let workspace = Workspace.empty
    let windows = [CapacitySlot(start: origin, end: date(90)), CapacitySlot(start: date(20), end: date(70), energy: .high)]
    let busy = [BusyInterval(start: date(30), end: date(50)), BusyInterval(start: date(40), end: date(60))]
    let result = try Engine.evaluate(workspace: workspace, slots: windows, busy: busy, now: date(10))
    #expect(result.capacityMinutes == 50) // [10,30) + [60,90)
}

@Test func sharedItemIsNotCountedTwiceAndUnknownIsNotAutomaticallyInfeasible() throws {
    let projects = [Project(id: "p1", name: "项目一", deadline: date(60), planningCompleteness: .complete), Project(id: "p2", name: "项目二", deadline: date(60), planningCompleteness: .complete)]
    var workspace = Workspace(projects: projects, items: [WorkItem(id: "shared", name: "共同工作", projectIDs: ["p1", "p2"], remainingMinutes: 60)])
    let result = try Engine.evaluate(workspace: workspace, slots: slots(60), now: origin)
    #expect(result.feasibility == .feasible)
    #expect(!result.risks.contains { $0.kind == .sharedResourceConflict })
    workspace.items[0].remainingMinutes = nil
    let unknown = try Engine.evaluate(workspace: workspace, slots: [], now: origin)
    #expect(unknown.feasibility == .undetermined)
    #expect(!unknown.risks.contains { $0.kind == .provenCapacityShortfall })
}

@Test func energyAndContinuityAreRealConstraintsAndAdjacentEnergyCanJoin() throws {
    let project = Project(id: "p", name: "项目", deadline: date(60), planningCompleteness: .complete)
    var workspace = Workspace(projects: [project], items: [WorkItem(id: "x", name: "专注", projectIDs: ["p"], remainingMinutes: 40, energy: .high, requiresContinuous: true)])
    let windows = [CapacitySlot(start: origin, end: date(20), energy: .high), CapacitySlot(start: date(30), end: date(60), energy: .high)]
    let result = try Engine.evaluate(workspace: workspace, slots: windows, now: origin)
    #expect(result.capacityMinutes == 50)
    #expect(result.availableActions[0].canFit == false)
    #expect(result.feasibility == .infeasible)
    #expect(result.risks.contains { $0.kind == .continuousConstraint })
    workspace.items[0].requiresContinuous = false
    let lowOnly = try Engine.evaluate(workspace: workspace, slots: slots(60), now: origin)
    #expect(lowOnly.risks.contains { $0.kind == .energyConstraint })
    workspace.items[0].energy = .normal; workspace.items[0].requiresContinuous = true
    let adjacent = [CapacitySlot(start: origin, end: date(20)), CapacitySlot(start: date(20), end: date(60), energy: .high)]
    let joined = try Engine.evaluate(workspace: workspace, slots: adjacent, now: origin)
    #expect(joined.availableActions[0].longestContinuousMinutes == 60)
    #expect(joined.feasibility == .feasible)
}

@Test func noDeadlineDoesNotProveInfeasibleAndTrialDoesNotForceUnlock() throws {
    let workspace = Workspace(items: [WorkItem(id: "x", name: "未定期限", remainingMinutes: 100)])
    let result = try Engine.evaluate(workspace: workspace, slots: [], now: origin)
    #expect(result.feasibility == .undetermined)
    let trial = try Engine.trial(workspace: workspace, selections: [TrialSelection(itemID: "x", minutes: 100)], slots: [], now: origin)
    #expect(trial.unallocatedMinutes == 100)
    #expect(trial.snapshot.feasibility == .undetermined)
    #expect(throws: CoreError.self) {
        try Engine.trial(workspace: Workspace.demo(now: origin), selections: [TrialSelection(itemID: "item-c", minutes: 5)], slots: slots(), now: origin)
    }
}

@Test func subMinuteBusyProducesCeilingShortageRatherThanTruncation() throws {
    let workspace = Workspace(projects: [Project(id: "p", name: "项目", deadline: date(60), planningCompleteness: .complete)],
                              items: [WorkItem(id: "x", name: "任务", projectIDs: ["p"], remainingMinutes: 60)])
    let busy = [BusyInterval(start: origin, end: origin.addingTimeInterval(30))]
    let result = try Engine.evaluate(workspace: workspace, slots: slots(60), busy: busy, now: origin)
    #expect(result.capacityMinutes == 59)
    #expect(result.projects[0].shortageMinutes == 1)
    #expect(result.feasibility == .infeasible)
}

@Test func invalidDirectEditsAndFailedCommandsLeaveOriginalUntouched() throws {
    var workspace = Workspace.demo(now: origin)
    let before = workspace
    #expect(throws: CoreError.self) { try workspace.updateRemaining(itemID: "item-a", minutes: -1, now: origin) }
    #expect(workspace == before)
    workspace.items[0].projectIDs.append("project-a")
    #expect(throws: CoreError.self) { try workspace.validate() }
    workspace = before
    workspace.items[0].started = Date(timeIntervalSince1970: .nan)
    #expect(throws: CoreError.self) { try workspace.validate() }
}

@Test func continuousTrialCannotSplitKnownWorkIntoSeparateSelections() throws {
    let workspace = Workspace(projects: [Project(id: "p", name: "项目", deadline: date(60), planningCompleteness: .complete)],
                              items: [WorkItem(id: "x", name: "连续工作", projectIDs: ["p"], remainingMinutes: 40, requiresContinuous: true)])
    // PRD D13: keep the partial trial visible and unallocated; do not claim completion.
    let partial = try Engine.trial(workspace: workspace, selections: [TrialSelection(itemID: "x", minutes: 20)], slots: slots(60), now: origin)
    #expect(partial.allocations.isEmpty)
    #expect(partial.unallocatedMinutes == 20)
    let result = try Engine.trial(workspace: workspace, selections: [TrialSelection(itemID: "x", minutes: 40)], slots: slots(60), now: origin)
    #expect(result.unallocatedMinutes == 0)
    #expect(result.allocations.count == 1)
}

@Test func failedGreedyScheduleDoesNotInventProofOfInfeasibility() throws {
    // EDF greedily places the fragmentable early work in the only long slot,
    // but moving it to [40,60) allows the continuous job in [0,30).
    let workspace = Workspace(projects: [Project(id: "p1", name: "较早截止", deadline: date(60)),
                                         Project(id: "p2", name: "稍后截止", deadline: date(70))],
                              items: [WorkItem(id: "early", name: "可分段", projectIDs: ["p1"], remainingMinutes: 20),
                                      WorkItem(id: "continuous", name: "连续任务", projectIDs: ["p2"], remainingMinutes: 30, requiresContinuous: true)])
    let windows = [CapacitySlot(start: origin, end: date(30)), CapacitySlot(start: date(40), end: date(60))]
    let result = try Engine.evaluate(workspace: workspace, slots: windows, now: origin)
    #expect(result.feasibility == .undetermined)
    // Unproven competition is allowed; it must not be presented as an infeasibility certificate.
    #expect(!result.risks.contains { $0.shortageMinutes != nil })
}

@Test func nodeGateAndTransitiveInvalidationReachAllStartedWork() throws {
    var workspace = Workspace.demo(now: origin)
    try workspace.addItem(WorkItem(id: "downstream", name: "C 后续", projectIDs: ["project-c"], remainingMinutes: 10), now: origin)
    try workspace.addDependency(Dependency(source: .node("node-c"), targetItemID: "downstream"), now: origin)
    try workspace.addAcceptance(Acceptance(id: "gate-node-a", subject: .node("node-a"), name: "节点验收"), now: origin)
    // PRD AC061: a node needs declared complete scope and its own required gate.
    for index in workspace.nodes.indices { workspace.nodes[index].planningCompleteness = .complete }
    try workspace.addAcceptance(Acceptance(id: "gate-node-c", subject: .node("node-c"), name: "C 节点验收"), now: origin)
    // Replace the A→C item edge with a node edge using the direct edit contract.
    workspace.dependencies[0].source = .node("node-a")
    try workspace.validate()
    try workspace.startItem(id: "item-a", now: origin)
    try workspace.completeItem(id: "item-a", now: date(1))
    #expect(throws: CoreError.self) { try workspace.startItem(id: "item-c", now: date(2)) }
    try workspace.accept(id: "gate-node-a", now: date(2))
    try workspace.startItem(id: "item-c", now: date(3))
    try workspace.completeItem(id: "item-c", now: date(4))
    try workspace.accept(id: "gate-node-c", now: date(4))
    try workspace.startItem(id: "downstream", now: date(5))
    try workspace.reworkItem(id: "item-a", remainingMinutes: 10, now: date(6))
    #expect(workspace.acceptances[0].state == .pending)
    #expect(workspace.items.first { $0.id == "item-c" }?.needsReview == true)
    #expect(workspace.items.first { $0.id == "downstream" }?.needsReview == true)
    #expect(workspace.items.first { $0.id == "downstream" }?.status == .inProgress)
}
