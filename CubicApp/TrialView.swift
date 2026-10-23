import SwiftUI
import CubicCore

struct TrialView: View {
    let itemID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var presentationID = UUID()
    @State private var isVisible = false
    @State private var minutes = ""
    @State private var note = ""
    @State private var result: PlanningTrialResult?
    @State private var conflictContext: PlanningCertificateContext?
    @State private var computing = false
    @State private var validation: String?
    @State private var generation = 0
    @State private var confirming = false
    @State private var refreshedForConfirmation = false
    @State private var useCustomStart = false
    @State private var counterfactual = false
    @State private var start = Date()
    private var calculationKey: String { "\(minutes):\(model.sourceVersion):\(useCustomStart):\(start.timeIntervalSince1970):\(counterfactual)" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let item = model.item(itemID) {
                        Text(item.name).font(.title3.weight(.semibold))
                        Text("剩余估计：\(minutesLabel(item.remainingMinutes))").foregroundStyle(.secondary)
                    }
                    Text("先试算：做一段时间后，这项工作和其他项目会怎样变化。结果按当前估计计算。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("准备投入多久") {
                    if model.isBlocked(itemID) {
                        Toggle("假设前置已完成，再试算", isOn: $counterfactual)
                            .accessibilityIdentifier("trial.counterfactual")
                        Text("这项工作目前还不能开始。开启后只是假设前置已完成，不会修改实际状态。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack { presetButtons }
                        VStack(alignment: .leading) { presetButtons }
                    }
                    TextField("投入分钟数（可留空）", text: $minutes).cubicNumberKeyboard()
                        .accessibilityIdentifier("trial-minutes")
                    Toggle("指定开始时间", isOn: $useCustomStart)
                    if useCustomStart { DatePicker("开始时间", selection: $start).accessibilityIdentifier("trial.start") }
                    Text("默认使用现在或下一个合适空档。留空时长只看影响；超出剩余估计的时间不分配。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let validation { Text(validation).foregroundStyle(.red) }
                }
                .disabled(confirming)
                if computing || model.isRefreshing {
                    Section { ProgressView("正在计算影响…") }
                }
                if let result, !computing {
                    Section("本次试算") {
                        Text("计算于 \(result.source.input.now.formatted(date: .abbreviated, time: .shortened))")
                        if let start = result.startPosition { Text("预计开始：\(start.formatted(date: .abbreviated, time: .shortened))") }
                        if result.request.minutes == nil { Text("未填写时长，目前只显示哪些工作可能受影响。") }
                        if let remaining = result.assumedRemainingMinutes { Text("投入后预计剩余：\(minutesLabel(remaining))") }
                        if let completion = result.estimatedCompletion { Text("预计完成：\(completion.formatted(date: .abbreviated, time: .shortened))") }
                        if let excess = result.excessMinutes, excess > 0 { Text("有 \(minutesLabel(excess)) 超出剩余估计，未分配") }
                        if let unavailable = result.unallocatedMinutes, unavailable > (result.excessMinutes ?? 0) {
                            Label("有 \(minutesLabel(unavailable - (result.excessMinutes ?? 0))) 暂时排不进可用空档", systemImage: "exclamationmark.triangle")
                        }
                        ForEach(result.conditions, id: \.id) { Text(PlanningCopy.condition($0)).font(.caption).foregroundStyle(.secondary) }
                    }
                    Section("会带来什么变化") {
                        if result.impacts.isEmpty { Text("信息还不够，暂时无法判断项目间的变化。") }
                        ForEach(conflictContext?.impactGroups ?? []) { group in
                            PlanningImpactRow(group: group, context: conflictContext)
                        }
                    }
                    if let scenario = result.scenario {
                        Section("各项目的预计情况") {
                            ForEach(scenario.projects, id: \.projectID) { assessment in
                                PlanningAssessmentRow(assessment: assessment, context: conflictContext)
                            }
                        }
                    }
                    if !result.unresolvedConflicts.isEmpty {
                        Section("还需要调整的安排") {
                            ForEach(conflictContext?.conflictGroups ?? []) { group in
                                PlanningCertificateRow(group: group, context: conflictContext)
                            }
                        }
                    }
                    Section {
                        TextField("选择理由（可选）", text: $note, axis: .vertical).lineLimit(2...4)
                        if refreshedForConfirmation { Text("结果已更新，请查看后再确认。") }
                        Button("接下来做这个") { Task { await confirm(result) } }
                            .buttonStyle(.borderedProminent).foregroundStyle(Color.cubicOnAccent).frame(minHeight: 44)
                            .disabled(model.saving || confirming || model.isRefreshing)
                            .accessibilityIdentifier("confirm-next-action")
                    } footer: { Text("确认后设为下一步。开始工作时再计时，结束后记录投入和剩余时间。") }
                } else if !computing, validation == nil, result == nil {
                    Section {
                        Text("这次试算未能完成。可调整投入时长重试，或直接设为下一步。")
                        Button("直接设为下一步") { Task { if await model.chooseNextAction(itemID: itemID, note: note + " · 最新影响未核验") { dismiss() } } }
                    }
                }
            }
            .cubicNavigationTitle("投入时间试算").cubicInlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(confirming) } }
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
            .task(id: calculationKey) { await calculate() }
        }.modifier(ModalMessages()).interactiveDismissDisabled(confirming)
    }
    private var presetButtons: some View {
        Group {
            Button("30 分钟") { minutes = "30" }.buttonStyle(.bordered)
            Button("1 小时") { minutes = "60" }.buttonStyle(.bordered)
            Button("用完当前空档") {
                let date = Date()
                if let slot = model.visibleCapacitySlots.first(where: { $0.end > date }) {
                    minutes = String(max(1, Int(slot.end.timeIntervalSince(max(date, slot.start)) / 60)))
                }
            }.buttonStyle(.bordered).disabled(model.visibleCapacitySlots.isEmpty)
        }
    }
    private func calculate() async {
        generation += 1
        let current = generation
        let text = minutes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty || (text.allSatisfy({ $0.isASCII && $0.isNumber }) && Int(text).map { (1...5256000).contains($0) } == true) else {
            validation = "请输入大于 0 的整数分钟；也可以留空。"; result = nil; computing = false; return
        }
        validation = nil; computing = true; refreshedForConfirmation = false
        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
        guard !Task.isCancelled else { return }
        let calculation = await model.planningTrial(itemID: itemID, minutes: Int(text), start: useCustomStart ? start : nil, counterfactual: counterfactual, reportErrors: false)
        guard current == generation, !Task.isCancelled else { return }
        let display = await Task.detached(priority: .userInitiated) {
            calculation.map(PlanningCertificateContext.init)
        }.value
        guard current == generation, !Task.isCancelled else { return }
        conflictContext = display
        result = calculation; computing = false
    }
    private func confirm(_ displayed: PlanningTrialResult) async {
        guard !confirming else { return }
        confirming = true
        defer { confirming = false }
        let key = calculationKey
        let request = PlanningTrialRequest(itemID: itemID,
            minutes: Int(minutes.trimmingCharacters(in: .whitespacesAndNewlines)),
            start: useCustomStart ? start : nil, counterfactual: counterfactual)
        let outcome = await model.confirmDisplayedTrial(presentationID: presentationID, displayed: displayed,
            request: request, note: note, isCurrent: { isVisible && key == calculationKey })
        switch outcome {
        case .confirmed:
            if isVisible { dismiss() }
        case .redisplay(let latest):
            let display = await Task.detached(priority: .userInitiated) { PlanningCertificateContext(latest) }.value
            guard isVisible, key == calculationKey, !Task.isCancelled else { return }
            conflictContext = display; result = latest; refreshedForConfirmation = true
        case .unavailable:
            break
        }
    }
}

struct PlanningAssessmentRow: View {
    let assessment: PlanningProjectAssessment
    var context: PlanningCertificateContext? = nil
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(context.map { $0.names[assessment.projectID] ?? "原记录项目" } ?? model.businessIssue(assessment.projectID)).font(.headline)
            if let total = assessment.totalDemandMinutes {
                Text("预计还需 \(minutesLabel(total))")
            } else if assessment.knownDemandMinutes > 0 {
                Text("已估计的部分至少需 \(minutesLabel(assessment.knownDemandMinutes))，总工作量还没确认")
            } else {
                Text("剩余工作量还没确认")
            }
            Text("截止前可用 \(minutesLabel(assessment.knownCapacityMinutes))")
            Text("按当前已添加的工作推算，结构修改后重新计算。")
                .font(.caption).foregroundStyle(.secondary)
            if let warning = assessment.warningMarginMinutes { Text("时间余量低于 \(minutesLabel(warning)) 时提醒") }
            Text(assessment.feasibility == .infeasible ? "按当前条件赶不上截止" : assessment.feasibility == .feasible ? "按当前估计和假设，可以排下" : "信息或安排尚未确认")
                .font(.subheadline.weight(.medium))
        }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 5)
    }
}

struct PlanningImpactRow: View {
    let group: PlanningDisplay.ImpactGroup
    var context: PlanningCertificateContext? = nil
    var allowsNavigation = true
    @Environment(AppModel.self) private var model
    private var impact: PlanningImpact { group.summary }
    private var missingInformation: [PlanningUnknown] {
        guard impact.kind == .unresolvedCompetition, impact.afterMinutes == nil, let context else { return [] }
        let projects = Set(impact.projectIDs)
        let nodes = context.source.nodes.filter { $0.required && projects.contains($0.projectID) }.map(\.id)
        let objects = Set(impact.itemIDs + impact.projectIDs + nodes)
        let conditions = Set(group.impacts.flatMap(\.conditionIDs)).compactMap { context.conditions[$0] }
        return PlanningDisplay.relatedUnknowns(context.unknowns, objectIDs: objects, conditions: conditions)
    }
    private var energyLabels: [String] {
        Set(group.impacts.compactMap(\.energy).map { energy in
            switch energy { case .low: "所有工作时段"; case .normal: "普通及高专注时段"; case .high: "高专注时段" }
        }).sorted()
    }
    private func name(_ id: String) -> String {
        if let context { return context.names[id] ?? "原记录对象" }
        return model.businessIssue(id)
    }
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(missingInformation.enumerated()), id: \.offset) { _, unknown in
                    PlanningUnknownRow(unknown: unknown, workspaceSnapshot: context.map { PlanningCopy.capturedWorkspace($0.source) }, allowsNavigation: allowsNavigation)
                }
                if allowsNavigation && impact.kind == .unresolvedCompetition { PlanningTimeSourceLinks() }
                if let before = impact.beforeMinutes, let after = impact.afterMinutes {
                    Text("试算前：\(minutesLabel(before)) → 试算后：\(minutesLabel(after))")
                }
                if let before = impact.beforeDate { Text("试算前日期：\(PlanningDateLabel.instant(before, zone: model.preferences.workTimeZone))") }
                if let after = impact.afterDate { Text("试算后日期：\(PlanningDateLabel.instant(after, zone: model.preferences.workTimeZone))") }
                if let start = impact.windowStart, let end = impact.windowEnd {
                    Text(PlanningDateLabel.window(start: start, end: end, zone: model.preferences.workTimeZone))
                        .font(.caption).foregroundStyle(.secondary)
                }
                let paths = Set(group.impacts.map { original in
                    original.chain.map { reference in context.map { PlanningCopy.referenceName(reference, names: $0.names) } ?? model.planningReferenceName(reference) }.joined(separator: " → ")
                }).sorted()
                ForEach(paths, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                ForEach(Set(impact.conditionIDs).sorted(), id: \.self) { id in
                    if let condition = (context?.conditions ?? model.planningConditionsByID)[id] {
                        Text("\(name(condition.objectID))：\(PlanningCopy.condition(condition))").font(.caption)
                    } else {
                        Label("这次记录缺少一项计算条件，请重新试算。", systemImage: "questionmark.circle").font(.caption)
                    }
                }
            }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 4)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Label(missingInformation.isEmpty ? PlanningCopy.impact(impact) : "还有信息需要补充，暂时算不出完整安排", systemImage: [.sharedProgress, .dependencyRelease, .boundaryImprovement].contains(impact.kind) ? "arrow.up.forward.circle" : impact.afterMinutes == nil && impact.kind == .unresolvedCompetition ? "questionmark.circle" : "exclamationmark.circle")
                Text(impact.projectIDs.map(name).joined(separator: "、"))
                    .font(.caption).foregroundStyle(.secondary)
                if !energyLabels.isEmpty { Text(energyLabels.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
            }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 4)
        }
    }
}
