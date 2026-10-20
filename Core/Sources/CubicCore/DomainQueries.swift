import Foundation

/// One indexed graph per operation. Queries do not repair legacy facts or fill missing gates.
struct DomainIndex {
    let items: [String: WorkItem]
    let nodes: [String: Node]
    let blockers: [String: Blocker]
    let members: [String: [WorkItem]]
    let gates: [WorkReferenceKey: [Acceptance]]
    let incoming: [String: [Dependency]]
    let outgoing: [DependencySourceKey: [Dependency]]
    let links: [String: [WorkLink]]
    let successors: [DependencySourceKey: Set<DependencySourceKey>]
    let sourceProjectIDs: [DependencySourceKey: Set<String>]
    private var nodeValidity: [String: Bool] = [:]
    private var itemValidity: [String: Bool] = [:]
    private let reviews: [String: ReviewRecord]
    init(_ workspace: Workspace) {
        items = Dictionary(workspace.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        nodes = Dictionary(workspace.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        blockers = Dictionary(workspace.blockers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        members = Dictionary(grouping: workspace.items.compactMap { item in item.nodeID.map { ($0, item) } }, by: { $0.0 }).mapValues { $0.map { $0.1 } }
        gates = Dictionary(grouping: workspace.acceptances.filter(\.isActive), by: { WorkReferenceKey($0.subject) })
        var effective = workspace.dependencies.filter(\.isActive)
        let nodeWaits = Dictionary(workspace.nodes.map { ($0.id, $0.blockerIDs ?? []) }, uniquingKeysWith: { first, _ in first })
        for item in workspace.items {
            if let nodeID = item.nodeID {
                if let predecessor = nodes[nodeID]?.sequentialPredecessorNodeID {
                    effective.append(Dependency(id: nodeSequenceDependencyID(nodeID: nodeID, predecessorID: predecessor, itemID: item.id),
                                                source: .node(predecessor), targetItemID: item.id))
                }
                for blockerID in nodeWaits[nodeID] ?? [] {
                    effective.append(Dependency(id: nodeBlockerDependencyID(nodeID: nodeID, blockerID: blockerID, itemID: item.id),
                                                source: .blocker(blockerID), targetItemID: item.id))
                }
            }
        }
        incoming = Dictionary(grouping: effective, by: \.targetItemID)
        outgoing = Dictionary(grouping: effective, by: { DependencySourceKey($0.source) })
        links = Dictionary(grouping: (workspace.workLinks ?? []).filter { $0.removedAt == nil && $0.nodeID != nil }, by: { $0.nodeID! })
        var graph: [DependencySourceKey: Set<DependencySourceKey>] = [:]
        var projects: [DependencySourceKey: Set<String>] = [:]
        for dependency in effective { graph[DependencySourceKey(dependency.source), default: []].insert(DependencySourceKey(.item(dependency.targetItemID))) }
        for item in workspace.items {
            let source = DependencySourceKey(.item(item.id))
            projects[source, default: []].formUnion(item.projectIDs)
            if item.required, let nodeID = item.nodeID { graph[source, default: []].insert(DependencySourceKey(.node(nodeID))) }
        }
        for node in workspace.nodes {
            projects[DependencySourceKey(.node(node.id)), default: []].insert(node.projectID)
            if let predecessor = node.sequentialPredecessorNodeID {
                graph[DependencySourceKey(.node(predecessor)), default: []].insert(DependencySourceKey(.node(node.id)))
            }
            for blockerID in node.blockerIDs ?? [] { graph[DependencySourceKey(.blocker(blockerID)), default: []].insert(DependencySourceKey(.node(node.id))) }
        }
        for link in workspace.workLinks ?? [] where link.removedAt == nil && link.isRequired {
            let source: DependencySourceKey
            switch link.source { case .item(let id): source = DependencySourceKey(.item(id)); case .node(let id): source = DependencySourceKey(.node(id)) }
            projects[source, default: []].insert(link.projectID)
            if let nodeID = link.nodeID { graph[source, default: []].insert(DependencySourceKey(.node(nodeID))) }
        }
        successors = graph; sourceProjectIDs = projects
        reviews = Dictionary(workspace.reviews?.map { ($0.itemID, $0) } ?? [], uniquingKeysWith: { a, b in a.date > b.date ? a : b })
        computeActualValidity()
    }
    func itemValid(_ id: String) -> Bool {
        itemValidity[id] == true
    }
    func gateValid(_ gate: Acceptance) -> Bool {
        let subjectRound: Int
        switch gate.subject { case .item(let id): subjectRound = items[id]?.currentRound ?? 1
        case .node(let id): subjectRound = nodes[id]?.currentRound ?? 1 }
        return gate.state == .accepted && gate.acceptedAt != nil && gate.currentRound == subjectRound
    }
    private func localNodeIssues(_ id: String, includeAcceptance: Bool) -> [String] {
        guard let node = nodes[id] else { return ["节点不存在: \(id)"] }
        var issues: [String] = []
        if node.needsReview == true { issues.append("节点成果需复核") }
        for member in members[id] ?? [] where member.required {
            if !itemValid(member.id) { issues.append("必需工作未完成或需复核: \(member.id)") }
            for gate in gates[WorkReferenceKey(.item(member.id))] ?? [] where gate.required && !gateValid(gate) {
                issues.append("工作验收未通过: \(gate.id)")
            }
        }
        for blockerID in node.blockerIDs ?? [] where blockers[blockerID]?.state != .resolved {
            issues.append("必需等待未解除: \(blockerID)")
        }
        if includeAcceptance {
            let required = (gates[WorkReferenceKey(.node(id))] ?? []).filter(\.required)
            // 默认验收：没有显式条件时，验收等于“完成自身”，上面的成员工作/等待/复核已覆盖。
            // 但默认模式下仍要求至少一条必需成员工作，避免空节点真空完成并解锁下游。
            if required.isEmpty, !(members[id] ?? []).contains(where: \.required) {
                issues.append("节点还没有工作")
            }
            for gate in required where !gateValid(gate) { issues.append("必需验收未通过: \(gate.id)") }
        }
        return issues
    }
    // Evaluate the whole item/node/blocker graph once. Legacy completed facts with new
    // unmet sources are preserved but ineligible until an explicit stillValid review.
    private mutating func computeActualValidity() {
        let vertices = items.keys.map { DependencySourceKey(.item($0)) } +
            nodes.keys.map { DependencySourceKey(.node($0)) } + blockers.keys.map { DependencySourceKey(.blocker($0)) }
        var predecessors: [DependencySourceKey: Set<DependencySourceKey>] = [:]
        var successors: [DependencySourceKey: Set<DependencySourceKey>] = [:]
        var reusable = Set<String>()
        for (id, review) in reviews where review.outcome == .stillValid {
            guard review.round == items[id]?.currentRound, let checked = review.currentSources else { continue }
            let current = sourcesUsed(for: id)
            if effectiveSourceConditionsMatch(current, checked) { reusable.insert(id) }
        }
        func connect(_ source: DependencySourceKey, _ target: DependencySourceKey) {
            predecessors[target, default: []].insert(source); successors[source, default: []].insert(target)
        }
        for (id, dependencies) in incoming where !reusable.contains(id) {
            for dependency in dependencies { connect(DependencySourceKey(dependency.source), DependencySourceKey(.item(id))) }
        }
        for (id, members) in members {
            for item in members where item.required { connect(DependencySourceKey(.item(item.id)), DependencySourceKey(.node(id))) }
        }
        for (id, links) in links {
            for link in links where link.isRequired {
                switch link.source {
                case .item(let source): connect(DependencySourceKey(.item(source)), DependencySourceKey(.node(id)))
                case .node(let source): connect(DependencySourceKey(.node(source)), DependencySourceKey(.node(id)))
                }
            }
        }
        for node in nodes.values {
            if let predecessor = node.sequentialPredecessorNodeID { connect(DependencySourceKey(.node(predecessor)), DependencySourceKey(.node(node.id))) }
        }
        for node in nodes.values { for id in node.blockerIDs ?? [] { connect(DependencySourceKey(.blocker(id)), DependencySourceKey(.node(node.id))) } }
        var degrees = Dictionary(uniqueKeysWithValues: vertices.map { ($0, predecessors[$0]?.count ?? 0) })
        var queue = vertices.filter { degrees[$0] == 0 }, cursor = 0
        var validity: [DependencySourceKey: Bool] = [:]
        while cursor < queue.count {
            let key = queue[cursor]; cursor += 1
            let sourcesReady = (predecessors[key] ?? []).allSatisfy { validity[$0] == true }
            switch key.kind {
            case 0:
                let item = items[key.id]!
                let ready = item.status == .completed && !item.needsReview && item.effectiveDisposition != .cancelled && sourcesReady
                itemValidity[key.id] = ready; validity[key] = ready
            case 1:
                let ready = sourcesReady && localNodeIssues(key.id, includeAcceptance: true).isEmpty
                nodeValidity[key.id] = ready; validity[key] = ready
            default: validity[key] = blockers[key.id]?.state == .resolved
            }
            for target in successors[key] ?? [] {
                degrees[target, default: 0] -= 1
                if degrees[target] == 0 { queue.append(target) }
            }
        }
    }
    func nodeIssues(_ id: String, includeAcceptance: Bool, visiting: inout Set<String>) -> [String] {
        var issues = localNodeIssues(id, includeAcceptance: includeAcceptance)
        if let predecessor = nodes[id]?.sequentialPredecessorNodeID, nodeValidity[predecessor] != true {
            issues.append("前置节点未完成或需复核: \(predecessor)")
        }
        for link in links[id] ?? [] where link.isRequired {
            switch link.source {
            case .item(let itemID): if !itemValid(itemID) { issues.append("共享工作未完成或需复核: \(itemID)") }
            case .node(let nodeID): if nodeValidity[nodeID] != true { issues.append("共享节点未通过或存在循环: \(nodeID)") }
            }
        }
        return issues
    }
    func sourceSatisfied(_ source: DependencySource) -> Bool {
        switch source {
        case .item(let id): return itemValid(id)
        case .node(let id): return nodeValidity[id] == true
        case .blocker(let id): return blockers[id]?.state == .resolved
        }
    }
    func sourcesUsed(for itemID: String) -> [SourceUse] {
        (incoming[itemID] ?? []).map { dependency in
            let round: Int
            switch dependency.source {
            case .item(let id): round = items[id]?.currentRound ?? 1
            case .node(let id): round = nodes[id]?.currentRound ?? 1
            case .blocker(let id): round = blockers[id]?.currentRound ?? 1
            }
            return SourceUse(dependencyID: dependency.id, source: dependency.source, sourceRound: round,
                             dependencyRevision: dependency.currentRevision,
                             nodeID: nodeBlockerDependencyParts(dependency.id)?.nodeID ?? nodeSequenceDependencyParts(dependency.id)?.nodeID)
        }
    }
    func invalidationClosure(of sources: [DependencySource], includeSources: Bool = false) -> DomainInvalidation {
        let roots = Set(sources.map(DependencySourceKey.init))
        var queue = Array(roots), cursor = 0, seen = Set<DependencySourceKey>()
        var result = DomainInvalidation()
        while cursor < queue.count {
            let key = queue[cursor]; cursor += 1
            guard seen.insert(key).inserted else { continue }
            result.projectIDs.formUnion(sourceProjectIDs[key] ?? [])
            if includeSources || !roots.contains(key) {
                if key.kind == 0 { result.itemIDs.insert(key.id) }
                if key.kind == 1 { result.nodeIDs.insert(key.id) }
            }
            queue.append(contentsOf: successors[key] ?? [])
        }
        return result
    }
}
struct WorkReferenceKey: Hashable {
    let kind: Int; let id: String
    init(_ reference: WorkReference) { switch reference { case .item(let id): self.kind = 0; self.id = id
    case .node(let id): self.kind = 1; self.id = id } }
}
struct DependencySourceKey: Hashable {
    let kind: Int; let id: String
    init(_ source: DependencySource) { switch source { case .item(let id): self.kind = 0; self.id = id
    case .node(let id): self.kind = 1; self.id = id; case .blocker(let id): self.kind = 2; self.id = id } }
}

/// Compares live prerequisite semantics without changing historical edge/scope provenance.
/// An inherited node wait is the actual blocker/round; explicit relations retain their own identity/version.
private enum EffectiveSourceConditionKey: Hashable {
    case inheritedBlocker(id: String, round: Int)
    case explicit(dependencyID: String, source: DependencySourceKey, round: Int, revision: Int, nodeID: String?)

    init(_ use: SourceUse) {
        if let nodeID = use.nodeID, let parts = nodeBlockerDependencyParts(use.dependencyID),
           parts.nodeID == nodeID, use.source == .blocker(parts.blockerID) {
            self = .inheritedBlocker(id: parts.blockerID, round: use.sourceRound)
        } else {
            self = .explicit(dependencyID: use.dependencyID, source: DependencySourceKey(use.source),
                             round: use.sourceRound, revision: use.dependencyRevision, nodeID: use.nodeID)
        }
    }
}

func effectiveSourceConditionsMatch(_ lhs: [SourceUse], _ rhs: [SourceUse]) -> Bool {
    Set(lhs.map(EffectiveSourceConditionKey.init)) == Set(rhs.map(EffectiveSourceConditionKey.init))
}

extension Workspace {
    /// 验收模式：无 active 条件 = 默认（完成自身）；有 active 条件 = 逐条人工通过。
    public enum AcceptanceMode: Sendable, Equatable { case selfCompletion, explicit }
    public func activeAcceptances(for subject: WorkReference) -> [Acceptance] {
        acceptances.filter { $0.isActive && $0.subject == subject }
    }
    public func acceptanceMode(for subject: WorkReference) -> AcceptanceMode {
        activeAcceptances(for: subject).isEmpty ? .selfCompletion : .explicit
    }
    /// Returns only the recorded origin; equal values in later events do not establish provenance.
    public func initialEstimateSource(itemID: String) -> HistoryEvent? {
        guard let eventID = items.first(where: { $0.id == itemID })?.initialEstimateEventID else { return nil }
        return history.first { $0.id == eventID && $0.objectID == itemID }
    }
    public var currentNextAction: NextActionChoice? { (choices ?? []).first { $0.id == currentChoiceID } }
    public func nodeCompletionIssues(id: String, includeAcceptance: Bool = true) -> [String] {
        var visiting = Set<String>()
        return DomainIndex(self).nodeIssues(id, includeAcceptance: includeAcceptance, visiting: &visiting)
    }
    public func projectCompletionIssues(id: String) -> [String] {
        guard projects.contains(where: { $0.id == id }) else { return ["项目不存在: \(id)"] }
        let index = DomainIndex(self)
        // The current structure is the delivery scope; legacy completeness flags are historical only.
        var issues: [String] = []
        for node in nodes where node.projectID == id && node.required {
            var visiting = Set<String>()
            issues.append(contentsOf: index.nodeIssues(node.id, includeAcceptance: true, visiting: &visiting).map { "\(node.id): \($0)" })
        }
        for item in items where item.projectIDs.contains(id) && item.required && item.nodeID.flatMap({ index.nodes[$0]?.projectID }) != id {
            if !index.itemValid(item.id) { issues.append("项目必需工作未完成或需复核: \(item.id)") }
            for gate in index.gates[WorkReferenceKey(.item(item.id))] ?? [] where gate.required && !index.gateValid(gate) {
                issues.append("项目工作验收未通过: \(gate.id)")
            }
        }
        for link in workLinks ?? [] where link.projectID == id && link.nodeID == nil && link.isRequired && link.removedAt == nil {
            switch link.source {
            case .item(let itemID): if !index.itemValid(itemID) { issues.append("共享工作未完成: \(itemID)") }
            case .node(let nodeID): if !index.sourceSatisfied(.node(nodeID)) { issues.append("共享节点未通过: \(nodeID)") }
            }
        }
        return issues
    }
    public func sourceSatisfied(_ source: DependencySource) -> Bool { DomainIndex(self).sourceSatisfied(source) }
    public func affectedItemIDs(by source: DependencySource) -> [String] {
        DomainIndex(self).invalidationClosure(of: [source]).itemIDs.sorted()
    }
    /// Includes empty/shared delivery nodes and every affected associated project.
    public func invalidationImpact(by sources: [DependencySource]) -> DomainInvalidation {
        DomainIndex(self).invalidationClosure(of: sources)
    }
    public func effectiveItemDependencies(itemID: String) -> [Dependency] {
        DomainIndex(self).incoming[itemID] ?? []
    }

    public static func dateOnlyDeadline(on date: Date, timeZoneID: String) throws -> Date {
        try checkDate(date, "deadline")
        guard let zone = TimeZone(identifier: timeZoneID) else { throw CoreError.invalid("截止时区无效") }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        guard let interval = calendar.dateInterval(of: .day, for: date) else { throw CoreError.invalid("截止日期无效") }
        return interval.end.addingTimeInterval(-0.001)
    }
    public var effectiveWorkSessions: [WorkSession] {
        let superseded = Set(workSessions.compactMap(\.correctsSessionID))
        return workSessions.filter { !superseded.contains($0.id) && $0.isVoided != true }
    }
    public func effortSummary(itemIDs: [String]? = nil) -> EffortSummary {
        // Detect across the global facts before filtering, so project filters cannot hide a conflict.
        let sessions = effectiveWorkSessions
        let exact = sessions.filter { $0.hasExactInterval && $0.actualMinutes > 0 }.sorted {
            $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start
        }
        var unresolved = Set<String>(), group: [WorkSession] = [], groupEnd = Date.distantPast
        func finish(_ group: [WorkSession]) {
            guard group.count > 1 else { return }
            let allocationIDs = Set(group.compactMap(\.allocationGroupID))
            let isConfirmed = allocationIDs.count == 1 && group.allSatisfy { $0.allocationGroupID != nil }
            if !isConfirmed { unresolved.formUnion(group.map(\.id)) }
        }
        for session in exact {
            if !group.isEmpty && session.start >= groupEnd { finish(group); group = [] }
            group.append(session); groupEnd = group.count == 1 ? session.end : max(groupEnd, session.end)
        }
        finish(group)
        let selected = itemIDs.map(Set.init)
        let relevant = sessions.filter { selected?.contains($0.itemID) ?? true }
        var total = 0
        for session in relevant {
            let (sum, overflow) = total.addingReportingOverflow(session.actualMinutes); total = overflow ? Int.max : sum
        }
        let relevantUnresolved = relevant.filter { unresolved.contains($0.id) }.map(\.id).sorted()
        return EffortSummary(confirmedMinutes: total, unresolvedSessionIDs: relevantUnresolved,
                             effectiveSessionIDs: relevant.map(\.id),
                             recordingIsComplete: true)
    }
}

extension Workspace {
    public var effectiveEstimateRevisions: [EstimateRevision] {
        let revisions = estimateRevisions ?? []
        let replacements = Dictionary(revisions.compactMap { revision in
            revision.correctsRevisionID.map { ($0, revision) }
        }, uniquingKeysWith: { first, _ in first })
        return revisions.filter { $0.correctsRevisionID == nil }.map { root in
            var current = root, seen: Set<String> = []
            while seen.insert(current.id).inserted, let next = replacements[current.id] { current = next }
            return current
        }
    }
    func subjectResultDates(_ subject: WorkReference) -> [Date] {
        let index = DomainIndex(self)
        var queue = [subject], cursor = 0, seen = Set<WorkReferenceKey>(), dates: [Date] = []
        while cursor < queue.count {
            let reference = queue[cursor]; cursor += 1
            guard seen.insert(WorkReferenceKey(reference)).inserted else { continue }
            dates.append(contentsOf: (index.gates[WorkReferenceKey(reference)] ?? []).compactMap(\.acceptedAt))
            switch reference {
            case .item(let id): if let date = index.items[id]?.completedAt { dates.append(date) }
            case .node(let id):
                if let date = index.nodes[id]?.completedAt { dates.append(date) }
                if let predecessor = index.nodes[id]?.sequentialPredecessorNodeID { queue.append(.node(predecessor)) }
                queue.append(contentsOf: (index.members[id] ?? []).filter(\.required).map { .item($0.id) })
                queue.append(contentsOf: (index.links[id] ?? []).filter(\.isRequired).map(\.source))
                dates.append(contentsOf: (index.nodes[id]?.blockerIDs ?? []).compactMap { index.blockers[$0]?.resolvedAt })
            }
        }
        return dates
    }

}

/// Preemptible earliest-deadline allocation of confirmed amounts inside their true intervals.
/// This checks the existence of a unique-resource attribution; total union alone is insufficient.
func validateEffortAllocation(_ sessions: [WorkSession]) throws {
    guard sessions.allSatisfy(\.hasExactInterval) else { throw CoreError.invalid("分摊组缺精确区间") }
    let ordered = sessions.sorted { $0.end == $1.end ? $0.id < $1.id : $0.end < $1.end }
    let boundaries = Array(Set(ordered.flatMap { [$0.start, $0.end] })).sorted()
    var remaining = ordered.map { Double($0.actualMinutes) * 60 }
    guard boundaries.count > 1 else {
        if remaining.contains(where: { $0 > 0 }) { throw CoreError.invalid("空区间分摊正工时") }
        return
    }
    for offset in 0..<(boundaries.count - 1) {
        let start = boundaries[offset], end = boundaries[offset + 1]
        if ordered.indices.contains(where: { ordered[$0].end <= start && remaining[$0] > 0.0001 }) {
            throw CoreError.invalid("分摊在局部重叠窗口仍重复占用实际时间")
        }
        var capacity = end.timeIntervalSince(start)
        for index in ordered.indices where ordered[index].start <= start && ordered[index].end >= end && remaining[index] > 0 {
            let applied = min(capacity, remaining[index]); remaining[index] -= applied; capacity -= applied
            if capacity <= 0 { break }
        }
    }
    guard remaining.allSatisfy({ $0 <= 0.0001 }) else { throw CoreError.invalid("分摊无法满足唯一实际时间区间") }
}

// Reserved, reversible derived identity: never persisted as an explicit Dependency.
func nodeBlockerDependencyID(nodeID: String, blockerID: String, itemID: String) -> String {
    "cubic.node-blocker.v1:" + [nodeID, blockerID, itemID].map { Data($0.utf8).base64EncodedString() }.joined(separator: ".")
}
func nodeBlockerDependencyParts(_ id: String) -> (nodeID: String, blockerID: String, itemID: String)? {
    let prefix = "cubic.node-blocker.v1:"
    guard id.hasPrefix(prefix) else { return nil }
    let parts = id.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }
    var decoded: [String] = []
    for part in parts {
        guard let data = Data(base64Encoded: String(part)), let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        decoded.append(value)
    }
    return (decoded[0], decoded[1], decoded[2])
}

/// One selectable work in a predecessor menu. `affiliation` is `-＞节点-＞项目` or `-＞直属工作-＞项目`.
public struct PredecessorWorkOffer: Sendable, Equatable, Identifiable {
    public var itemID: String
    public var name: String
    public var affiliation: String
    public var cycleReason: String?
    public var keptDespiteArchive: Bool
    public var id: String { itemID }
    public init(itemID: String, name: String, affiliation: String, cycleReason: String?, keptDespiteArchive: Bool) {
        self.itemID = itemID
        self.name = name
        self.affiliation = affiliation
        self.cycleReason = cycleReason
        self.keptDespiteArchive = keptDespiteArchive
    }
}

/// 一次线性扫描构建“项目 > 节点 > 子工作”层级，供“修改详情”页与性能基准复用。
public struct ProjectStructure: Sendable, Equatable {
    public var nodes: [Node]
    public var membersByNode: [String: [WorkItem]]
    public var directItems: [WorkItem]
    public init(nodes: [Node], membersByNode: [String: [WorkItem]], directItems: [WorkItem]) {
        self.nodes = nodes; self.membersByNode = membersByNode; self.directItems = directItems
    }
}

extension Workspace {
    /// 只包含未归档节点与工作；节点成员按 nodeID 归组，其余关联本项目的工作为直属工作。
    /// One indexed graph serves both lookup and readiness, including inherited node prerequisites.
    public func unsatisfiedItemDependencies(itemID: String) -> [Dependency] {
        let index = DomainIndex(self)
        return (index.incoming[itemID] ?? []).filter { !index.sourceSatisfied($0.source) }
    }

    public func projectStructure(projectID: String) -> ProjectStructure {
        let visibleNodes = Self.inStructureOrder(nodes.filter { $0.projectID == projectID && $0.archived != true }, order: { $0.structureOrder })
        let nodeIDs = Set(visibleNodes.map(\.id))
        var members: [String: [WorkItem]] = [:]
        var direct: [WorkItem] = []
        for item in items where item.archived != true {
            if let nodeID = item.nodeID, nodeIDs.contains(nodeID) { members[nodeID, default: []].append(item) }
            else if item.projectIDs.contains(projectID) { direct.append(item) }
        }
        members = members.mapValues { Self.inStructureOrder($0, order: { $0.structureOrder }) }
        return ProjectStructure(nodes: visibleNodes, membersByNode: members,
                                directItems: Self.inStructureOrder(direct, order: { $0.structureOrder }))
    }

    /// 新的前置候选。归档项目不会把旗下节点和工作标成已归档，选择菜单仍要按所属项目排除。
    /// `keeping` 只保留正在编辑的那一条，避免已有关系在修改时从列表里消失。
    public func predecessorNodeCandidates(keeping selectedID: String? = nil) -> [Node] {
        nodes.filter { $0.id == selectedID || canOfferAsNewPredecessor($0) }
    }

    public func predecessorItemCandidates(excluding itemID: String, keeping selectedID: String? = nil) -> [WorkItem] {
        items.filter { item in
            item.id != itemID && (item.id == selectedID || canOfferAsNewPredecessor(item))
        }
    }

    /// Work-only predecessor menu for one target. Same project and node come first, then the rest of
    /// that project, then other projects. Search must keep this order. Shared work appears once.
    public func predecessorWorkOffers(for targetItemID: String, inProject projectID: String, keeping selectedIDs: Set<String> = []) -> [PredecessorWorkOffer] {
        guard items.contains(where: { $0.id == targetItemID }) else { return [] }
        let targetNodeID = items.first { $0.id == targetItemID }?.nodeID
        let home = projectStructure(projectID: projectID)
        var sameNodeOrder: [String: Int] = [:]
        if let targetNodeID {
            for (offset, item) in (home.membersByNode[targetNodeID] ?? []).enumerated() { sameNodeOrder[item.id] = offset }
        }
        var sameProjectOrder: [String: Int] = [:]
        var cursor = 0
        for node in home.nodes where node.id != targetNodeID {
            for item in home.membersByNode[node.id] ?? [] {
                sameProjectOrder[item.id] = cursor
                cursor += 1
            }
        }
        for item in home.directItems {
            sameProjectOrder[item.id] = cursor
            cursor += 1
        }
        var externalOrder: [String: Int] = [:]
        var externalCursor = 0
        for project in projects where project.id != projectID && !project.archived {
            let structure = projectStructure(projectID: project.id)
            for node in structure.nodes {
                for item in structure.membersByNode[node.id] ?? [] where externalOrder[item.id] == nil {
                    externalOrder[item.id] = externalCursor
                    externalCursor += 1
                }
            }
            for item in structure.directItems where externalOrder[item.id] == nil {
                externalOrder[item.id] = externalCursor
                externalCursor += 1
            }
        }
        let graph = constraintGraph()
        let ranked = items.enumerated().compactMap { offset, item -> (Int, Int, Int, WorkItem)? in
            guard item.id != targetItemID, selectedIDs.contains(item.id) || canOfferAsNewPredecessor(item) else { return nil }
            let group = predecessorGroup(of: item, targetNodeID: targetNodeID, projectID: projectID)
            let order: Int
            switch group {
            case 0: order = sameNodeOrder[item.id] ?? item.structureOrder ?? Int.max
            case 1: order = sameProjectOrder[item.id] ?? Int.max
            default: order = externalOrder[item.id] ?? Int.max
            }
            return (group, order, offset, item)
        }.sorted { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            return lhs.2 < rhs.2
        }
        return ranked.map { _, _, _, item in
            let offered = canOfferAsNewPredecessor(item)
            let reason = workPredecessorCycleReason(sourceItemID: item.id, targetItemID: targetItemID, graph: graph)
            return PredecessorWorkOffer(itemID: item.id,
                                        name: offered ? item.name : "\(item.name)（已归档）",
                                        affiliation: predecessorAffiliation(of: item, preferredProjectID: projectID),
                                        cycleReason: reason,
                                        keptDespiteArchive: !offered)
        }
    }

    private func predecessorGroup(of item: WorkItem, targetNodeID: String?, projectID: String) -> Int {
        if let targetNodeID, item.nodeID == targetNodeID { return 0 }
        if item.projectIDs.contains(projectID) { return 1 }
        if let nodeID = item.nodeID, nodes.contains(where: { $0.id == nodeID && $0.projectID == projectID }) { return 1 }
        return 2
    }

    private func predecessorAffiliation(of item: WorkItem, preferredProjectID: String) -> String {
        if let nodeID = item.nodeID, let node = nodes.first(where: { $0.id == nodeID }) {
            let projectName = projects.first { $0.id == node.projectID }?.name ?? "未归属项目"
            return "-＞\(node.name)-＞\(projectName)"
        }
        let projectID = item.projectIDs.contains(preferredProjectID) ? preferredProjectID : item.projectIDs.first { id in
            projects.contains { $0.id == id && !$0.archived }
        } ?? item.projectIDs.first
        let projectName = projectID.flatMap { id in projects.first { $0.id == id }?.name } ?? "未归属项目"
        return "-＞直属工作-＞\(projectName)"
    }

    public func canOfferAsNewPredecessor(_ node: Node) -> Bool {
        !node.archived && projects.contains { $0.id == node.projectID && !$0.archived }
    }

    public func canOfferAsNewPredecessor(_ item: WorkItem) -> Bool {
        if item.archived { return false }
        if let nodeID = item.nodeID, let node = nodes.first(where: { $0.id == nodeID }) {
            return canOfferAsNewPredecessor(node)
        }
        if item.projectIDs.isEmpty { return true }
        let archivedProjects = Set(projects.filter(\.archived).map(\.id))
        return item.projectIDs.contains { !archivedProjects.contains($0) }
    }

    static func inStructureOrder<T>(_ values: [T], order: (T) -> Int?) -> [T] {
        // Legacy arrays already carry their display order. Avoid sorting each unnumbered group.
        guard values.count > 1, values.contains(where: { order($0) != nil }) else { return values }
        return values.enumerated().sorted {
            let left = order($0.element), right = order($1.element)
            if let left, let right, left != right { return left < right }
            if (left == nil) != (right == nil) { return left != nil }
            return $0.offset < $1.offset
        }.map(\.element)
    }

    /// Backfill once, preserving explicit dependencies and removals. Cycle-producing defaults are skipped.
    public mutating func initializeSequentialDependencies(projectID: String, now: Date) throws {
        try command(at: now) { draft in
            for node in draft.nodes where node.projectID == projectID && !node.archived {
                try draft.initializeSequentialDependencies(nodeID: node.id, now: now)
            }
        }
    }

    mutating func initializeSequentialDependencies(nodeID: String, now: Date) throws {
        guard let index = nodes.firstIndex(where: { $0.id == nodeID }),
              nodes[index].sequentialDependenciesInitialized != true else { return }
        ensureWorkStructureOrders(nodeID: nodeID)
        let members = Self.inStructureOrder(items.filter { $0.nodeID == nodeID && !$0.archived }, order: { $0.structureOrder })
        for item in members.dropFirst() { try addSequentialPredecessor(to: item.id, nodeID: nodeID, now: now) }
        nodes[index].sequentialDependenciesInitialized = true
    }

    mutating func ensureWorkStructureOrders(nodeID: String) {
        var order = items.filter { $0.nodeID == nodeID }.compactMap(\.structureOrder).max() ?? 0
        for index in items.indices where items[index].nodeID == nodeID && items[index].structureOrder == nil {
            order += 1; items[index].structureOrder = order
        }
    }

    mutating func addSequentialPredecessor(to itemID: String, nodeID: String, now: Date,
                                          ignoringDependencies: Set<String> = []) throws {
        let members = Self.inStructureOrder(items.filter { $0.nodeID == nodeID && !$0.archived }, order: { $0.structureOrder })
        guard let index = members.firstIndex(where: { $0.id == itemID }), index > 0 else { return }
        let previous = members[index - 1]
        // Existing explicit sources (including removed edges) describe a deliberate choice.
        guard !dependencies.contains(where: { $0.targetItemID == itemID && !ignoringDependencies.contains($0.id) }) else { return }
        let dependency = Dependency(id: "node-order:\(nodeID):\(previous.id):\(itemID)", source: .item(previous.id),
                                    targetItemID: itemID, createdAt: now, effectiveAt: now)
        do { try addDependency(dependency, now: now) }
        catch CoreError.cycle { /* Retain the existing graph when a default would contradict it. */ }
    }

    /// 旧数据需要“验收规则已更新”一次性迁移提示：只认旧版明确的“非必需”验收条件（`isRequired == false`）。
    /// 取舍（已记录）：无验收条件的旧节点与“新用户默认节点”不可区分，因此不再触发提示，
    /// 否则会对全新用户误报；若日后要补齐，应引入升级时的 schema/迁移标记而非从当前形状反推。
    public var needsAcceptanceReinterpretationNotice: Bool {
        acceptances.contains { $0.isRequired == false }
    }
}
