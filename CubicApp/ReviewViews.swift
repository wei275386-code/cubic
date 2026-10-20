import SwiftUI
import CubicCore

/// Root can mount this without arguments in any NavigationStack.
struct ReviewView: View {
    @Environment(AppModel.self) private var model
    @State private var staleDays = 14
    private var now: Date { Date() }
    var body: some View {
        List {
            Section("待处理事项") {
                Text("逐项补充信息、确认验收和复核成果，让下一步更清楚。")
                    .fixedSize(horizontal: false, vertical: true)
                Stepper("提醒核对超过多久的估计：\(staleDays) 天", value: $staleDays, in: 1...90)
                    .frame(minHeight: 44).accessibilityIdentifier("review.staleDays")
                NavigationLink { WaitingView() } label: { Label("全部等待", systemImage: "hourglass").frame(minHeight: 44) }.accessibilityIdentifier("review.waiting")
            }
            reviewItems("收件箱里待整理的工作", items: model.pendingInboxItems, prefix: "inbox")
            Section("需要跟进的等待") {
                let blockers = model.workspace.blockers.filter { $0.state != .resolved && (($0.followUpAt.map { $0 <= now } ?? false) || ($0.estimatedResolution.map { $0 <= now } ?? false)) }
                ForEach(blockers, id: \.id) { blocker in
                    NavigationLink { BlockerDetailView(blockerID: blocker.id) } label: {
                        ProjectInfoLine(title: blocker.name, value: "\(ProjectUI.blockerLabel(blocker.state)) · 请跟进或确认等待是否已结束").frame(minHeight: 44)
                    }.accessibilityIdentifier("review.blocker.\(blocker.id)")
                }
                if blockers.isEmpty { Text("暂无到期等待。") }
            }
            reviewItems("需要补充或更新的时间估计", items: model.workspace.items.filter { item in
                guard item.status != .completed, !item.archived, item.effectiveDisposition == .active,
                      !model.pendingInboxItems.contains(where: { $0.id == item.id }) else { return false }
                let latest = (model.workspace.estimateRevisions ?? []).filter { $0.itemID == item.id }.map(\.date).max()
                    ?? model.workspace.history.filter { $0.objectID == item.id && ($0.kind == .created || $0.kind == .remainingUpdated) }.map(\.date).max()
                return item.remainingMinutes == nil || (latest.map { now.timeIntervalSince($0) >= Double(staleDays) * 86400 } ?? true)
            }, prefix: "estimate")
            Section("待验收与返工") {
                ForEach(model.workspace.acceptances.filter { $0.isActive && $0.state != .accepted }, id: \.id) { gate in
                    WorkReferenceLink(subject: gate.subject, label: gate.name, subtitle: "\(ProjectUI.acceptanceLabel(gate.state))\(gate.state == .failed && gate.reworkScopeConfirmed != true ? " · 待选择返工工作" : "")", identifier: "review.acceptance.\(gate.id)")
                }
            }
            reviewItems("已有成果待复核", items: model.workspace.items.filter(\.needsReview), prefix: "validity")
            Section("排期问题") {
                if model.calculationIsStale || model.isRefreshing { Label("排期正在更新…", systemImage: "arrow.triangle.2.circlepath") }
                let risks = model.visiblePlanningRisks.filter { $0.kind == .sharedResourceConflict || $0.kind == .provenCapacityShortfall || $0.kind == .energyConstraint || $0.kind == .continuousConstraint }
                ForEach(Array(risks.enumerated()), id: \.offset) { index, risk in
                    VStack(alignment: .leading, spacing: 8) {
                        RiskRow(risk: risk, itemLinkIdentifierPrefix: "review.conflict.item.\(index)")
                        if let projectID = risk.projectID {
                            NavigationLink { CubicProjectDetailView(projectID: projectID) } label: { Text("查看受影响项目").frame(minHeight: 44) }.accessibilityIdentifier("review.conflict.project.\(index)")
                        }
                    }
                }
                if model.snapshot == nil { Text("排期尚未核对，请稍后查看。") }
                NavigationLink { CalendarView() } label: { Label("查看日历安排", systemImage: "calendar").frame(minHeight: 44) }.accessibilityIdentifier("review.conflict.calendar")
            }
            Section("已完成项目的记录") {
                ForEach(model.workspace.projects.filter { $0.effectiveStatus == .completed || $0.completedAt != nil }, id: \.id) { project in
                    NavigationLink { CompletedProjectTimelineView(projectID: project.id) } label: { ProjectSummaryRow(project: project) }.accessibilityIdentifier("review.completed.\(project.id)")
                }
            }
            Section("投入时间有重叠") {
                let summary = model.workspace.effortSummary()
                Text(summary.unresolvedSessionIDs.isEmpty ? "当前没有发现投入时间重叠。" : "有 \(summary.unresolvedSessionIDs.count) 条记录时间重叠，当前按记录累加；可进入工作更正记录。")
                ForEach(model.workspace.effectiveWorkSessions.filter { summary.unresolvedSessionIDs.contains($0.id) }, id: \.id) { session in
                    WorkReferenceLink(subject: .item(session.itemID), label: model.item(session.itemID)?.name ?? "原记录工作", subtitle: minutesLabel(session.actualMinutes), identifier: "review.overlap.\(session.id)")
                }
            }
        }.cubicNavigationTitle("待处理事项").cubicInlineNavigationTitle()
    }
    private func reviewItems(_ title: String, items: [WorkItem], prefix: String) -> some View {
        Section("\(title)（\(items.count)）") {
            ForEach(items, id: \.id) { item in NavigationLink { WorkDetailView(itemID: item.id) } label: { ProjectWorkRow(item: item) }.accessibilityIdentifier("review.\(prefix).\(item.id)") }
            if items.isEmpty { Text("暂无待处理事项。").foregroundStyle(.secondary) }
        }
    }
}

struct CompletedProjectTimelineView: View {
    let projectID: String
    @Environment(AppModel.self) private var model
    var body: some View {
        List {
            if let project = model.workspace.projects.first(where: { $0.id == projectID }) {
                let ids = model.projectItemIDs(projectID)
                Section("项目投入概况") {
                    Text(project.name).font(.headline)
                    let summary = model.workspace.effortSummary(itemIDs: Array(ids))
                    Text("已记录投入：\(minutesLabel(summary.confirmedMinutes))")
                    if !summary.unresolvedSessionIDs.isEmpty { Label("记录有重叠，当前按各条记录累加", systemImage: "exclamationmark.circle") }
                    Text("按当前有效投入记录统计。")
                }
                ForEach(model.workspace.items.filter { ids.contains($0.id) }, id: \.id) { item in
                    Section(item.name) {
                        ProjectInfoLine(title: "耗时与轮次", value: "\(minutesLabel(item.remainingMinutes)) · 第 \(item.currentRound) 轮")
                        WorkReferenceLink(subject: .item(item.id), label: "查看工作记录", identifier: "timeline.work.\(item.id)")
                    }
                }
            }
        }.cubicNavigationTitle("项目记录").cubicInlineNavigationTitle()
    }
}

struct WorkEstimateHistorySection: View {
    let itemID: String
    @Environment(AppModel.self) private var model
    @State private var sheet: ProjectUISheet?
    var body: some View {
        Section("耗时修改历史") {
            ForEach(model.workspace.estimateRevisions?.filter { $0.itemID == itemID }.sorted { $0.date > $1.date } ?? [], id: \.id) { revision in
                VStack(alignment: .leading, spacing: 6) {
                    ProjectInfoLine(title: ProjectUI.dateLabel(revision.date), value: "\(minutesLabel(revision.previousMinutes)) → \(minutesLabel(revision.minutes))")
                    if let corrects = revision.correctsRevisionID, let original = model.workspace.estimateRevisions?.first(where: { $0.id == corrects }) { Text("更正的是 \(original.date.formatted(date: .abbreviated, time: .shortened)) 的耗时记录").font(.caption) }
                    if !revision.note.isEmpty { Text(revision.note) }
                    if (model.workspace.estimateRevisions ?? []).contains(where: { $0.correctsRevisionID == revision.id }) { Text("已更正，下方保留原记录").font(.caption) }
                    else { Button { sheet = .correctEstimate(revision) } label: { Label("更正这次记录", systemImage: "pencil.circle").frame(minHeight: 44) }.accessibilityIdentifier("estimate.correct.\(revision.id)") }
                }.fixedSize(horizontal: false, vertical: true)
            }
            Text("每次修改保留修改时间及前后耗时。").font(.caption).foregroundStyle(.secondary)
        }.sheet(item: $sheet) { ProjectUISheetContent(sheet: $0) }
    }
}

struct WorkEffortHistorySection: View {
    let itemID: String
    @Environment(AppModel.self) private var model
    @State private var sheet: ProjectUISheet?
    var body: some View {
        Section("投入记录") {
            let summary = model.workspace.effortSummary(itemIDs: [itemID])
            Text("已记录投入：\(minutesLabel(summary.confirmedMinutes))")
            if !summary.unresolvedSessionIDs.isEmpty {
                Label("记录有重叠，当前按各条记录累加", systemImage: "exclamationmark.triangle")

            }
            ForEach(model.workspace.workSessions.filter { $0.itemID == itemID }.sorted { ($0.recordedAt ?? $0.end) > ($1.recordedAt ?? $1.end) }, id: \.id) { session in
                VStack(alignment: .leading, spacing: 6) {
                    let effective = model.workspace.effectiveWorkSessions.contains { $0.id == session.id }
                    Text("\(minutesLabel(session.actualMinutes)) · \(effective ? "有效记录" : "已被更正 / 撤销")").font(.headline)
                    if session.hasExactInterval {
                        ProjectInfoLine(title: "开始时间", value: ProjectUI.dateLabel(session.start))
                        ProjectInfoLine(title: "结束时间", value: ProjectUI.dateLabel(session.end))
                    } else { ProjectInfoLine(title: "只记录了日期和时长", value: ProjectUI.datePart(session.occurredOn ?? session.end, zone: model.preferences.workTimeZone.identifier)) }
                    ProjectInfoLine(title: "记录时间", value: ProjectUI.dateLabel(session.recordedAt ?? session.end))
                    if let corrects = session.correctsSessionID, let original = model.workspace.workSessions.first(where: { $0.id == corrects }) { Text("更正的是 \((original.recordedAt ?? original.end).formatted(date: .abbreviated, time: .shortened)) 的投入记录").font(.caption) }
                    if effective {
                        Button { sheet = .correctSession(session) } label: { Label("更正或撤销这次投入", systemImage: "pencil.circle").frame(minHeight: 44) }.accessibilityIdentifier("effort.correct.\(session.id)")
                    }
                }.fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("effort.session.\(session.id)")
            }

        }.sheet(item: $sheet) { ProjectUISheetContent(sheet: $0) }
    }
}

struct EstimateCorrectionEditor: View {
    let revision: EstimateRevision
    @Environment(AppModel.self) private var model
    @State private var minutes: String
    @State private var note = ""
    init(revision: EstimateRevision) { self.revision = revision; _minutes = State(initialValue: revision.minutes.map(String.init) ?? "") }
    var body: some View {
        ProjectEditorContainer(title: "更正耗时记录", identifier: "estimate.correction", validation: ProjectUI.minutesValidation(minutes, title: "更正分钟"), save: {
            let corrected = ProjectUI.optionalMinutes(minutes), memo = note
            return await model.mutate { try $0.correctEstimate(revisionID: revision.id, minutes: corrected, now: Date(), note: memo) }
        }) {
            Section("原记录与更正") {
                Text("原记录：\(revision.date.formatted(date: .abbreviated, time: .shortened))\n原耗时：\(minutesLabel(revision.minutes))")
                ProjectMinutesField(title: "正确的分钟数（可留空）", text: $minutes, identifier: "estimate.correction.minutes")
                TextField("更正说明（可选）", text: $note, axis: .vertical).frame(minHeight: 44).accessibilityIdentifier("estimate.correction.note")
                Text("更正旧记录保留原值；更正最新记录时同步更新当前耗时。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct WorkSessionCorrectionEditor: View {
    let session: WorkSession
    @Environment(AppModel.self) private var model
    @State private var minutes: String
    @State private var exact: Bool
    @State private var day: Date
    @State private var start: Date
    @State private var end: Date
    @State private var void = false
    @State private var note = ""
    init(session: WorkSession) {
        self.session = session; _minutes = State(initialValue: String(session.actualMinutes)); _exact = State(initialValue: session.hasExactInterval)
        _day = State(initialValue: session.occurredOn ?? session.end); _start = State(initialValue: session.start); _end = State(initialValue: session.end)
    }
    private var workCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = model.preferences.workTimeZone
        return calendar
    }
    private var validation: String? {
        if void { return nil }
        if let error = ProjectUI.minutesValidation(minutes, title: "正确投入") { return error }
        if ProjectUI.optionalMinutes(minutes) == nil { return "请填写正确的投入分钟数，或选择撤销这条记录。" }
        if exact && (end < start || end > Date()) { return "请核对实际开始和结束时间。" }
        return nil
    }
    var body: some View {
        ProjectEditorContainer(title: "更正投入记录", identifier: "effort.correction", validation: validation, save: save) {
            Section("更正投入记录") {
                Text("原投入 \(minutesLabel(session.actualMinutes))\n原记录：\((session.recordedAt ?? session.end).formatted(date: .abbreviated, time: .shortened))")
                Toggle("撤销这条投入记录", isOn: $void).frame(minHeight: 44).accessibilityIdentifier("effort.correction.void")
                if !void {
                    ProjectMinutesField(title: "正确投入分钟", text: $minutes, identifier: "effort.correction.minutes")
                    Toggle("填写准确起止时间", isOn: $exact).frame(minHeight: 44).accessibilityIdentifier("effort.correction.exact")
                    if exact { ProjectDateField(title: "开始", date: $start, identifier: "effort.correction.start"); ProjectDateField(title: "结束", date: $end, identifier: "effort.correction.end") }
                    else {
                        DatePicker("实际发生日期", selection: $day, in: ...Date(), displayedComponents: .date)
                            .environment(\.calendar, workCalendar).environment(\.timeZone, workCalendar.timeZone)
                            .frame(minHeight: 44).accessibilityIdentifier("effort.correction.day")
                        Text("发生日期按工作时区 \(workCalendar.timeZone.identifier) 解释。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                TextField("更正说明（可选）", text: $note, axis: .vertical).frame(minHeight: 44).accessibilityIdentifier("effort.correction.note")
                Text("更正后按新值统计，原记录保留。准确起止时间仍会检查重叠，当前剩余不变。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func save() async -> Bool {
        let replacement: WorkSession?
        if void { replacement = nil }
        else {
            let recorded = Date()
            replacement = WorkSession(itemID: session.itemID, start: exact ? start : recorded, end: exact ? end : recorded, actualMinutes: ProjectUI.optionalMinutes(minutes) ?? 0, remainingMinutesAfter: session.remainingMinutesAfter, intervalIsExact: exact, occurredOn: exact ? nil : day, recordedAt: recorded, round: session.round)
        }
        let memo = note
        return await model.mutate { try $0.correctWorkSession(id: session.id, replacement: replacement, now: Date(), note: memo) }
    }
}

struct EffortAllocationEditor: View {
    let sessionIDs: [String]
    @Environment(AppModel.self) private var model
    @State private var values: [String: String] = [:]
    private var validation: String? {
        for id in sessionIDs { guard let text = values[id], ProjectUI.optionalMinutes(text) != nil else { return "请填写每项工作分到的分钟数，没有投入可填 0。" }; if let error = ProjectUI.minutesValidation(text, title: "分摊分钟") { return error } }
        return nil
    }
    var body: some View {
        ProjectEditorContainer(title: "核对重叠投入", identifier: "effort.allocation", validation: validation, save: {
            let ids = sessionIDs, minutes = sessionIDs.map { ProjectUI.optionalMinutes(values[$0] ?? "") ?? 0 }
            return await model.mutate { try $0.confirmEffortAllocation(sessionIDs: ids, allocatedMinutes: minutes, now: Date()) }
        }) {
            Section("分配实际投入时间") {
                Text("同一段时间只计一次。请分配到各项工作，总量不能超过这组记录覆盖的时间。")
                ForEach(sessionIDs, id: \.self) { id in
                    if let session = model.workspace.effectiveWorkSessions.first(where: { $0.id == id }) {
                        ProjectInfoLine(title: model.item(session.itemID)?.name ?? session.itemID, value: "\(ProjectUI.dateLabel(session.start))\n至\n\(ProjectUI.dateLabel(session.end))\n原投入 \(minutesLabel(session.actualMinutes))")
                        ProjectMinutesField(title: "分配给此工作的分钟", text: Binding(get: { values[id] ?? "" }, set: { values[id] = $0 }), identifier: "effort.allocation.\(id)")
                    }
                }
            }
        }
    }
}

extension ProjectUI {
    static func estimateReason(_ reason: EstimateReason?) -> String {
        switch reason { case .revision: "重新估计"; case .scopeChange: "范围变化"; case .rework: "返工"; case .correction: "记录更正"; case .other: "其他"; case nil: "未填原因" }
    }
    static func overlapGroups(workspace: Workspace) -> [[String]] {
        let unresolved = Set(workspace.effortSummary().unresolvedSessionIDs)
        let sessions = workspace.effectiveWorkSessions.filter { $0.hasExactInterval && unresolved.contains($0.id) }.sorted { $0.start < $1.start }
        var groups: [[String]] = []; var current: [String] = []; var end: Date?
        for session in sessions {
            if let boundary = end, session.start >= boundary { if !current.isEmpty { groups.append(current.sorted()) }; current = []; end = nil }
            current.append(session.id); end = max(end ?? session.end, session.end)
        }
        if !current.isEmpty { groups.append(current.sorted()) }
        return groups
    }
    static func historyLabel(_ kind: HistoryKind) -> String {
        switch kind {
        case .created: "创建"; case .dependencyAdded: "添加前置条件"; case .acceptanceAdded: "添加验收条件"; case .started: "开始工作"
        case .effortRecorded: "记录实际投入"; case .remainingUpdated: "修改耗时"; case .completed: "完成工作"; case .reworked: "开始返工"
        case .reviewed: "复核成果"; case .blockerTriggered: "开始或重新发起等待"; case .blockerResolved: "结束等待"
        case .accepted: "验收通过"; case .decisionRecorded: "确认下一步"; case .edited: "编辑资料"; case .deadlineChanged: "修改截止时间"
        case .scopeChanged: "范围变化"; case .dependencyChanged: "修改前置条件"; case .dependencyRemoved: "移除前置条件"; case .acceptanceChanged: "编辑验收"
        case .acceptanceRemoved: "移除验收要求"; case .acceptanceFailed: "验收未通过"; case .blockerUpdated: "修改预计结束或跟进时间"
        case .archived: "归档"; case .restored: "恢复显示"; case .cancelled: "取消工作"; case .deferred: "以后再做"
        case .estimateCorrected: "更正耗时记录"; case .effortCorrected: "更正投入记录"; case .choiceRecorded: "选择当前下一步"
        case .projectCompleted: "确认项目完成"; case .nodeCompleted: "确认节点完成"; case .baselineCaptured: "记录开工前估计"
        case .deleted: "删除工作"; case .timeBlockChanged: "调整日历时间块"
        }
    }
}

/// An immutable historical correction annotation. Original baselines are never overwritten;
/// this correction does not change current remaining or fabricate a missing start snapshot.
struct ProjectBaselineCorrection: Codable {
    let itemID: String
    let kind: String
    let originalMinutes: Int?
    let correctedMinutes: Int?
    let originalCapturedAt: Date?
}
struct BaselineCorrectionSummary: View {
    let itemID: String
    @Environment(AppModel.self) private var model
    var body: some View {
        ForEach(Array(model.workspace.baselineCorrections(itemID: itemID).enumerated()), id: \.offset) { _, correction in
            ProjectInfoLine(title: correction.baseline == .initial ? "首次估计的更正记录" : "开工前估计的更正记录",
                value: "原值 \(minutesLabel(correction.originalMinutes)) → 更正为 \(minutesLabel(correction.correctedMinutes))\n\(ProjectUI.dateLabel(correction.date))\n\(correction.reason)")
        }
        ForEach(model.workspace.history.filter { $0.objectID == itemID && $0.detail?.hasPrefix("baseline-correction:") == true }.sorted { $0.date > $1.date }, id: \.id) { event in
            if let correction = ProjectUI.baselineCorrection(event) {
                ProjectInfoLine(title: correction.kind == "initial" ? "首次估计的更正记录" : "开工前估计的更正记录",
                    value: "原值 \(minutesLabel(correction.originalMinutes)) → 更正为 \(minutesLabel(correction.correctedMinutes))\n\(ProjectUI.dateLabel(event.date))\n\(event.note)")
                    .accessibilityIdentifier("baseline.annotation.\(event.id)")
            }
        }
    }
}
struct BaselineCorrectionEditor: View {
    let item: WorkItem
    let kind: String
    @Environment(AppModel.self) private var model
    @State private var minutes: String
    @State private var note = ""
    init(item: WorkItem, kind: String) {
        self.item = item; self.kind = kind
        _minutes = State(initialValue: (kind == "initial" ? item.initialMinutes : item.preStartMinutes).map(String.init) ?? "")
    }
    private var validation: String? {
        if kind == "initial", item.initialMinutes == nil { return "首次估计未记录，无法更正。请到编辑工作填写当前剩余估计。" }
        if kind == "preStart", item.preStartCapturedAt == nil { return "开工前估计未记录，无法更正。可以继续更新当前剩余时间。" }
        return ProjectUI.minutesValidation(minutes, title: "正确原估计")
    }
    var body: some View {
        ProjectEditorContainer(title: "更正原始估计", identifier: "baseline.correction", validation: validation, save: save) {
            Section("原始估计") {
                ProjectInfoLine(title: kind == "initial" ? "首次估计原值" : "原开工前估计", value: minutesLabel(kind == "initial" ? item.initialMinutes : item.preStartMinutes))
                ProjectMinutesField(title: "正确的原估计分钟数（可留空）", text: $minutes, identifier: "baseline.correction.minutes")
                TextField("更正说明（可选）", text: $note, axis: .vertical).frame(minHeight: 44).accessibilityIdentifier("baseline.correction.note")
                Text("用于改正当时记错的数值，原值和记录时间保留。若只是现在有了新的判断，请更新当前剩余。")
            }
        }
    }
    private func save() async -> Bool {
        let corrected = ProjectUI.optionalMinutes(minutes), memo = note
        return await model.mutate { workspace in
            try workspace.correctEstimateBaseline(itemID: item.id, baseline: kind == "initial" ? .initial : .preStart,
                                                  minutes: corrected, now: Date(), note: memo)
        }
    }
}
extension ProjectUI {
    static func baselineCorrection(_ event: HistoryEvent) -> ProjectBaselineCorrection? {
        guard let detail = event.detail, detail.hasPrefix("baseline-correction:"), let data = String(detail.dropFirst("baseline-correction:".count)).data(using: .utf8) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(ProjectBaselineCorrection.self, from: data)
    }
}
