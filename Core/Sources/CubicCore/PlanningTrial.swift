import Foundation

extension Engine {
    public static func trial(workspace: Workspace, request: PlanningTrialRequest,
                             input: PlanningInput) throws -> PlanningTrialResult {
        let baseline = try plan(workspace: workspace, input: input)
        guard let item = workspace.items.first(where: { $0.id == request.itemID }), item.status != .completed,
              item.effectiveDisposition != .cancelled else { throw CoreError.invalid("试算目标必须为存在、未完成且未取消的待办") }
        try checkMinutes(request.minutes, "planning.trial.minutes"); try checkDate(request.start, "planning.trial.start")
        if let minutes = request.minutes, minutes <= 0 { throw CoreError.invalid("试算时长必须为正，未选择时长使用 nil") }
        if let start = request.start, start < input.now || start >= input.horizonEnd { throw CoreError.invalid("试算开始位置不在未来规划窗口") }
        let state = baseline.summary.itemStates.first { $0.itemID == item.id }
        guard state?.isBlocked != true || request.counterfactual else {
            throw CoreError.blocked("当前前置或复核未就绪。请先处理前置，或明确选择反事实假设；真实工作仍受阻。")
        }
        var conditions: [PlanningCondition] = []
        if state?.isBlocked == true {
            conditions.append(PlanningCondition(id: "counterfactual:\(item.id)", kind: .counterfactualReadiness, objectID: item.id,
                dependencyIDs: state?.reasons.compactMap { if case .dependency(let id) = $0 { return id }; return nil } ?? [],
                expectedAt: request.start ?? input.now, message: "反事实假设当前前置/复核已处理；真实状态仍受阻。"))
        }
        let graph = try PlanningGraph(workspace: workspace, input: input)
        let impactedProjects = graph.projectRequirements.filter { $0.value.contains("item:\(item.id)") }.map(\.key).sorted()
        var descendants = Set<String>(), queue = ["item:\(item.id)"], cursor = 0
        while cursor < queue.count {
            let key = queue[cursor]; cursor += 1
            for target in (graph.vertices[key]?.successors ?? []).sorted() where descendants.insert(target).inserted { queue.append(target) }
        }
        let downstreamItems = descendants.compactMap { graph.vertices[$0] }.filter { $0.kind == .item }.map(\.objectID).sorted()
        func impact(kind: PlanningImpactKind, projects: [String], items: [String], before: Int? = nil, after: Int? = nil,
                    beforeDate: Date? = nil, afterDate: Date? = nil, start: Date? = nil, end: Date? = nil,
                    energy: Energy? = nil, assumptions: [String] = [], chain: [String], message: String) -> PlanningImpact {
            PlanningImpact(kind: kind, projectIDs: projects, itemIDs: items, beforeMinutes: before, afterMinutes: after,
                beforeDate: beforeDate, afterDate: afterDate, windowStart: start, windowEnd: end,
                energy: energy, conditionIDs: assumptions, chain: chain, message: message)
        }
        guard let minutes = request.minutes else {
            var directions = [impact(kind: .sharedProgress, projects: impactedProjects, items: [item.id],
                chain: ["item:\(item.id)"] + impactedProjects.map { "project:\($0)" },
                message: "投入这一份共享工作可能推进上述项目；未选择时长，不输出确定分钟或延期。")]
            if !downstreamItems.isEmpty {
                directions.append(impact(kind: .dependencyRelease,
                    projects: graph.projectRequirements.filter { !$0.value.isDisjoint(with: descendants) }.map(\.key).sorted(),
                    items: downstreamItems, assumptions: graph.conditionIDs(for: graph.ancestors(of: descendants)),
                    chain: ["item:\(item.id)"] + descendants.sorted(), message: "按估计完成可能释放这些依赖；节点引用仍待人工验收。"))
            }
            directions.append(impact(kind: .compatibleCapacityLoss, projects: baseline.projects.map(\.projectID).filter { !impactedProjects.contains($0) },
                items: [], energy: item.energy, chain: ["item:\(item.id)", "resource:shared"],
                message: "投入会占用同一份匹配资源；时长尚未选定，具体损失与冲突未计算。"))
            return PlanningTrialResult(request: request, source: baseline.source, baseline: baseline, scenario: nil,
                allocations: [], startPosition: request.start, assumedRemainingMinutes: nil, estimatedCompletion: nil,
                unallocatedMinutes: nil, excessMinutes: nil, impacts: directions, unresolvedConflicts: [], conditions: conditions)
        }
        let scheduled = try CalendarPlanning(workspace: workspace, input: input)
        var pool = try PlanningPool(input: input)
        pool.subtract(scheduled.blocks)
        let start = max(request.start ?? pool.windows.first?.start ?? input.now, scheduled.finishes[item.id] ?? input.now)
        let expected = item.remainingMinutes.map { max(0, Double($0) * 60 - (scheduled.reductions[item.id] ?? 0)) }
        let requested = Double(minutes) * 60
        let productive = min(requested, expected ?? requested)
        let excess = max(0, requested - productive)
        let continuousRequirement = item.continuousMinutes.map { Double($0) * 60 } ?? expected
        let cannotSplit = item.requiresContinuous && continuousRequirement.map { productive + 0.0001 < $0 } == true
        let allocations: [TrialAllocation]
        if cannotSplit { allocations = [] }
        else {
            // A user trial can expose a deadline conflict; the selected block is not silently moved before/after a deadline.
            allocations = pool.allocate(itemID: item.id, seconds: productive, energy: item.energy,
                continuous: item.requiresContinuous, start: start, end: input.horizonEnd, requireComplete: false)
        }
        let used = allocations.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        let remaining = expected.map { max(0, $0 - used) }
        let finish = remaining.map { $0 <= 0.0001 } == true ? (allocations.last?.end ?? start) : nil
        let progressCondition = PlanningCondition(id: "trial-progress:\(item.id)", kind: .estimatedCompletion,
            objectID: item.id, expectedAt: finish,
            message: "假设按当前剩余估计正常推进；实际投入与实际剩余独立填写，本试算不自动解锁。")
        conditions.append(progressCondition)
        let resourceCondition = PlanningCondition(id: "trial-resource:\(item.id)", kind: .trialResourceUse,
            objectID: item.id, expectedAt: allocations.first?.start ?? start,
            message: "资源情景只占用本次实际分配的匹配劳动块；忙碌、中间空隙及超出估计的未分配部分没有占用。")
        conditions.append(resourceCondition)
        let reductions = [item.id: used]
        let completions = finish.map { [item.id: $0] } ?? [:]
        // Counterfactual applies only to the chosen work's trial segment; other real gates stay explicit.
        var scenario = try planningSnapshot(workspace: workspace, input: input, pool: pool, reductions: reductions, completions: completions,
            counterfactualItemIDs: request.counterfactual ? [item.id] : [])
        if !conditions.isEmpty { scenario.conditions.append(contentsOf: conditions) }
        let scenarioConditions = conditions.map(\.id)
        scenario.witness.conditionIDs = Set(scenario.witness.conditionIDs + scenarioConditions).sorted()
        for index in scenario.projects.indices {
            scenario.projects[index].conditionIDs = Set(scenario.projects[index].conditionIDs + scenarioConditions).sorted()
            scenario.projects[index].witness.conditionIDs = Set(scenario.projects[index].witness.conditionIDs + scenarioConditions).sorted()
        }
        for index in scenario.certificates.indices {
            scenario.certificates[index].conditionIDs = Set(scenario.certificates[index].conditionIDs + [resourceCondition.id]).sorted()
        }
        for index in scenario.boundaries.indices {
            scenario.boundaries[index].conditionIDs = Set(scenario.boundaries[index].conditionIDs + scenarioConditions).sorted()
        }
        if allocations.isEmpty && productive > 0 {
            scenario.witness.isComplete = false
            if scenario.summary.feasibility == .feasible { scenario.summary.feasibility = .undetermined }
        }
        var impacts: [PlanningImpact] = []
        impacts.append(impact(kind: .sharedProgress, projects: impactedProjects, items: [item.id],
            before: item.remainingMinutes, after: remaining.map { planningMinutes($0, up: true) }, afterDate: finish,
            start: allocations.first?.start ?? start, end: allocations.last?.end, energy: item.energy,
            assumptions: [progressCondition.id], chain: ["item:\(item.id)"] + impactedProjects.map { "project:\($0)" },
            message: "同一工作只减一份假设需求，可同时推进多个引用项目；非真实进展。"))
        if let finish, !downstreamItems.isEmpty {
            let downstreamProjects = graph.projectRequirements.filter { !$0.value.isDisjoint(with: descendants) }.map(\.key).sorted()
            let directEdges = workspace.dependencies.filter { $0.isActive && $0.source == .item(item.id) }
            let paths = ["item:\(item.id)"] + directEdges.flatMap { ["dependency:\($0.id)", "item:\($0.targetItemID)"] }
            impacts.append(impact(kind: .dependencyRelease, projects: downstreamProjects, items: downstreamItems,
                beforeDate: baseline.witness.eventTimes["item:\(item.id)"], afterDate: finish,
                assumptions: [progressCondition.id] + graph.conditionIDs(for: descendants), chain: paths + descendants.sorted(),
                message: "假设此时完成目标待办，待办粒度下游可能就绪；其他 AND 前置、外部确认与节点人工验收仍须满足。"))
        }
        let beforePool = try PlanningPool(input: input)
        let beforeProjects = Dictionary(uniqueKeysWithValues: baseline.projects.map { ($0.projectID, $0) })
        let afterProjects = Dictionary(uniqueKeysWithValues: scenario.projects.map { ($0.projectID, $0) })
        for project in workspace.projects {
            guard let before = beforeProjects[project.id], let after = afterProjects[project.id] else { continue }
            let keys = graph.projectRequirements[project.id] ?? []
            let labor = keys.compactMap { graph.vertices[$0] }.filter { $0.kind == .item && $0.objectID != item.id && $0.knownSeconds > 0 }
            let end = min(project.deadline ?? input.horizonEnd, input.horizonEnd)
            // Separate opportunity loss by energy threshold; ordinary minutes cannot hide loss of a high-focus slot.
            for energy in [Energy.low, .normal, .high] where labor.contains(where: { $0.energy.rank >= energy.rank }) {
                let earlier = beforePool.seconds(energy: energy, start: input.now, end: end)
                let later = pool.seconds(energy: energy, start: input.now, end: end)
                if earlier > later + 0.0001 {
                    impacts.append(impact(kind: .compatibleCapacityLoss, projects: [project.id],
                        items: labor.filter { $0.energy.rank >= energy.rank }.map(\.objectID).sorted(),
                        before: planningMinutes(earlier), after: planningMinutes(later), start: input.now, end: end, energy: energy,
                        assumptions: [resourceCondition.id], chain: ["item:\(item.id)", "resource:\(energy.rawValue)", "project:\(project.id)"],
                        message: "选中试算块使该截止窗口内的匹配机会减少；这不是给该项目预定剩余槽。"))
                }
            }
            if let earlier = before.slackUpperBoundMinutes, let later = after.slackUpperBoundMinutes, earlier != later {
                impacts.append(impact(kind: later < earlier ? .slackLoss : .boundaryImprovement, projects: [project.id],
                    items: labor.map(\.objectID).sorted(), before: earlier, after: later, start: input.now, end: end,
                    assumptions: after.conditionIDs + [progressCondition.id], chain: ["item:\(item.id)", "project:\(project.id)"],
                    message: "单项目可工作余量上界变化；共享冲突未解决时不当作全局可靠余量。"))
            }
            let earlier = baseline.certificates.filter { $0.projectIDs == [project.id] }.map(\.shortageMinutes).max() ?? 0
            let later = scenario.certificates.filter { $0.projectIDs == [project.id] }.map(\.shortageMinutes).max() ?? 0
            if later > earlier {
                impacts.append(impact(kind: .shortageIncrease, projects: [project.id], items: labor.map(\.objectID).sorted(),
                    before: earlier, after: later, start: input.now, end: end,
                    assumptions: after.conditionIDs + [progressCondition.id], chain: ["item:\(item.id)", "resource:shared", "project:\(project.id)"],
                    message: "该窗口内已证明的劳动缺口增大；不据此输出确定延期日期。"))
            }
        }
        let conflicts = scenario.certificates.filter { $0.projectIDs.count > 1 }
        for conflict in conflicts {
            impacts.append(impact(kind: .unresolvedCompetition, projects: conflict.projectIDs, items: conflict.itemIDs,
                before: nil, after: conflict.shortageMinutes, start: conflict.windowStart, end: conflict.windowEnd,
                energy: conflict.energy, assumptions: conflict.conditionIDs + [progressCondition.id],
                chain: ["item:\(item.id)", "resource:shared"] + conflict.itemIDs.map { "item:\($0)" },
                message: "这些工作共同放不下，需用户取舍；候选失败未指定哪个项目延期。"))
        }
        impacts.append(contentsOf: scenario.unprovenCompetitions)
        if used + 0.0001 < productive || remaining == nil {
            impacts.append(impact(kind: .unknown, projects: impactedProjects, items: [item.id],
                start: start, end: input.horizonEnd, energy: item.energy, assumptions: [progressCondition.id],
                chain: ["item:\(item.id)", item.requiresContinuous ? "constraint:continuous" : "constraint:capacity"],
                message: remaining == nil ? "剩余未知，可展示投入机会损失，但不能假定完成或解锁。" :
                    "选定劳动未在精力/连续/有限窗口条件下完整分配；不会强行画满，也不以分配失败证明项目无解。"))
        }
        if let first = allocations.first, first.start > start {
            impacts.append(impact(kind: .unknown, projects: impactedProjects, items: [item.id],
                beforeDate: start, afterDate: first.start, start: start, end: first.start, energy: item.energy,
                chain: ["item:\(item.id)", "resource:next-compatible-slot"],
                message: "所选开始位置没有匹配空档，实际试算劳动从所示下一兼容槽开始；外部占用保留。"))
        }
        if allocations.count > 1 {
            impacts.append(impact(kind: .unknown, projects: impactedProjects, items: [item.id],
                start: allocations.first?.start, end: allocations.last?.end, energy: item.energy,
                chain: ["item:\(item.id)", "resource:split-slots"],
                message: "本次假设投入跨多个可用槽分段，经过时间不等于投入时长；中间忙碌/不可工作时间未画满。"))
        }
        return PlanningTrialResult(request: request, source: baseline.source, baseline: baseline, scenario: scenario,
            allocations: allocations, startPosition: allocations.first?.start ?? start, assumedRemainingMinutes: remaining.map { planningMinutes($0, up: true) },
            estimatedCompletion: finish, unallocatedMinutes: planningMinutes(max(0, requested - used), up: true),
            excessMinutes: planningMinutes(excess, up: true), impacts: impacts,
            unresolvedConflicts: conflicts, conditions: conditions)
    }
}
