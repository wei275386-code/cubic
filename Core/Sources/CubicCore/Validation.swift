import Foundation

func checkDate(_ value: Date?, _ label: String) throws {
    if let value, !value.timeIntervalSince1970.isFinite { throw CoreError.invalid("\(label)：日期必须有限") }
}
func checkMinutes(_ value: Int?, _ label: String) throws {
    if let value, value < 0 || value > 5_256_000 { throw CoreError.invalid("\(label)：分钟需在 0–5256000 之间") }
}
func checkIDs(_ ids: [String], _ label: String) throws {
    guard ids.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }), Set(ids).count == ids.count else { throw CoreError.invalid("\(label)：ID 为空或重复") }
}
func checkInterval(_ start: Date, _ end: Date, _ label: String, allowEmpty: Bool = false) throws {
    try checkDate(start, label); try checkDate(end, label)
    guard allowEmpty ? start <= end : start < end, end.timeIntervalSince(start).isFinite else { throw CoreError.invalid("\(label)：时间区间无效") }
}
func checkRound(_ round: Int?, _ label: String) throws {
    if let round, !(1...1_000_000).contains(round) { throw CoreError.invalid("\(label)：轮次无效") }
}
func checkDeadline(_ date: Date?, zone: String?, dateOnly: Bool?) throws {
    try checkDate(date, "deadline")
    if let zone, TimeZone(identifier: zone) == nil { throw CoreError.invalid("截止时区无效") }
    if dateOnly == true, let date {
        guard let zone else { throw CoreError.invalid("日期型截止缺明确时区") }
        let normalized = try Workspace.dateOnlyDeadline(on: date, timeZoneID: zone)
        guard abs(date.timeIntervalSince(normalized)) < 0.002 else { throw CoreError.invalid("日期型截止必须是所声明时区日末") }
    }
}

extension Workspace {
    /// Structural validation preserves historical accepted/completed legacy facts.
    /// Current eligibility is checked by the domain gate queries and business commands.
    public func validate() throws {
        guard schemaVersion == Self.schemaVersion else { throw CoreError.unsupportedSchema(schemaVersion) }
        let collections: [(String, [String])] = [
            ("projects", projects.map(\.id)), ("nodes", nodes.map(\.id)), ("items", items.map(\.id)),
            ("blockers", blockers.map(\.id)), ("dependencies", dependencies.map(\.id)),
            ("acceptances", acceptances.map(\.id)), ("history", history.map(\.id)),
            ("decisions", decisions.map(\.id)), ("workSessions", workSessions.map(\.id)),
            ("workLinks", (workLinks ?? []).map(\.id)), ("estimateRevisions", (estimateRevisions ?? []).map(\.id)),
            ("workRounds", (workRounds ?? []).map(\.id)), ("blockerRounds", (blockerRounds ?? []).map(\.id)),
            ("acceptanceResults", (acceptanceResults ?? []).map(\.id)), ("reviews", (reviews ?? []).map(\.id)),
            ("choices", (choices ?? []).map(\.id)), ("deletedItems", (deletedItems ?? []).map(\.id)),
            ("timeBlocks", (timeBlocks ?? []).map(\.id)),
            ("projectTemplates", (projectTemplates ?? []).map(\.id))]
        for (name, ids) in collections { try checkIDs(ids, name) }
        let index = DomainIndex(self)
        let liveItemIDs = Set(items.map(\.id)), deletedItemIDs = Set((deletedItems ?? []).map(\.id))
        guard liveItemIDs.isDisjoint(with: deletedItemIDs) else { throw CoreError.invalid("已删除工作不能重新成为可操作工作") }
        let projectIDs = Set(projects.map(\.id)), itemIDs = liveItemIDs.union(deletedItemIDs), nodeIDs = Set(nodes.map(\.id)), blockerIDs = Set(blockers.map(\.id))
        let dependencyIDs = Set(dependencies.map(\.id)), acceptanceIDs = Set(acceptances.map(\.id))
        let sessionMap = Dictionary(uniqueKeysWithValues: workSessions.map { ($0.id, $0) })
        let historyMap = Dictionary(uniqueKeysWithValues: history.map { ($0.id, $0) })
        let estimateMap = Dictionary(uniqueKeysWithValues: (estimateRevisions ?? []).map { ($0.id, $0) })
        func checkReference(_ reference: WorkReference) throws {
            switch reference { case .item(let id): guard itemIDs.contains(id) else { throw CoreError.missing("item: \(id)") }
            case .node(let id): guard nodeIDs.contains(id) else { throw CoreError.missing("node: \(id)") } }
        }
        func checkSource(_ source: DependencySource) throws {
            switch source { case .item(let id): guard itemIDs.contains(id) else { throw CoreError.missing("item: \(id)") }
            case .node(let id): guard nodeIDs.contains(id) else { throw CoreError.missing("node: \(id)") }
            case .blocker(let id): guard blockerIDs.contains(id) else { throw CoreError.missing("blocker: \(id)") } }
        }
        for project in projects {
            guard (0...5).contains(project.importance) else { throw CoreError.invalid("importance 必须为 0...5") }
            try checkDeadline(project.deadline, zone: project.deadlineTimeZoneID, dateOnly: project.deadlineIsDateOnly)
            try checkMinutes(project.warningBufferMinutes, "warningBufferMinutes"); try checkDate(project.completedAt, "project.completedAt")
            guard (project.effectiveStatus == .completed) == (project.completedAt != nil) else { throw CoreError.invalid("项目完成状态/时间不一致") }
        }
        for node in nodes {
            guard projectIDs.contains(node.projectID) else { throw CoreError.missing("node.projectID: \(node.projectID)") }
            if let predecessor = node.sequentialPredecessorNodeID {
                guard predecessor != node.id, index.nodes[predecessor]?.projectID == node.projectID else { throw CoreError.invalid("节点顺序前置须属于同一项目") }
            }
            try checkDate(node.completedAt, "node.completedAt"); try checkRound(node.round, "node.round")
            try checkIDs(node.blockerIDs ?? [], "node.blockerIDs")
            guard (node.blockerIDs ?? []).allSatisfy(blockerIDs.contains) else { throw CoreError.missing("node.blockerIDs") }
        }
        for item in items + (deletedItems ?? []) {
            try checkIDs(item.projectIDs, "item.projectIDs")
            guard item.projectIDs.allSatisfy(projectIDs.contains) else { throw CoreError.missing("item.projectIDs: \(item.id)") }
            if let nodeID = item.nodeID {
                guard let node = index.nodes[nodeID], item.projectIDs.contains(node.projectID) else { throw CoreError.invalid("item.nodeID 或所属项目不一致: \(item.id)") }
            }
            for minutes in [item.remainingMinutes, item.initialMinutes, item.preStartMinutes, item.continuousMinutes] { try checkMinutes(minutes, "item minutes") }
            if let originID = item.initialEstimateEventID {
                guard let initial = item.initialMinutes, let event = historyMap[originID], event.objectID == item.id,
                      event.kind == .created || event.kind == .remainingUpdated, event.minutes == initial,
                      (event.relatedIDs ?? []).contains(where: { revisionID in
                          guard let revision = estimateMap[revisionID] else { return false }
                          return revision.itemID == item.id && revision.minutes == initial && revision.date == event.date &&
                              revision.round == (event.round ?? 1)
                      }) else { throw CoreError.invalid("首次估计来源缺确切事件/估计关联: \(item.id)") }
            }
            if let continuous = item.continuousMinutes, continuous == 0 { throw CoreError.invalid("连续时长必须为正") }
            try checkRound(item.round, "item.round")
            try checkDate(item.started, "started"); try checkDate(item.completedAt, "completedAt")
            try checkDate(item.preStartCapturedAt, "preStartCapturedAt")
            if let captured = item.preStartCapturedAt {
                guard let started = item.started, captured == started else { throw CoreError.invalid("开工前快照需真实首次开工时点") }
            } else if item.preStartMinutes != nil { throw CoreError.invalid("基线值缺真实采集时点") }
            try checkDeadline(item.deadline, zone: item.deadlineTimeZoneID, dateOnly: item.deadlineIsDateOnly)
            try checkIDs(item.contextTags ?? [], "contextTags")
            switch item.status {
            case .pending:
                guard item.completedAt == nil, !item.needsReview, item.started == nil || item.currentRound > 1 else { throw CoreError.invalid("pending 状态无效: \(item.id)") }
            case .inProgress:
                guard item.started != nil || item.startTimeIsUnknown == true, item.completedAt == nil else { throw CoreError.invalid("inProgress 状态无效: \(item.id)") }
            case .completed:
                guard let end = item.completedAt, item.remainingMinutes == 0 else { throw CoreError.invalid("completed 状态无效: \(item.id)") }
                if let start = item.started { try checkInterval(start, end, "item completion", allowEmpty: true) }
            }
        }
        for blocker in blockers {
            try checkDate(blocker.expectedResolution, "expectedResolution"); try checkDate(blocker.followUpAt, "followUpAt")
            try checkDate(blocker.triggeredAt, "triggeredAt"); try checkDate(blocker.resolvedAt, "resolvedAt")
            try checkMinutes(blocker.expectedDurationMinutes, "expectedDurationMinutes"); try checkRound(blocker.round, "blocker.round")
            if let id = blocker.followUpItemID, !itemIDs.contains(id) { throw CoreError.missing("followUpItemID") }
            switch blocker.state {
            case .inactive: guard blocker.triggeredAt == nil, blocker.resolvedAt == nil else { throw CoreError.invalid("inactive blocker 实际日期无效") }
            case .active: guard blocker.triggeredAt != nil, blocker.resolvedAt == nil else { throw CoreError.invalid("active blocker 实际日期无效") }
            case .resolved:
                guard let start = blocker.triggeredAt, let end = blocker.resolvedAt else { throw CoreError.invalid("resolved blocker 缺实际日期") }
                try checkInterval(start, end, "blocker resolution", allowEmpty: true)
            }
        }
        var seenDependencies = Set<String>()
        func vertex(_ source: DependencySource) -> String {
            switch source { case .item(let id): return "item:\(id)"; case .node(let id): return "node:\(id)"; case .blocker(let id): return "blocker:\(id)" }
        }
        for dependency in dependencies {
            guard itemIDs.contains(dependency.targetItemID) else { throw CoreError.missing("dependency target: \(dependency.targetItemID)") }
            try checkSource(dependency.source)
            try checkDate(dependency.createdAt, "dependency.createdAt"); try checkDate(dependency.effectiveAt, "dependency.effectiveAt")
            try checkDate(dependency.removedAt, "dependency.removedAt"); try checkRound(dependency.revision, "dependency.revision")
            if let created = dependency.createdAt, let effective = dependency.effectiveAt, created > effective { throw CoreError.invalid("依赖生效早于创建") }
            guard dependency.isActive else { continue }
            if case .item(let id) = dependency.source, !liveItemIDs.contains(id) { throw CoreError.invalid("有效依赖不可引用已删除工作") }
            guard liveItemIDs.contains(dependency.targetItemID) else { throw CoreError.invalid("有效依赖不可指向已删除工作") }
            let key = vertex(dependency.source) + "→item:" + dependency.targetItemID
            guard seenDependencies.insert(key).inserted else { throw CoreError.invalid("重复有效依赖") }
        }
        var seenLinks = Set<String>()
        for link in workLinks ?? [] {
            try checkReference(link.source); try checkDate(link.removedAt, "link.removedAt")
            guard projectIDs.contains(link.projectID) else { throw CoreError.missing("link.projectID") }
            if let nodeID = link.nodeID, index.nodes[nodeID]?.projectID != link.projectID { throw CoreError.invalid("共享引用节点与项目不一致") }
            guard link.removedAt == nil else { continue }
            if case .item(let id) = link.source, !liveItemIDs.contains(id) { throw CoreError.invalid("有效共享引用不可引用已删除工作") }
            let source: String
            switch link.source { case .item(let id): source = "item:\(id)"; case .node(let id): source = "node:\(id)" }
            let key = source + "→" + link.projectID + ":" + (link.nodeID ?? "")
            guard seenLinks.insert(key).inserted else { throw CoreError.invalid("重复有效共享引用") }
        }
        try validateAcyclic(constraintGraph())
        for acceptance in acceptances {
            try checkReference(acceptance.subject); try checkRound(acceptance.round, "acceptance.round")
            try checkDate(acceptance.acceptedAt, "acceptedAt"); try checkDate(acceptance.failedAt, "failedAt"); try checkDate(acceptance.removedAt, "acceptance.removedAt")
            try checkIDs(acceptance.candidateItemIDs ?? [], "candidateItemIDs"); try checkIDs(acceptance.candidateBlockerIDs ?? [], "candidateBlockerIDs")
            guard (acceptance.candidateItemIDs ?? []).allSatisfy(itemIDs.contains), (acceptance.candidateBlockerIDs ?? []).allSatisfy(blockerIDs.contains) else { throw CoreError.missing("验收返工候选") }
            if acceptance.isActive, case .item(let id) = acceptance.subject, !liveItemIDs.contains(id) { throw CoreError.invalid("有效验收不可引用已删除工作") }
            guard !(acceptance.candidateItemIDs ?? []).contains(where: deletedItemIDs.contains) else { throw CoreError.invalid("返工候选不可包含已删除工作") }
            switch acceptance.state {
            case .pending: guard acceptance.acceptedAt == nil, acceptance.failedAt == nil else { throw CoreError.invalid("pending gate 有结果时间") }
            case .accepted: guard acceptance.acceptedAt != nil, acceptance.failedAt == nil else { throw CoreError.invalid("accepted gate 结果时间无效") }
            case .failed: guard acceptance.failedAt != nil, acceptance.acceptedAt == nil else { throw CoreError.invalid("failed gate 结果时间无效") }
            }
            // Legacy accepted gates remain historical facts; missing new scope/gates degrades node eligibility.
        }
        var correctionTargets = Set<String>(), corrections: [String: Set<String>] = [:]
        for session in workSessions {
            guard itemIDs.contains(session.itemID) else { throw CoreError.missing("workSession.itemID") }
            try checkInterval(session.start, session.end, "workSession", allowEmpty: true)
            try checkDate(session.occurredOn, "occurredOn"); try checkDate(session.recordedAt, "recordedAt"); try checkRound(session.round, "session.round")
            try checkMinutes(session.actualMinutes, "actualMinutes"); try checkMinutes(session.remainingMinutesAfter, "remainingMinutesAfter")
            guard session.hasExactInterval || session.start == session.end else { throw CoreError.invalid("近似记录不可伪造时间区间") }
            guard !session.hasExactInterval || Double(session.actualMinutes) <= ceil(session.end.timeIntervalSince(session.start) / 60) else { throw CoreError.invalid("实际投入超过记录区间") }
            if let recorded = session.recordedAt {
                guard session.end <= recorded, session.occurredOn.map({ $0 <= recorded }) ?? true else { throw CoreError.invalid("记录时间早于投入事实") }
            }
            if let corrected = session.correctsSessionID {
                guard let old = sessionMap[corrected], old.id != session.id else { throw CoreError.missing("更正来源记录") }
                guard correctionTargets.insert(corrected).inserted else { throw CoreError.invalid("同一投入出现并发更正，须先解决冲突") }
                corrections[corrected, default: []].insert(session.id)
            }
        }
        try validateAcyclic(corrections)
        // Every acknowledged interval group must admit a single-resource allocation.
        let allocationGroups = Dictionary(grouping: effectiveWorkSessions.filter { $0.allocationGroupID != nil }, by: { $0.allocationGroupID! })
        for group in allocationGroups.values { try validateEffortAllocation(group) }
        let revisions = estimateRevisions ?? [], revisionMap = Dictionary(uniqueKeysWithValues: revisions.map { ($0.id, $0) })
        var revisionCorrections: [String: Set<String>] = [:], correctedRevisions = Set<String>()
        for revision in revisions {
            guard itemIDs.contains(revision.itemID) else { throw CoreError.missing("estimateRevision.itemID") }
            try checkDate(revision.date, "estimateRevision.date"); try checkRound(revision.round, "estimateRevision.round")
            try checkMinutes(revision.minutes, "estimateRevision.minutes"); try checkMinutes(revision.previousMinutes, "estimateRevision.previousMinutes")
            if let corrected = revision.correctsRevisionID {
                guard let old = revisionMap[corrected], old.itemID == revision.itemID, old.round == revision.round,
                      old.date <= revision.date, corrected != revision.id, correctedRevisions.insert(corrected).inserted else { throw CoreError.invalid("估计更正关系无效或并发") }
                revisionCorrections[corrected, default: []].insert(revision.id)
            }
        }
        try validateAcyclic(revisionCorrections)
        func checkUses(_ uses: [SourceUse], itemID: String) throws {
            try checkIDs(uses.map(\.dependencyID), "来源使用快照")
            for use in uses {
                if let nodeID = use.nodeID {
                    let wait = nodeBlockerDependencyParts(use.dependencyID)
                    let sequence = nodeSequenceDependencyParts(use.dependencyID)
                    let validWait = wait.map { $0.nodeID == nodeID && $0.itemID == itemID && use.source == .blocker($0.blockerID) && blockerIDs.contains($0.blockerID) } ?? false
                    let validSequence = sequence.map { $0.nodeID == nodeID && $0.itemID == itemID && use.source == .node($0.predecessorID) && nodeIDs.contains($0.predecessorID) } ?? false
                    guard nodeIDs.contains(nodeID), validWait || validSequence else { throw CoreError.invalid("全节点前置来源快照无效") }
                    // Historical scope may have been removed; preserve the exact source identity/round.
                } else {
                    guard dependencyIDs.contains(use.dependencyID) else { throw CoreError.missing("来源使用快照依赖") }
                }
                try checkSource(use.source); try checkRound(use.sourceRound, "sourceRound"); try checkRound(use.dependencyRevision, "dependencyRevision")
            }
        }
        var workRoundKeys = Set<String>()
        for round in workRounds ?? [] {
            guard itemIDs.contains(round.itemID), workRoundKeys.insert("\(round.itemID):\(round.round)").inserted else { throw CoreError.invalid("workRound 来源/轮次重复") }
            try checkRound(round.round, "workRound.round"); try checkDate(round.openedAt, "workRound.openedAt")
            try checkDate(round.startedAt, "workRound.startedAt"); try checkDate(round.completedAt, "workRound.completedAt")
            try checkMinutes(round.initialMinutes, "workRound.initialMinutes"); try checkMinutes(round.preStartMinutes, "workRound.preStartMinutes")
            if round.preStartMinutes != nil && round.startedAt == nil { throw CoreError.invalid("轮次基线缺真实开工") }
            if let start = round.startedAt, let end = round.completedAt { try checkInterval(start, end, "workRound completion", allowEmpty: true) }
            try checkUses(round.sources ?? [], itemID: round.itemID)
        }
        var blockerRoundKeys = Set<String>()
        for round in blockerRounds ?? [] {
            guard blockerIDs.contains(round.blockerID), blockerRoundKeys.insert("\(round.blockerID):\(round.round)").inserted else { throw CoreError.invalid("blockerRound 来源/轮次重复") }
            try checkRound(round.round, "blockerRound.round"); try checkDate(round.triggeredAt, "blockerRound.triggeredAt")
            try checkDate(round.expectedResolution, "blockerRound.expectedResolution"); try checkDate(round.followUpAt, "blockerRound.followUpAt")
            try checkDate(round.resolvedAt, "blockerRound.resolvedAt"); try checkMinutes(round.expectedDurationMinutes, "blockerRound.duration")
            if let end = round.resolvedAt {
                guard let start = round.triggeredAt else { throw CoreError.invalid("历史解除缺发起时点") }
                try checkInterval(start, end, "blockerRound resolution", allowEmpty: true)
            }
        }
        let resultMap = Dictionary(uniqueKeysWithValues: (acceptanceResults ?? []).map { ($0.id, $0) })
        for result in acceptanceResults ?? [] {
            guard acceptanceIDs.contains(result.acceptanceID), result.state != .pending else { throw CoreError.invalid("验收历史无效") }
            try checkDate(result.date, "acceptanceResult.date"); try checkRound(result.round, "acceptanceResult.round")
            if let reused = result.reusedResultID {
                guard let old = resultMap[reused], old.acceptanceID == result.acceptanceID, old.state == .accepted,
                      old.date <= result.date, old.id != result.id else { throw CoreError.invalid("沿用结果关系无效") }
            }
        }
        for review in reviews ?? [] {
            guard itemIDs.contains(review.itemID) else { throw CoreError.missing("review.itemID") }
            try checkDate(review.date, "review.date"); try checkRound(review.round, "review.round"); try checkUses(review.sources, itemID: review.itemID); try checkUses(review.currentSources ?? [], itemID: review.itemID)
        }
        func checkSnapshot(_ trial: TrialResult) throws {
            try validateTrial(trial, itemIDs: itemIDs, projectIDs: projectIDs)
            for state in trial.snapshot.itemStates { for reason in state.reasons {
                switch reason {
                case .dependency(let id):
                    let inherited = nodeBlockerDependencyParts(id)
                    let validInherited = inherited.map { nodeIDs.contains($0.nodeID) && blockerIDs.contains($0.blockerID) && itemIDs.contains($0.itemID) } ?? false
                    let sequence = nodeSequenceDependencyParts(id)
                    let validSequence = sequence.map { nodeIDs.contains($0.nodeID) && nodeIDs.contains($0.predecessorID) && itemIDs.contains($0.itemID) } ?? false
                    guard dependencyIDs.contains(id) || validInherited || validSequence else { throw CoreError.missing("snapshot dependency: \(id)") }
                case .acceptance(let id): guard acceptanceIDs.contains(id) else { throw CoreError.missing("snapshot acceptance: \(id)") }
                case .needsReview: break
                }
            } }
        }
        for decision in decisions { try checkDate(decision.date, "decision.date"); try checkSnapshot(decision.trial) }
        for choice in choices ?? [] {
            try checkDate(choice.date, "choice.date"); try checkIDs(choice.displayedItemIDs, "choice.displayedItemIDs")
            guard choice.itemID.map(itemIDs.contains) ?? true, choice.displayedItemIDs.allSatisfy(itemIDs.contains) else { throw CoreError.missing("choice.itemID") }
            if let trial = choice.trial { try checkSnapshot(trial) }
            if choice.impactWasVerified, choice.trial == nil || choice.dataVersion == nil { throw CoreError.invalid("已核验选择缺数据版本或情景") }
        }
        if let currentChoiceID, !(choices ?? []).contains(where: { $0.id == currentChoiceID }) { throw CoreError.missing("currentChoiceID") }
        if let selected = currentNextAction?.itemID, !liveItemIDs.contains(selected) { throw CoreError.invalid("下一步不能是已删除工作") }
        for block in timeBlocks ?? [] {
            guard liveItemIDs.contains(block.itemID) else { throw CoreError.missing("时间块引用已删除或不存在工作") }
            try checkInterval(block.start, block.end, "时间块")
        }
        let orderedBlocks = (timeBlocks ?? []).sorted { $0.start < $1.start }
        for pair in zip(orderedBlocks, orderedBlocks.dropFirst()) where pair.0.end > pair.1.start { throw CoreError.invalid("工作时间块重叠") }
        let allIDs = Set(collections.flatMap { $0.1 })
        for event in history {
            try checkDate(event.date, "history.date"); try checkMinutes(event.minutes, "history.minutes")
            try checkMinutes(event.previousMinutes, "history.previousMinutes"); try checkRound(event.round, "history.round")
            guard allIDs.contains(event.objectID) else { throw CoreError.missing("history.objectID: \(event.objectID)") }
            if let corrected = event.correctsEventID, !allIDs.contains(corrected) { throw CoreError.missing("history.correctsEventID") }
        }
    }
    func reasons(for id: String, includeReview: Bool = true) -> [BlockReason] {
        let index = DomainIndex(self)
        var result: [BlockReason] = []
        if includeReview, let item = index.items[id], item.needsReview || (item.status == .completed && !index.itemValid(id)) { result.append(.needsReview) }
        for dependency in index.incoming[id] ?? [] where !index.sourceSatisfied(dependency.source) {
            result.append(.dependency(dependency.id))
            if case .node(let nodeID) = dependency.source {
                for gate in index.gates[WorkReferenceKey(.node(nodeID))] ?? [] where gate.required && !index.gateValid(gate) {
                    if !result.contains(.acceptance(gate.id)) { result.append(.acceptance(gate.id)) }
                }
            }
        }
        return result
    }
}

extension Workspace {
    /// Same edges `validate()` checks for cycles. Item vertices stay present so an empty node can still close a loop.
    func constraintGraph() -> [String: Set<String>] {
        let index = DomainIndex(self)
        var graph: [String: Set<String>] = [:]
        for item in items {
            graph["item:\(item.id)", default: []] = []
            if let nodeID = item.nodeID { graph["item:\(item.id)", default: []].insert("node:\(nodeID)") }
        }
        for node in nodes {
            if graph["node:\(node.id)"] == nil { graph["node:\(node.id)"] = [] }
            if let predecessor = node.sequentialPredecessorNodeID {
                graph["node:\(predecessor)", default: []].insert("node:\(node.id)")
                for member in index.members[node.id] ?? [] { graph["node:\(predecessor)", default: []].insert("item:\(member.id)") }
            }
            for blockerID in node.blockerIDs ?? [] {
                graph["blocker:\(blockerID)", default: []].insert("node:\(node.id)")
                for member in index.members[node.id] ?? [] { graph["blocker:\(blockerID)", default: []].insert("item:\(member.id)") }
            }
        }
        for dependency in dependencies where dependency.isActive {
            let source: String
            switch dependency.source {
            case .item(let id): source = "item:\(id)"
            case .node(let id): source = "node:\(id)"
            case .blocker(let id): source = "blocker:\(id)"
            }
            graph[source, default: []].insert("item:\(dependency.targetItemID)")
        }
        for link in workLinks ?? [] where link.removedAt == nil && link.isRequired {
            guard let nodeID = link.nodeID else { continue }
            let source: String
            switch link.source { case .item(let id): source = "item:\(id)"; case .node(let id): source = "node:\(id)" }
            graph[source, default: []].insert("node:\(nodeID)")
        }
        return graph
    }

    func constraintVertexLabel(_ vertex: String) -> String {
        let parts = vertex.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return vertex }
        switch parts[0] {
        case "item": return items.first { $0.id == parts[1] }?.name ?? parts[1]
        case "node": return nodes.first { $0.id == parts[1] }?.name ?? parts[1]
        case "blocker": return blockers.first { $0.id == parts[1] }?.name ?? parts[1]
        default: return vertex
        }
    }

    /// Nil when `sourceItemID` may precede `targetItemID`. Already-active edges are allowed.
    public func workPredecessorCycleReason(sourceItemID: String, targetItemID: String) -> String? {
        workPredecessorCycleReason(sourceItemID: sourceItemID, targetItemID: targetItemID, graph: constraintGraph())
    }

    func workPredecessorCycleReason(sourceItemID: String, targetItemID: String, graph: [String: Set<String>]) -> String? {
        if dependencies.contains(where: { $0.isActive && $0.targetItemID == targetItemID && $0.source == .item(sourceItemID) }) {
            return nil
        }
        guard sourceItemID != targetItemID else { return "不能把这项工作设为自己的前置。" }
        guard let path = constraintPath(from: "item:\(targetItemID)", to: "item:\(sourceItemID)", graph: graph) else { return nil }
        let names = (["item:\(sourceItemID)"] + path).map(constraintVertexLabel)
        return "会互相等待：" + names.joined(separator: " → ")
    }
}

func constraintPath(from start: String, to goal: String, graph: [String: Set<String>]) -> [String]? {
    if start == goal { return [start] }
    var queue = [start]
    var previous: [String: String] = [:]
    var seen: Set<String> = [start]
    var index = 0
    while index < queue.count {
        let node = queue[index]
        index += 1
        for next in (graph[node] ?? []).sorted() where seen.insert(next).inserted {
            previous[next] = node
            if next == goal {
                var reversed = [goal]
                var cursor = goal
                while let prior = previous[cursor] {
                    reversed.append(prior)
                    if prior == start { break }
                    cursor = prior
                }
                return Array(reversed.reversed())
            }
            queue.append(next)
        }
    }
    return nil
}

/// Iterative DFS returns an actual closed path; no recursion depth or Kahn residual-node approximation.
func validateAcyclic(_ edges: [String: Set<String>]) throws {
    var colors: [String: Int] = [:]
    for root in edges.keys.sorted() where colors[root] == nil {
        var stack: [(String, [String], Int)] = [(root, (edges[root] ?? []).sorted(), 0)]
        var positions: [String: Int] = [root: 0]; colors[root] = 1
        while let frame = stack.last {
            if frame.2 == frame.1.count {
                colors[frame.0] = 2; positions.removeValue(forKey: frame.0); stack.removeLast(); continue
            }
            let child = frame.1[frame.2]; stack[stack.count - 1].2 += 1
            if colors[child] == 1 {
                let begin = positions[child] ?? 0
                throw CoreError.cycle(Array(stack[begin...].map { $0.0 }) + [child])
            }
            if colors[child] == nil {
                colors[child] = 1; positions[child] = stack.count
                stack.append((child, (edges[child] ?? []).sorted(), 0))
            }
        }
    }
}
func validateTrial(_ trial: TrialResult, itemIDs: Set<String>, projectIDs: Set<String>) throws {
    try checkIDs(trial.selections.map(\.itemID), "trial selections")
    try checkMinutes(trial.unallocatedMinutes, "trial unallocatedMinutes")
    for selection in trial.selections {
        guard itemIDs.contains(selection.itemID), selection.minutes > 0 else { throw CoreError.invalid("trial selection 无效") }
    }
    for allocation in trial.allocations {
        guard trial.selections.contains(where: { $0.itemID == allocation.itemID }) else { throw CoreError.invalid("trial allocation 引用无效") }
        try checkInterval(allocation.start, allocation.end, "trial allocation")
    }
    let ordered = trial.allocations.sorted { $0.start < $1.start }
    for pair in zip(ordered, ordered.dropFirst()) where pair.0.end > pair.1.start { throw CoreError.invalid("trial allocation 重叠") }
    var unallocatedSeconds = 0.0
    for selection in trial.selections {
        let seconds = trial.allocations.filter { $0.itemID == selection.itemID }.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
        guard seconds <= Double(selection.minutes) * 60 + 0.0001 else { throw CoreError.invalid("trial allocation 超出选择分钟") }
        unallocatedSeconds += max(0, Double(selection.minutes) * 60 - seconds)
    }
    guard trial.unallocatedMinutes == roundedMinutes(unallocatedSeconds, up: true) else { throw CoreError.invalid("trial 未分配分钟不一致") }
    let snapshot = trial.snapshot
    try checkMinutes(snapshot.capacityMinutes, "snapshot capacity")
    try checkIDs(snapshot.itemStates.map(\.itemID), "snapshot itemStates")
    try checkIDs(snapshot.availableActions.map(\.itemID), "snapshot actions")
    try checkIDs(snapshot.projects.map(\.projectID), "snapshot projects")
    for state in snapshot.itemStates {
        guard itemIDs.contains(state.itemID), state.isBlocked == !state.reasons.isEmpty else { throw CoreError.invalid("snapshot state 无效") }
    }
    for action in snapshot.availableActions {
        guard itemIDs.contains(action.itemID) else { throw CoreError.missing("snapshot action") }
        guard (action.remainingMinutes == nil) == (action.canFit == nil) else { throw CoreError.invalid("action canFit 与未知剩余不一致") }
        try checkMinutes(action.remainingMinutes, "action remaining")
        try checkMinutes(action.compatibleMinutes, "action capacity"); try checkMinutes(action.longestContinuousMinutes, "action continuous")
        guard action.longestContinuousMinutes <= action.compatibleMinutes else { throw CoreError.invalid("action continuous 超过 capacity") }
    }
    for project in snapshot.projects {
        guard projectIDs.contains(project.projectID), project.conditionalItemIDs.allSatisfy(itemIDs.contains) else { throw CoreError.missing("snapshot project") }
        try checkIDs(project.conditionalItemIDs, "snapshot conditionalItemIDs")
        try checkMinutes(project.demandMinutes, "project demand"); try checkMinutes(project.capacityMinutes, "project capacity")
        try checkMinutes(project.shortageMinutes, "project shortage")
    }
    for risk in snapshot.risks {
        guard risk.itemIDs.allSatisfy(itemIDs.contains), risk.projectID.map(projectIDs.contains) ?? true else { throw CoreError.missing("snapshot risk") }
        try checkIDs(risk.itemIDs, "snapshot risk itemIDs")
        try checkMinutes(risk.shortageMinutes, "risk shortage")
    }
}

// Saturation avoids traps even for very distant finite Dates / caller-supplied Int estimates.
func roundedMinutes(_ seconds: Double, up: Bool = false) -> Int {
    let value = up ? ceil(max(0, seconds) / 60 - 1e-9) : floor(max(0, seconds) / 60 + 1e-9)
    if value >= Double(Int.max) { return Int.max }
    return Int(max(0, value))
}
