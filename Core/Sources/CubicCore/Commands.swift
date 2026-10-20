import Foundation

extension Workspace {
    mutating func command(at now: Date, validateExisting: Bool = true, _ operation: (inout Workspace) throws -> Void) throws {
        try checkDate(now, "command.now")
        if validateExisting { try validate() }
        var draft = self
        try operation(&draft)
        try draft.validate()
        self = draft
    }
    func itemIndex(_ id: String) throws -> Int {
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw CoreError.missing("item: \(id)") }
        return index
    }
    func requireReady(_ id: String, includeReview: Bool = true) throws {
        let index = try itemIndex(id)
        guard items[index].effectiveDisposition == .active,
              reasons(for: id, includeReview: includeReview).isEmpty else { throw CoreError.blocked("item: \(id)") }
        if let nodeID = items[index].nodeID, let node = nodes.first(where: { $0.id == nodeID }) {
            let waiting = (node.blockerIDs ?? []).filter { blockerID in blockers.first(where: { $0.id == blockerID })?.state != .resolved }
            guard waiting.isEmpty else { throw CoreError.blocked("node waiting: " + waiting.joined(separator: ", ")) }
        }
    }
    @discardableResult mutating func appendHistory(_ kind: HistoryKind, id: String, now: Date, note: String = "", minutes: Int? = nil,
                                previousMinutes: Int? = nil, relatedIDs: [String]? = nil,
                                round: Int? = nil, reason: EstimateReason? = nil, detail: String? = nil) -> String {
        let event = HistoryEvent(date: now, kind: kind, objectID: id, note: note, minutes: minutes,
                                    previousMinutes: previousMinutes, relatedIDs: relatedIDs, round: round,
                                    changeReason: reason, detail: detail)
        history.append(event)
        return event.id
    }
    mutating func captureCreatedItemHistory(at index: Int, now: Date, note: String = "", relatedIDs: [String] = []) {
        let item = items[index]
        var related = relatedIDs
        var revisions: [EstimateRevision] = []
        if let initial = item.initialMinutes {
            let revision = EstimateRevision(itemID: item.id, date: now, minutes: initial, round: item.currentRound)
            revisions.append(revision); related.append(revision.id)
        }
        // Retain a distinct current estimate (including explicitly unknown) without mislabelling it as initial.
        if item.remainingMinutes != item.initialMinutes {
            let revision = EstimateRevision(itemID: item.id, date: now, minutes: item.remainingMinutes,
                                            previousMinutes: item.initialMinutes, round: item.currentRound)
            revisions.append(revision); related.append(revision.id)
        }
        if !revisions.isEmpty {
            if estimateRevisions == nil { estimateRevisions = [] }
            estimateRevisions?.append(contentsOf: revisions)
        }
        let eventID = appendHistory(.created, id: item.id, now: now, note: note, minutes: item.initialMinutes,
                                    relatedIDs: related.isEmpty ? nil : related, round: item.currentRound)
        if item.initialMinutes != nil { items[index].initialEstimateEventID = eventID }
    }
    mutating func preserveAcceptance(_ index: Int, now: Date) {
        let gate = acceptances[index]
        guard gate.state != .pending else { return }
        let date = gate.acceptedAt ?? gate.failedAt ?? now
        if !(acceptanceResults ?? []).contains(where: { $0.acceptanceID == gate.id && $0.round == gate.currentRound && $0.state == gate.state && $0.date == date }) {
            acceptanceResults = (acceptanceResults ?? []) + [AcceptanceResult(acceptanceID: gate.id, round: gate.currentRound,
                                                                             state: gate.state, date: date, reason: gate.reason ?? "")]
        }
    }
    mutating func resetGates(_ subject: WorkReference, now: Date) {
        for index in acceptances.indices where acceptances[index].subject == subject && acceptances[index].isActive {
            let unresolvedFailure = acceptances[index].state == .failed && acceptances[index].reworkScopeConfirmed != true
            let failedAt = acceptances[index].failedAt
            preserveAcceptance(index, now: now)
            acceptances[index].state = unresolvedFailure ? .failed : .pending
            acceptances[index].acceptedAt = nil
            acceptances[index].failedAt = unresolvedFailure ? failedAt : nil
            acceptances[index].reworkScopeConfirmed = unresolvedFailure ? false : nil
            switch subject {
            case .item(let id): acceptances[index].round = items.first { $0.id == id }?.currentRound ?? 1
            case .node(let id): acceptances[index].round = nodes.first { $0.id == id }?.currentRound ?? 1
            }
        }
    }
    func affectedSources(for itemID: String) -> [DependencySource] {
        var sources: [DependencySource] = [.item(itemID)]
        if let item = items.first(where: { $0.id == itemID }), item.required, let nodeID = item.nodeID { sources.append(.node(nodeID)) }
        return sources
    }
    mutating func reopenNodeResult(_ nodeID: String, now: Date) {
        guard let index = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        let hasResult = nodes[index].completedAt != nil || acceptances.contains { $0.subject == .node(nodeID) && $0.isActive && $0.state == .accepted }
        if hasResult { nodes[index].round = nodes[index].currentRound + 1 }
        nodes[index].completedAt = nil
        resetGates(.node(nodeID), now: now)
        reopenProjectResult(nodes[index].projectID, now: now)
    }
    mutating func reopenProjectResult(_ projectID: String, now: Date) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }), projects[index].effectiveStatus == .completed else { return }
        projects[index].status = .active; projects[index].completedAt = nil
        appendHistory(.scopeChanged, id: projectID, now: now, note: "交付成果失效，项目重新打开")
    }
    mutating func resetItemGates(_ itemID: String, now: Date) {
        resetGates(.item(itemID), now: now)
        if let item = items.first(where: { $0.id == itemID }), item.required, let nodeID = item.nodeID { reopenNodeResult(nodeID, now: now) }
        for projectID in items.first(where: { $0.id == itemID })?.projectIDs ?? [] { reopenProjectResult(projectID, now: now) }
    }
    mutating func applyInvalidation(_ impact: DomainInvalidation, now: Date) {
        // One index/sweep per closure, including nodes with no own item. Never rebuild DomainIndex per item.
        let nodePositions = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) })
        let itemPositions = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
        let acceptedNodes = Set(acceptances.compactMap { gate -> String? in
            guard gate.isActive, gate.state == .accepted, case .node(let id) = gate.subject else { return nil }
            return id
        })
        for id in impact.itemIDs {
            if let position = itemPositions[id], items[position].status != .pending { items[position].needsReview = true }
        }
        for id in impact.nodeIDs {
            guard let position = nodePositions[id] else { continue }
            if nodes[position].completedAt != nil || acceptedNodes.contains(id) { nodes[position].round = nodes[position].currentRound + 1 }
            nodes[position].completedAt = nil
        }
        var results = acceptanceResults ?? []
        let recorded = Dictionary(grouping: results, by: \.acceptanceID)
        for position in acceptances.indices where acceptances[position].isActive {
            let gate = acceptances[position]
            let affected: Bool; let round: Int
            switch gate.subject {
            case .item(let id): affected = impact.itemIDs.contains(id); round = itemPositions[id].map { items[$0].currentRound } ?? gate.currentRound
            case .node(let id): affected = impact.nodeIDs.contains(id); round = nodePositions[id].map { nodes[$0].currentRound } ?? gate.currentRound
            }
            guard affected else { continue }
            if gate.state != .pending {
                let date = gate.acceptedAt ?? gate.failedAt ?? now
                if !(recorded[gate.id] ?? []).contains(where: { $0.round == gate.currentRound && $0.state == gate.state && $0.date == date }) {
                    results.append(AcceptanceResult(acceptanceID: gate.id, round: gate.currentRound, state: gate.state, date: date, reason: gate.reason ?? ""))
                }
            }
            let unresolvedFailure = gate.state == .failed && gate.reworkScopeConfirmed != true
            acceptances[position].state = unresolvedFailure ? .failed : .pending
            acceptances[position].acceptedAt = nil
            acceptances[position].failedAt = unresolvedFailure ? gate.failedAt : nil
            acceptances[position].reworkScopeConfirmed = unresolvedFailure ? false : nil
            acceptances[position].round = round
        }
        if !results.isEmpty || acceptanceResults != nil { acceptanceResults = results }
        for position in projects.indices where impact.projectIDs.contains(projects[position].id) && projects[position].effectiveStatus == .completed {
            let id = projects[position].id
            projects[position].status = .active; projects[position].completedAt = nil
            appendHistory(.scopeChanged, id: id, now: now, note: "交付成果失效，项目重新打开")
        }
    }
    mutating func invalidate(items initial: [String], now: Date) {
        let index = DomainIndex(self)
        applyInvalidation(index.invalidationClosure(of: initial.map(DependencySource.item), includeSources: true), now: now)
    }
    mutating func invalidateDownstream(of sources: [DependencySource], now: Date) {
        let index = DomainIndex(self)
        applyInvalidation(index.invalidationClosure(of: sources), now: now)
    }
    mutating func ensureWorkRound(itemID: String, now: Date) throws -> Int {
        let item = items[try itemIndex(itemID)]
        if let index = (workRounds ?? []).firstIndex(where: { $0.itemID == itemID && $0.round == item.currentRound }) { return index }
        var rounds = workRounds ?? []
        rounds.append(WorkRound(itemID: itemID, round: item.currentRound, openedAt: item.started ?? now,
                                initialMinutes: item.currentRound == 1 ? item.initialMinutes : item.remainingMinutes,
                                preStartMinutes: item.currentRound == 1 ? item.preStartMinutes : nil,
                                startedAt: item.started, completedAt: item.completedAt))
        workRounds = rounds
        return rounds.count - 1
    }
    mutating func beginItem(_ id: String, at now: Date) throws {
        let index = try itemIndex(id)
        guard items[index].status == .pending else { throw CoreError.invalid("仅 pending 可开工") }
        try requireReady(id)
        guard items[index].started.map({ $0 <= now }) ?? true else { throw CoreError.invalid("新轮开工早于既有事实") }
        let roundIndex = try ensureWorkRound(itemID: id, now: now)
        items[index].status = .inProgress; items[index].startTimeIsUnknown = false
        // started is the first recorded true start; never synthesize one for legacy completion.
        if items[index].started == nil { items[index].started = now }
        if items[index].currentRound == 1 {
            items[index].preStartMinutes = items[index].remainingMinutes
            items[index].preStartCapturedAt = now
        }
        workRounds?[roundIndex].startedAt = now
        workRounds?[roundIndex].preStartMinutes = items[index].remainingMinutes
        let sources = DomainIndex(self).sourcesUsed(for: id)
        workRounds?[roundIndex].sources = sources
        appendHistory(.baselineCaptured, id: id, now: now, minutes: items[index].remainingMinutes, round: items[index].currentRound)
        appendHistory(.started, id: id, now: now, round: items[index].currentRound)
    }
    mutating func changeRemaining(itemID: String, minutes: Int?, now: Date, reason: EstimateReason? = nil,
                                   note: String = "", correctsRevisionID: String? = nil) throws {
        let index = try itemIndex(itemID)
        guard items[index].status != .completed else { throw CoreError.invalid("已完成任务须先返工") }
        let previous = items[index].remainingMinutes
        let capturesInitial = items[index].initialMinutes == nil && minutes != nil
        if capturesInitial { items[index].initialMinutes = minutes }
        items[index].remainingMinutes = minutes
        let revision = EstimateRevision(itemID: itemID, date: now, minutes: minutes, previousMinutes: previous,
                                        reason: reason, note: note, round: items[index].currentRound, correctsRevisionID: correctsRevisionID)
        estimateRevisions = (estimateRevisions ?? []) + [revision]
        let eventID = appendHistory(capturesInitial || correctsRevisionID == nil ? .remainingUpdated : .estimateCorrected, id: itemID, now: now,
                      note: note, minutes: minutes, previousMinutes: previous, relatedIDs: [revision.id],
                      round: items[index].currentRound, reason: reason)
        if capturesInitial { items[index].initialEstimateEventID = eventID }
    }
    public mutating func addProject(_ project: Project, now: Date) throws {
        try command(at: now) { draft in draft.projects.append(project); draft.appendHistory(.created, id: project.id, now: now) }
    }
    public mutating func addNode(_ node: Node, now: Date) throws {
        try command(at: now) { draft in
            var value = node
            draft.ensureNodeStructureOrders(projectID: node.projectID)
            value.structureOrder = (draft.nodes.filter { $0.projectID == node.projectID }.compactMap(\.structureOrder).max() ?? 0) + 1
            value.sequentialPredecessorNodeID = draft.projectStructure(projectID: node.projectID).nodes.last?.id
            value.sequentialDependenciesInitialized = true
            draft.nodes.append(value); draft.reopenProjectResult(node.projectID, now: now)
            draft.appendHistory(.created, id: node.id, now: now)
        }
    }
    public mutating func addItem(_ item: WorkItem, now: Date) throws {
        try command(at: now) { draft in
            var value = item
            if value.structureOrder == nil, let nodeID = value.nodeID {
                draft.ensureWorkStructureOrders(nodeID: nodeID)
                value.structureOrder = (draft.items.filter { $0.nodeID == nodeID }.compactMap(\.structureOrder).max() ?? 0) + 1
            }
            guard value.initialEstimateEventID == nil else { throw CoreError.invalid("新建初估来源由创建命令采集，不可复制历史来源") }
            if value.initialMinutes == nil { value.initialMinutes = value.remainingMinutes }
            draft.items.append(value)
            if value.required, let nodeID = value.nodeID {
                draft.reopenNodeResult(nodeID, now: now); draft.invalidateDownstream(of: [.node(nodeID)], now: now)
            }
            for projectID in value.projectIDs where value.required { draft.reopenProjectResult(projectID, now: now) }
            draft.captureCreatedItemHistory(at: draft.items.count - 1, now: now)
            if let nodeID = value.nodeID {
                try draft.initializeSequentialDependencies(nodeID: nodeID, now: now)
                try draft.addSequentialPredecessor(to: value.id, nodeID: nodeID, now: now)
            }
        }
    }
    public mutating func addBlocker(_ blocker: Blocker, now: Date) throws {
        try command(at: now) { draft in draft.blockers.append(blocker); draft.appendHistory(.created, id: blocker.id, now: now) }
    }
    public mutating func addDependency(_ dependency: Dependency, now: Date) throws {
        try command(at: now) { draft in
            var value = dependency; value.createdAt = value.createdAt ?? now; value.effectiveAt = value.effectiveAt ?? now
            draft.dependencies.append(value)
            // Changing the declared inputs of existing work requires checking its result even if the new source is ready.
            draft.invalidate(items: [value.targetItemID], now: now)
            draft.appendHistory(.dependencyAdded, id: value.id, now: now, relatedIDs: [value.source.id, value.targetItemID])
        }
    }
    public mutating func addAcceptance(_ acceptance: Acceptance, now: Date) throws {
        try command(at: now) { draft in
            guard acceptance.state == .pending else { throw CoreError.invalid("新验收必须 pending；通过逐项 accept") }
            var value = acceptance
            switch value.subject {
            case .item(let id): value.round = draft.items[try draft.itemIndex(id)].currentRound
            case .node(let id):
                draft.reopenNodeResult(id, now: now)
                value.round = draft.nodes.first { $0.id == id }?.currentRound ?? 1
            }
            draft.acceptances.append(value)
            if value.required {
                switch value.subject {
                case .item(let id): if let nodeID = draft.items.first(where: { $0.id == id })?.nodeID {
                    draft.reopenNodeResult(nodeID, now: now); draft.invalidateDownstream(of: [.node(nodeID)], now: now)
                }
                case .node(let id): draft.invalidateDownstream(of: [.node(id)], now: now)
                }
            }
            draft.appendHistory(.acceptanceAdded, id: value.id, now: now)
        }
    }
    public mutating func startItem(id: String, now: Date) throws { try command(at: now) { try $0.beginItem(id, at: now) } }
    public mutating func recordWork(itemID: String, start: Date, end: Date, actualMinutes: Int,
                                    remainingMinutes: Int?, note: String = "") throws {
        try recordWork(itemID: itemID, start: start, end: end, actualMinutes: actualMinutes,
                       remaining: remainingMinutes.map(RemainingUpdate.minutes) ?? .unknown, note: note)
    }
    public mutating func recordWork(itemID: String, start: Date, end: Date, actualMinutes: Int,
                                    remaining: RemainingUpdate = .unchanged, note: String = "") throws {
        try command(at: end) { draft in
            let index = try draft.itemIndex(itemID)
            try checkInterval(start, end, "recordWork", allowEmpty: true)
            guard draft.items[index].status != .completed else { throw CoreError.invalid("已完成任务不能记录当前投入；可使用补录/更正") }
            try draft.requireReady(itemID)
            if draft.items[index].status == .pending { try draft.beginItem(itemID, at: start) }
            try draft.applyRemaining(remaining, itemID: itemID, now: end, note: note)
            draft.workSessions.append(WorkSession(itemID: itemID, start: start, end: end, actualMinutes: actualMinutes,
                                                  remainingMinutesAfter: draft.items[index].remainingMinutes,
                                                  recordedAt: end, round: draft.items[index].currentRound))
            draft.appendHistory(.effortRecorded, id: itemID, now: end, note: note, minutes: actualMinutes, round: draft.items[index].currentRound)
        }
    }
    public mutating func recordApproximateWork(itemID: String, recordedAt: Date, actualMinutes: Int,
                                               remainingMinutes: Int?, note: String = "") throws {
        try recordApproximateWork(itemID: itemID, occurredOn: recordedAt, recordedAt: recordedAt, actualMinutes: actualMinutes,
                                 remaining: remainingMinutes.map(RemainingUpdate.minutes) ?? .unknown, note: note)
    }
    public mutating func recordApproximateWork(itemID: String, occurredOn: Date, recordedAt: Date, actualMinutes: Int,
                                               remaining: RemainingUpdate = .unchanged, note: String = "") throws {
        try command(at: recordedAt) { draft in
            let index = try draft.itemIndex(itemID)
            try checkDate(occurredOn, "occurredOn")
            guard occurredOn <= recordedAt else { throw CoreError.invalid("投入归属日期不能在记录之后") }
            try draft.requireReady(itemID)
            guard draft.items[index].status != .completed else { throw CoreError.invalid("已完成轮次请用显式历史补录") }
            // Current labor has the same gate regardless of interval precision.
            if draft.items[index].status == .pending, actualMinutes > 0 {
                let roundIndex = try draft.ensureWorkRound(itemID: itemID, now: recordedAt)
                let sources = DomainIndex(draft).sourcesUsed(for: itemID)
                draft.workRounds?[roundIndex].sources = sources
                draft.items[index].status = .inProgress
                draft.items[index].startTimeIsUnknown = draft.items[index].started == nil
                draft.appendHistory(.started, id: itemID, now: recordedAt, note: "补录实际投入证明已执行；实际开工时点未知，未补造基线", round: draft.items[index].currentRound)
            }
            try draft.applyRemaining(remaining, itemID: itemID, now: recordedAt, note: note)
            draft.workSessions.append(WorkSession(itemID: itemID, start: recordedAt, end: recordedAt, actualMinutes: actualMinutes,
                                                  remainingMinutesAfter: draft.items[index].remainingMinutes, intervalIsExact: false,
                                                  occurredOn: occurredOn, recordedAt: recordedAt, round: draft.items[index].currentRound))
            draft.appendHistory(.effortRecorded, id: itemID, now: recordedAt, note: note, minutes: actualMinutes, round: draft.items[index].currentRound)
        }
    }
    /// Historical supplement only: explicit occurrence and round, with no current progress/estimate mutation.
    public mutating func recordHistoricalApproximateWork(itemID: String, occurredOn: Date, round: Int,
                                                         recordedAt: Date, actualMinutes: Int, note: String = "") throws {
        try command(at: recordedAt) { draft in
            let item = draft.items[try draft.itemIndex(itemID)]
            try checkDate(occurredOn, "historical occurredOn"); try checkRound(round, "historical round")
            try checkMinutes(actualMinutes, "historical actualMinutes")
            guard occurredOn < recordedAt, round <= item.currentRound else { throw CoreError.invalid("历史补录必须明确过去发生日期和既有轮次") }
            let rounds = (draft.workRounds ?? []).filter { $0.itemID == itemID }
            let selected = rounds.first { $0.round == round }
            let isCurrent = round == item.currentRound
            let existing = draft.workSessions.contains { $0.itemID == itemID && ($0.round ?? 1) == round && $0.actualMinutes > 0 }
            let started = selected != nil ? selected?.startedAt : (round == 1 && item.currentRound == 1 ? item.started : nil)
            let completed = selected?.completedAt ?? (isCurrent ? item.completedAt : nil)
            guard selected != nil || isCurrent, started != nil || completed != nil || existing else {
                throw CoreError.invalid("所选轮次没有既有执行/完成事实，不能以历史补录伪造新轮已开工")
            }
            let lower = started ?? (round > 1 ? selected?.openedAt : nil)
            let nextOpening = rounds.filter { $0.round > round }.map(\.openedAt).min()
            guard lower.map({ $0 <= occurredOn }) ?? true,
                  completed.map({ occurredOn <= $0 }) ?? true,
                  nextOpening.map({ occurredOn < $0 }) ?? true else { throw CoreError.invalid("历史补录发生日期不属于所选工作轮次") }
            draft.workSessions.append(WorkSession(itemID: itemID, start: recordedAt, end: recordedAt,
                actualMinutes: actualMinutes, intervalIsExact: false, occurredOn: occurredOn,
                recordedAt: recordedAt, round: round))
            draft.appendHistory(.effortRecorded, id: itemID, now: recordedAt, note: "历史补录：" + note,
                                minutes: actualMinutes, round: round)
        }
    }
    mutating func applyRemaining(_ remaining: RemainingUpdate, itemID: String, now: Date, note: String) throws {
        switch remaining { case .unchanged: break
        case .unknown: try changeRemaining(itemID: itemID, minutes: nil, now: now, note: note)
        case .minutes(let value): try changeRemaining(itemID: itemID, minutes: value, now: now, note: note) }
    }
    public mutating func updateRemaining(itemID: String, minutes: Int?, now: Date) throws {
        try updateRemaining(itemID: itemID, minutes: minutes, now: now, reason: nil)
    }
    public mutating func updateRemaining(itemID: String, minutes: Int?, now: Date, reason: EstimateReason?, note: String = "") throws {
        try command(at: now) { try $0.changeRemaining(itemID: itemID, minutes: minutes, now: now, reason: reason, note: note) }
    }
    public mutating func completeItem(id: String, now: Date) throws {
        try command(at: now) { draft in
            let index = try draft.itemIndex(id)
            guard draft.items[index].status != .completed else { throw CoreError.invalid("任务已经完成") }
            try draft.requireReady(id)
            guard draft.items[index].started.map({ $0 <= now }) ?? true,
                  draft.effectiveWorkSessions.filter({ $0.itemID == id && $0.hasExactInterval }).allSatisfy({ $0.end <= now }) else {
                throw CoreError.invalid("完成早于实际工作")
            }
            let roundIndex = try draft.ensureWorkRound(itemID: id, now: now)
            draft.items[index].status = .completed; draft.items[index].completedAt = now; draft.items[index].remainingMinutes = 0
            draft.workRounds?[roundIndex].completedAt = now
            draft.appendHistory(.completed, id: id, now: now, round: draft.items[index].currentRound)
        }
    }
    mutating func reopenItem(_ id: String, remainingMinutes: Int?, now: Date, note: String) throws {
        let index = try itemIndex(id)
        guard items[index].completedAt.map({ $0 <= now }) ?? true,
              items[index].started.map({ $0 <= now }) ?? true else { throw CoreError.invalid("返工早于既有工作") }
        _ = try ensureWorkRound(itemID: id, now: now)
        items[index].round = items[index].currentRound + 1
        // Opening rework does not mean the new round has actually started.
        items[index].status = .pending; items[index].completedAt = nil
        items[index].needsReview = false; items[index].disposition = .active; items[index].startTimeIsUnknown = nil
        items[index].effortRecordingComplete = false
        workRounds = (workRounds ?? []) + [WorkRound(itemID: id, round: items[index].currentRound, openedAt: now, initialMinutes: remainingMinutes)]
        try changeRemaining(itemID: id, minutes: remainingMinutes, now: now, reason: .rework, note: note)
        resetItemGates(id, now: now); invalidateDownstream(of: affectedSources(for: id), now: now)
        appendHistory(.reworked, id: id, now: now, note: note, minutes: remainingMinutes, round: items[index].currentRound)
    }
    public mutating func reworkItem(id: String, remainingMinutes: Int?, now: Date, note: String = "") throws {
        try command(at: now) { try $0.reopenItem(id, remainingMinutes: remainingMinutes, now: now, note: note) }
    }
    public mutating func reviewItem(id: String, now: Date, note: String = "") throws {
        try reviewItem(id: id, outcome: .stillValid, now: now, note: note)
    }
    public mutating func reviewItem(id: String, outcome: ReviewOutcome, now: Date, note: String = "") throws {
        try command(at: now) { draft in
            let index = try draft.itemIndex(id)
            let domain = DomainIndex(draft)
            let legacyEligibilityGap = draft.items[index].status == .completed && !domain.itemValid(id)
            guard draft.items[index].needsReview || legacyEligibilityGap else { throw CoreError.invalid("任务无需复核") }
            guard draft.items[index].completedAt.map({ $0 <= now }) ?? true,
                  draft.items[index].started.map({ $0 <= now }) ?? true else { throw CoreError.invalid("复核时间无效") }
            draft.items[index].needsReview = outcome != .stillValid
            let consumed = (draft.workRounds ?? []).last { $0.itemID == id && $0.round == draft.items[index].currentRound }?.sources ?? []
            let record = ReviewRecord(itemID: id, date: now, outcome: outcome, sources: consumed, note: note,
                                      currentSources: domain.sourcesUsed(for: id), round: draft.items[index].currentRound)
            draft.reviews = (draft.reviews ?? []) + [record]
            draft.appendHistory(.reviewed, id: id, now: now, note: note, relatedIDs: [record.id], round: draft.items[index].currentRound)
        }
    }
    mutating func storeBlockerRound(_ index: Int) {
        let value = blockers[index]
        let snapshot = BlockerRound(blockerID: value.id, round: value.currentRound, triggeredAt: value.triggeredAt,
                                    expectedResolution: value.expectedResolution, expectedDurationMinutes: value.expectedDurationMinutes,
                                    followUpAt: value.followUpAt, resolvedAt: value.resolvedAt)
        var rounds = blockerRounds ?? []
        if let position = rounds.firstIndex(where: { $0.blockerID == value.id && $0.round == value.currentRound }) {
            rounds[position] = snapshot
        } else { rounds.append(snapshot) }
        blockerRounds = rounds
    }
    mutating func beginBlocker(_ id: String, now: Date) throws {
        guard let index = blockers.firstIndex(where: { $0.id == id }) else { throw CoreError.missing("blocker: \(id)") }
        guard blockers[index].state != .active else { throw CoreError.invalid("blocker 已触发") }
        guard blockers[index].resolvedAt.map({ $0 <= now }) ?? true else { throw CoreError.invalid("触发早于上次解除") }
        if blockers[index].state == .resolved {
            storeBlockerRound(index); blockers[index].round = blockers[index].currentRound + 1
            // An explicit absolute expectation from the previous round is not a new promise.
            blockers[index].expectedResolution = nil
        }
        blockers[index].state = .active; blockers[index].triggeredAt = now; blockers[index].resolvedAt = nil
        storeBlockerRound(index)
        invalidateDownstream(of: [.blocker(id)], now: now)
        appendHistory(.blockerTriggered, id: id, now: now, round: blockers[index].currentRound)
    }
    public mutating func triggerBlocker(id: String, now: Date) throws { try command(at: now) { try $0.beginBlocker(id, now: now) } }
    public mutating func resolveBlocker(id: String, now: Date) throws {
        try command(at: now) { draft in
            guard let index = draft.blockers.firstIndex(where: { $0.id == id }) else { throw CoreError.missing("blocker: \(id)") }
            guard draft.blockers[index].state == .active else { throw CoreError.invalid("只能解除已触发 blocker") }
            draft.blockers[index].state = .resolved; draft.blockers[index].resolvedAt = now
            draft.storeBlockerRound(index)
            draft.appendHistory(.blockerResolved, id: id, now: now, round: draft.blockers[index].currentRound)
        }
    }
    mutating func acceptCriterion(_ id: String, now: Date, reusedResultID: String? = nil, note: String = "") throws {
        guard let index = acceptances.firstIndex(where: { $0.id == id && $0.isActive }) else { throw CoreError.missing("acceptance: \(id)") }
        let subject = acceptances[index].subject
        guard acceptances[index].state != .accepted else { throw CoreError.invalid("本轮条件已经通过") }
        guard acceptances[index].state != .failed || acceptances[index].reworkScopeConfirmed == true else {
            throw CoreError.blocked("失败条件需确认实际返工范围")
        }
        let domain = DomainIndex(self)
        guard subjectResultDates(subject).allSatisfy({ $0 <= now }) else { throw CoreError.invalid("验收早于已有完成/解除事实") }
        switch subject {
        case .item(let itemID):
            guard domain.itemValid(itemID) else { throw CoreError.blocked("验收对象未完成或需要复核") }
            acceptances[index].round = items[try itemIndex(itemID)].currentRound
        case .node(let nodeID):
            guard nodeCompletionIssues(id: nodeID, includeAcceptance: false).isEmpty else { throw CoreError.blocked("节点必需范围、工作、等待或复核尚未处理") }
            acceptances[index].round = nodes.first { $0.id == nodeID }?.currentRound ?? 1
        }
        guard acceptances[index].failedAt.map({ $0 <= now }) ?? true else { throw CoreError.invalid("验收早于失败事实") }
        preserveAcceptance(index, now: now)
        acceptances[index].state = .accepted; acceptances[index].acceptedAt = now; acceptances[index].failedAt = nil
        acceptances[index].reason = note
        let result = AcceptanceResult(acceptanceID: id, round: acceptances[index].currentRound, state: .accepted,
                                      date: now, reason: note, reusedResultID: reusedResultID)
        acceptanceResults = (acceptanceResults ?? []) + [result]
        appendHistory(.accepted, id: id, now: now, note: note, relatedIDs: [result.id], round: acceptances[index].currentRound)
    }
    public mutating func accept(id: String, now: Date) throws { try command(at: now) { try $0.acceptCriterion(id, now: now) } }
    public mutating func recordDecision(_ trial: TrialResult, now: Date, note: String = "") throws {
        try command(at: now) { draft in
            let decision = Decision(date: now, note: note, trial: trial)
            draft.decisions.append(decision); draft.appendHistory(.decisionRecorded, id: decision.id, now: now, note: note)
            if let itemID = trial.selections.first?.itemID {
                let choice = NextActionChoice(itemID: itemID, date: now, note: note, trial: trial,
                                              displayedItemIDs: trial.selections.map(\.itemID), impactWasVerified: false)
                draft.choices = (draft.choices ?? []) + [choice]; draft.currentChoiceID = choice.id
                draft.appendHistory(.choiceRecorded, id: choice.id, now: now, note: note)
            }
        }
    }
}
