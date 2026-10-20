import Foundation

/// Pure planning. Candidate allocations are evidence, never calendar reservations or real work.
public enum Engine {
    public static func evaluate(workspace: Workspace, slots: [CapacitySlot], busy: [BusyInterval] = [], now: Date) throws -> EngineSnapshot {
        try plan(workspace: workspace, input: PlanningInput(slots: slots, busy: busy, now: now)).legacy
    }
    public static func availableActions(workspace: Workspace, slots: [CapacitySlot], busy: [BusyInterval] = [], now: Date) throws -> [AvailableAction] {
        try evaluate(workspace: workspace, slots: slots, busy: busy, now: now).availableActions
    }
    public static func risks(workspace: Workspace, slots: [CapacitySlot], busy: [BusyInterval] = [], now: Date) throws -> [Risk] {
        try evaluate(workspace: workspace, slots: slots, busy: busy, now: now).risks
    }
    public static func trial(workspace: Workspace, selections: [TrialSelection], slots: [CapacitySlot],
                             busy: [BusyInterval] = [], now: Date) throws -> TrialResult {
        try workspace.validate(); try checkIDs(selections.map(\.itemID), "trial selections")
        let input = PlanningInput(slots: slots, busy: busy, now: now)
        if let selection = selections.first, selections.count == 1 {
            let detailed = try trial(workspace: workspace,
                request: PlanningTrialRequest(itemID: selection.itemID, minutes: selection.minutes), input: input)
            return TrialResult(selections: selections, allocations: detailed.allocations,
                unallocatedMinutes: detailed.unallocatedMinutes ?? 0,
                snapshot: detailed.scenario?.legacy ?? detailed.baseline.legacy, planning: detailed)
        }
        // Legacy ordered multi-selection uses one shared pool and one final snapshot.
        try validatePlanningInput(workspace: workspace, input: input)
        let scheduled = try CalendarPlanning(workspace: workspace, input: input)
        var pool = try PlanningPool(input: input)
        pool.subtract(scheduled.blocks)
        let graph = try PlanningGraph(workspace: workspace, input: input,
                                      reductions: scheduled.reductions,
                                      scheduledFinishes: scheduled.finishes)
        let items = Dictionary(uniqueKeysWithValues: workspace.items.map { ($0.id, $0) })
        let states = Dictionary(uniqueKeysWithValues: graph.states.map { ($0.itemID, $0) })
        var allocations: [TrialAllocation] = [], reductions: [String: Double] = [:]
        var completions: [String: Date] = [:], unallocated = 0.0, productiveMissing = 0.0, excess = 0.0
        for selection in selections {
            try checkMinutes(selection.minutes, "trial minutes")
            guard selection.minutes > 0, let item = items[selection.itemID], item.status != .completed,
                  item.effectiveDisposition != .cancelled else { throw CoreError.invalid("试算选择必须引用未完成待办且分钟为正") }
            guard states[item.id]?.isBlocked != true else { throw CoreError.blocked("无法试算受阻任务：\(item.id)") }
            let requested = Double(selection.minutes) * 60
            let scheduledSeconds = scheduled.reductions[item.id] ?? 0
            let expected = item.remainingMinutes.map { max(0, Double($0) * 60 - scheduledSeconds) }
            let productive = min(requested, expected ?? requested)
            let continuous = item.continuousMinutes.map { Double($0) * 60 } ?? expected
            let split = item.requiresContinuous && continuous.map { productive + 0.0001 < $0 } == true
            let start = max(input.now, scheduled.finishes[item.id] ?? input.now)
            let allocated: [TrialAllocation] = split ? [] : pool.allocate(itemID: item.id, seconds: productive, energy: item.energy,
                continuous: item.requiresContinuous, start: start, end: input.horizonEnd, requireComplete: false)
            let used = allocated.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
            allocations.append(contentsOf: allocated); reductions[item.id] = used
            if let remaining = item.remainingMinutes, used + 0.0001 >= Double(remaining) * 60 {
                completions[item.id] = allocated.last?.end ?? input.now
            }
            unallocated += requested - used
            productiveMissing += max(0, productive - used); excess += requested - productive
        }
        var snapshot = try planningSnapshot(workspace: workspace, input: input, pool: pool,
            reductions: reductions, completions: completions).legacy
        if productiveMissing > 0.0001 {
            snapshot.risks.append(Risk(kind: .sharedResourceConflict, itemIDs: selections.map(\.itemID),
                message: "选定试算劳动未完整分配；这是此候选的约束警告，不把分配失败当作项目无解或必然缺口。"))
        }
        if excess > 0.0001 {
            snapshot.risks.append(Risk(kind: .insufficientInformation, itemIDs: selections.map(\.itemID),
                message: "超出当前估计的 \(planningMinutes(excess, up: true)) 分钟未分配，不是新增劳动或匹配容量缺口。"))
        }
        return TrialResult(selections: selections, allocations: allocations,
            unallocatedMinutes: planningMinutes(unallocated, up: true), snapshot: snapshot)
    }
}
