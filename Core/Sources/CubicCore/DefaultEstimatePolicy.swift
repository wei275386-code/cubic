import Foundation

extension WorkItem {
    public var isPendingInboxOrganization: Bool {
        projectIDs.isEmpty && nodeID == nil && description == nil && deadline == nil && remainingMinutes == nil && status != .completed
    }
}

extension Workspace {
    public var defaultEstimateItemIDs: [String] {
        let referenced = Set((workLinks ?? []).filter { $0.removedAt == nil }.compactMap { link -> String? in
            if case .item(let id) = link.source { return id }; return nil
        } + dependencies.filter(\.isActive).flatMap { dependency -> [String] in
            if case .item(let id) = dependency.source { return [id, dependency.targetItemID] }
            return [dependency.targetItemID]
        })
        return items.filter {
            $0.status != .completed && !$0.archived && $0.effectiveDisposition == .active && $0.remainingMinutes == nil &&
                (!$0.isPendingInboxOrganization || referenced.contains($0.id))
        }.map(\.id)
    }
    /// A current estimate, never a backdated correction of a recorded work session or pre-start baseline.
    public mutating func applyDefaultRemainingEstimates(now: Date) throws {
        let ids = defaultEstimateItemIDs
        guard !ids.isEmpty else { return }
        try command(at: now) { draft in
            for id in ids { try draft.changeRemaining(itemID: id, minutes: 60, now: now, reason: .other, note: "未设置剩余估计，默认按 1 小时计算") }
        }
    }
}
