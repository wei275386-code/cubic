import SwiftUI
import CryptoKit
import CubicCore

struct RiskOverviewView: View {
    var projectID: String? = nil
    @Environment(AppModel.self) private var model
    private var subjectIDs: Set<String> {
        guard let projectID else { return [] }
        var ids = model.projectItemIDs(projectID).union([projectID])
        ids.formUnion(model.workspace.nodes.filter { $0.projectID == projectID }.map(\.id))
        let conditionIDs = Set(model.planning?.projects.first { $0.projectID == projectID }?.conditionIDs ?? [])
        ids.formUnion(model.planning?.conditions.filter { conditionIDs.contains($0.id) }.map(\.objectID) ?? [])
        let gateIDs = model.workspace.acceptances.filter { ids.contains($0.subject.id) }.map(\.id)
        ids.formUnion(gateIDs)
        return ids
    }
    private var risks: [Risk] {
        (projectID == nil ? model.visiblePlanningRisks : model.presentedRisks).filter { risk in
            let matches = projectID == nil || risk.projectID == projectID || (risk.projectID == nil && !subjectIDs.isDisjoint(with: risk.itemIDs))
            return matches && risk.kind != .insufficientInformation && (risk.kind != .conditionalUnlock || risk.message.contains("预警阈值"))
        }
    }
    var body: some View {
        List {
            if model.calculationIsStale || model.isRefreshing {
                Label("排期正在更新，请稍后查看", systemImage: "arrow.triangle.2.circlepath")
            }
            if let planning = model.planning {
                let scopedUnknowns = projectID == nil ? model.visiblePlanningUnknowns(planning.unknowns) : planning.unknowns.filter { subjectIDs.contains($0.objectID) || $0.objectID == "capacity" }
                let unknowns = PlanningDisplay.overviewUnknowns(scopedUnknowns)
                Section("需要补充或确认") {
                    ForEach(unknowns, id: \.objectID) { unknown in
                        PlanningUnknownRow(unknown: unknown).accessibilityIdentifier("planning.unknown." + unknown.objectID)
                    }
                    if unknowns.isEmpty { Text("暂时没有缺失信息").foregroundStyle(.secondary) }
                }
                let groups = PlanningDisplay.overviewRisks(risks.filter { risk in
                        // Missing information is already listed once above, not repeated as an unverified conflict.
                        let missing = model.missingPlanningInformation(itemIDs: risk.itemIDs, projectIDs: risk.projectID.map { [$0] } ?? [])
                        let visibleMissing = projectID == nil ? model.visiblePlanningUnknowns(missing) : missing
                        return visibleMissing.isEmpty || risk.kind != .sharedResourceConflict || risk.shortageMinutes != nil ||
                            (model.riskCertificateGroups[PlanningDisplay.riskKey(risk)] ?? []).contains { $0.proofs.contains { $0.elapsedDelaySeconds != nil } }
                    })
                Section("排期问题") {
                    ForEach(groups) { group in
                        RiskRow(risk: group.primary, additionalRisks: group.risks.filter { $0 != group.primary }, showsMissingInformation: false, usesVisibleScope: projectID == nil, displayID: group.id)
                            .accessibilityIdentifier("planning.problem." + group.id.joined(separator: "."))
                    }
                    if groups.isEmpty {
                        Text(unknowns.isEmpty ? "目前未发现明确的时间冲突" : "请先补齐信息，再核对排期").foregroundStyle(.secondary)
                    }
                }

            }
            if projectID != nil {
                NavigationLink("查看全部项目的排期问题") { RiskOverviewView() }
            }
        }.cubicNavigationTitle("排期与待确认事项").refreshable { await model.refresh(background: false) }
    }
}

struct PlanningUnknownRow: View {
    let unknown: PlanningUnknown
    var workspaceSnapshot: Workspace? = nil
    var allowsNavigation = true
    @Environment(AppModel.self) private var model
    @State private var showingSettings = false
    @State private var showingDetails = false
    @State private var sheet: ProjectUISheet?
    private var subject: WorkReference? {
        if model.workspace.items.contains(where: { $0.id == unknown.objectID }) { return .item(unknown.objectID) }
        if model.workspace.nodes.contains(where: { $0.id == unknown.objectID }) { return .node(unknown.objectID) }
        return model.workspace.acceptances.first { $0.id == unknown.objectID }?.subject
    }
    private var needsSchedule: Bool { unknown.objectID == "capacity" || unknown.message.contains("容量窗口未覆盖") }
    private var label: some View {
        VStack(alignment: .leading, spacing: 5) {
            ProjectListTitle(text: subjectName)
            Text(PlanningCopy.unknown(unknown, in: workspaceSnapshot ?? model.workspace)).font(.subheadline).foregroundStyle(.secondary)
        }
    }
    private var subjectName: String {
        if unknown.objectID == "capacity" { return "工作时间与日历占用" }
        guard let workspaceSnapshot else { return model.businessIssue(unknown.objectID) }
        return workspaceSnapshot.items.first { $0.id == unknown.objectID }?.name
            ?? workspaceSnapshot.projects.first { $0.id == unknown.objectID }?.name
            ?? workspaceSnapshot.nodes.first { $0.id == unknown.objectID }?.name
            ?? workspaceSnapshot.blockers.first { $0.id == unknown.objectID }?.name
            ?? workspaceSnapshot.acceptances.first { $0.id == unknown.objectID }?.name ?? "当时的待确认信息"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            label
            if allowsNavigation {
                if needsSchedule {
                    Button("检查工作时间与日历设置") { showingSettings = true }
                        .accessibilityIdentifier("planning.unknown.settings")
                    Button("查看并刷新日历空档") { showingDetails = true }
                        .accessibilityIdentifier("planning.unknown.calendar")
                } else {
                    if let item = model.item(unknown.objectID), item.remainingMinutes == nil {
                        Button("补充剩余时间估计") { sheet = .editItem(item) }
                            .accessibilityIdentifier("planning.unknown.remaining.\(item.id)")
                    } else if let node = model.workspace.nodes.first(where: { $0.id == unknown.objectID }) {
                        Button("补充节点信息") { sheet = .editNode(node) }
                    } else if let project = model.workspace.projects.first(where: { $0.id == unknown.objectID }) {
                        Button(project.deadline == nil ? "设置项目截止" : "编辑项目") { sheet = .project(project) }
                    } else if let blocker = model.workspace.blockers.first(where: { $0.id == unknown.objectID }) {
                        Button("补充等待的预计时间") { sheet = .blocker(blocker) }
                    }
                    if subject != nil || model.workspace.projects.contains(where: { $0.id == unknown.objectID }) || model.workspace.blockers.contains(where: { $0.id == unknown.objectID }) {
                        Button("查看相关事项并处理") { showingDetails = true }
                    }
                }
            }
        }.buttonStyle(.borderless).padding(.vertical, 4)
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .sheet(item: $sheet) { ProjectUISheetContent(sheet: $0) }
            .sheet(isPresented: $showingDetails) {
                NavigationStack {
                    Group {
                        if needsSchedule { CalendarView() }
                        else if let subject {
                            switch subject {
                            case .item(let id): WorkDetailView(itemID: id)
                            case .node(let id): CubicNodeDetailView(nodeID: id)
                            }
                        } else if model.workspace.projects.contains(where: { $0.id == unknown.objectID }) { CubicProjectDetailView(projectID: unknown.objectID) }
                        else { BlockerDetailView(blockerID: unknown.objectID) }
                    }.toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showingDetails = false } } }
                }
            }
    }
}

struct PlanningTimeSourceLinks: View {
    @State private var showingSettings = false
    @State private var showingCalendar = false
    var body: some View {
        DisclosureGroup("可用时间是怎么算的？") {
            Text("从已保存的工作时段中扣掉计入占用的日历事件。还会检查工作需要的专注程度、连续空档和前置完成时间。")
                .font(.caption).foregroundStyle(.secondary)
            Button("检查工作时间与日历设置") { showingSettings = true }
                .buttonStyle(.borderless).frame(minHeight: 44, alignment: .leading)
            Button("查看日历空档") { showingCalendar = true }
                .buttonStyle(.borderless).frame(minHeight: 44, alignment: .leading)
        }.sheet(isPresented: $showingSettings) { SettingsView() }
            .sheet(isPresented: $showingCalendar) {
                NavigationStack { CalendarView().toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showingCalendar = false } } } }
            }
    }
}

struct ChoiceContext: Codable, Sendable {
    var date: Date
    var displayedItems: [WorkItem]
    var projects: [Project]
    var dataVersion: String
}

struct ChoiceDetailView: View {
    let choice: NextActionChoice
    @Environment(AppModel.self) private var model
    private var evidenceFingerprint: String {
        let detail = model.workspace.history.last(where: { $0.objectID == choice.id && $0.detail?.hasPrefix("{") == true })?.detail ?? ""
        return SHA256.hash(data: Data(detail.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private var originalPlanning: PlanningTrialResult? {
        guard let detail = model.workspace.history.last(where: { $0.objectID == choice.id && $0.detail?.hasPrefix("{") == true })?.detail,
              let data = detail.data(using: .utf8) else { return nil }
        return try? JSONCoding.decode(PlanningTrialResult.self, from: data)
    }
    private var originalContext: ChoiceContext? {
        guard let detail = model.workspace.history.last(where: { $0.objectID == choice.id && $0.detail?.hasPrefix("{") == true })?.detail,
              let data = detail.data(using: .utf8) else { return nil }
        return try? JSONCoding.decode(ChoiceContext.self, from: data)
    }
    var body: some View {
        let capturedTrial = originalPlanning
        let legacyContext = capturedTrial == nil ? originalContext : nil
        let display = capturedTrial.map(PlanningCertificateContext.init)
        let legacyNames = Dictionary((legacyContext?.displayedItems ?? []).map { ($0.id, $0.name) } +
            (legacyContext?.projects ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        func originalName(_ id: String) -> String {
            if let display { return display.names[id] ?? "历史工作" }
            if legacyContext != nil { return legacyNames[id] ?? "历史工作" }
            return model.item(id)?.name ?? "历史工作"
        }
        return List {
            Section("当时选择") {
                Text(choice.itemID.map { originalName($0) } ?? "取消当前选择")
                Text(choice.date.formatted(date: .abbreviated, time: .shortened))
                Text(capturedTrial?.request.minutes == nil && capturedTrial != nil ? "未填写时长，只查看了可能影响的工作" : choice.impactWasVerified ? "选择前已试算影响" : "直接选择，未试算影响")
                if !choice.note.isEmpty { Text(choice.note) }
                Text("这里保留选择时看到的内容，后续进度不会改写这次记录。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let trial = capturedTrial {
                Section("当时的试算条件") {
                    Text(trial.source.input.now.formatted(date: .abbreviated, time: .shortened))
                        .accessibilityIdentifier("choice.evidence.\(evidenceFingerprint)")
                    Text(trial.request.minutes.map { "试算 \(minutesLabel($0))" } ?? "未填写时长，只查看可能影响")
                    ForEach(trial.conditions, id: \.id) { Text(PlanningCopy.condition($0)) }
                }
                Section("当时看到的变化") {
                    ForEach(display?.impactGroups ?? []) { group in
                        PlanningImpactRow(group: group, context: display, allowsNavigation: false)
                    }
                }
            } else if let trial = choice.trial {
                Section("当时试算") {
                    ForEach(trial.selections, id: \.itemID) { selection in Text(minutesLabel(selection.minutes)) }
                    ForEach(Array(PlanningDisplay.risks(trial.snapshot.risks).enumerated()), id: \.offset) { _, risk in Text(PlanningCopy.summary(risk)) }
                }
            }
            Section("当时可选择的工作") {
                ForEach(choice.displayedItemIDs, id: \.self) { id in Text(originalName(id)) }
            }
        }.cubicNavigationTitle("选择记录").cubicInlineNavigationTitle()
    }
}

typealias PlanningCertificateContext = PlanningDisplay.TrialContext

/// Shared by action, calendar and trial explanations.
struct PlanningCertificateRow: View {
    let group: PlanningDisplay.CertificateGroup
    var context: PlanningCertificateContext? = nil
    @Environment(AppModel.self) private var model
    private var proof: PlanningCertificate { group.summary }
    private func name(_ id: String) -> String {
        if let context { return context.names[id] ?? "原记录内容" }
        return model.businessIssue(id)
    }
    private var constraints: [String] {
        Set(group.proofs.map { certificate in
            switch certificate.kind {
            case .capacityShortfall: "可用时间"
            case .energyShortfall: certificate.energy == .high ? "高专注时段" : "普通及高专注时段"
            case .continuousShortfall: "连续空档（\(energyName(certificate.energy))）"
            case .dependencyWindow: certificate.elapsedDelaySeconds == nil ? "前置完成后的空档（\(energyName(certificate.energy))）" : "最早能交付的时间与截止"
            }
        }).sorted()
    }
    private func energyName(_ energy: Energy) -> String {
        switch energy { case .low: "所有工作时段"; case .normal: "普通及高专注"; case .high: "高专注" }
    }
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if proof.elapsedDelaySeconds == nil {
                    Text("这些工作至少需要 \(minutesLabel(proof.demandMinutes))")
                    Text("符合工作要求的可用空档：\(minutesLabel(proof.capacityMinutes))")
                }
                Text(proof.elapsedDelaySeconds == nil ? "这些工作所需的时间超过了对应空档。请检查工作范围和可用时段。" : "预计最早能交付的时间已晚于截止。请检查下面的日期与等待条件。").font(.caption).foregroundStyle(.secondary)
                let scopes = Set(group.proofs.map { certificate in
                    let names = certificate.projectIDs.map(name).joined(separator: "、")
                    return certificate.projectIDs.count > 1 ? "共用时间的项目：" + names : names.isEmpty ? "独立工作" : "项目：" + names
                }).sorted()
                ForEach(scopes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                if let ready = proof.requiredReadyAt { Text("预计最早能交付：\(PlanningDateLabel.instant(ready, zone: model.preferences.workTimeZone))").font(.caption) }
                if let latest = proof.latestAllowedAt { Text("需要在此前完成：\(PlanningDateLabel.instant(latest, zone: model.preferences.workTimeZone))").font(.caption) }
                ForEach(Set(proof.conditionIDs).sorted(), id: \.self) { id in
                    if let condition = (context?.conditions ?? model.planningConditionsByID)[id] {
                        Text("\(name(condition.objectID))：\(PlanningCopy.condition(condition))").font(.caption)
                    } else {
                        Label("这次记录缺少一项计算条件", systemImage: "questionmark.circle").font(.caption)
                    }
                }
                if !proof.itemIDs.isEmpty {
                    Text("涉及工作：" + proof.itemIDs.map(name).joined(separator: "、"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if context == nil { PlanningTimeSourceLinks() }
            }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 4)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Label(proof.elapsedDelaySeconds.map { "预计最早能交付的时间比截止晚至少 \(minutesLabel(Int(ceil($0 / 60))))" } ?? "合适空档至少还差 \(minutesLabel(proof.shortageMinutes))", systemImage: "exclamationmark.triangle")
                    .font(.subheadline.weight(.medium)).foregroundStyle(Color.cubicAmber)
                Text(constraints.joined(separator: " · ")).font(.caption)
                Text(PlanningDateLabel.window(start: proof.windowStart, end: proof.windowEnd, zone: model.preferences.workTimeZone))
                    .font(.caption).foregroundStyle(.secondary)
                Text(proof.itemIDs.prefix(2).map(name).joined(separator: "、") + (proof.itemIDs.count > 2 ? " 等\(proof.itemIDs.count)项" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 4)
        }
    }
}

enum PlanningDateLabel {
    static func instant(_ date: Date, zone: TimeZone) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: zone))
    }
    static func window(start: Date, end: Date, zone: TimeZone) -> String {
        if start == end { return "截止 " + instant(end, zone: zone) + " · 已无可用时间" }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        if calendar.isDate(start, inSameDayAs: end) {
            return instant(start, zone: zone) + " – " + end.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone))
        }
        return instant(start, zone: zone) + " – " + instant(end, zone: zone)
    }
}
