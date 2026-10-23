import SwiftUI
import CubicCore

struct HistoryFactDetails: View {
    let event: HistoryEvent
    @Environment(AppModel.self) private var model
    private var data: Data? { event.detail?.data(using: .utf8) }
    var body: some View {
        if let data, event.note == RiskNoticeEngine.historyMarker,
           let notice = try? JSONCoding.decode(RiskNotice.self, from: data) {
            NoticeRow(notice: notice)
            Text(notice.isRead ? "已读" : "未读").font(.caption)
            NavigationLink("查看提醒当前状态") { NoticeDetailView(noticeID: notice.id) }
        } else if let data, event.note == "cubic.baseline.correction.v1",
                  let correction = try? JSONCoding.decode(EstimateBaselineCorrection.self, from: data) {
            Text(correction.baseline == .initial ? "首次估计更正" : "开工前估计更正")
            Text("保留原值 \(minutesLabel(correction.originalMinutes)) → 更正为 \(minutesLabel(correction.correctedMinutes))")
            if !correction.reason.isEmpty { Text(correction.reason) }
            Text("当前剩余不变，原始估计保留").font(.caption).foregroundStyle(.secondary)
        } else if event.kind == .choiceRecorded,
                  let choice = model.workspace.choices?.first(where: { $0.id == event.objectID }) {
            NavigationLink("查看这次选择的记录") { ChoiceDetailView(choice: choice) }
        } else if let data, let value = try? JSONCoding.decode(JSONValue.self, from: data),
                  case .object(let values) = value,
                  case .object(let before) = values["before"], case .object(let after) = values["after"] {
            let fields = Set(before.keys).union(after.keys).filter { $0 != "id" && before[$0] != after[$0] }.sorted()
            ForEach(fields, id: \.self) { field in
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.fieldTitle(field)).font(.subheadline.weight(.medium))
                    Text("原值：\(describe(before[field] ?? .null, field: field))")
                    Text("新值：\(describe(after[field] ?? .null, field: field))")
                }.font(.caption).fixedSize(horizontal: false, vertical: true)
            }
        } else if let detail = event.detail, !detail.hasPrefix("{") {
            Text(detail).font(.caption).fixedSize(horizontal: false, vertical: true)
        } else {
            Text("原始记录保留在备份中，也可以到相关工作查看当前状态。").font(.caption).foregroundStyle(.secondary)
        }
    }
    static func fieldTitle(_ field: String) -> String {
        Self.titles[field] ?? "其他资料（\(field)）"
    }
    private func describe(_ value: JSONValue, field: String) -> String {
        switch value {
        case .null: return "未记录"
        case .bool(let value): return value ? "是" : "否"
        case .number(let value):
            if Self.dateFields.contains(field) { return ProjectUI.dateLabel(Date(timeIntervalSince1970: value / 1000)) }
            if field.lowercased().contains("minutes"), let minutes = Int(exactly: value) { return minutesLabel(minutes) }
            return String(format: "%g", value)
        case .string(let value):
            if ["name", "title", "description", "detail", "note", "notes", "reason", "outcome", "contactNote", "resolutionCondition"].contains(field) { return value }
            return model.item(value)?.name ?? model.workspace.nodes.first { $0.id == value }?.name
                ?? model.workspace.projects.first { $0.id == value }?.name
                ?? model.workspace.blockers.first { $0.id == value }?.name
                ?? model.workspace.acceptances.first { $0.id == value }?.name
                ?? Self.states[value] ?? (value.isEmpty ? "未填写" : value)
        case .array(let values): return values.isEmpty ? "无" : values.map { describe($0, field: field) }.joined(separator: "、")
        case .object(let values):
            if values.count == 1, let (key, nested) = values.first {
                if ["item", "node", "blocker"].contains(key) { return describe(nested, field: field) }
                if key == "_0" { return describe(nested, field: field) }
            }
            return values.sorted { $0.key < $1.key }.map { "\(Self.fieldTitle($0.key))：\(describe($0.value, field: $0.key))" }.joined(separator: "\n")
        }
    }
    private static let dateFields: Set<String> = ["deadline", "started", "completedAt", "preStartCapturedAt", "triggeredAt", "resolvedAt", "expectedResolution", "followUpAt", "acceptedAt", "failedAt", "removedAt", "createdAt", "effectiveAt"]
    private static let states = ["planning": "待拆分", "active": "进行中 / 条件等待中", "deferred": "暂缓", "completed": "已完成", "cancelled": "已取消", "pending": "待处理", "inProgress": "已开工", "inactive": "尚未发起", "resolved": "等待已结束", "accepted": "验收已通过", "failed": "验收未通过", "complete": "工作已列全", "incomplete": "还没拆完", "normal": "普通精力", "high": "高专注", "low": "低负荷"]
    private static let titles = ["name": "名称", "title": "标题", "description": "目标 / 说明", "detail": "说明", "notes": "备注", "note": "说明", "importance": "重要性", "status": "工作状态", "disposition": "是否继续做", "state": "条件状态", "planningCompleteness": "是否已拆完", "warningBufferMinutes": "时间余量提醒", "isArchived": "是否归档", "isRequired": "是否必需", "isFocused": "当前关注", "contextTags": "标签", "energy": "精力需求", "requiresContinuous": "是否需连续", "continuousMinutes": "连续分钟", "remainingMinutes": "当前剩余", "initialMinutes": "首次估计", "preStartMinutes": "开工前估计", "preStartCapturedAt": "开工前估计记录时间", "started": "首次开始", "completedAt": "完成时间", "needsReview": "是否需复核", "round": "工作 / 等待轮次", "deadline": "截止时间", "deadlineTimeZoneID": "截止时区", "deadlineIsDateOnly": "是否在当天结束前截止", "structureOrder": "节点 / 工作顺序", "sequentialPredecessorNodeID": "默认前置节点", "nodeID": "所属节点", "projectID": "主归属项目", "projectIDs": "关联项目", "outcome": "节点成果", "blockerIDs": "整个节点的等待", "triggeredAt": "开始等待时间", "expectedDurationMinutes": "预计等待分钟数", "expectedResolution": "预计结束", "followUpAt": "下次跟进", "resolvedAt": "等待结束时间", "resolutionCondition": "等待结束条件", "contactNote": "跟进备注", "followUpItemID": "跟进待办", "subject": "对应工作或节点", "source": "前置条件", "targetItemID": "后续工作", "acceptedAt": "验收通过时间", "failedAt": "验收未通过时间", "reason": "原因", "candidateItemIDs": "可能返工的工作", "candidateBlockerIDs": "可能重新发起的等待", "reworkScopeConfirmed": "是否已选定返工工作", "removedAt": "范围移除时点", "createdAt": "创建时点", "effectiveAt": "生效时点", "revision": "关联版本"]
}
