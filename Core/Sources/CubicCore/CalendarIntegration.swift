import Foundation

extension Workspace {
    /// Assess current future reservations without creating history or altering domain facts.
    /// Started blocks are clipped to `now`, matching CalendarPlanning's remaining commitment semantics.
    public func calendarTimeBlockIssues(slots: [CapacitySlot], busy: [BusyInterval] = [],
                                       mappedBusy: [String: [BusyInterval]] = [:], now: Date) throws -> [String: String] {
        let future = (timeBlocks ?? []).filter { $0.end > now }.sorted { $0.start < $1.start }
        let horizon = max(now, future.map(\.end).max() ?? now)
        let allBusy = busy + mappedBusy.values.flatMap { $0 }
        let pool = try PlanningPool(input: PlanningInput(slots: slots, busy: allBusy, now: now, horizonEnd: horizon))
        let index = DomainIndex(self)
        var totalByItem: [String: Double] = [:]
        for block in future { totalByItem[block.itemID, default: 0] += block.end.timeIntervalSince(max(now, block.start)) }
        var reasons: [String: String] = [:]
        for block in future {
            guard let item = index.items[block.itemID] else { reasons[block.id] = "对应工作已删除，时间块需要确认。"; continue }
            guard item.status != .completed, !item.archived, item.effectiveDisposition == .active else {
                reasons[block.id] = "对应工作已完成、归档或当前不可安排，时间块需要确认。"; continue
            }
            guard !item.needsReview, (index.incoming[item.id] ?? []).allSatisfy({ index.sourceSatisfied($0.source) }) else {
                reasons[block.id] = "工作前置条件或成果复核尚未满足，请先处理后再确认时间块。"; continue
            }
            let start = max(now, block.start), seconds = block.end.timeIntervalSince(start)
            guard let remaining = item.remainingMinutes, totalByItem[item.id, default: 0] <= Double(remaining) * 60 + 0.001 else {
                reasons[block.id] = "未来时间块合计超过当前剩余估计，或剩余估计尚未明确。"; continue
            }
            guard !item.requiresContinuous || seconds + 0.001 >= Double(item.continuousMinutes ?? remaining) * 60 else {
                reasons[block.id] = "当前时间块剩余的连续时段不足，请重新安排。"; continue
            }
            // Its own Calendar projection can still be at the old time while Cubic moves/resizes the block.
            // That reservation must not prevent publishing the new time; other Events remain real occupancy.
            let assessmentPool: PlanningPool
            if mappedBusy[block.id] != nil {
                let otherBusy = busy + mappedBusy.filter { $0.key != block.id }.values.flatMap { $0 }
                assessmentPool = try PlanningPool(input: PlanningInput(slots: slots, busy: otherBusy, now: now, horizonEnd: horizon))
            } else { assessmentPool = pool }
            guard assessmentPool.seconds(energy: item.energy, start: start, end: block.end) + 0.001 >= seconds else {
                reasons[block.id] = "时间块与当前日历占用、工作时段或精力要求不匹配，请重新安排。"; continue
            }
        }
        var latest: WorkTimeBlock?
        for block in future {
            if let previous = latest, max(now, block.start) < previous.end {
                reasons[block.id] = "时间块与另一个 Cubic 时间块重叠，请先确认安排。"
                reasons[previous.id] = "时间块与另一个 Cubic 时间块重叠，请先确认安排。"
            }
            if latest == nil || block.end > latest!.end { latest = block }
        }
        return reasons
    }
}
