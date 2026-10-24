import Foundation

extension Workspace {
    public mutating func updateProject(_ project: Project, now: Date, note: String = "") throws {
        try command(at: now) { draft in
            guard let index = draft.projects.firstIndex(where: { $0.id == project.id }) else { throw CoreError.missing("project: \(project.id)") }
            let old = draft.projects[index]
            guard project.completedAt == old.completedAt,
                  project.effectiveStatus != .completed || old.effectiveStatus == .completed else { throw CoreError.invalid("项目完成需 completeProject") }
            draft.projects[index] = project
            let kind: HistoryKind = old.deadline != project.deadline || old.deadlineTimeZoneID != project.deadlineTimeZoneID || old.deadlineIsDateOnly != project.deadlineIsDateOnly ? .deadlineChanged :
                old.planningCompleteness != project.planningCompleteness || old.status != project.status ? .scopeChanged : .edited
            if project.effectiveStatus == .completed, !draft.projectCompletionIssues(id: project.id).isEmpty {
                draft.projects[index].status = .active; draft.projects[index].completedAt = nil
            }
            draft.appendHistory(kind, id: project.id, now: now, note: note, detail: try domainChangeDetail(old, project))
        }
    }
    public mutating func updateNode(_ node: Node, now: Date, note: String = "") throws {
        try command(at: now) { draft in
            guard let index = draft.nodes.firstIndex(where: { $0.id == node.id }) else { throw CoreError.missing("node: \(node.id)") }
            let old = draft.nodes[index]
            guard node.projectID == old.projectID, node.completedAt == old.completedAt, node.round == old.round,
                  node.needsReview == old.needsReview, node.structureOrder == old.structureOrder,
                  node.sequentialPredecessorNodeID == old.sequentialPredecessorNodeID else { throw CoreError.invalid("节点归属/完成/轮次/复核不可通过编辑覆盖") }
            draft.nodes[index] = node
            let changed = old.required != node.required || old.planningCompleteness != node.planningCompleteness || old.blockerIDs != node.blockerIDs || old.outcome != node.outcome
            if changed {
                draft.reopenNodeResult(node.id, now: now)
                if old.blockerIDs != node.blockerIDs {
                    // Adding/removing a whole-node prerequisite changes the actual inputs of every member.
                    let members = draft.items.filter { $0.nodeID == node.id }.map(\.id)
                    draft.invalidate(items: members, now: now)
                }
                draft.invalidateDownstream(of: [.node(node.id)], now: now)
            }
            draft.appendHistory(changed ? .scopeChanged : .edited, id: node.id, now: now, note: note, detail: try domainChangeDetail(old, node))
        }
    }
    public mutating func updateItem(_ item: WorkItem, now: Date, note: String = "") throws {
        try command(at: now) { draft in
            let index = try draft.itemIndex(item.id); let old = draft.items[index]
            guard item.status == old.status, item.started == old.started, item.completedAt == old.completedAt,
                  item.initialMinutes == old.initialMinutes, item.initialEstimateEventID == old.initialEstimateEventID,
                  item.preStartMinutes == old.preStartMinutes,
                  item.preStartCapturedAt == old.preStartCapturedAt, item.round == old.round,
                  item.needsReview == old.needsReview, item.disposition == old.disposition, item.startTimeIsUnknown == old.startTimeIsUnknown else {
                throw CoreError.invalid("业务事实与基线需专用命令，不能经普通编辑覆盖")
            }
            let scopeChanged = old.nodeID != item.nodeID || old.projectIDs != item.projectIDs || old.required != item.required || old.description != item.description
            // Capture inputs before membership changes, and before reopening any delivery rounds.
            let previousIndex = scopeChanged ? DomainIndex(draft) : nil
            var value = item; value.remainingMinutes = old.remainingMinutes
            if old.nodeID != item.nodeID, let nodeID = item.nodeID {
                draft.ensureWorkStructureOrders(nodeID: nodeID)
                value.structureOrder = (draft.items.filter { $0.nodeID == nodeID }.compactMap(\.structureOrder).max() ?? 0) + 1
            }
            draft.items[index] = value
            // Membership and its generated edges form one atomic edit, checked at the outer command boundary.
            if old.nodeID != item.nodeID {
                // A moved work item leaves its old default chain; explicit and manually removed edges stay intact.
                let generated = draft.dependencies.filter { dependency in
                    guard let oldNodeID = old.nodeID else { return false }
                    return dependency.isActive && dependency.id.hasPrefix("node-order:\(oldNodeID):") &&
                        (dependency.targetItemID == item.id || dependency.source == .item(item.id))
                }
                let removedIDs = Set(generated.map(\.id))
                for index in draft.dependencies.indices where removedIDs.contains(draft.dependencies[index].id) {
                    let previous = draft.dependencies[index]
                    draft.dependencies[index].removedAt = now
                    draft.dependencies[index].revision = previous.currentRevision + 1
                    draft.appendHistory(.dependencyRemoved, id: previous.id, now: now, note: "调整节点归属，更新默认顺序",
                                        relatedIDs: [previous.source.id, previous.targetItemID],
                                        detail: try domainChangeDetail(previous, draft.dependencies[index]))
                }
                if let oldNodeID = old.nodeID {
                    let members = Self.inStructureOrder(draft.items.filter { $0.nodeID == oldNodeID && !$0.archived }, order: { $0.structureOrder })
                    for member in members.dropFirst() {
                        try draft.addSequentialPredecessor(to: member.id, nodeID: oldNodeID, now: now, ignoringDependencies: removedIDs)
                    }
                }
                if let nodeID = item.nodeID {
                    try draft.initializeSequentialDependencies(nodeID: nodeID, now: now)
                    try draft.addSequentialPredecessor(to: item.id, nodeID: nodeID, now: now, ignoringDependencies: removedIDs)
                }
            }
            if old.remainingMinutes != item.remainingMinutes {
                try draft.changeRemaining(itemID: item.id, minutes: item.remainingMinutes, now: now, reason: .revision, note: note)
            }
            if let previousIndex {
                let currentIndex = DomainIndex(draft)
                let inputsMatch = effectiveSourceConditionsMatch(previousIndex.sourcesUsed(for: item.id),
                                                                currentIndex.sourcesUsed(for: item.id))
                var roots: [DependencySource] = []
                if old.nodeID != item.nodeID || old.required != item.required || old.description != item.description {
                    roots = Set([old.nodeID, item.nodeID].compactMap { $0 }).map(DependencySource.node)
                }
                if !inputsMatch || old.description != item.description && old.status != .pending {
                    roots.append(.item(item.id))
                }
                // Union both graphs so migration cannot lose the old delivery scopes; reset each result only once.
                var impact = previousIndex.invalidationClosure(of: roots, includeSources: true)
                let currentImpact = currentIndex.invalidationClosure(of: roots, includeSources: true)
                impact.itemIDs.formUnion(currentImpact.itemIDs); impact.nodeIDs.formUnion(currentImpact.nodeIDs)
                impact.projectIDs.formUnion(currentImpact.projectIDs); impact.projectIDs.formUnion(old.projectIDs + item.projectIDs)
                draft.applyInvalidation(impact, now: now)
            }
            let kind: HistoryKind = scopeChanged ? .scopeChanged : old.deadline != item.deadline || old.deadlineTimeZoneID != item.deadlineTimeZoneID ? .deadlineChanged : .edited
            draft.appendHistory(kind, id: item.id, now: now, note: note, detail: try domainChangeDetail(old, item))
        }
    }
    public mutating func updateBlocker(_ blocker: Blocker, now: Date, note: String = "") throws {
        try command(at: now) { draft in
            guard let index = draft.blockers.firstIndex(where: { $0.id == blocker.id }) else { throw CoreError.missing("blocker: \(blocker.id)") }
            let old = draft.blockers[index]
            guard blocker.state == old.state, blocker.triggeredAt == old.triggeredAt,
                  blocker.resolvedAt == old.resolvedAt, blocker.round == old.round else { throw CoreError.invalid("等待状态需 trigger/resolve 命令") }
            guard old.state != .resolved || old.resolutionCondition == blocker.resolutionCondition else {
                throw CoreError.invalid("已解除条件修改需先重开等待")
            }
            draft.blockers[index] = blocker; draft.storeBlockerRound(index)
            // An estimate/follow-up change is not result invalidation.
            if old.resolutionCondition != blocker.resolutionCondition { draft.invalidateDownstream(of: [.blocker(blocker.id)], now: now) }
            draft.appendHistory(.blockerUpdated, id: blocker.id, now: now, note: note, round: blocker.currentRound,
                                detail: try domainChangeDetail(old, blocker))
        }
    }
    public mutating func updateAcceptance(_ acceptance: Acceptance, now: Date, note: String = "") throws {
        try command(at: now) { draft in
            guard let index = draft.acceptances.firstIndex(where: { $0.id == acceptance.id && $0.isActive }) else { throw CoreError.missing("acceptance: \(acceptance.id)") }
            let old = draft.acceptances[index]
            guard acceptance.subject == old.subject, acceptance.state == old.state, acceptance.acceptedAt == old.acceptedAt,
                  acceptance.failedAt == old.failedAt, acceptance.round == old.round,
                  acceptance.reworkScopeConfirmed == old.reworkScopeConfirmed, acceptance.removedAt == nil else {
                throw CoreError.invalid("验收事实需专用命令")
            }
            draft.acceptances[index] = acceptance
            if old.name != acceptance.name {
                draft.preserveAcceptance(index, now: now)
                switch old.subject {
                case .node(let id): draft.reopenNodeResult(id, now: now); draft.invalidateDownstream(of: [.node(id)], now: now)
                case .item(let id):
                    draft.resetGates(.item(id), now: now)
                    if let nodeID = draft.items.first(where: { $0.id == id })?.nodeID {
                        draft.reopenNodeResult(nodeID, now: now); draft.invalidateDownstream(of: [.node(nodeID)], now: now)
                    }
                }
            }
            draft.appendHistory(.acceptanceChanged,
                                id: acceptance.id, now: now, note: note, detail: try domainChangeDetail(old, acceptance))
        }
    }
    public mutating func updateDependency(_ dependency: Dependency, now: Date, note: String = "") throws {
        try command(at: now) { draft in
            guard let index = draft.dependencies.firstIndex(where: { $0.id == dependency.id && $0.isActive }) else { throw CoreError.missing("dependency: \(dependency.id)") }
            let old = draft.dependencies[index]
            guard dependency.removedAt == nil else { throw CoreError.invalid("移除依赖需 removeDependency") }
            var value = dependency; value.createdAt = old.createdAt; value.effectiveAt = now; value.revision = old.currentRevision + 1
            draft.dependencies[index] = value
            draft.invalidate(items: Array(Set([old.targetItemID, value.targetItemID])).sorted(), now: now)
            draft.appendHistory(.dependencyChanged, id: value.id, now: now, note: note,
                                relatedIDs: [old.source.id, old.targetItemID, value.source.id, value.targetItemID], detail: try domainChangeDetail(old, value))
        }
    }
    public mutating func removeDependency(id: String, now: Date, note: String = "") throws {
        try command(at: now) { draft in
            guard let index = draft.dependencies.firstIndex(where: { $0.id == id && $0.isActive }) else { throw CoreError.missing("dependency: \(id)") }
            let old = draft.dependencies[index]
            draft.dependencies[index].removedAt = now; draft.dependencies[index].revision = old.currentRevision + 1
            draft.invalidate(items: [old.targetItemID], now: now)
            draft.appendHistory(.dependencyRemoved, id: id, now: now, note: note, relatedIDs: [old.source.id, old.targetItemID], detail: try domainChangeDetail(old, draft.dependencies[index]))
        }
    }
    public mutating func removeAcceptance(id: String, now: Date, note: String = "") throws {
        try command(at: now) { draft in
            guard let index = draft.acceptances.firstIndex(where: { $0.id == id && $0.isActive }) else { throw CoreError.missing("acceptance: \(id)") }
            let gate = draft.acceptances[index]; draft.preserveAcceptance(index, now: now)
            draft.acceptances[index].removedAt = now
            switch gate.subject {
            case .node(let nodeID): draft.reopenNodeResult(nodeID, now: now); draft.invalidateDownstream(of: [.node(nodeID)], now: now)
            case .item(let itemID): if let nodeID = draft.items.first(where: { $0.id == itemID })?.nodeID {
                draft.reopenNodeResult(nodeID, now: now); draft.invalidateDownstream(of: [.node(nodeID)], now: now)
            }
            }
            draft.appendHistory(.acceptanceRemoved, id: id, now: now, note: note, detail: try domainChangeDetail(gate, draft.acceptances[index]))
        }
    }
    public mutating func addWorkLink(_ link: WorkLink, now: Date) throws {
        try command(at: now) { draft in
            guard link.removedAt == nil else { throw CoreError.invalid("新引用不能已移除") }
            draft.workLinks = (draft.workLinks ?? []) + [link]
            if let nodeID = link.nodeID { draft.reopenNodeResult(nodeID, now: now); draft.invalidateDownstream(of: [.node(nodeID)], now: now) }
            draft.reopenProjectResult(link.projectID, now: now)
            draft.appendHistory(.scopeChanged, id: link.id, now: now, note: "引用现有工作，未复制劳动", relatedIDs: [link.source.id, link.projectID])
        }
    }
    public mutating func removeWorkLink(id: String, now: Date, note: String = "") throws {
        try command(at: now) { draft in
            guard let index = (draft.workLinks ?? []).firstIndex(where: { $0.id == id && $0.removedAt == nil }), let old = draft.workLinks?[index] else { throw CoreError.missing("workLink: \(id)") }
            draft.workLinks?[index].removedAt = now
            if let nodeID = old.nodeID { draft.reopenNodeResult(nodeID, now: now); draft.invalidateDownstream(of: [.node(nodeID)], now: now) }
            draft.reopenProjectResult(old.projectID, now: now)
            draft.appendHistory(.scopeChanged, id: id, now: now, note: note, relatedIDs: [old.source.id, old.projectID], detail: try domainChangeDetail(old, draft.workLinks![index]))
        }
    }
    public mutating func setItemProjectReference(itemID: String, projectID: String, included: Bool, now: Date) throws {
        try command(at: now) { draft in
            let index = try draft.itemIndex(itemID)
            guard draft.projects.contains(where: { $0.id == projectID }) else { throw CoreError.missing("project: \(projectID)") }
            let old = draft.items[index]
            if !included, let nodeID = old.nodeID, draft.nodes.first(where: { $0.id == nodeID })?.projectID == projectID {
                throw CoreError.invalid("主归属不可作为共享引用移除；请显式调整归属")
            }
            if included { if !draft.items[index].projectIDs.contains(projectID) { draft.items[index].projectIDs.append(projectID) } }
            else { draft.items[index].projectIDs.removeAll { $0 == projectID } }
            draft.reopenProjectResult(projectID, now: now)
            draft.appendHistory(.scopeChanged, id: itemID, now: now, note: included ? "添加项目引用" : "移除项目引用，保留来源工作", relatedIDs: [projectID], detail: try domainChangeDetail(old, draft.items[index]))
        }
    }
    @discardableResult public mutating func copyItem(id: String, newID: String = UUID().uuidString, projectID: String, nodeID: String? = nil, now: Date) throws -> String {
        try command(at: now) { draft in
            let old = draft.items[try draft.itemIndex(id)]
            var item = WorkItem(id: newID, name: old.name, nodeID: nodeID, projectIDs: [projectID],
                                remainingMinutes: old.remainingMinutes, initialMinutes: old.remainingMinutes,
                                energy: old.energy, requiresContinuous: old.requiresContinuous,
                                description: old.description, contextTags: old.contextTags,
                                isRequired: old.isRequired, continuousMinutes: old.continuousMinutes)
            if let nodeID {
                draft.ensureWorkStructureOrders(nodeID: nodeID)
                item.structureOrder = (draft.items.filter { $0.nodeID == nodeID }.compactMap(\.structureOrder).max() ?? 0) + 1
            }
            draft.items.append(item)
            if let nodeID { draft.reopenNodeResult(nodeID, now: now); draft.invalidateDownstream(of: [.node(nodeID)], now: now) }
            draft.reopenProjectResult(projectID, now: now)
            draft.captureCreatedItemHistory(at: draft.items.count - 1, now: now,
                                           note: "显式创建独立副本；增加一份劳动需求", relatedIDs: [id])
            if let nodeID {
                try draft.initializeSequentialDependencies(nodeID: nodeID, now: now)
                try draft.addSequentialPredecessor(to: newID, nodeID: nodeID, now: now)
            }
        }
        return newID
    }
    public mutating func setArchived(_ subject: WorkReference, archived: Bool, now: Date) throws {
        try command(at: now) { draft in
            switch subject {
            case .item(let id): let index = try draft.itemIndex(id); draft.items[index].isArchived = archived
            case .node(let id):
                guard let index = draft.nodes.firstIndex(where: { $0.id == id }) else { throw CoreError.missing("node: \(id)") }
                draft.nodes[index].isArchived = archived
            }
            draft.appendHistory(archived ? .archived : .restored, id: subject.id, now: now)
        }
    }
    public mutating func setProjectArchived(id: String, archived: Bool, now: Date) throws {
        try command(at: now) { draft in
            guard let index = draft.projects.firstIndex(where: { $0.id == id }) else { throw CoreError.missing("project: \(id)") }
            draft.projects[index].isArchived = archived; draft.appendHistory(archived ? .archived : .restored, id: id, now: now)
        }
    }
    public mutating func setBlockerArchived(id: String, archived: Bool, now: Date) throws {
        try command(at: now) { draft in
            guard let index = draft.blockers.firstIndex(where: { $0.id == id }) else { throw CoreError.missing("blocker: \(id)") }
            draft.blockers[index].isArchived = archived; draft.appendHistory(archived ? .archived : .restored, id: id, now: now)
        }
    }
    public mutating func setItemDisposition(id: String, disposition: WorkDisposition, now: Date, note: String = "") throws {
        try command(at: now) { draft in
            let index = try draft.itemIndex(id); let old = draft.items[index]
            draft.items[index].disposition = disposition
            if disposition == .cancelled {
                draft.items[index].isRequired = false
                draft.resetItemGates(id, now: now)
                var sources: [DependencySource] = [.item(id)]
                if old.required, let nodeID = old.nodeID {
                    draft.reopenNodeResult(nodeID, now: now); sources.append(.node(nodeID))
                }
                draft.invalidateDownstream(of: sources, now: now)
            } else if old.effectiveDisposition == .cancelled {
                draft.items[index].isRequired = old.isRequired // false remains explicit; callers restore scope separately.
            }
            draft.appendHistory(disposition == .cancelled ? .cancelled : disposition == .deferred ? .deferred : .restored,
                                id: id, now: now, note: note, detail: try domainChangeDetail(old, draft.items[index]))
        }
    }
    public mutating func completeNode(id: String, now: Date) throws {
        try command(at: now) { draft in
            guard draft.nodeCompletionIssues(id: id).isEmpty else { throw CoreError.blocked("节点完成门槛未满足") }
            guard let index = draft.nodes.firstIndex(where: { $0.id == id }) else { throw CoreError.missing("node: \(id)") }
            guard draft.nodes[index].completedAt == nil else { throw CoreError.invalid("节点已经确认完成") }
            guard draft.subjectResultDates(.node(id)).allSatisfy({ $0 <= now }) else { throw CoreError.invalid("节点确认早于已有成果事实") }
            draft.nodes[index].completedAt = now; draft.appendHistory(.nodeCompleted, id: id, now: now, round: draft.nodes[index].currentRound)
        }
    }
    public mutating func completeProject(id: String, now: Date) throws {
        try command(at: now) { draft in
            guard draft.projectCompletionIssues(id: id).isEmpty else { throw CoreError.blocked("项目完成门槛未满足") }
            guard let index = draft.projects.firstIndex(where: { $0.id == id }) else { throw CoreError.missing("project: \(id)") }
            guard draft.projects[index].effectiveStatus != .completed && draft.projects[index].effectiveStatus != .cancelled else { throw CoreError.invalid("项目状态不可完成") }
            guard draft.items.filter({ $0.projectIDs.contains(id) }).compactMap(\.completedAt).allSatisfy({ $0 <= now }),
                  draft.nodes.filter({ $0.projectID == id }).compactMap(\.completedAt).allSatisfy({ $0 <= now }) else { throw CoreError.invalid("项目确认早于已有成果事实") }
            draft.projects[index].status = .completed; draft.projects[index].completedAt = now
            draft.appendHistory(.projectCompleted, id: id, now: now)
        }
    }
    public mutating func reopenProject(id: String, now: Date, note: String = "") throws {
        try command(at: now) { draft in
            guard let index = draft.projects.firstIndex(where: { $0.id == id }) else { throw CoreError.missing("project: \(id)") }
            draft.projects[index].status = .active; draft.projects[index].completedAt = nil
            draft.appendHistory(.scopeChanged, id: id, now: now, note: note)
        }
    }
    public mutating func setProjectDeadline(id: String, deadline: Date?, timeZoneID: String?, dateOnly: Bool = false, now: Date) throws {
        try command(at: now) { draft in
            guard let index = draft.projects.firstIndex(where: { $0.id == id }) else { throw CoreError.missing("project: \(id)") }
            let old = draft.projects[index]
            let value = try normalizedDeadline(deadline, zone: timeZoneID, dateOnly: dateOnly)
            draft.projects[index].deadline = value; draft.projects[index].deadlineTimeZoneID = timeZoneID
            draft.projects[index].deadlineIsDateOnly = dateOnly
            draft.appendHistory(.deadlineChanged, id: id, now: now, detail: try domainChangeDetail(old, draft.projects[index]))
        }
    }
    public mutating func setItemDeadline(id: String, deadline: Date?, timeZoneID: String?, dateOnly: Bool = false, now: Date) throws {
        try command(at: now) { draft in
            let index = try draft.itemIndex(id); let old = draft.items[index]
            draft.items[index].deadline = try normalizedDeadline(deadline, zone: timeZoneID, dateOnly: dateOnly)
            draft.items[index].deadlineTimeZoneID = timeZoneID; draft.items[index].deadlineIsDateOnly = dateOnly
            draft.appendHistory(.deadlineChanged, id: id, now: now, detail: try domainChangeDetail(old, draft.items[index]))
        }
    }
    public mutating func correctEstimate(revisionID: String, minutes: Int?, now: Date, note: String = "") throws {
        try command(at: now) { draft in
            guard let revision = (draft.estimateRevisions ?? []).first(where: { $0.id == revisionID }) else { throw CoreError.missing("estimateRevision: \(revisionID)") }
            guard revision.date <= now, !(draft.estimateRevisions ?? []).contains(where: { $0.correctsRevisionID == revisionID }) else { throw CoreError.invalid("估计已经被更正或更正早于原事实") }
            let item = draft.items[try draft.itemIndex(revision.itemID)]
            // Correct an old fact without silently replacing a later legitimate estimate.
            let latest = draft.effectiveEstimateRevisions.last { $0.itemID == item.id && $0.round == item.currentRound }
            if revision.round == item.currentRound && latest?.id == revisionID && item.status != .completed {
                try draft.changeRemaining(itemID: item.id, minutes: minutes, now: now, reason: .correction, note: note, correctsRevisionID: revisionID)
            } else {
                let correction = EstimateRevision(itemID: revision.itemID, date: now, minutes: minutes,
                    previousMinutes: revision.minutes, reason: .correction, note: note,
                    round: revision.round, correctsRevisionID: revisionID)
                draft.estimateRevisions = (draft.estimateRevisions ?? []) + [correction]
                draft.appendHistory(.estimateCorrected, id: item.id, now: now, note: note, minutes: minutes,
                                    previousMinutes: revision.minutes, relatedIDs: [revisionID, correction.id],
                                    round: revision.round, reason: .correction)
            }
        }
    }
    public mutating func correctWorkSession(id: String, replacement: WorkSession?, now: Date, note: String = "") throws {
        try command(at: now) { draft in try draft.replaceWorkSession(id, replacement: replacement, now: now, note: note) }
    }
    mutating func replaceWorkSession(_ id: String, replacement: WorkSession?, now: Date, note: String) throws {
        guard let old = effectiveWorkSessions.first(where: { $0.id == id }) else { throw CoreError.missing("有效 workSession: \(id)") }
        guard (old.recordedAt ?? old.end) <= now else { throw CoreError.invalid("更正早于原记录") }
        var value = replacement ?? old
        value.id = replacement?.id ?? UUID().uuidString
        guard value.id != id else { throw CoreError.invalid("更正必须是新记录 ID") }
        value.correctsSessionID = id; value.recordedAt = now
        if replacement == nil { value.isVoided = true }
        workSessions.append(value)
        appendHistory(.effortCorrected, id: value.itemID, now: now, note: note, minutes: value.actualMinutes,
                      previousMinutes: old.actualMinutes, relatedIDs: [id, value.id], detail: try domainChangeDetail(old, value))
    }
    public mutating func confirmEffortAllocation(sessionIDs: [String], allocatedMinutes: [Int], now: Date) throws {
        try command(at: now) { draft in
            try checkIDs(sessionIDs, "分摊投入")
            guard sessionIDs.count >= 2 && sessionIDs.count == allocatedMinutes.count else { throw CoreError.invalid("分摊需至少两条有效记录及逐项分钟") }
            let effective = Dictionary(uniqueKeysWithValues: draft.effectiveWorkSessions.map { ($0.id, $0) })
            let sessions = try sessionIDs.map { id -> WorkSession in
                guard let session = effective[id], session.hasExactInterval else { throw CoreError.invalid("分摊须为有效精确区间") }
                return session
            }
            let chosen = Set(sessionIDs)
            // Include every record in the connected overlap component, not just a convenient subset.
            var connected = chosen, changed = true
            while changed {
                changed = false
                for candidate in effective.values where candidate.hasExactInterval && candidate.actualMinutes > 0 && !connected.contains(candidate.id) {
                    if effective.values.contains(where: { connected.contains($0.id) && $0.start < candidate.end && candidate.start < $0.end }) {
                        connected.insert(candidate.id); changed = true
                    }
                }
            }
            guard connected == chosen else { throw CoreError.invalid("需核对整组重叠记录，不能仅确认其中一部分") }
            var intervals = sessions.map { ($0.start, $0.end) }.sorted { $0.0 < $1.0 }
            var unionSeconds = 0.0
            if let first = intervals.first {
                var start = first.0, end = first.1
                intervals.removeFirst()
                for value in intervals {
                    if value.0 <= end { end = max(end, value.1) }
                    else { unionSeconds += end.timeIntervalSince(start); start = value.0; end = value.1 }
                }
                unionSeconds += end.timeIntervalSince(start)
            }
            var total = 0
            for minutes in allocatedMinutes { try checkMinutes(minutes, "分摊分钟"); total += minutes }
            guard Double(total) <= unionSeconds / 60 + 0.0001 else { throw CoreError.invalid("分摊合计超过唯一实际时间") }
            var allocated = sessions
            for position in allocated.indices { allocated[position].actualMinutes = allocatedMinutes[position] }
            try validateEffortAllocation(allocated)
            let groupID = UUID().uuidString
            for (offset, old) in sessions.enumerated() {
                var replacement = old; replacement.id = UUID().uuidString
                replacement.actualMinutes = allocatedMinutes[offset]; replacement.allocationGroupID = groupID
                try draft.replaceWorkSession(old.id, replacement: replacement, now: now, note: "人工核对重叠并显式分摊")
            }
        }
    }
    public mutating func setEffortRecordingComplete(itemID: String, complete: Bool, now: Date) throws {
        try command(at: now) { draft in
            let index = try draft.itemIndex(itemID); draft.items[index].effortRecordingComplete = complete
            draft.appendHistory(.edited, id: itemID, now: now, note: complete ? "人工确认投入记录完整" : "投入记录不完整")
        }
    }
    public mutating func failAcceptance(id: String, now: Date, reason: String = "") throws {
        try command(at: now) { draft in
            guard let index = draft.acceptances.firstIndex(where: { $0.id == id && $0.isActive }) else { throw CoreError.missing("acceptance: \(id)") }
            let subject = draft.acceptances[index].subject
            guard (draft.acceptances[index].acceptedAt ?? draft.acceptances[index].failedAt).map({ $0 <= now }) ?? true else { throw CoreError.invalid("失败早于原验收结果") }
            draft.preserveAcceptance(index, now: now)
            switch subject {
            case .node(let nodeID): draft.reopenNodeResult(nodeID, now: now); draft.invalidateDownstream(of: [.node(nodeID)], now: now)
            case .item(let itemID):
                if let nodeID = draft.items.first(where: { $0.id == itemID })?.nodeID {
                    draft.reopenNodeResult(nodeID, now: now); draft.invalidateDownstream(of: [.node(nodeID)], now: now)
                }
            }
            draft.acceptances[index].state = .failed; draft.acceptances[index].acceptedAt = nil
            draft.acceptances[index].failedAt = now; draft.acceptances[index].reason = reason
            draft.acceptances[index].reworkScopeConfirmed = false
            let result = AcceptanceResult(acceptanceID: id, round: draft.acceptances[index].currentRound, state: .failed, date: now, reason: reason)
            draft.acceptanceResults = (draft.acceptanceResults ?? []) + [result]
            draft.appendHistory(.acceptanceFailed, id: id, now: now, note: reason, relatedIDs: [result.id], round: draft.acceptances[index].currentRound)
        }
    }
    public mutating func confirmAcceptanceRework(id: String, itemIDs: [String], blockerIDs: [String], remainingByItem: [String: Int] = [:], now: Date, note: String = "") throws {
        try command(at: now) { draft in
            guard let index = draft.acceptances.firstIndex(where: { $0.id == id && $0.isActive && $0.state == .failed && $0.reworkScopeConfirmed != true }) else { throw CoreError.invalid("需要尚未确认范围的失败验收") }
            try checkIDs(itemIDs, "实际返工工作"); try checkIDs(blockerIDs, "实际返工等待")
            guard Set(remainingByItem.keys).isSubset(of: Set(itemIDs)) else { throw CoreError.invalid("返工估计必须属于已确认工作") }
            let gate = draft.acceptances[index]
            // Candidates are hints; users may explicitly select additional existing work.
            for itemID in itemIDs { try draft.reopenItem(itemID, remainingMinutes: remainingByItem[itemID], now: now, note: note) }
            for blockerID in blockerIDs { try draft.beginBlocker(blockerID, now: now) }
            draft.acceptances[index].state = .failed; draft.acceptances[index].acceptedAt = nil
            draft.acceptances[index].failedAt = gate.failedAt; draft.acceptances[index].reason = gate.reason
            draft.acceptances[index].reworkScopeConfirmed = true
            draft.appendHistory(.scopeChanged, id: id, now: now, note: note, relatedIDs: itemIDs + blockerIDs,
                                round: draft.acceptances[index].currentRound)
        }
    }
    public mutating func reuseAcceptanceResult(id: String, resultID: String, now: Date, note: String = "") throws {
        try command(at: now) { draft in
            guard let result = (draft.acceptanceResults ?? []).first(where: { $0.id == resultID && $0.acceptanceID == id && $0.state == .accepted }), result.date <= now else { throw CoreError.invalid("沿用需明确选择该条件的历史通过结果") }
            try draft.acceptCriterion(id, now: now, reusedResultID: resultID, note: note)
        }
    }
    public mutating func reviewNode(id: String, outcome: ReviewOutcome, now: Date, note: String = "") throws {
        try command(at: now) { draft in
            guard let index = draft.nodes.firstIndex(where: { $0.id == id }), draft.nodes[index].needsReview == true else { throw CoreError.invalid("节点不存在或无需复核") }
            guard draft.subjectResultDates(.node(id)).allSatisfy({ $0 <= now }) else { throw CoreError.invalid("复核早于原成果事实") }
            let old = draft.nodes[index]
            draft.nodes[index].needsReview = outcome != .stillValid
            // Member reviews, required blockers and manual gates remain independent gates.
            draft.appendHistory(.reviewed, id: id, now: now, note: note, round: draft.nodes[index].currentRound,
                                detail: try domainChangeDetail(old, draft.nodes[index]))
        }
    }
    public mutating func chooseNextAction(itemID: String?, now: Date, trial: TrialResult? = nil, displayedItemIDs: [String] = [], dataVersion: String? = nil, impactWasVerified: Bool = false, note: String = "") throws {
        try command(at: now) { draft in
            if let itemID {
                let item = draft.items[try draft.itemIndex(itemID)]
                guard item.status != .completed && item.effectiveDisposition == .active else { throw CoreError.invalid("当前选择需为未完成有效行动") }
            }
            let choice = NextActionChoice(itemID: itemID, date: now, note: note, trial: trial, displayedItemIDs: displayedItemIDs,
                                          dataVersion: dataVersion, impactWasVerified: impactWasVerified)
            draft.choices = (draft.choices ?? []) + [choice]; draft.currentChoiceID = choice.id
            draft.appendHistory(.choiceRecorded, id: choice.id, now: now, note: note)
        }
    }
}

func normalizedDeadline(_ deadline: Date?, zone: String?, dateOnly: Bool) throws -> Date? {
    try checkDate(deadline, "deadline")
    if let zone, TimeZone(identifier: zone) == nil { throw CoreError.invalid("截止时区无效") }
    if dateOnly, let deadline {
        guard let zone else { throw CoreError.invalid("日期型截止需要明确时区") }
        return try Workspace.dateOnlyDeadline(on: deadline, timeZoneID: zone)
    }
    return deadline
}
func domainChangeDetail<T: Encodable>(_ old: T, _ new: T) throws -> String {
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970; encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(DomainChange(before: old, after: new)), as: UTF8.self)
}

private struct DomainChange<Value: Encodable>: Encodable { let before: Value; let after: Value }
