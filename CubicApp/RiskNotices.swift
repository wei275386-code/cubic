import Foundation
import CubicCore
import CryptoKit

struct RiskNotice: Codable, Sendable, Identifiable, Equatable {
    var id: String
    var rootObjectID: String
    var kind: String
    var title: String
    var body: String
    var projectIDs: [String]
    var itemIDs: [String]
    var createdAt: Date
    var changedAt: Date
    var dueAt: Date?
    var snoozedUntil: Date?
    var isRead = false
    var isResolved = false
    var fingerprint: String
    var nextNotificationDate: Date? {
        if isResolved { return nil }
        // An explicit reminder remains valid even for an acknowledged notice.
        if let snoozedUntil { return snoozedUntil }
        guard !isRead, kind == "followUp" || kind == "waitingExpected" else { return nil }
        // Legacy risk notices stored an artificial now + 2 seconds deadline.
        // Only real, user-declared dates may become automatic system alerts.
        return dueAt
    }
}

/// Apply current wording to earlier reminders without rewriting saved history.
enum NoticeCopy {
    static func title(_ notice: RiskNotice) -> String {
        switch notice.kind {
        case "capacityConflict": return notice.body.hasPrefix("前置时间") || notice.body.hasPrefix("预计最早") ? "交付时间赶不上截止" : "截止前的时间不够"
        case "syncConflict": return "有同步冲突需要处理"
        case "projectRisk": return replacingPrefix("需要取舍：", with: "请检查安排：", in: notice.title)
        case "waitingExpected": return replacingPrefix("确认等待状态：", with: "确认等待是否结束：", in: notice.title)
        case "review": return "前置已变化，请复核成果"
        case "unlock": return replacingPrefix("条件已解除：", with: "等待已结束：", in: notice.title)
        default: return notice.title
        }
    }
    static func summary(_ notice: RiskNotice) -> String {
        switch notice.kind {
        case "syncConflict": return "请到设置选择要使用的版本。其他工作可以继续。"
        case "waitingExpected": return "到预计结束时间后，请确认等待是否已结束。跟进日期可以单独设置。"
        case "acceptanceFailed":
            return notice.body.hasPrefix("已保留失败结果") || notice.body.hasPrefix("返工范围已确认") ? "返工范围已确认，请检查返工和需要复核的后续成果。" : "请确认哪些工作需要返工，或添加新的返工工作。"
        default:
            let replacements = [
                ("前置时间至少延迟", "预计最早能交付的时间比截止至少晚"),
                ("共同窗口内劳动至少缺", "这些工作共用的时间至少还差"),
                ("查看共同根因与关联工作，可调整范围、窗口或下一步。", "请检查关联工作，调整范围、可用时间或下一步。"),
                ("在当前声明条件下至少缺", "按当前估计，截止前至少还差"),
                ("查看影响，可调整下一步、范围或截止。", "请检查安排，调整工作范围、可用时间或截止。"),
                ("余量已进入预警范围，查看前提并试算下一步。", "截止前时间偏紧，请检查剩余工作和下一步安排。"),
                ("检查条件、更新预期或安排下一次跟进。", "请确认等待进展、更新预计结束时间或设置下次跟进。"),
                ("项已有工作需要核对。保留完成和投入事实，可确认仍有效、等待或局部返工。", "项成果需要复核。请确认仍可使用，还是需要等待或返工。"),
                ("项关联工作可推进。查看或试算，系统不会替你选择。", "项关联工作可以开始，请查看并选择下一步。")
            ]
            return formatMinutes(replacements.reduce(notice.body) { $0.replacingOccurrences(of: $1.0, with: $1.1) })
        }
    }
    private static let minutePattern = try! NSRegularExpression(pattern: "([0-9]+) 分钟")
    private static func formatMinutes(_ text: String) -> String {
        var result = text
        for match in minutePattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let numberRange = Range(match.range(at: 1), in: text), let minutes = Int(text[numberRange]),
                  let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: minutesLabel(minutes))
        }
        return result
    }
    private static func replacingPrefix(_ prefix: String, with value: String, in text: String) -> String {
        text.hasPrefix(prefix) ? value + text.dropFirst(prefix.count) : text
    }
}

/// Notification handling facts use immutable history events, so backup and sync preserve them.
/// They never mutate deadlines, effort, remaining work or blocker state.
enum RiskNoticeEngine {
    static let historyMarker = "cubic.notification.state.v1"
    static func stored(in workspace: Workspace) -> [RiskNotice] {
        var result: [String: RiskNotice] = [:]
        for event in workspace.history.filter({ $0.note == historyMarker }).sorted(by: {
            $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date
        }) {
            guard let detail = event.detail, let data = detail.data(using: .utf8),
                  let notice = try? SyncCoding.decode(RiskNotice.self, from: data) else { continue }
            if var previous = result[notice.id] {
                // Acknowledgement is monotonic for the same unchanged root cause.
                var value = notice
                if previous.fingerprint == notice.fingerprint { value.isRead = previous.isRead || notice.isRead }
                previous = value
                result[notice.id] = previous
            } else { result[notice.id] = notice }
        }
        return result.values.sorted { $0.changedAt > $1.changedAt }
    }
    static func event(_ notice: RiskNotice, at date: Date) throws -> HistoryEvent {
        let data = try SyncCoding.encode(notice)
        return HistoryEvent(date: date, kind: .edited, objectID: notice.rootObjectID,
                            note: historyMarker, detail: String(decoding: data, as: UTF8.self))
    }
    static func changes(workspace: Workspace, planning: PlanningSnapshot, now: Date, conflicts: [SyncConflict] = []) -> [RiskNotice] {
        let previous = Dictionary(uniqueKeysWithValues: stored(in: workspace).map { ($0.id, $0) })
        // Archive hides reminders the same way project and risk lists hide scope. Planning demand is unchanged.
        let visibility = PlanningDisplay.PlanningVisibility(workspace: workspace) { Set($0.projectIDs) }
        let certificates = visibility.certificates(planning.certificates)
        var current: [RiskNotice] = []
        func add(id: String, root: String, kind: String, title: String, body: String,
                 projects: [String], items: [String], due: Date?, fingerprint: String) {
            var notice = RiskNotice(id: id, rootObjectID: root, kind: kind, title: title, body: body,
                                    projectIDs: projects.sorted(), itemIDs: items.sorted(), createdAt: now,
                                    changedAt: now, dueAt: due, fingerprint: fingerprint)
            notice.title = NoticeCopy.title(notice)
            notice.body = NoticeCopy.summary(notice)
            if let old = previous[id] {
                notice.createdAt = old.createdAt
                // An explicit reminder belongs to this active root cause, even
                // when planning recalculates its severity or affected scope.
                if !old.isResolved { notice.snoozedUntil = old.snoozedUntil }
                if old.fingerprint == fingerprint && !old.isResolved {
                    notice.isRead = old.isRead
                    if old.dueAt == due { notice.changedAt = old.changedAt }
                }
            }
            current.append(notice)
        }
        let provenProjects = Set(certificates.flatMap(\.projectIDs))
        let groupedCertificates = Dictionary(grouping: certificates) { certificate in
            "\(certificate.kind.rawValue):\(certificate.itemIDs.sorted().joined(separator: ",")):\(certificate.energy.rawValue):\(certificate.windowEnd.timeIntervalSince1970)"
        }
        for cause in groupedCertificates.keys.sorted() {
            let certificates = groupedCertificates[cause] ?? []
            guard let certificate = certificates.max(by: {
                ($0.elapsedDelaySeconds.map { Int(ceil($0 / 60)) } ?? $0.shortageMinutes) < ($1.elapsedDelaySeconds.map { Int(ceil($0 / 60)) } ?? $1.shortageMinutes)
            }) else { continue }
            let projects = Set(certificates.flatMap(\.projectIDs).filter { visibility.projectIDs.contains($0) }).sorted()
            let items = Set(certificates.flatMap(\.itemIDs).filter { visibility.itemIDs.contains($0) }).sorted()
            guard !projects.isEmpty || !items.isEmpty else { continue }
            let root = items.first ?? projects[0]
            let rootKey = SHA256.hash(data: Data(cause.utf8)).map { String(format: "%02x", $0) }.joined()
            let delay = certificate.elapsedDelaySeconds.map { Int(ceil($0 / 60)) }
            let magnitude = delay ?? certificate.shortageMinutes
            add(id: "capacity.\(rootKey)", root: root, kind: "capacityConflict", title: "多个需求需要取舍",
                body: (delay.map { "前置时间至少延迟 \($0) 分钟。" } ?? "共同窗口内劳动至少缺 \(certificate.shortageMinutes) 分钟。") + "查看共同根因与关联工作，可调整范围、窗口或下一步。",
                projects: projects, items: items, due: nil,
                fingerprint: "\(rootKey):\(max(1, magnitude) / 15):\(projects.joined(separator: ","))")
        }
        for conflict in conflicts {
            guard let root = conflict.affectedItemIDs.first ?? workspace.projects.first?.id ?? workspace.items.first?.id else { continue }
            let projects = Set(workspace.items.filter { conflict.affectedItemIDs.contains($0.id) }.flatMap(\.projectIDs))
            add(id: "sync.\(conflict.id)", root: root, kind: "syncConflict", title: "需要确认并发事实",
                body: "\(conflict.message) 原始事实均保留；可在设置处理，其他工作继续。",
                projects: Array(projects), items: conflict.affectedItemIDs, due: nil, fingerprint: conflict.id)
        }
        for assessment in planning.projects {
            guard let project = workspace.projects.first(where: { $0.id == assessment.projectID }),
                  project.hasDeliveryCommitment, visibility.projectIDs.contains(project.id) else { continue }
            if [.insufficient, .boundaryReached, .infeasible].contains(assessment.warningState) && !provenProjects.contains(project.id) {
                let shortage = certificates.filter { $0.projectIDs.contains(project.id) }.map(\.shortageMinutes).max() ?? 0
                add(id: "risk.project.\(project.id)", root: project.id, kind: "projectRisk", title: "需要取舍：\(project.name)",
                    body: shortage > 0 ? "在当前声明条件下至少缺 \(shortage) 分钟。查看影响，可调整下一步、范围或截止。" : "余量已进入预警范围，查看前提并试算下一步。",
                    projects: [project.id], items: workspace.items.filter { $0.projectIDs.contains(project.id) }.map(\.id), due: nil,
                    fingerprint: "\(assessment.warningState.rawValue):\(shortage / 15):\(assessment.warningMarginMinutes ?? -1)")
            }
        }
        // Shared root cause produces one follow-up notice, with all direct/indirect impacts.
        for blocker in workspace.blockers where blocker.state != .resolved && blocker.isArchived != true {
            let affected = workspace.affectedItemIDs(by: .blocker(blocker.id))
            let visibleAffected = affected.filter { visibility.itemIDs.contains($0) }
            if !affected.isEmpty && visibleAffected.isEmpty { continue }
            let projects = Set(workspace.items.filter { visibleAffected.contains($0.id) }.flatMap(\.projectIDs).filter { visibility.projectIDs.contains($0) })
            if let followUp = blocker.followUpAt {
                add(id: "followup.\(blocker.id)", root: blocker.id, kind: "followUp", title: "跟进：\(blocker.name)",
                    body: "影响 \(projects.count) 个项目、\(visibleAffected.count) 项工作。检查条件、更新预期或安排下一次跟进。",
                    projects: Array(projects), items: visibleAffected, due: followUp,
                    fingerprint: "\(blocker.currentRound):\(followUp.timeIntervalSince1970):\(visibleAffected.sorted().joined(separator: ","))")
            }
            if blocker.state == .active, let expected = blocker.estimatedResolution {
                add(id: "waiting.\(blocker.id)", root: blocker.id, kind: "waitingExpected", title: "确认等待状态：\(blocker.name)",
                    body: "预计解除时间已到时，请人工确认。到期不会自动解除，跟进日期与这个预期分别维护。",
                    projects: Array(projects), items: visibleAffected, due: expected,
                    fingerprint: "\(blocker.currentRound):\(expected.timeIntervalSince1970)")
            }
        }
        let reviewItems = workspace.items.filter { $0.needsReview && visibility.itemIDs.contains($0.id) }
        // Group disputed downstream results by the shared upstream reason, where available.
        var reviewGroups: [String: [WorkItem]] = [:]
        for item in reviewItems {
            let dependency = workspace.dependencies.first { $0.isActive && $0.targetItemID == item.id && !workspace.sourceSatisfied($0.source) }
            let root = dependency?.source.id ?? item.id
            reviewGroups[root, default: []].append(item)
        }
        for (root, items) in reviewGroups {
            let projects = Set(items.flatMap(\.projectIDs))
            add(id: "review.\(root)", root: root, kind: "review", title: "前置变化，需要复核",
                body: "\(items.count) 项已有工作需要核对。保留完成和投入事实，可确认仍有效、等待或局部返工。",
                projects: Array(projects), items: items.map(\.id), due: nil,
                fingerprint: items.map { "\($0.id):\($0.currentRound)" }.sorted().joined(separator: ","))
        }
        for gate in workspace.acceptances where gate.state == .failed && gate.removedAt == nil {
            let members = workspace.items.filter { item in
                switch gate.subject { case .item(let id): item.id == id; case .node(let id): item.nodeID == id }
            }
            let visibleMembers = members.filter { visibility.itemIDs.contains($0.id) }
            guard !visibleMembers.isEmpty || visibility.objectIDs.contains(gate.id) else { continue }
            add(id: "acceptance.\(gate.id)", root: gate.id, kind: "acceptanceFailed", title: "验收未通过：\(gate.name)",
                body: gate.reworkScopeConfirmed == true ? "已保留失败结果，查看返工与下游复核。" : "返工范围尚未确认，请选择实际需重开的工作或新增返工。",
                projects: Array(Set(visibleMembers.flatMap(\.projectIDs).filter { visibility.projectIDs.contains($0) })), items: visibleMembers.map(\.id), due: nil,
                fingerprint: "\(gate.currentRound):\(gate.reworkScopeConfirmed == true)")
        }
        // A real release exposes concrete currently executable descendants; no automatic choice.
        for blocker in workspace.blockers where blocker.state == .resolved {
            guard let resolved = blocker.resolvedAt, now.timeIntervalSince(resolved) < 86400 else { continue }
            let affected = workspace.affectedItemIDs(by: .blocker(blocker.id))
            let ready = planning.legacy.availableActions.map(\.itemID).filter { affected.contains($0) && visibility.itemIDs.contains($0) }
            guard !ready.isEmpty else { continue }
            let projects = Set(workspace.items.filter { ready.contains($0.id) }.flatMap(\.projectIDs).filter { visibility.projectIDs.contains($0) })
            add(id: "unlock.\(blocker.id).\(blocker.currentRound)", root: blocker.id, kind: "unlock", title: "条件已解除：\(blocker.name)",
                body: "现在有 \(ready.count) 项关联工作可推进。查看或试算，系统不会替你选择。",
                projects: Array(projects), items: ready, due: nil, fingerprint: ready.sorted().joined(separator: ","))
        }
        let activeIDs = Set(current.map(\.id))
        var changes = current.filter { notice in
            guard let old = previous[notice.id] else { return true }
            return old.fingerprint != notice.fingerprint || old.isResolved || old.dueAt != notice.dueAt
        }
        for old in previous.values where !activeIDs.contains(old.id) && !old.isResolved {
            var resolved = old; resolved.isResolved = true; resolved.changedAt = now; resolved.dueAt = nil
            changes.append(resolved)
        }
        return changes
    }
}
