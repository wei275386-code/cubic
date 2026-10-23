import Foundation

extension Engine {
    public static func plan(workspace: Workspace, input: PlanningInput) throws -> PlanningSnapshot {
        try workspace.validate()
        try validatePlanningInput(workspace: workspace, input: input)
        let pool = try PlanningPool(input: input)
        return try planningSnapshot(workspace: workspace, input: input, pool: pool)
    }

    static func validatePlanningInput(workspace: Workspace, input: PlanningInput) throws {
        let options = input.options
        guard (0...10_000_000).contains(options.maximumIntervalChecks) else { throw CoreError.invalid("interval proof 预算需为 0…10000000") }
        let items = Set(workspace.items.map(\.id)), nodes = Set(workspace.nodes.map(\.id))
        let projects = Set(workspace.projects.map(\.id)), blockers = Set(workspace.blockers.map(\.id))
        let gates = Set(workspace.acceptances.map(\.id))
        guard Set(options.requiredItemIDs.keys).union(options.itemDeadlines.keys).isSubset(of: items),
              Set(options.requiredNodeIDs.keys).isSubset(of: nodes),
              Set(options.warningMargins.keys).union(options.committedProjectIDs.keys).isSubset(of: projects),
              Set(options.manualGateDates.keys).isSubset(of: gates) else { throw CoreError.missing("Planning override 引用不存在对象") }
        for date in options.itemDeadlines.values { try checkDate(date, "planning.itemDeadline") }
        for date in options.manualGateDates.values { try checkDate(date, "planning.manualGate") }
        for margin in options.warningMargins.values { try checkMinutes(margin, "planning.warningMargin") }
        try checkIDs(options.waits.map(\.blockerID), "planning.waits")
        for wait in options.waits {
            guard blockers.contains(wait.blockerID), Set(wait.startAfterItemIDs).isSubset(of: items) else { throw CoreError.missing("Planning wait 引用不存在对象") }
            try checkIDs(wait.startAfterItemIDs, "planning.waitPredecessors")
            try checkDate(wait.assumedStart, "planning.waitStart")
            try checkDate(wait.expectedResolution, "planning.waitResolution")
            try checkMinutes(wait.elapsedMinutes, "planning.waitDuration")
        }
    }

    static func planningSnapshot(workspace: Workspace, input: PlanningInput, pool: PlanningPool,
                                 reductions: [String: Double] = [:], completions: [String: Date] = [:],
                                 counterfactualItemIDs: Set<String> = []) throws -> PlanningSnapshot {
        let scheduled = try CalendarPlanning(workspace: workspace, input: input)
        var pool = pool
        pool.subtract(scheduled.blocks)
        var combinedReductions = reductions, combinedCompletions = completions
        let remainingByID = Dictionary(uniqueKeysWithValues: workspace.items.map { ($0.id, $0.remainingMinutes) })
        for (id, seconds) in scheduled.reductions {
            combinedReductions[id, default: 0] += seconds
            if let remaining = remainingByID[id] ?? nil,
               combinedReductions[id, default: 0] + 0.001 >= Double(remaining) * 60,
               let finish = scheduled.finishes[id] {
                combinedCompletions[id] = max(combinedCompletions[id] ?? finish, finish)
            }
        }
        let graph = try PlanningGraph(workspace: workspace, input: input, reductions: combinedReductions,
            estimatedCompletions: combinedCompletions, counterfactualItemIDs: counterfactualItemIDs,
            scheduledFinishes: scheduled.finishes)
        let solution = PlanningSolution(graph: graph, pool: pool, input: input)
        let globalKeys = graph.committed
        let globalForward = solution.witness(keys: globalKeys)
        let globalReverse = solution.witness(keys: globalKeys, backwards: true)
        // Try two independently validated candidates. Neither failing proves impossibility.
        let globalWitness = globalForward.isComplete ? globalForward : (globalReverse.isComplete ? globalReverse : globalForward)
        var proofs = solution.certificates(keys: globalKeys), assessments: [PlanningProjectAssessment] = []
        var summaryProjects: [ProjectAssessment] = [], boundaries: [PlanningBoundary] = []
        boundaries += solution.boundaries(keys: globalKeys, layer: .dependency, projectIDs: graph.projectRequirements.keys.sorted())
        boundaries += solution.boundaries(keys: globalKeys, layer: .global, projectIDs: graph.projectRequirements.keys.sorted(),
            candidate: globalReverse.isComplete ? globalReverse : nil)
        var projectScopesKnown = true
        let capacityIndex = PlanningCapacityIndex(pool: pool)
        for project in workspace.projects where graph.projectRequirements[project.id] != nil {
            let keys = graph.projectRequirements[project.id] ?? []
            let labor = keys.compactMap { graph.vertices[$0] }.filter { $0.kind == .item }
            let known = labor.reduce(0) { $0 + $1.knownSeconds }
            let allKnown = keys.allSatisfy { graph.vertices[$0]?.unknown != true }
            let scope = graph.projectComplete[project.id] == true
            let covered = project.deadline.map { $0 <= input.horizonEnd } ?? false
            if project.deadline != nil && (!scope || !allKnown || !covered) { projectScopesKnown = false }
            let upperEnd = min(project.deadline ?? input.horizonEnd, input.horizonEnd)
            let available = capacityIndex.seconds(start: input.now, end: upperEnd, energy: .low)
            // A single-project layer ignores other projects' deadlines, while preserving standalone constraints.
            var localGraph = graph
            localGraph.deadlines = [:]
            for key in keys {
                if let vertex = graph.vertices[key], vertex.kind == .item,
                   let item = graph.items[vertex.objectID], let deadline = input.options.itemDeadlines[item.id] ?? item.deadline {
                    localGraph.deadlines[key] = deadline
                }
            }
            if let deadline = project.deadline {
                for root in graph.projectRoots[project.id] ?? [] { localGraph.deadlines[root] = min(localGraph.deadlines[root] ?? deadline, deadline) }
            }
            for key in graph.order.reversed() {
                if let deadline = localGraph.deadlines[key] {
                    for predecessor in graph.vertices[key]?.predecessors.intersection(keys) ?? [] {
                        localGraph.deadlines[predecessor] = min(localGraph.deadlines[predecessor] ?? deadline, deadline)
                    }
                }
            }
            let localSolution = PlanningSolution(graph: localGraph, pool: pool, input: input)
            let projectProofs = localSolution.certificates(keys: keys, projectID: project.id)
            proofs.append(contentsOf: projectProofs)
            let forward = localSolution.witness(keys: keys), reverse = localSolution.witness(keys: keys, backwards: true)
            let witness = forward.isComplete ? forward : (reverse.isComplete ? reverse : forward)
            let scheduledIDs = Set(labor.map(\.objectID))
            let scheduledSeconds = scheduled.blocks.filter { scheduledIDs.contains($0.itemID) }.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
            let calendarValid = !scheduled.issues.contains { scheduledIDs.contains($0.objectID) }
            let feasibility: Feasibility = !projectProofs.isEmpty ? .infeasible :
                (scope && allKnown && covered && calendarValid && input.options.capacityVerified && witness.isComplete ? .feasible : .undetermined)
            var lower: Int?, upper: Int?
            if scope && allKnown && covered && feasibility != .infeasible {
                upper = planningMinutes(max(0, available - known))
                let necessaryStarts = keys.compactMap { key -> Date? in
                    guard let vertex = localGraph.vertices[key], !vertex.actual,
                          vertex.kind == .item && vertex.knownSeconds > 0 || vertex.lag > 0 else { return nil }
                    return localSolution.latestStarts[key]
                }
                if let necessary = necessaryStarts.min() {
                    upper = min(upper ?? Int.max, planningMinutes(capacityIndex.seconds(start: input.now, end: necessary, energy: .low)))
                }
                if reverse.isComplete {
                    var starts = reverse.allocations.map(\.start)
                    for key in keys {
                        if let vertex = graph.vertices[key], vertex.lag > 0, !vertex.actual, let finish = reverse.eventTimes[key] {
                            starts.append(finish.addingTimeInterval(-vertex.lag))
                        }
                    }
                    if let first = starts.min() { lower = planningMinutes(capacityIndex.seconds(start: input.now, end: first, energy: .low)) }
                    else { lower = upper }
                }
            }
            let margin = graph.projectMargins[project.id]
            let warning: PlanningWarningState
            if feasibility == .infeasible { warning = .infeasible }
            else if let upper, upper == 0, lower == 0 { warning = .boundaryReached }
            else if margin == nil { warning = .notConfigured }
            else if let lower, let margin, lower >= margin { warning = .sufficient }
            else if let upper, let margin, upper < margin { warning = .insufficient }
            else { warning = .undetermined }
            let conditionIDs = graph.conditionIDs(for: keys)
            assessments.append(PlanningProjectAssessment(projectID: project.id, knownDemandMinutes: planningMinutes(known + scheduledSeconds, up: true),
                totalDemandMinutes: scope && allKnown ? planningMinutes(known + scheduledSeconds, up: true) : nil,
                knownCapacityMinutes: planningMinutes(available + scheduledSeconds), feasibility: feasibility, scopeComplete: scope,
                warningMarginMinutes: margin, slackLowerBoundMinutes: lower, slackUpperBoundMinutes: upper,
                warningState: warning, conditionIDs: conditionIDs, witness: scheduled.adding(to: witness, itemIDs: scheduledIDs)))
            summaryProjects.append(ProjectAssessment(projectID: project.id,
                demandMinutes: scope && allKnown ? planningMinutes(known + scheduledSeconds, up: true) : nil,
                capacityMinutes: planningMinutes(available + scheduledSeconds), shortageMinutes: covered ? (projectProofs.map(\.shortageMinutes).max() ?? 0) : nil,
                feasibility: feasibility, conditionalItemIDs: labor.filter { !$0.actual && (!$0.predecessors.isEmpty || $0.unknown) }.map(\.objectID).sorted()))
            boundaries += localSolution.boundaries(keys: keys, layer: .singleProject, projectIDs: [project.id],
                candidate: reverse.isComplete && scope && allKnown ? reverse : nil)
        }
        let knownGlobal = globalKeys.compactMap { graph.vertices[$0] }.filter { $0.kind == .item }.reduce(0) { $0 + $1.knownSeconds }
        let knownDeclared = graph.declared.compactMap { graph.vertices[$0] }.filter { $0.kind == .item }.reduce(0) { $0 + $1.knownSeconds }
        let allKnown = globalKeys.allSatisfy { graph.vertices[$0]?.unknown != true }
        let covered = globalKeys.allSatisfy { graph.deadlines[$0].map { $0 <= input.horizonEnd } ?? false }
        let globalProofs = proofs
        let feasibility: Feasibility = !globalProofs.isEmpty ? .infeasible :
            (!globalKeys.isEmpty && globalWitness.isComplete && scheduled.issues.isEmpty && projectScopesKnown && allKnown && covered && input.options.capacityVerified ? .feasible : .undetermined)
        var unknowns = graph.unknowns + scheduled.issues
        for key in globalKeys where graph.deadlines[key].map({ $0 > input.horizonEnd }) == true {
            unknowns.append(PlanningUnknown(objectID: graph.vertices[key]?.objectID ?? key,
                message: "已给容量窗口未覆盖真实截止；窗外资源未知，不凭本窗口失败证明最终不可行。"))
        }
        let unknownKeys = Set(unknowns.map(\.objectID))
        var risks: [Risk] = []
        var competitions: [PlanningImpact] = []
        if !globalWitness.isComplete && proofs.isEmpty && globalKeys.count > 1 {
            let labor = globalKeys.compactMap { graph.vertices[$0] }.filter { $0.kind == .item && !$0.actual }
            let competition = PlanningImpact(kind: .unresolvedCompetition,
                projectIDs: graph.projectRequirements.filter { !$0.value.isDisjoint(with: globalKeys) }.map(\.key).sorted(),
                itemIDs: labor.map(\.objectID).sorted(), beforeMinutes: nil, afterMinutes: nil, beforeDate: nil, afterDate: nil,
                windowStart: input.now, windowEnd: input.horizonEnd, energy: nil,
                conditionIDs: graph.conditionIDs(for: globalKeys), chain: labor.map { "item:\($0.objectID)" }.sorted(),
                message: "这些需求的统一候选尚未验证成功；存在缺失前提或仍需比较的资源安排，不据此指定延期者或宣称必然无解。")
            competitions.append(competition)
            risks.append(Risk(kind: .sharedResourceConflict, itemIDs: competition.itemIDs,
                message: competition.message))
        }
        for proof in proofs {
            let kind: RiskKind
            switch proof.kind {
            case .continuousShortfall: kind = .continuousConstraint
            case .energyShortfall: kind = .energyConstraint
            case .capacityShortfall, .dependencyWindow: kind = proof.projectIDs.count == 1 ? .provenCapacityShortfall : .sharedResourceConflict
            }
            risks.append(Risk(kind: kind, projectID: proof.projectIDs.count == 1 ? proof.projectIDs.first : nil,
                itemIDs: proof.itemIDs, shortageMinutes: proof.elapsedDelaySeconds == nil ? proof.shortageMinutes : nil, message: proof.message))
        }
        for project in assessments where !project.conditionIDs.isEmpty {
            risks.append(Risk(kind: .conditionalUnlock, projectID: project.projectID,
                itemIDs: (graph.projectRequirements[project.projectID] ?? []).compactMap { graph.vertices[$0] }.filter { $0.kind == .item && !$0.actual }.map(\.objectID).sorted(),
                message: "候选只在列出的进展、人工验收/等待假设成立时可行；真实依赖状态保持不变。"))
        }
        if !unknowns.isEmpty { risks.append(Risk(kind: .insufficientInformation, itemIDs: unknownKeys.intersection(graph.items.keys).sorted(),
            message: "未知范围与已知需求/缺口并存；查看 Planning unknowns 中每个对象的缺失前提。")) }
        for project in assessments where [.insufficient, .boundaryReached].contains(project.warningState) {
            risks.append(Risk(kind: .conditionalUnlock, projectID: project.projectID,
                message: "项目可工作余量已到边界或低于显式预警阈值；阈值不占用资源。"))
        }
        let stateMap = Dictionary(uniqueKeysWithValues: graph.states.map { ($0.itemID, $0) })
        let actions = workspace.items.filter {
            $0.status != .completed && $0.effectiveDisposition == .active && stateMap[$0.id]?.isBlocked == false
        }.map { item in
            let vertex = graph.vertices["item:\(item.id)"]
            let available = pool.seconds(energy: item.energy, start: input.now, end: input.horizonEnd)
            let longest = pool.longest(energy: item.energy, start: input.now, end: input.horizonEnd)
            return AvailableAction(itemID: item.id, remainingMinutes: vertex?.unknown == true ? nil : vertex.map { planningMinutes($0.knownSeconds, up: true) },
                canFit: vertex?.unknown == true ? nil : (vertex?.knownSeconds ?? 0) <= (item.requiresContinuous ? longest : available) + 0.0001,
                compatibleMinutes: planningMinutes(available), longestContinuousMinutes: planningMinutes(longest))
        }
        var distinctRisks: [Risk] = []
        for risk in risks where !distinctRisks.contains(risk) { distinctRisks.append(risk) }
        let summary = EngineSnapshot(availableActions: actions, itemStates: graph.states, risks: distinctRisks,
            projects: summaryProjects, capacityMinutes: planningMinutes(pool.seconds(start: input.now, end: input.horizonEnd)), feasibility: feasibility)
        return PlanningSnapshot(source: PlanningSource(workspace: workspace, input: input), summary: summary,
            knownDemandMinutes: planningMinutes(knownDeclared + scheduled.blocks.filter { graph.declared.contains("item:\($0.itemID)") }.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }, up: true),
            committedDemandMinutes: planningMinutes(knownGlobal + scheduled.blocks.filter { graph.committed.contains("item:\($0.itemID)") }.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }, up: true), unknowns: unknowns,
            conditions: graph.conditions, witness: scheduled.adding(to: globalWitness), boundaries: boundaries,
            projects: assessments, certificates: proofs, unprovenCompetitions: competitions)
    }
}
