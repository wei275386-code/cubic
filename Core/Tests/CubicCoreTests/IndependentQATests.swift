import Foundation
import Testing
@testable import CubicCore

private let qaNow = Date(timeIntervalSince1970: 1_800_000_000)
private func qaDate(_ minutes: Int) -> Date { qaNow.addingTimeInterval(Double(minutes) * 60) }

@Test func qaCrossProjectEarlierDeadlineWitness() throws {
    let workspace = Workspace(projects: [Project(id: "early", name: "Early", deadline: qaDate(30)), Project(id: "late", name: "Late", deadline: qaDate(90))], items: [WorkItem(id: "shared", name: "Shared", projectIDs: ["early", "late"], remainingMinutes: 60)])
    let slots = [CapacitySlot(start: qaDate(30), end: qaDate(90))]
    let result = try Engine.evaluate(workspace: workspace, slots: slots, now: qaNow)
    print("QA CROSS-DEADLINE global=\(result.feasibility) projects=\(result.projects)")
    #expect(result.feasibility == .infeasible)
    #expect(result.projects.first { $0.projectID == "early" }?.shortageMinutes == 60)
    let trial = try Engine.trial(workspace: workspace, selections: [TrialSelection(itemID: "shared", minutes: 60)], slots: slots, now: qaNow)
    // PRD §10.1/D13: the selected future block may expose a missed delivery
    // deadline; productive labor stays visible rather than being silently moved.
    #expect(trial.unallocatedMinutes == 0)
    #expect(trial.allocations.count == 1)
    #expect(trial.allocations.first?.start == qaDate(30))
    #expect(trial.allocations.first?.end == qaDate(90))
    let scenario = try #require(trial.planning?.scenario)
    #expect(scenario.feasibility == .infeasible)
    // The selected 60 minutes are already allocated: the remaining contradiction
    // is completion at t+90 versus the t+30 deadline, not 60 unperformed minutes.
    #expect(scenario.certificates.contains {
        $0.projectIDs == ["early"] && $0.kind == .dependencyWindow &&
        $0.windowEnd == qaDate(30) && $0.requiredReadyAt == qaDate(90) &&
        $0.latestAllowedAt == qaDate(30) && $0.elapsedDelaySeconds == 3600 &&
        $0.shortageMinutes == 0 && $0.conditionIDs.contains("trial-resource:shared")
    })
    print("QA CROSS-DEADLINE TRIAL certificates=\(scenario.certificates)")
    // PRD §9.3: local project feasibility does not promise simultaneous global feasibility.
    #expect(result.feasibility == .infeasible)
}

@Test func qaScale1000AndStorage() throws {
    let workspace = Workspace(projects: [Project(id: "p", name: "Scale", deadline: qaDate(1000), planningCompleteness: .complete)], items: (0..<1000).map { WorkItem(id: "item-\($0)", name: "Task \($0)", projectIDs: ["p"], remainingMinutes: 1) })
    let start = Date()
    let result = try Engine.evaluate(workspace: workspace, slots: [CapacitySlot(start: qaNow, end: qaDate(1000))], now: qaNow)
    print("QA SCALE items=1000 evaluate_seconds=\(Date().timeIntervalSince(start))")
    #expect(result.feasibility == .feasible)
    #expect(result.availableActions.count == 1000)
    let saveStart = Date()
    #expect(try persistedCopy(workspace) == workspace)
    print("QA STORAGE items=1000 save_load_seconds=\(Date().timeIntervalSince(saveStart))")
}

@Test func qaUndatedEmptyProjectIsUndetermined() throws {
    let result = try Engine.evaluate(workspace: Workspace(projects: [Project(id: "p", name: "Empty")]), slots: [], now: qaNow)
    #expect(result.projects[0].feasibility == .undetermined)
    #expect(result.feasibility == .undetermined)
}

@Test func qaPartialContinuousTrialCannotInventFeasibleSchedule() throws {
    let workspace = Workspace(projects: [Project(id: "p", name: "Nonpreemptive", deadline: qaDate(90))], items: [WorkItem(id: "continuous", name: "Needs full hour", projectIDs: ["p"], remainingMinutes: 60, requiresContinuous: true)])
    let windows = [CapacitySlot(start: qaNow, end: qaDate(30)), CapacitySlot(start: qaDate(60), end: qaDate(90))]
    let baseline = try Engine.evaluate(workspace: workspace, slots: windows, now: qaNow)
    #expect(baseline.feasibility == .infeasible)
    #expect(baseline.risks.contains { $0.kind == .continuousConstraint })
    // PRD D13: partial continuous trials report unallocated labor, no fake split.
    let partial = try Engine.trial(workspace: workspace, selections: [TrialSelection(itemID: "continuous", minutes: 30)], slots: windows, now: qaNow)
    #expect(partial.allocations.isEmpty)
    #expect(partial.unallocatedMinutes == 30)
    let full = try Engine.trial(workspace: workspace, selections: [TrialSelection(itemID: "continuous", minutes: 60)], slots: windows, now: qaNow)
    #expect(full.allocations.isEmpty)
    #expect(full.unallocatedMinutes == 60)
    #expect(full.snapshot.feasibility == .infeasible)
    #expect(workspace.items[0].remainingMinutes == 60)
}

@Test func qaApproximateEffortIsIndependentAndPortable() throws {
    var workspace = Workspace.demo(now: qaNow)
    try workspace.recordApproximateWork(itemID: "item-a", recordedAt: qaDate(40), actualMinutes: 40, remainingMinutes: 40, note: "约40分钟")
    let session = try #require(workspace.workSessions.first)
    #expect(session.start == qaDate(40))
    #expect(session.end == qaDate(40))
    #expect(session.intervalIsExact == false)
    #expect(!session.hasExactInterval)
    #expect(session.actualMinutes == 40)
    #expect(workspace.items[0].remainingMinutes == 40)
    #expect(workspace.items[0].status == .inProgress)
    #expect(workspace.items[0].completedAt == nil)
    let result = try Engine.evaluate(workspace: workspace, slots: [CapacitySlot(start: qaNow, end: qaDate(90))], now: qaDate(40))
    #expect(result.capacityMinutes == 50)
    #expect(result.itemStates.first { $0.itemID == "item-c" }?.isBlocked == true)
    #expect(result.projects.first { $0.projectID == "project-b" }?.shortageMinutes == 10)
    let stored = try persistedCopy(workspace)
    #expect(stored == workspace)
    #expect(stored.workSessions[0].intervalIsExact == false)
}

@Test func qaLegacyExactWorkSessionAndInvalidApproximateIntervals() throws {
    let json = """
    {"id":"legacy","itemID":"item-a","start":1800000000000,"end":1800002400000,"actualMinutes":40,"remainingMinutesAfter":40}
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    let legacy = try decoder.decode(WorkSession.self, from: Data(json.utf8))
    #expect(legacy.intervalIsExact == nil)
    #expect(legacy.hasExactInterval)
    var workspace = Workspace.demo(now: qaNow)
    try workspace.startItem(id: "item-a", now: qaNow)
    workspace.workSessions = [legacy]
    try workspace.validate()
    workspace.workSessions[0].intervalIsExact = false
    #expect(throws: CoreError.self) { try workspace.validate() }
    workspace.workSessions[0].end = workspace.workSessions[0].start
    try workspace.validate()
    workspace.workSessions[0].intervalIsExact = nil
    #expect(throws: CoreError.self) { try workspace.validate() }
}

@Test func qaUnreasonableMinuteInputsRejectAtomically() throws {
    var workspace = Workspace.demo(now: qaNow)
    let before = workspace
    #expect(throws: CoreError.self) { try workspace.updateRemaining(itemID: "item-a", minutes: Int.max, now: qaNow) }
    #expect(workspace == before)
    #expect(throws: CoreError.self) { try workspace.recordApproximateWork(itemID: "item-a", recordedAt: qaNow, actualMinutes: Int.max, remainingMinutes: 40) }
    #expect(workspace == before)
    #expect(throws: CoreError.self) { try workspace.recordWork(itemID: "item-a", start: qaNow, end: qaDate(40), actualMinutes: Int.max, remainingMinutes: 40) }
    #expect(workspace == before)
    var invalid = before
    invalid.items[0].initialMinutes = Int.max
    #expect(throws: CoreError.self) { try invalid.validate() }
    try workspace.updateRemaining(itemID: "item-a", minutes: 5_256_000, now: qaNow)
    #expect(workspace.items[0].remainingMinutes == 5_256_000)
    #expect(throws: CoreError.self) { try workspace.updateRemaining(itemID: "item-a", minutes: 5_256_001, now: qaNow) }
}
