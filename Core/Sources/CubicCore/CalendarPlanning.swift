import Foundation

struct CalendarPlanning {
    var blocks: [WorkTimeBlock] = []
    var reductions: [String: Double] = [:]
    var finishes: [String: Date] = [:]
    var issues: [PlanningUnknown] = []
    init(workspace: Workspace, input: PlanningInput) throws {
        let original = try PlanningPool(input: input)
        let index = DomainIndex(workspace)
        for block in (workspace.timeBlocks ?? []).sorted(by: { $0.start < $1.start }) {
            guard block.end > input.now, let item = index.items[block.itemID], item.status != .completed else { continue }
            let start = max(input.now, block.start), end = block.end
            let seconds = end.timeIntervalSince(start)
            let prior = reductions[item.id] ?? 0
            let ready = item.effectiveDisposition == .active && !item.archived && !item.needsReview &&
                (index.incoming[item.id] ?? []).allSatisfy { index.sourceSatisfied($0.source) }
            let continuousValid = !item.requiresContinuous || seconds + 0.001 >= Double(item.continuousMinutes ?? item.remainingMinutes ?? 0) * 60
            guard ready, continuousValid, end <= input.horizonEnd,
                  original.seconds(energy: item.energy, start: start, end: end) + 0.001 >= seconds,
                  item.remainingMinutes.map({ prior + seconds <= Double($0) * 60 + 0.001 }) == true else {
                issues.append(PlanningUnknown(objectID: item.id, message: "已放置的时间块与当前工作条件、剩余估计或可用时段不匹配，请在日历重新安排。"))
                continue
            }
            blocks.append(WorkTimeBlock(id: block.id, itemID: item.id, start: start, end: end))
            reductions[item.id] = prior + seconds
            finishes[item.id] = max(finishes[item.id] ?? end, end)
        }
    }
    func adding(to witness: PlanningWitness, itemIDs: Set<String>? = nil) -> PlanningWitness {
        var result = witness
        result.allocations += blocks.filter { itemIDs?.contains($0.itemID) ?? true }.map { TrialAllocation(itemID: $0.itemID, start: $0.start, end: $0.end) }
        result.allocations.sort { $0.start < $1.start }
        return result
    }
}
