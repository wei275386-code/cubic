import Foundation

/// Pure planning. Candidate allocations are evidence, never calendar reservations or real work.
public enum Engine {
    public static func evaluate(workspace: Workspace, slots: [CapacitySlot], busy: [BusyInterval] = [], now: Date) throws -> EngineSnapshot {
        try plan(workspace: workspace, input: PlanningInput(slots: slots, busy: busy, now: now)).summary
    }
    public static func availableActions(workspace: Workspace, slots: [CapacitySlot], busy: [BusyInterval] = [], now: Date) throws -> [AvailableAction] {
        try evaluate(workspace: workspace, slots: slots, busy: busy, now: now).availableActions
    }
    public static func risks(workspace: Workspace, slots: [CapacitySlot], busy: [BusyInterval] = [], now: Date) throws -> [Risk] {
        try evaluate(workspace: workspace, slots: slots, busy: busy, now: now).risks
    }
    /// Single-item trial in the `TrialResult` form stored with decisions.
    public static func trial(workspace: Workspace, selection: TrialSelection, slots: [CapacitySlot],
                             busy: [BusyInterval] = [], now: Date) throws -> TrialResult {
        let detailed = try trial(workspace: workspace, request: PlanningTrialRequest(itemID: selection.itemID, minutes: selection.minutes),
                                 input: PlanningInput(slots: slots, busy: busy, now: now))
        return TrialResult(selections: [selection], allocations: detailed.allocations,
            unallocatedMinutes: detailed.unallocatedMinutes ?? 0,
            snapshot: detailed.scenario?.summary ?? detailed.baseline.summary, planning: detailed)
    }
}
