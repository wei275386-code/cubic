import Foundation

struct PlanningVertex {
    enum Kind { case item, node, blocker, gate }
    var key: String
    var objectID: String
    var kind: Kind
    var knownSeconds: Double = 0
    var energy: Energy = .normal
    var continuous: Bool = false
    var unknown: Bool = false
    var actual: Bool = false
    var notBefore: Date?
    var minimumFinish: Date?
    var fixedEventAt: Date?
    /// Waiting duration is elapsed time, independent of working capacity.
    var lag: Double = 0
    var predecessors: Set<String> = []
    var successors: Set<String> = []
    var conditionIDs: [String] = []
}

struct PlanningGraph {
    var vertices: [String: PlanningVertex] = [:]
    var order: [String] = []
    var conditions: [PlanningCondition] = []
    var globalConditionIDs: [String] = []
    var unknowns: [PlanningUnknown] = []
    var projectRoots: [String: Set<String>] = [:]
    var projectRequirements: [String: Set<String>] = [:]
    var projectComplete: [String: Bool] = [:]
    var projectMargins: [String: Int] = [:]
    var deadlines: [String: Date] = [:]
    var directDeadlines: [String: Date] = [:]
    var committed: Set<String> = []
    var declared: Set<String> = []
    var states: [ItemState] = []
    var items: [String: WorkItem] = [:]
    var dependencies: [String: [Dependency]] = [:]
    var links: [WorkLink] = []

    init(workspace: Workspace, input: PlanningInput, reductions: [String: Double] = [:],
         estimatedCompletions: [String: Date] = [:], counterfactualItemIDs: Set<String> = [],
         scheduledFinishes: [String: Date] = [:]) throws {
        let options = input.options
        let disputed = Set(options.disputedItemIDs)
        items = Dictionary(uniqueKeysWithValues: workspace.items.map { ($0.id, $0) })
        links = (workspace.workLinks ?? []).filter { $0.removedAt == nil && $0.isRequired }
        let nodes = Dictionary(uniqueKeysWithValues: workspace.nodes.map { ($0.id, $0) })
        let blockers = Dictionary(uniqueKeysWithValues: workspace.blockers.map { ($0.id, $0) })
        let waits = Dictionary(uniqueKeysWithValues: options.waits.map { ($0.blockerID, $0) })
        let domainIndex = DomainIndex(workspace)
        var nodeMembers: [String: Set<String>] = [:]
        var nodeLinks: [String: [WorkReference]] = [:]
        var gates: [String: [Acceptance]] = [:]
        for acceptance in workspace.acceptances where acceptance.removedAt == nil && acceptance.required {
            let key = Self.key(acceptance.subject)
            gates[key, default: []].append(acceptance)
        }
        for link in links {
            if let id = link.nodeID { nodeLinks[id, default: []].append(link.source) }
        }
        func required(_ item: WorkItem) -> Bool { options.requiredItemIDs[item.id] ?? item.required }
        for item in workspace.items {
            if required(item), let nodeID = item.nodeID {
                nodeMembers[nodeID, default: []].insert(item.id)
            }
            let actual = domainIndex.itemValid(item.id) && !disputed.contains(item.id)
            let known = actual ? 0 : max(0, Double(item.remainingMinutes ?? 0) * 60 - (reductions[item.id] ?? 0))
            let unknown = !actual && (item.remainingMinutes == nil ||
                ((item.needsReview || disputed.contains(item.id) || item.status == .completed) && !counterfactualItemIDs.contains(item.id)) || item.effectiveDisposition == .cancelled)
            var vertex = PlanningVertex(key: "item:\(item.id)", objectID: item.id, kind: .item,
                                        knownSeconds: known, energy: item.energy,
                                        continuous: item.requiresContinuous, unknown: unknown, actual: actual)
            if item.requiresContinuous && item.continuousMinutes == nil && item.remainingMinutes == nil {
                vertex.unknown = true
            }
            if item.requiresContinuous, let minimum = item.continuousMinutes,
               let remaining = item.remainingMinutes, minimum > remaining, !actual {
                vertex.unknown = true
                unknowns.append(PlanningUnknown(objectID: item.id, message: "连续时长要求大于当前剩余估计，需澄清；不把较短分配当满足较长要求。"))
            }
            if !actual {
                let conditionID = "completion:\(item.id)"
                vertex.conditionIDs.append(conditionID)
                conditions.append(PlanningCondition(id: conditionID, kind: .estimatedCompletion, objectID: item.id,
                    expectedAt: estimatedCompletions[item.id], message: "假设按当前剩余估计推进并由用户确认待办完成；不写回真实状态。"))
            }
            if let finish = scheduledFinishes[item.id] { vertex.notBefore = finish }
            if let finish = estimatedCompletions[item.id] { vertex.notBefore = finish; vertex.fixedEventAt = finish }
            if unknown { unknowns.append(PlanningUnknown(objectID: item.id, message: "剩余、返工/复核工作范围或被取消的前置成果未知；已知劳动仍保留。")) }
            vertices[vertex.key] = vertex
            if let deadline = options.itemDeadlines[item.id] ?? item.deadline, item.effectiveDisposition != .cancelled {
                directDeadlines[vertex.key] = deadline
            }
        }
        var disputedNodes = Set(nodeMembers.filter { !$0.value.isDisjoint(with: disputed) }.map(\.key))
        var nodeConsumers: [String: Set<String>] = [:]
        for (target, references) in nodeLinks {
            for reference in references {
                switch reference {
                case .item(let id): if disputed.contains(id) { disputedNodes.insert(target) }
                case .node(let id): nodeConsumers[id, default: []].insert(target)
                }
            }
        }
        for node in workspace.nodes {
            if let predecessor = node.sequentialPredecessorNodeID { nodeConsumers[predecessor, default: []].insert(node.id) }
        }
        var disputedQueue = disputedNodes.sorted(), disputedCursor = 0
        while disputedCursor < disputedQueue.count {
            let id = disputedQueue[disputedCursor]; disputedCursor += 1
            for target in nodeConsumers[id] ?? [] where disputedNodes.insert(target).inserted { disputedQueue.append(target) }
        }
        for blocker in workspace.blockers {
            let wait = waits[blocker.id]
            let actual = blocker.state == .resolved
            var vertex = PlanningVertex(key: "blocker:\(blocker.id)", objectID: blocker.id, kind: .blocker, actual: actual)
            if !actual {
                let duration = wait?.elapsedMinutes ?? blocker.expectedDurationMinutes
                let expected = wait?.expectedResolution ?? blocker.expectedResolution
                if let duration, let wait, !wait.startAfterItemIDs.isEmpty {
                    vertex.notBefore = wait.assumedStart ?? input.now
                    vertex.lag = Double(duration) * 60
                    vertex.minimumFinish = expected
                } else if let expected { vertex.notBefore = max(input.now, expected) }
                else if let start = blocker.triggeredAt, let duration {
                    vertex.notBefore = max(input.now, start.addingTimeInterval(Double(duration) * 60))
                } else if let duration, let assumedStart = wait?.assumedStart {
                    vertex.notBefore = max(input.now, assumedStart.addingTimeInterval(Double(duration) * 60))
                } else { vertex.unknown = true }
                if blocker.state == .inactive {
                    // An estimate without an actual/explicit assumed start cannot launch itself.
                    if wait?.assumedStart == nil && (wait?.startAfterItemIDs.isEmpty ?? true) { vertex.unknown = true }
                    let id = "wait-start:\(blocker.id)"
                    vertex.conditionIDs.append(id)
                    conditions.append(PlanningCondition(id: id, kind: .assumedWaitStart, objectID: blocker.id,
                        expectedAt: wait?.assumedStart, message: "尚未真实发起，等待起点按显式情景前置/时间假设。"))
                }
                let id = "resolution:\(blocker.id)"
                vertex.conditionIDs.append(id)
                conditions.append(PlanningCondition(id: id, kind: .externalResolution, objectID: blocker.id,
                    expectedAt: vertex.minimumFinish ?? (vertex.lag == 0 ? vertex.notBefore : nil), message: "预计解除是条件假设，到期仍须确认；自然经过时间不扣个人容量。"))
                if vertex.unknown { unknowns.append(PlanningUnknown(objectID: blocker.id, message: "等待预计解除或发起起点未知。")) }
            }
            vertices[vertex.key] = vertex
        }
        for node in workspace.nodes {
            let key = "node:\(node.id)", requiredGates = gates[key] ?? []
            let actual = domainIndex.sourceSatisfied(.node(node.id)) && !disputedNodes.contains(node.id)
            var vertex = PlanningVertex(key: key, objectID: node.id, kind: .node,
                unknown: !actual && (node.needsReview == true || (requiredGates.isEmpty && (nodeMembers[node.id] ?? []).isEmpty)), actual: actual)
            if !actual {
                for gate in requiredGates where !domainIndex.gateValid(gate) {
                    let id = "acceptance:\(gate.id)"
                    vertex.conditionIDs.append(id)
                    conditions.append(PlanningCondition(id: id, kind: .manualAcceptance, objectID: gate.id,
                        expectedAt: options.manualGateDates[gate.id], message: "节点必需验收逐项人工通过的条件假设，非真实通过。"))
                    if let date = options.manualGateDates[gate.id] { vertex.notBefore = max(vertex.notBefore ?? input.now, date) }
                    if gate.state == .failed && gate.reworkScopeConfirmed != true { vertex.unknown = true }
                }
                if vertex.unknown { unknowns.append(PlanningUnknown(objectID: node.id, message: "节点验收/返工或成果复核信息不完整。")) }
            }
            vertices[key] = vertex
        }
        let conditionIndex = Dictionary(uniqueKeysWithValues: conditions.enumerated().map { ($0.element.id, $0.offset) })
        let effectiveDependencies = workspace.items.flatMap { domainIndex.incoming[$0.id] ?? [] }
        for dependency in effectiveDependencies {
            dependencies[dependency.targetItemID, default: []].append(dependency)
            let target = "item:\(dependency.targetItemID)", source = Self.key(dependency.source)
            // Validated completed+stillValid retains its existing result, without inventing upstream completion.
            if vertices[target]?.actual != true && !counterfactualItemIDs.contains(dependency.targetItemID) { connect(source, to: target) }
            let conditionKey: String
            switch dependency.source {
            case .item(let id): conditionKey = "completion:\(id)"
            case .blocker(let id): conditionKey = "resolution:\(id)"
            case .node: conditionKey = ""
            }
            if let index = conditionIndex[conditionKey] {
                conditions[index].dependencyIDs.append(dependency.id)
            }
        }
        for node in workspace.nodes where vertices["node:\(node.id)"]?.actual != true {
            if let predecessor = node.sequentialPredecessorNodeID { connect("node:\(predecessor)", to: "node:\(node.id)") }
            for id in nodeMembers[node.id] ?? [] { connect("item:\(id)", to: "node:\(node.id)") }
            for reference in nodeLinks[node.id] ?? [] { connect(Self.key(reference), to: "node:\(node.id)") }
            for id in node.blockerIDs ?? [] { connect("blocker:\(id)", to: "node:\(node.id)") }
        }
        for wait in options.waits where blockers[wait.blockerID]?.state != .resolved {
            for id in wait.startAfterItemIDs { connect("item:\(id)", to: "blocker:\(wait.blockerID)") }
        }
        // Item gates constrain the owning delivery, never a dependency on that item's completion.
        var itemDeliveryGates: [String: Set<String>] = [:]
        for item in workspace.items {
            for gate in gates["item:\(item.id)"] ?? [] {
                let key = "gate:\(gate.id)"
                let actual = domainIndex.gateValid(gate) && vertices["item:\(item.id)"]?.actual == true
                var vertex = PlanningVertex(key: key, objectID: gate.id, kind: .gate,
                    unknown: !actual && gate.state == .failed && gate.reworkScopeConfirmed != true,
                    actual: actual, notBefore: options.manualGateDates[gate.id])
                if !actual {
                    let id = "acceptance:\(gate.id)"
                    vertex.conditionIDs.append(id)
                    conditions.append(PlanningCondition(id: id, kind: .manualAcceptance, objectID: gate.id,
                        expectedAt: options.manualGateDates[gate.id], message: "工作成果人工确认仍是假设，不延迟仅引用待办完成的下游。"))
                    if vertex.unknown { unknowns.append(PlanningUnknown(objectID: gate.id, message: "工作验收失败，返工范围尚未确认。")) }
                }
                vertices[key] = vertex
                if !actual { connect("item:\(item.id)", to: key) }
                itemDeliveryGates[item.id, default: []].insert(key)
                if required(item), let nodeID = item.nodeID, vertices["node:\(nodeID)"]?.actual != true { connect(key, to: "node:\(nodeID)") }
            }
        }
        try topologicalOrder()
        for project in workspace.projects {
            let active = options.committedProjectIDs[project.id] ?? project.hasDeliveryCommitment
            if !active { continue }
            var roots = Set<String>()
            for node in workspace.nodes where node.projectID == project.id && (options.requiredNodeIDs[node.id] ?? node.required) {
                roots.insert("node:\(node.id)")
            }
            for item in workspace.items where item.projectIDs.contains(project.id) && required(item) {
                if let nodeID = item.nodeID, nodes[nodeID]?.projectID == project.id,
                   !(options.requiredNodeIDs[nodeID] ?? nodes[nodeID]?.required ?? true) { continue }
                roots.insert("item:\(item.id)")
                roots.formUnion(itemDeliveryGates[item.id] ?? [])
            }
            for link in links where link.projectID == project.id { roots.insert(Self.key(link.source)) }
            projectRoots[project.id] = roots
            projectRequirements[project.id] = ancestors(of: roots)
            declared.formUnion(projectRequirements[project.id] ?? [])
            // Evaluate exactly the currently added requirements, including an empty structure.
            // Missing estimates, acceptance, waits and capacity remain independent unknowns.
            projectComplete[project.id] = true
            if let margin = options.warningMargins[project.id] ?? project.warningBufferMinutes { projectMargins[project.id] = margin }
            if let deadline = project.deadline {
                committed.formUnion(projectRequirements[project.id] ?? [])
                for key in roots { directDeadlines[key] = min(directDeadlines[key] ?? deadline, deadline) }
            } else { unknowns.append(PlanningUnknown(objectID: project.id, message: "项目没有真实截止，不生成精确倒排约束。")) }
        }
        for key in directDeadlines.keys where key.hasPrefix("item:") { committed.formUnion(ancestors(of: [key])) }
        for item in workspace.items where item.required && item.effectiveDisposition == .active && item.projectIDs.isEmpty && !item.isPendingInboxOrganization {
            declared.formUnion(ancestors(of: ["item:\(item.id)"]))
        }
        declared.formUnion(committed)
        // Building vertices retains historical identities for dependencies. Only
        // current requirements (including their ancestors) contribute missing
        // premises; cancelled scope must not resurface as a global reminder.
        let currentActionRoots = Set(workspace.items.filter {
            !$0.archived && $0.effectiveDisposition == .active && $0.status != .completed && !$0.isPendingInboxOrganization
        }.map { "item:\($0.id)" })
        let currentObjectIDs = Set(ancestors(of: declared.union(currentActionRoots)).compactMap { vertices[$0]?.objectID })
            .union(projectRequirements.keys)
        unknowns.removeAll { !currentObjectIDs.contains($0.objectID) }
        deadlines = directDeadlines
        for key in order.reversed() {
            guard let deadline = deadlines[key] else { continue }
            for predecessor in vertices[key]?.predecessors ?? [] { deadlines[predecessor] = min(deadlines[predecessor] ?? deadline, deadline) }
        }
        let actualNodes = Dictionary(uniqueKeysWithValues: workspace.nodes.map { ($0.id, vertices["node:\($0.id)"]?.actual == true) })
        for item in workspace.items {
            var reasons: [BlockReason] = []
            if item.needsReview || disputed.contains(item.id) { reasons.append(.needsReview) }
            for dependency in dependencies[item.id] ?? [] {
                let satisfied: Bool
                switch dependency.source {
                case .item(let id): satisfied = vertices["item:\(id)"]?.actual == true
                case .node(let id): satisfied = actualNodes[id] == true
                case .blocker(let id): satisfied = blockers[id]?.state == .resolved
                }
                if !satisfied { reasons.append(.dependency(dependency.id)) }
                if !satisfied, case .node(let id) = dependency.source {
                    let relatedGates = (domainIndex.gates[WorkReferenceKey(.node(id))] ?? []) +
                        (domainIndex.members[id] ?? []).filter(\.required).flatMap { domainIndex.gates[WorkReferenceKey(.item($0.id))] ?? [] }
                    for gate in relatedGates where gate.required && !domainIndex.gateValid(gate) {
                        if !reasons.contains(.acceptance(gate.id)) { reasons.append(.acceptance(gate.id)) }
                    }
                }
            }
            states.append(ItemState(itemID: item.id, isBlocked: !reasons.isEmpty, reasons: reasons))
        }
        if !options.capacityVerified {
            globalConditionIDs.append("capacity:unverified")
            conditions.append(PlanningCondition(id: "capacity:unverified", kind: .capacityUnverified, objectID: "capacity",
                message: options.capacityNote ?? "外部占用/容量来源或时效未核对；只能给当前输入的条件结果。"))
            unknowns.append(PlanningUnknown(objectID: "capacity", message: options.capacityNote ?? "外部占用未核对。"))
        }
    }
    static func key(_ source: DependencySource) -> String {
        switch source { case .item(let id): "item:\(id)"; case .node(let id): "node:\(id)"; case .blocker(let id): "blocker:\(id)" }
    }
    static func key(_ source: WorkReference) -> String {
        switch source { case .item(let id): "item:\(id)"; case .node(let id): "node:\(id)" }
    }
    mutating func connect(_ source: String, to target: String) {
        vertices[target]?.predecessors.insert(source); vertices[source]?.successors.insert(target)
    }
    func ancestors(of roots: Set<String>) -> Set<String> {
        var seen = roots, queue = roots.sorted(), cursor = 0
        while cursor < queue.count {
            let key = queue[cursor]; cursor += 1
            for predecessor in vertices[key]?.predecessors ?? [] where seen.insert(predecessor).inserted { queue.append(predecessor) }
        }
        return seen
    }
    func conditionIDs(for keys: Set<String>) -> [String] {
        Set(keys.flatMap { vertices[$0]?.conditionIDs ?? [] } + globalConditionIDs).sorted()
    }
    mutating func topologicalOrder() throws {
        var degrees = vertices.mapValues { $0.predecessors.count }
        var queue = degrees.filter { $0.value == 0 }.map(\.key).sorted(), cursor = 0
        while cursor < queue.count {
            let key = queue[cursor]; cursor += 1
            for successor in (vertices[key]?.successors ?? []).sorted() {
                degrees[successor, default: 0] -= 1
                if degrees[successor] == 0 { queue.append(successor) }
            }
        }
        guard queue.count == vertices.count else { throw CoreError.cycle(degrees.filter { $0.value > 0 }.map(\.key).sorted()) }
        order = queue
    }
}
