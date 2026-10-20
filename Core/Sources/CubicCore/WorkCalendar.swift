import Foundation

/// A user-pinned calendar commitment, not an effort/completion fact.
public struct WorkTimeBlock: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var itemID: String
    public var start: Date
    public var end: Date
    public init(id: String = UUID().uuidString, itemID: String, start: Date, end: Date) {
        self.id = id; self.itemID = itemID; self.start = start; self.end = end
    }
}

extension Workspace {
    public mutating func deleteItem(id: String, now: Date) throws {
        try command(at: now) { draft in
            let index = try draft.itemIndex(id), item = draft.items[index]
            // Invalidate against the OLD graph before severing relationships.
            let impact = DomainIndex(draft).invalidationClosure(of: [.item(id)], includeSources: false)
            draft.applyInvalidation(impact, now: now)
            for i in draft.dependencies.indices where draft.dependencies[i].targetItemID == id || draft.dependencies[i].source == .item(id) {
                draft.dependencies[i].removedAt = now
            }
            for i in draft.acceptances.indices {
                if draft.acceptances[i].subject == .item(id) { draft.acceptances[i].removedAt = now }
                draft.acceptances[i].candidateItemIDs?.removeAll { $0 == id }
            }
            if var links = draft.workLinks {
                for i in links.indices where links[i].source == .item(id) { links[i].removedAt = now }
                draft.workLinks = links
            }
            for i in draft.blockers.indices where draft.blockers[i].followUpItemID == id { draft.blockers[i].followUpItemID = nil }
            if draft.currentNextAction?.itemID == id { draft.currentChoiceID = nil }
            draft.timeBlocks?.removeAll { $0.itemID == id }
            draft.items.remove(at: index)
            draft.deletedItems = (draft.deletedItems ?? []) + [item]
            for projectID in item.projectIDs { draft.reopenProjectResult(projectID, now: now) }
            draft.appendHistory(.deleted, id: id, now: now, note: "删除工作：\(item.name)；保留历史事实，不再参与交互或排期")
        }
    }

    public mutating func setTimeBlock(_ block: WorkTimeBlock, slots: [CapacitySlot], busy: [BusyInterval] = [], now: Date) throws {
        try command(at: now) { draft in
            try checkInterval(block.start, block.end, "工作时间块")
            guard block.start >= now else { throw CoreError.invalid("请将时间块放在未来；真实投入请另行记录。") }
            let item = draft.items[try draft.itemIndex(block.itemID)]
            guard item.status != .completed, !item.archived, item.effectiveDisposition == .active else { throw CoreError.invalid("这项工作当前不可安排。") }
            try draft.requireReady(item.id)
            if let old = draft.timeBlocks?.first(where: { $0.id == block.id }), old.itemID != block.itemID { throw CoreError.invalid("时间块不能更换工作身份。") }
            let others = (draft.timeBlocks ?? []).filter { $0.id != block.id }
            guard !others.contains(where: { $0.start < block.end && block.start < $0.end }) else { throw CoreError.invalid("时间块与已放置的工作重叠，请选择其他时间。") }
            let pool = try PlanningPool(input: PlanningInput(slots: slots, busy: busy, now: now, horizonEnd: block.end))
            let seconds = block.end.timeIntervalSince(block.start)
            guard pool.seconds(energy: item.energy, start: block.start, end: block.end) + 0.001 >= seconds else { throw CoreError.invalid("这个时段被日历占用、超出工作时段或精力不匹配，请选择可用时间。") }
            let scheduled = others.filter { $0.itemID == item.id && $0.end > now }.reduce(seconds) { $0 + $1.end.timeIntervalSince(max(now, $1.start)) }
            guard let remaining = item.remainingMinutes, scheduled <= Double(remaining) * 60 + 0.001 else { throw CoreError.invalid("时间块合计不能超过当前剩余估计；请先补充或调整估计。") }
            if item.requiresContinuous {
                guard seconds >= Double(item.continuousMinutes ?? remaining) * 60 else { throw CoreError.invalid("这项工作需要连续时间，请放置足够长的时间块。") }
            }
            draft.timeBlocks = others + [block]
            draft.appendHistory(.timeBlockChanged, id: item.id, now: now, note: "设置日历时间块，不改变实际投入或剩余", detail: String(decoding: try SyncCoding.encode(block), as: UTF8.self))
        }
    }
    public mutating func removeTimeBlock(id: String, now: Date) throws {
        try command(at: now) { draft in
            guard let block = draft.timeBlocks?.first(where: { $0.id == id }) else { throw CoreError.missing("时间块") }
            draft.timeBlocks?.removeAll { $0.id == id }
            draft.appendHistory(.timeBlockChanged, id: block.itemID, now: now, note: "移除日历时间块，工作与投入记录保留")
        }
    }
}
