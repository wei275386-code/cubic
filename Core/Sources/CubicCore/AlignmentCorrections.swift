import Foundation

public enum EstimateBaselineKind: String, Codable, Sendable { case initial, preStart }
public struct EstimateBaselineCorrection: Codable, Sendable, Equatable {
    public var itemID: String
    public var baseline: EstimateBaselineKind
    public var originalMinutes: Int?
    public var correctedMinutes: Int?
    public var date: Date
    public var reason: String
}

extension Workspace {
    /// An explicit scope reset retains all referenced identities and immutable histories.
    public mutating func archiveCurrentWorkspace(now: Date) throws {
        try command(at: now) { draft in
            for index in draft.projects.indices {
                draft.projects[index].isArchived = true
                if draft.projects[index].effectiveStatus != .completed { draft.projects[index].status = .cancelled }
                draft.appendHistory(.archived, id: draft.projects[index].id, now: now, note: "人工归档全部当前范围；未完成交付承诺明确取消")
            }
            for index in draft.items.indices {
                draft.items[index].isArchived = true
                if draft.items[index].status != .completed { draft.items[index].disposition = .cancelled }
                draft.appendHistory(.archived, id: draft.items[index].id, now: now, note: "人工归档当前范围，历史与来源保留")
            }
            for index in draft.nodes.indices { draft.nodes[index].isArchived = true }
            for index in draft.blockers.indices { draft.blockers[index].isArchived = true }
            draft.currentChoiceID = nil
        }
    }
    /// Correct the interpretation of a captured fact while preserving its original immutable value.
    public mutating func correctEstimateBaseline(itemID: String, baseline: EstimateBaselineKind,
                                                 minutes: Int?, now: Date, note: String = "") throws {
        try command(at: now) { draft in
            let item = draft.items[try draft.itemIndex(itemID)]
            if baseline == .preStart, item.preStartCapturedAt == nil {
                throw CoreError.invalid("没有开工前快照，不能由后来的记录补造")
            }
            if baseline == .initial, item.initialMinutes == nil {
                throw CoreError.invalid("首次估计未记录，不能补造历史基线")
            }
            try checkMinutes(minutes, "baseline correction")
            let original = baseline == .initial ? item.initialMinutes : item.preStartMinutes
            let correction = EstimateBaselineCorrection(itemID: itemID, baseline: baseline, originalMinutes: original,
                                                        correctedMinutes: minutes, date: now, reason: note)
            let source = draft.history.first { event in
                guard event.objectID == itemID else { return false }
                if baseline == .initial {
                    return event.id == item.initialEstimateEventID
                }
                return event.kind == .baselineCaptured && event.date == item.preStartCapturedAt && (event.round ?? 1) == 1
            }
            let previous = draft.history.last { event in
                guard event.objectID == itemID, event.note == "cubic.baseline.correction.v1",
                      let data = event.detail?.data(using: .utf8),
                      let correction = try? SyncCoding.decode(EstimateBaselineCorrection.self, from: data) else { return false }
                return correction.baseline == baseline
            }
            let event = HistoryEvent(date: now, kind: .estimateCorrected, objectID: itemID, note: "cubic.baseline.correction.v1",
                                     minutes: minutes, previousMinutes: original, round: baseline == .preStart ? 1 : nil,
                                     correctsEventID: previous?.id ?? source?.id, changeReason: .correction,
                                     detail: String(decoding: try SyncCoding.encode(correction), as: UTF8.self))
            draft.history.append(event)
        }
    }
    public func baselineCorrections(itemID: String) -> [EstimateBaselineCorrection] {
        history.filter { $0.objectID == itemID && $0.note == "cubic.baseline.correction.v1" }.compactMap { event in
            guard let data = event.detail?.data(using: .utf8) else { return nil }
            return try? SyncCoding.decode(EstimateBaselineCorrection.self, from: data)
        }.sorted { $0.date < $1.date }
    }
    /// Moves the primary location without copying work or declaring its factual outcome invalid.
    /// Project delivery results reopen; explicit references and all original histories survive.
    public mutating func moveNode(id: String, projectID: String, now: Date, note: String = "") throws {
        try command(at: now) { draft in
            guard let nodeIndex = draft.nodes.firstIndex(where: { $0.id == id }),
                  draft.projects.contains(where: { $0.id == projectID }) else { throw CoreError.missing("node/target project") }
            let old = draft.nodes[nodeIndex]
            guard old.projectID != projectID else { return }
            let previousIndex = DomainIndex(draft)
            draft.ensureNodeStructureOrders(projectID: projectID)
            let predecessor = draft.projectStructure(projectID: projectID).nodes.last?.id
            var changedNodes: [String] = old.sequentialPredecessorNodeID == predecessor ? [] : [id]
            for index in draft.nodes.indices where draft.nodes[index].sequentialPredecessorNodeID == id {
                draft.nodes[index].sequentialPredecessorNodeID = old.sequentialPredecessorNodeID
                changedNodes.append(draft.nodes[index].id)
            }
            draft.nodes[nodeIndex].projectID = projectID
            draft.nodes[nodeIndex].structureOrder = (draft.nodes.filter { $0.projectID == projectID && $0.id != id }.compactMap(\.structureOrder).max() ?? 0) + 1
            draft.nodes[nodeIndex].sequentialPredecessorNodeID = predecessor
            for index in draft.items.indices where draft.items[index].nodeID == id {
                var ids = Set(draft.items[index].projectIDs)
                ids.remove(old.projectID); ids.insert(projectID)
                draft.items[index].projectIDs = ids.sorted()
            }
            if var links = draft.workLinks {
                for index in links.indices where links[index].nodeID == id && links[index].projectID == old.projectID {
                    links[index].projectID = projectID
                }
                draft.workLinks = links
            }
            draft.invalidateNodeSequenceChanges(changedNodes, previousIndex: previousIndex, now: now)
            for affected in [old.projectID, projectID] {
                draft.reopenProjectResult(affected, now: now)
                draft.appendHistory(.scopeChanged, id: affected, now: now, note: "节点主归属迁移，按当前结构更新交付范围", relatedIDs: [id])
            }
            draft.appendHistory(.scopeChanged, id: id, now: now, note: note,
                                relatedIDs: [old.projectID, projectID], detail: try domainChangeDetail(old, draft.nodes[nodeIndex]))
        }
    }
}
