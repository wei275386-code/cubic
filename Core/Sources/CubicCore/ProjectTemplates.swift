import Foundation

private let templateMaximumDayOffset = 36_500
private let templateMaximumSecondOffset: Double = 36_500 * 86_400

private func templateFailureMessage(_ error: Error) -> String {
    switch error {
    case CoreError.invalid(let message), CoreError.missing(let message), CoreError.blocked(let message): return message
    case CoreError.cycle: return "模板中存在循环依赖，请调整前置关系。"
    default: return "模板内容无效：\(error)"
    }
}

extension ProjectTemplatePayload {
    /// Separate from Workspace.validate: a quarantined template cannot disable existing planning.
    public func validate() throws {
        guard version == Self.currentVersion else { throw CoreError.invalid("模板内容版本不受支持：\(version)") }
        let ids = [project.id] + nodes.map(\.id) + items.map(\.id) + blockers.map(\.id)
            + dependencies.map(\.id) + acceptances.map(\.id) + workLinks.map(\.id)
        try checkIDs(ids, "template snapshot")
        func name(_ value: String) throws {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CoreError.invalid("模板名称不能为空") }
        }
        func order(_ value: Int) throws { guard value > 0 else { throw CoreError.invalid("模板结构顺序须为正数") } }
        try name(project.name)
        guard (0...5).contains(project.importance) else { throw CoreError.invalid("模板 importance 必须为 0...5") }
        try checkMinutes(project.warningBufferMinutes, "template.warningBufferMinutes")
        let nodeIDs = Set(nodes.map(\.id)), itemIDs = Set(items.map(\.id)), blockerIDs = Set(blockers.map(\.id))
        func reference(_ value: WorkReference) throws {
            switch value {
            case .item(let id): guard itemIDs.contains(id) else { throw CoreError.missing("模板 item：\(id)") }
            case .node(let id): guard nodeIDs.contains(id) else { throw CoreError.missing("模板 node：\(id)") }
            }
        }
        func vertex(_ value: DependencySource) throws -> String {
            switch value {
            case .item(let id): try reference(.item(id)); return "i:" + id
            case .node(let id): try reference(.node(id)); return "n:" + id
            case .blocker(let id): guard blockerIDs.contains(id) else { throw CoreError.missing("模板 blocker：\(id)") }; return "b:" + id
            }
        }
        var graph: [String: Set<String>] = [:], members: [String: [String]] = [:]
        for item in items {
            try name(item.name); try order(item.structureOrder)
            try checkMinutes(item.durationMinutes, "template.durationMinutes")
            try checkMinutes(item.continuousMinutes, "template.continuousMinutes")
            guard item.continuousMinutes != 0 else { throw CoreError.invalid("模板连续时长须为正数") }
            try checkIDs(item.contextTags, "template.contextTags")
            graph["i:" + item.id, default: []] = []
            if let nodeID = item.nodeID {
                guard nodeIDs.contains(nodeID) else { throw CoreError.missing("模板工作所属节点：\(nodeID)") }
                graph["i:" + item.id, default: []].insert("n:" + nodeID)
                members[nodeID, default: []].append(item.id)
            }
            switch item.deadlineRule {
            case .calendarDays(let days):
                guard (-templateMaximumDayOffset...templateMaximumDayOffset).contains(days) else { throw CoreError.invalid("模板日期偏移超出 100 年范围") }
            case .seconds(let seconds):
                guard seconds.isFinite, abs(seconds) <= templateMaximumSecondOffset else { throw CoreError.invalid("模板秒数偏移无效或超出 100 年范围") }
            case nil: break
            }
        }
        for node in nodes {
            try name(node.name); try order(node.structureOrder); try checkIDs(node.blockerIDs, "template.node.blockerIDs")
            guard node.blockerIDs.allSatisfy(blockerIDs.contains) else { throw CoreError.missing("模板节点等待条件") }
            graph["n:" + node.id, default: []] = []
            if let predecessor = node.sequentialPredecessorNodeID {
                guard nodeIDs.contains(predecessor), predecessor != node.id else { throw CoreError.invalid("模板节点顺序前置无效") }
                graph["n:" + predecessor, default: []].insert("n:" + node.id)
                for item in members[node.id] ?? [] { graph["n:" + predecessor, default: []].insert("i:" + item) }
            }
            for blocker in node.blockerIDs {
                graph["b:" + blocker, default: []].insert("n:" + node.id)
                for item in members[node.id] ?? [] { graph["b:" + blocker, default: []].insert("i:" + item) }
            }
        }
        for blocker in blockers {
            try name(blocker.name); try checkMinutes(blocker.expectedDurationMinutes, "template.blocker.expectedDurationMinutes")
            if let id = blocker.followUpItemID, !itemIDs.contains(id) { throw CoreError.missing("模板 followUpItemID：\(id)") }
        }
        var edges = Set<String>()
        for dependency in dependencies {
            guard itemIDs.contains(dependency.targetItemID) else { throw CoreError.missing("模板依赖 target：\(dependency.targetItemID)") }
            let source = try vertex(dependency.source), target = "i:" + dependency.targetItemID
            guard edges.insert(source + "→" + target).inserted else { throw CoreError.invalid("模板重复有效依赖") }
            graph[source, default: []].insert(target)
        }
        var aliases = Set<String>()
        for link in workLinks {
            try reference(link.source); try order(link.structureOrder)
            if let node = link.nodeID, !nodeIDs.contains(node) { throw CoreError.missing("模板引用位置：\(node)") }
            let source: String
            switch link.source { case .item(let id): source = "i:" + id; case .node(let id): source = "n:" + id }
            guard aliases.insert(source + "→" + (link.nodeID ?? "")).inserted else { throw CoreError.invalid("模板重复共享引用") }
            if link.isRequired, let node = link.nodeID { graph[source, default: []].insert("n:" + node) }
        }
        for acceptance in acceptances {
            try name(acceptance.name); try reference(acceptance.subject)
            try checkIDs(acceptance.candidateItemIDs ?? [], "template.acceptance.candidateItemIDs")
            try checkIDs(acceptance.candidateBlockerIDs ?? [], "template.acceptance.candidateBlockerIDs")
            guard (acceptance.candidateItemIDs ?? []).allSatisfy(itemIDs.contains),
                  (acceptance.candidateBlockerIDs ?? []).allSatisfy(blockerIDs.contains) else {
                throw CoreError.missing("模板验收条件的返工候选内容缺失")
            }
        }
        try validateAcyclic(graph)
    }
}

extension Workspace {
    public func projectTemplate(id: String) -> ProjectTemplate? { (projectTemplates ?? []).first { $0.id == id } }
    /// Source collection order is retained. UI may choose its own metadata sort.
    public func availableProjectTemplates(includeArchived: Bool = false) -> [ProjectTemplate] {
        (projectTemplates ?? []).filter { !$0.isRemoved && (includeArchived || !$0.archived) }
    }

    /// Pure extraction. baselineDeadline is used only when the source has no project deadline.
    /// baselineTimeZoneID is required for a date-only baseline; UTC is the deterministic legacy fallback.
    public func previewProjectTemplate(projectID: String, baselineDeadline: Date? = nil,
                                       baselineTimeZoneID: String? = nil, baselineIsDateOnly: Bool = false) -> ProjectTemplatePreview {
        var errors: [ProjectTemplateIssue] = [], warnings: [ProjectTemplateIssue] = []
        func issue(_ code: ProjectTemplateIssueCode, _ message: String, _ id: String? = nil) -> ProjectTemplateIssue {
            .init(code: code, message: message, objectID: id)
        }
        guard let project = projects.first(where: { $0.id == projectID }) else {
            return .init(payload: nil, errors: [issue(.missingProject, "项目不存在", projectID)])
        }
        guard !project.archived, project.effectiveStatus != .cancelled else {
            return .init(payload: nil, errors: [issue(.excludedScope, "归档或取消项目不能保存为模板", projectID)])
        }
        // Check identities before indexing. Dictionary(uniqueKeysWithValues:) must never trap on imported data.
        do {
            try checkIDs(projects.map(\.id), "projects"); try checkIDs(nodes.map(\.id), "nodes")
            try checkIDs(items.map(\.id), "items"); try checkIDs(blockers.map(\.id), "blockers")
            try checkIDs(dependencies.map(\.id), "dependencies"); try checkIDs(acceptances.map(\.id), "acceptances")
            try checkIDs((workLinks ?? []).map(\.id), "workLinks")
            try checkIDs((estimateRevisions ?? []).map(\.id), "estimateRevisions")
        } catch { return .init(payload: nil, errors: [issue(.invalidPayload, templateFailureMessage(error))]) }
        let nodeMap = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let blockerMap = Dictionary(uniqueKeysWithValues: blockers.map { ($0.id, $0) })
        let sourceNames = (nodes.map { ($0.id, $0.name) } + items.map { ($0.id, $0.name) }
            + blockers.map { ($0.id, $0.name) }).reduce(into: [String: String]()) { $0[$1.0] = $1.1 }
        let selectedNodes = Self.inStructureOrder(nodes.filter { $0.projectID == projectID && !$0.archived }, order: { $0.structureOrder })
        let selectedNodeIDs = Set(selectedNodes.map(\.id))
        for node in selectedNodes {
            if let predecessor = node.sequentialPredecessorNodeID, !selectedNodeIDs.contains(predecessor) {
                errors.append(issue(.externalDependency, "节点前置不在模板范围内：\(node.name)", node.id))
            }
        }
        for node in nodes where node.projectID == projectID && node.archived {
            warnings.append(issue(.excludedScope, "归档节点及其成员不复制：\(node.name)", node.id))
        }
        var selectedItems: [WorkItem] = []
        for item in items {
            let ownsNode = item.nodeID.flatMap { nodeMap[$0] }?.projectID == projectID
            guard item.projectIDs.contains(projectID) || ownsNode else { continue }
            if let nodeID = item.nodeID, nodeMap[nodeID] == nil {
                errors.append(issue(.invalidPayload, "工作所属节点缺失：\(item.name)", item.id)); continue
            }
            if item.archived || item.effectiveDisposition == .cancelled {
                warnings.append(issue(.excludedScope, "归档或取消工作不复制：\(item.name)", item.id)); continue
            }
            // A member of an archived source node is excluded, never flattened into direct project work.
            if ownsNode, let nodeID = item.nodeID, !selectedNodeIDs.contains(nodeID) {
                warnings.append(issue(.excludedScope, "归档节点成员不复制：\(item.name)", item.id)); continue
            }
            guard item.projectIDs.contains(projectID) else {
                errors.append(issue(.invalidPayload, "工作所属项目与节点不一致：\(item.name)", item.id)); continue
            }
            selectedItems.append(item)
        }
        selectedItems = Self.inStructureOrder(selectedItems, order: { $0.structureOrder })
        let selectedItemIDs = Set(selectedItems.map(\.id))
        func contains(_ reference: WorkReference) -> Bool {
            switch reference { case .item(let id): return selectedItemIDs.contains(id); case .node(let id): return selectedNodeIDs.contains(id) }
        }
        var selectedLinks: [WorkLink] = []
        for link in Self.inStructureOrder(workLinks ?? [], order: { $0.structureOrder }) where link.projectID == projectID && link.removedAt == nil {
            if let node = link.nodeID, !selectedNodeIDs.contains(node) {
                if nodeMap[node]?.projectID == projectID && nodeMap[node]?.archived == true {
                    warnings.append(issue(.excludedScope, "归档节点内的共享引用不复制", link.id))
                } else { errors.append(issue(.externalWorkLink, "共享引用位置不在有效结构内：\(sourceNames[node] ?? node)", link.id)) }
                continue
            }
            guard contains(link.source) else {
                errors.append(issue(.externalWorkLink, "共享引用来源不在模板有效结构内：\(sourceNames[link.source.id] ?? link.source.id)", link.id)); continue
            }
            selectedLinks.append(link)
        }
        let selectedAcceptances = acceptances.filter { $0.isActive && contains($0.subject) }
        var selectedBlockerIDs = Set(selectedNodes.flatMap { $0.blockerIDs ?? [] })
        for acceptance in selectedAcceptances {
            selectedBlockerIDs.formUnion(acceptance.candidateBlockerIDs ?? [])
            for id in acceptance.candidateItemIDs ?? [] where !selectedItemIDs.contains(id) {
                errors.append(issue(.externalDependency, "验收条件“\(acceptance.name)”的返工候选工作不在模板有效结构内：\(sourceNames[id] ?? id)", acceptance.id))
            }
        }
        // Involved blocker definitions are discovered from included dependency targets in one pass.
        for dependency in dependencies where dependency.isActive && selectedItemIDs.contains(dependency.targetItemID) {
            if case .blocker(let id) = dependency.source { selectedBlockerIDs.insert(id) }
        }
        var selectedDependencies: [Dependency] = []
        for dependency in dependencies where dependency.isActive {
            let sourceInside: Bool
            switch dependency.source {
            case .item(let id): sourceInside = selectedItemIDs.contains(id)
            case .node(let id): sourceInside = selectedNodeIDs.contains(id)
            case .blocker(let id): sourceInside = selectedBlockerIDs.contains(id)
            }
            let targetInside = selectedItemIDs.contains(dependency.targetItemID)
            guard sourceInside || targetInside else { continue }
            guard sourceInside && targetInside else {
                errors.append(issue(.externalDependency, "前置关系涉及模板外的内容：\(sourceNames[dependency.source.id] ?? dependency.source.id) → \(sourceNames[dependency.targetItemID] ?? dependency.targetItemID)", dependency.id)); continue
            }
            selectedDependencies.append(dependency)
        }
        let selectedBlockers = blockers.filter { selectedBlockerIDs.contains($0.id) }
        for id in selectedBlockerIDs.sorted() where blockerMap[id] == nil || blockerMap[id]?.isArchived == true {
            errors.append(issue(.missingBlocker, "等待条件缺失或已归档：\(sourceNames[id] ?? id)", id))
        }
        // Every payload identity is distinct from every source runtime identity.
        var ids: [String: String] = [:]
        let sourceIDs = [project.id] + selectedNodes.map(\.id) + selectedItems.map(\.id) + selectedBlockers.map(\.id)
            + selectedDependencies.map(\.id) + selectedAcceptances.map(\.id) + selectedLinks.map(\.id)
        do { try checkIDs(sourceIDs, "snapshot source identities") } catch {
            errors.append(issue(.invalidPayload, templateFailureMessage(error)))
            return .init(payload: nil, errors: errors, warnings: warnings)
        }
        for id in sourceIDs { ids[id] = UUID().uuidString }
        func remap(_ reference: WorkReference) -> WorkReference {
            switch reference { case .item(let id): return .item(ids[id]!); case .node(let id): return .node(ids[id]!) }
        }
        let needsAnchor = project.deadline == nil && selectedItems.contains { $0.deadline != nil } && baselineDeadline == nil
        if needsAnchor { errors.append(issue(.needsDeadlineAnchor, "项目没有截止日期；请提供模板基准截止日期以保存工作相对截止", projectID)) }
        var anchor = project.deadline ?? baselineDeadline
        let anchorZone = project.deadline != nil ? (project.deadlineTimeZoneID ?? "UTC") : (baselineTimeZoneID ?? "UTC")
        let anchorDateOnly = project.deadline != nil ? project.deadlineIsDateOnly == true : baselineIsDateOnly
        do {
            try checkDate(anchor, "template deadline anchor")
            guard TimeZone(identifier: anchorZone) != nil else { throw CoreError.invalid("模板基准时区无效") }
            if anchorDateOnly, project.deadline == nil, baselineTimeZoneID == nil { throw CoreError.invalid("日期型模板基准需明确时区") }
            if anchorDateOnly, project.deadline != nil, project.deadlineTimeZoneID == nil { throw CoreError.invalid("日期型项目截止需明确时区") }
            if let value = anchor, anchorDateOnly { anchor = try Self.dateOnlyDeadline(on: value, timeZoneID: anchorZone) }
        } catch { errors.append(issue(.invalidDeadline, templateFailureMessage(error), projectID)); anchor = nil }
        let revisions = estimateRevisions ?? []
        let superseded = Set(revisions.compactMap(\.correctsRevisionID))
        // O(history): one indexed selection, current round first, then latest applicable earlier round.
        var latestByItemRound: [String: [Int: EstimateRevision]] = [:]
        for revision in revisions where selectedItemIDs.contains(revision.itemID) && !superseded.contains(revision.id) {
            guard let minutes = revision.minutes, (0...5_256_000).contains(minutes), revision.date.timeIntervalSince1970.isFinite else { continue }
            let old = latestByItemRound[revision.itemID]?[revision.round]
            if old == nil || old!.date < revision.date || (old!.date == revision.date && old!.id < revision.id) {
                latestByItemRound[revision.itemID, default: [:]][revision.round] = revision
            }
        }
        var snapshotItems: [ProjectTemplateWork] = []
        for (offset, item) in selectedItems.enumerated() {
            var duration = item.remainingMinutes ?? 60
            if item.status != .completed, item.remainingMinutes == nil {
                warnings.append(issue(.durationFallback, "工作未设置耗时，模板耗时使用 60 分钟：\(item.name)", item.id))
            }
            if item.status == .completed {
                let byRound = latestByItemRound[item.id] ?? [:]
                let latest = byRound[item.currentRound] ?? byRound.values.filter { $0.round <= item.currentRound }.max {
                    $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date
                }
                if let minutes = latest?.minutes { duration = minutes }
                else {
                    duration = 60
                    warnings.append(issue(.durationFallback, "已完成工作没有可用的耗时修改记录，模板耗时使用 60 分钟：\(item.name)", item.id))
                }
            }
            var rule: ProjectTemplateDeadlineRule?
            if let deadline = item.deadline, let anchor {
                do {
                    try checkDate(deadline, "template work deadline")
                    if item.deadlineIsDateOnly == true {
                        guard let zoneID = item.deadlineTimeZoneID else { throw CoreError.invalid("日期型工作截止需明确时区") }
                        guard let zone = TimeZone(identifier: zoneID) else { throw CoreError.invalid("工作截止时区无效") }
                        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
                        let normalized = try Self.dateOnlyDeadline(on: deadline, timeZoneID: zoneID)
                        guard let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: anchor), to: calendar.startOfDay(for: normalized)).day else {
                            throw CoreError.invalid("截止日期不能计算 Calendar-day 偏移")
                        }
                        rule = .calendarDays(days)
                    } else {
                        if let zone = item.deadlineTimeZoneID, TimeZone(identifier: zone) == nil { throw CoreError.invalid("工作截止时区无效") }
                        rule = .seconds(deadline.timeIntervalSince(anchor))
                    }
                } catch { errors.append(issue(.invalidDeadline, templateFailureMessage(error), item.id)) }
            }
            snapshotItems.append(.init(id: ids[item.id]!, name: item.name, description: item.description,
                nodeID: item.nodeID.flatMap { selectedNodeIDs.contains($0) ? ids[$0] : nil }, durationMinutes: duration,
                energy: item.energy, requiresContinuous: item.requiresContinuous, continuousMinutes: item.continuousMinutes,
                contextTags: item.contextTags ?? [], isRequired: item.required, deadlineRule: rule, structureOrder: offset + 1))
        }
        let snapshotBlockers = selectedBlockers.map { blocker -> ProjectTemplateBlocker in
            if blocker.expectedResolution != nil || blocker.followUpAt != nil {
                warnings.append(issue(.clearedBlockerDates, "等待条件的旧预计解除/跟进日期会清空；静态等待时长保留：\(blocker.name)", blocker.id))
            }
            var followUpID: String?
            if let id = blocker.followUpItemID {
                if selectedItemIDs.contains(id) { followUpID = ids[id] }
                else { warnings.append(issue(.clearedExternalFollowUp, "等待条件的外部跟进工作引用会清空：\(blocker.name)", blocker.id)) }
            }
            return .init(id: ids[blocker.id]!, name: blocker.name, resolutionCondition: blocker.resolutionCondition,
                expectedDurationMinutes: blocker.expectedDurationMinutes, contactNote: blocker.contactNote, followUpItemID: followUpID)
        }
        // Never dereference an incomplete graph after collecting a specific preview blocker.
        guard errors.isEmpty else { return .init(payload: nil, errors: errors, warnings: warnings, needsDeadlineAnchor: needsAnchor) }
        let payload = ProjectTemplatePayload(project: .init(id: ids[project.id]!, name: project.name,
            description: project.description, importance: project.importance, warningBufferMinutes: project.warningBufferMinutes),
            nodes: selectedNodes.enumerated().map { offset, node in
                var value = ProjectTemplateNode(id: ids[node.id]!, name: node.name, outcome: node.outcome, isRequired: node.required,
                      blockerIDs: (node.blockerIDs ?? []).compactMap { ids[$0] }, structureOrder: offset + 1)
                value.sequentialPredecessorNodeID = node.sequentialPredecessorNodeID.flatMap { ids[$0] }
                return value
            }, items: snapshotItems, blockers: snapshotBlockers,
            dependencies: selectedDependencies.map { dependency in
                let source: DependencySource
                switch dependency.source {
                case .item(let id): source = .item(ids[id]!)
                case .node(let id): source = .node(ids[id]!)
                case .blocker(let id): source = .blocker(ids[id]!)
                }
                return .init(id: ids[dependency.id]!, source: source, targetItemID: ids[dependency.targetItemID]!)
            }, acceptances: selectedAcceptances.map {
                .init(id: ids[$0.id]!, subject: remap($0.subject), name: $0.name,
                      candidateItemIDs: $0.candidateItemIDs.map { $0.map { ids[$0]! } },
                      candidateBlockerIDs: $0.candidateBlockerIDs.map { $0.map { ids[$0]! } })
            },
            workLinks: selectedLinks.enumerated().map { offset, link in
                .init(id: ids[link.id]!, source: remap(link.source), nodeID: link.nodeID.flatMap { ids[$0] },
                      isRequired: link.isRequired, structureOrder: offset + 1)
            })
        warnings.append(issue(.executionReset, "新项目从规划中开始，工作全部未开始，验收条件重新确认。原项目的投入、完成记录、历史安排与日历绑定不带入模板。"))
        do { try payload.validate() } catch { errors.append(issue(.invalidPayload, templateFailureMessage(error))) }
        return .init(payload: errors.isEmpty ? payload : nil, errors: errors, warnings: warnings, needsDeadlineAnchor: needsAnchor)
    }

    @discardableResult
    public mutating func saveProjectTemplate(projectID: String, title: String, baselineDeadline: Date? = nil,
                                            baselineTimeZoneID: String? = nil, baselineIsDateOnly: Bool = false,
                                            now: Date) throws -> String {
        let title = try Self.templateTitle(title)
        let preview = previewProjectTemplate(projectID: projectID, baselineDeadline: baselineDeadline,
            baselineTimeZoneID: baselineTimeZoneID, baselineIsDateOnly: baselineIsDateOnly)
        guard preview.canSave, let payload = preview.payload else {
            throw CoreError.blocked(preview.errors.map(\.message).joined(separator: "；"))
        }
        let template = ProjectTemplate(title: title, payload: payload, createdAt: now, provenanceProjectName: payload.project.name)
        try command(at: now, validateExisting: false) { draft in
            if draft.projectTemplates == nil { draft.projectTemplates = [] }
            draft.projectTemplates?.append(template)
        }
        return template.id
    }

    @discardableResult
    public mutating func instantiateProjectTemplate(templateID: String, deadline: Date,
                                                   timeZoneID: String, dateOnly: Bool, now: Date) throws -> String {
        guard let template = projectTemplate(id: templateID) else { throw CoreError.missing("template：\(templateID)") }
        let issues = template.validationIssues
        guard issues.isEmpty, let payload = template.payload else { throw CoreError.blocked(issues.map(\.message).joined(separator: "；")) }
        try checkDate(deadline, "template instance deadline")
        guard let zone = TimeZone(identifier: timeZoneID) else { throw CoreError.invalid("截止时区无效") }
        let normalized = dateOnly ? try Self.dateOnlyDeadline(on: deadline, timeZoneID: timeZoneID) : deadline
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        var ids: [String: String] = [:]
        for id in [payload.project.id] + payload.nodes.map(\.id) + payload.items.map(\.id) + payload.blockers.map(\.id)
            + payload.dependencies.map(\.id) + payload.acceptances.map(\.id) + payload.workLinks.map(\.id) { ids[id] = UUID().uuidString }
        let projectID = ids[payload.project.id]!
        func remap(_ reference: WorkReference) -> WorkReference {
            switch reference { case .item(let id): return .item(ids[id]!); case .node(let id): return .node(ids[id]!) }
        }
        let project = Project(id: projectID, name: payload.project.name, deadline: normalized,
            importance: payload.project.importance, description: payload.project.description, status: .planning,
            isArchived: false, warningBufferMinutes: payload.project.warningBufferMinutes,
            deadlineTimeZoneID: timeZoneID, deadlineIsDateOnly: dateOnly)
        let newNodes = payload.nodes.map { node -> Node in
            var value = Node(id: ids[node.id]!, projectID: projectID, name: node.name, outcome: node.outcome,
                isRequired: node.isRequired, isArchived: false, blockerIDs: node.blockerIDs.map { ids[$0]! },
                needsReview: false, round: 1, structureOrder: node.structureOrder)
            value.sequentialPredecessorNodeID = node.sequentialPredecessorNodeID.map { ids[$0]! }
            value.sequentialDependenciesInitialized = true
            return value
        }
        let newItems = try payload.items.map { item -> WorkItem in
            let workDeadline: Date?
            let workDateOnly: Bool?
            switch item.deadlineRule {
            case .calendarDays(let days):
                guard let shifted = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: normalized)) else { throw CoreError.invalid("工作截止日期偏移失败") }
                workDeadline = try Self.dateOnlyDeadline(on: shifted, timeZoneID: timeZoneID); workDateOnly = true
            case .seconds(let seconds): workDeadline = normalized.addingTimeInterval(seconds); workDateOnly = false
            case nil: workDeadline = nil; workDateOnly = nil
            }
            try checkDate(workDeadline, "instance work deadline")
            return WorkItem(id: ids[item.id]!, name: item.name, nodeID: item.nodeID.map { ids[$0]! }, projectIDs: [projectID],
                remainingMinutes: item.durationMinutes, initialMinutes: item.durationMinutes, energy: item.energy,
                requiresContinuous: item.requiresContinuous, status: .pending, needsReview: false, description: item.description,
                deadline: workDeadline, deadlineTimeZoneID: workDeadline == nil ? nil : timeZoneID, deadlineIsDateOnly: workDateOnly,
                contextTags: item.contextTags, isFocused: false, isRequired: item.isRequired, disposition: .active,
                isArchived: false, round: 1, continuousMinutes: item.continuousMinutes, structureOrder: item.structureOrder)
        }
        let newBlockers = payload.blockers.map { blocker in
            Blocker(id: ids[blocker.id]!, name: blocker.name, state: .inactive, resolutionCondition: blocker.resolutionCondition,
                expectedDurationMinutes: blocker.expectedDurationMinutes, contactNote: blocker.contactNote,
                followUpItemID: blocker.followUpItemID.map { ids[$0]! }, round: 1, isArchived: false)
        }
        let newDependencies = payload.dependencies.map { dependency -> Dependency in
            let source: DependencySource
            switch dependency.source {
            case .item(let id): source = .item(ids[id]!); case .node(let id): source = .node(ids[id]!); case .blocker(let id): source = .blocker(ids[id]!)
            }
            return Dependency(id: ids[dependency.id]!, source: source, targetItemID: ids[dependency.targetItemID]!, createdAt: now, effectiveAt: now, revision: 1)
        }
        let newAcceptances = payload.acceptances.map {
            Acceptance(id: ids[$0.id]!, subject: remap($0.subject), name: $0.name, state: .pending,
                       candidateItemIDs: $0.candidateItemIDs.map { $0.map { ids[$0]! } },
                       candidateBlockerIDs: $0.candidateBlockerIDs.map { $0.map { ids[$0]! } }, round: 1)
        }
        let newLinks = payload.workLinks.map {
            WorkLink(id: ids[$0.id]!, source: remap($0.source), projectID: projectID, nodeID: $0.nodeID.map { ids[$0]! },
                     isRequired: $0.isRequired, structureOrder: $0.structureOrder)
        }
        // One candidate, batched append, one full boundary validation. addItem would invent sequential edges.
        try command(at: now, validateExisting: false) { draft in
            let start = draft.items.count
            draft.projects.append(project); draft.nodes.append(contentsOf: newNodes); draft.items.append(contentsOf: newItems)
            draft.blockers.append(contentsOf: newBlockers); draft.dependencies.append(contentsOf: newDependencies)
            draft.acceptances.append(contentsOf: newAcceptances)
            if !newLinks.isEmpty {
                if draft.workLinks == nil { draft.workLinks = [] }
                draft.workLinks?.append(contentsOf: newLinks)
            }
            draft.appendHistory(.created, id: projectID, now: now, note: "从项目模板创建独立项目")
            for node in newNodes { draft.appendHistory(.created, id: node.id, now: now) }
            for index in start..<draft.items.count { draft.captureCreatedItemHistory(at: index, now: now, note: "模板耗时") }
            for blocker in newBlockers { draft.appendHistory(.created, id: blocker.id, now: now) }
            for dependency in newDependencies { draft.appendHistory(.created, id: dependency.id, now: now) }
            for acceptance in newAcceptances { draft.appendHistory(.created, id: acceptance.id, now: now) }
            for link in newLinks { draft.appendHistory(.created, id: link.id, now: now) }
        }
        return projectID
    }

    public mutating func renameProjectTemplate(templateID: String, title: String, now: Date) throws {
        let title = try Self.templateTitle(title)
        try command(at: now, validateExisting: false) { draft in
            let index = try draft.templateIndex(templateID)
            guard draft.projectTemplates![index].removedAt == nil else { throw CoreError.blocked("模板已删除") }
            draft.projectTemplates![index].title = title; draft.projectTemplates![index].renamedAt = now
        }
    }
    public mutating func archiveProjectTemplate(templateID: String, isArchived: Bool = true, now: Date) throws {
        try command(at: now, validateExisting: false) { draft in
            let index = try draft.templateIndex(templateID)
            guard draft.projectTemplates![index].removedAt == nil else { throw CoreError.blocked("模板已删除") }
            draft.projectTemplates![index].isArchived = isArchived
            draft.projectTemplates![index].archivedAt = now
        }
    }
    public mutating func deleteProjectTemplate(templateID: String, now: Date) throws {
        try command(at: now, validateExisting: false) { draft in
            let index = try draft.templateIndex(templateID)
            if draft.projectTemplates![index].removedAt == nil { draft.projectTemplates![index].removedAt = now }
        }
    }
    private func templateIndex(_ id: String) throws -> Int {
        guard let index = projectTemplates?.firstIndex(where: { $0.id == id }) else { throw CoreError.missing("template：\(id)") }
        return index
    }
    private static func templateTitle(_ title: String) throws -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw CoreError.invalid("模板标题不能为空") }
        return title
    }
}
