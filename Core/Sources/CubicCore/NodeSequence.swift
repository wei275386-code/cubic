import Foundation

// Derived member edges carry a reversible identity for result and planning snapshots.
func nodeSequenceDependencyID(nodeID: String, predecessorID: String, itemID: String) -> String {
    "cubic.node-sequence.v1:" + [nodeID, predecessorID, itemID].map { Data($0.utf8).base64EncodedString() }.joined(separator: ".")
}
func nodeSequenceDependencyParts(_ id: String) -> (nodeID: String, predecessorID: String, itemID: String)? {
    let prefix = "cubic.node-sequence.v1:"
    guard id.hasPrefix(prefix) else { return nil }
    let values = id.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
    guard values.count == 3 else { return nil }
    let decoded = values.compactMap { Data(base64Encoded: String($0)).flatMap { String(data: $0, encoding: .utf8) } }
    guard decoded.count == 3, decoded.allSatisfy({ !$0.isEmpty }) else { return nil }
    return (decoded[0], decoded[1], decoded[2])
}

extension Workspace {
    mutating func ensureNodeStructureOrders(projectID: String) {
        let ordered = Self.inStructureOrder(nodes.filter { $0.projectID == projectID }, order: { $0.structureOrder })
        let orders = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element.id, $0.offset + 1) })
        for index in nodes.indices where nodes[index].projectID == projectID { nodes[index].structureOrder = orders[nodes[index].id] }
    }

    /// The entire sequence changes atomically. Manual item dependencies are never rewritten.
    public mutating func reorderProjectNodes(projectID: String, orderedNodeIDs: [String], now: Date) throws {
        try command(at: now) { draft in
            guard draft.projects.contains(where: { $0.id == projectID }) else { throw CoreError.missing("project: \(projectID)") }
            let visible = draft.nodes.filter { $0.projectID == projectID && !$0.archived }
            guard orderedNodeIDs.count == visible.count, Set(orderedNodeIDs) == Set(visible.map(\.id)) else {
                throw CoreError.invalid("节点顺序必须包含本项目全部未归档节点，且不可重复")
            }
            let oldGraph = DomainIndex(draft)
            let positions = Dictionary(uniqueKeysWithValues: orderedNodeIDs.enumerated().map { ($0.element, $0.offset) })
            var changedNodes: [String] = [], editedNodes: [Node] = []
            let archived = Self.inStructureOrder(draft.nodes.filter { $0.projectID == projectID && $0.archived }, order: { $0.structureOrder })
            let archivedPositions = Dictionary(uniqueKeysWithValues: archived.enumerated().map { ($0.element.id, orderedNodeIDs.count + $0.offset + 1) })
            for index in draft.nodes.indices where draft.nodes[index].projectID == projectID {
                let old = draft.nodes[index]
                let position = positions[old.id]
                let predecessor = position.flatMap { $0 > 0 ? orderedNodeIDs[$0 - 1] : nil }
                draft.nodes[index].structureOrder = position.map { $0 + 1 } ?? archivedPositions[old.id]
                draft.nodes[index].sequentialPredecessorNodeID = predecessor
                if old.sequentialPredecessorNodeID != predecessor { changedNodes.append(old.id) }
                if old != draft.nodes[index] { editedNodes.append(old) }
            }
            guard !editedNodes.isEmpty else { return }
            // Check cycles before reopening any results. command rolls back the complete change on failure.
            try draft.validate()
            draft.invalidateNodeSequenceChanges(changedNodes, previousIndex: oldGraph, now: now)
            let current = Dictionary(uniqueKeysWithValues: draft.nodes.map { ($0.id, $0) })
            for old in editedNodes {
                draft.appendHistory(.scopeChanged, id: old.id, now: now, note: "调整节点顺序与默认前置", relatedIDs: [projectID],
                                    detail: try domainChangeDetail(old, current[old.id]!))
            }
        }
    }

    mutating func invalidateNodeSequenceChanges(_ nodeIDs: [String], previousIndex: DomainIndex, now: Date) {
        guard !nodeIDs.isEmpty else { return }
        let changed = Set(nodeIDs)
        let roots = nodeIDs.map(DependencySource.node) + items.filter { $0.nodeID.map(changed.contains) == true }.map { DependencySource.item($0.id) }
        var impact = previousIndex.invalidationClosure(of: roots, includeSources: true)
        let current = DomainIndex(self).invalidationClosure(of: roots, includeSources: true)
        impact.itemIDs.formUnion(current.itemIDs); impact.nodeIDs.formUnion(current.nodeIDs); impact.projectIDs.formUnion(current.projectIDs)
        applyInvalidation(impact, now: now)
    }
}

/// One complete project sequence travels together through causal merge and conflict resolution.
struct NodeSequenceEntry: Codable {
    var nodeID: String
    var structureOrder: Int?
    var sequentialPredecessorNodeID: String?
    init(_ node: Node) {
        nodeID = node.id; structureOrder = node.structureOrder
        sequentialPredecessorNodeID = node.sequentialPredecessorNodeID
    }
}

extension SyncDocument {
    static func applyNodeSequences(_ values: [SyncPath: SyncValue], to workspace: inout Workspace) throws {
        let positions = Dictionary(uniqueKeysWithValues: workspace.nodes.enumerated().map { ($0.element.id, $0.offset) })
        let projectMembers = Dictionary(grouping: workspace.nodes, by: \.projectID)
        for project in workspace.projects {
            let path = SyncPath(collection: "projects", entityID: project.id, field: nodeSequence)
            guard let value = values[path], value != .null else { continue } // Older journals retain their per-node fields.
            let entries = try SyncCoding.decode([NodeSequenceEntry].self, from: SyncCoding.encode(value))
            try checkIDs(entries.map(\.nodeID), "sync.nodeSequence")
            let entryMap = Dictionary(uniqueKeysWithValues: entries.map { ($0.nodeID, $0) })
            let members = projectMembers[project.id] ?? []
            let memberIDs = Set(members.map(\.id))
            // A concurrent move can remove a source from this snapshot. Bridge only its managed edge.
            var bridged: [String: String] = [:], noPredecessor = Set<String>()
            func predecessor(_ id: String?) -> String? {
                guard let id else { return nil }
                var cursor: String? = id, walked: [String] = [], seen = Set<String>(), result: String?
                while let candidate = cursor, seen.insert(candidate).inserted {
                    if memberIDs.contains(candidate) { result = candidate; break }
                    if let cached = bridged[candidate] { result = cached; break }
                    if noPredecessor.contains(candidate) { break }
                    walked.append(candidate); cursor = entryMap[candidate]?.sequentialPredecessorNodeID
                }
                for missing in walked { if let result { bridged[missing] = result } else { noPredecessor.insert(missing) } }
                return result
            }
            var known = Set<String>(), tail: String?, maxOrder = 0
            for entry in entries where memberIDs.contains(entry.nodeID) {
                guard let position = positions[entry.nodeID] else { continue }
                workspace.nodes[position].structureOrder = entry.structureOrder
                workspace.nodes[position].sequentialPredecessorNodeID = predecessor(entry.sequentialPredecessorNodeID)
                known.insert(entry.nodeID); maxOrder = max(maxOrder, entry.structureOrder ?? 0)
                if !workspace.nodes[position].archived { tail = entry.nodeID }
            }
            // Keep nodes created on the losing concurrent branch; append them deterministically.
            for node in members.filter({ !known.contains($0.id) }).sorted(by: { $0.id < $1.id }) {
                guard let position = positions[node.id] else { continue }
                guard maxOrder < Int.max else { throw SyncError.invalidJournal("node sequence order overflow") }
                maxOrder += 1
                workspace.nodes[position].structureOrder = maxOrder
                workspace.nodes[position].sequentialPredecessorNodeID = node.archived ? nil : tail
                if !node.archived { tail = node.id }
            }
        }
    }
}
