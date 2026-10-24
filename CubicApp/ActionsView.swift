import SwiftUI
import CubicCore

struct ActionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var trialID: String?
    private var actionItems: [WorkItem] {
        PlanningDisplay.actionItems(workspace: model.workspace) { model.relatedProjectIDs(for: $0) }
    }
    private var available: [WorkItem] {
        let ids = Set(model.snapshot?.availableActions.map(\.itemID) ?? [])
        return actionItems.filter { ids.contains($0.id) }.sorted {
            let firstDeadline = deadline($0), secondDeadline = deadline($1)
            return firstDeadline == secondDeadline ? $0.name < $1.name : firstDeadline < secondDeadline
        }
    }
    private func deadline(_ item: WorkItem) -> Date {
        min(item.deadline ?? .distantFuture, model.workspace.projects.filter { model.relatedProjectIDs(for: item).contains($0.id) }.compactMap(\.deadline).min() ?? .distantFuture)
    }
    var body: some View {
        List {
            if let choice = model.workspace.currentNextAction, let id = choice.itemID, let item = model.item(id) {
                Section("当前下一步") {
                    NavigationLink { WorkDetailView(itemID: item.id) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Label(item.name, systemImage: "arrow.right.circle.fill")
                            Text("选择于 \(choice.date.formatted(date: .abbreviated, time: .shortened)) · 尚未开始计时")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink("查看这次选择的记录") { ChoiceDetailView(choice: choice) }
                        .accessibilityIdentifier("actions.choice.record.\(choice.id).count.\(model.workspace.choices?.count ?? 0)")
                    Button("取消当前选择") { Task { _ = await model.chooseNextAction(itemID: nil) } }
                        .accessibilityIdentifier("actions.clearChoice")
                }
            }
            Section {
                if available.isEmpty {
                    EmptyMessage(symbol: "checkmark.circle", title: "暂时没有可开始的工作", detail: "可以到收件箱添加工作，或检查哪些工作还在等待。")
                }
                ForEach(available.filter { !$0.needsReview }, id: \.id) { item in
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                        : AnyLayout(HStackLayout(spacing: 12))
                    layout {
                        NavigationLink { WorkDetailView(itemID: item.id) } label: { ActionRow(item: item) }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("试算") { trialID = item.id }
                            .buttonStyle(.bordered).frame(minHeight: 44)
                            .accessibilityLabel("试算 \(item.name)")
                            .accessibilityIdentifier("action.trial.\(item.id)")
                    }
                }
            } header: { Text("现在可开始") } footer: {
                Text("按截止时间排序。选一项查看，或先试算投入时间后的影响。")
            }
            let availableIDs = Set(available.map(\.id))
            let focused = actionItems.filter { $0.isFocused == true && !$0.needsReview && !availableIDs.contains($0.id) }
            if !focused.isEmpty {
                Section("我关注的工作") {
                    ForEach(focused, id: \.id) { item in
                        NavigationLink { WorkDetailView(itemID: item.id) } label: { ActionRow(item: item) }
                    }
                }
            }
            if !model.workspace.items.filter(\.needsReview).isEmpty {
                Section("前置有变化，需要复核") {
                    ForEach(model.workspace.items.filter(\.needsReview), id: \.id) { item in
                        NavigationLink { WorkDetailView(itemID: item.id) } label: { ActionRow(item: item) }
                    }
                }
            }
            let waiting = model.workspace.blockers.filter { $0.state == .active }
            if !waiting.isEmpty {
                Section("等待跟进") {
                    ForEach(waiting, id: \.id) { blocker in
                        VStack(alignment: .leading, spacing: 6) {
                            Label(blocker.name, systemImage: "hourglass")
                            if let date = blocker.followUpAt {
                                Text("跟进 \(date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else { Text("跟进日期尚未设置").font(.caption).foregroundStyle(.secondary) }
                            Button("确认等待已结束") { Task { _ = await model.mutate { try $0.resolveBlocker(id: blocker.id, now: Date()) } } }
                                .buttonStyle(.bordered).disabled(model.saving)
                        }.padding(.vertical, 5)
                    }
                }
            }
            let visibleRisks = model.visiblePlanningRisks
            if !visibleRisks.isEmpty {
                Section("排期提醒") {
                    ForEach(Array(visibleRisks.prefix(8).enumerated()), id: \.offset) { _, risk in RiskRow(risk: risk) }
                    NavigationLink("查看排期与待确认事项") { RiskOverviewView() }
                }
            }
            Section("回顾与跟进") {
                Label(model.syncState.label, systemImage: model.syncState.phase == .synced ? "icloud" : "icloud.slash")
                    .font(.caption).foregroundStyle(.secondary)
                NavigationLink { ReviewView() } label: { Label("查看待处理事项", systemImage: "checklist") }
                    .accessibilityIdentifier("actions.review")
                NavigationLink { NoticeListView() } label: { Label("待处理提醒（\(model.notices.filter { !$0.isResolved }.count)）", systemImage: "bell.badge") }
                    .accessibilityIdentifier("actions.notices")
                if model.calculationIsStale || model.isRefreshing {
                    Label("排期正在更新…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let date = model.calculationUpdatedAt {
                    Text("更新于 \(date.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .cubicNavigationTitle("行动")
        .sheet(isPresented: Binding(get: { trialID != nil }, set: { if !$0 { trialID = nil } })) {
            if let trialID { TrialView(itemID: trialID) }
        }
        .refreshable { await model.refresh(background: false) }
    }
}
struct ActionRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let item: WorkItem
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top) {
                Image(systemName: item.status == .completed ? "checkmark.circle.fill" : item.needsReview ? "arrow.triangle.2.circlepath" : model.isBlocked(item.id) ? "lock.circle" : "circle")
                    .foregroundStyle(item.needsReview ? Color.cubicAmber : Color.cubicAccent)
                ProjectListTitle(text: item.name).layoutPriority(1)
            }
            let linkedIDs = model.relatedProjectIDs(for: item)
            ForEach(model.workspace.projects.filter { linkedIDs.contains($0.id) }, id: \.id) { project in
                VStack(alignment: .leading, spacing: 3) {
                    Text("项目：\(project.name)")
                    Text("重要性：\(ProjectUI.importance(project.importance))")
                    if let date = project.deadline {
                        Text("截止：\(ProjectUI.datePart(date, zone: project.deadlineTimeZoneID)) \(project.deadlineIsDateOnly == true ? "日末" : ProjectUI.timePart(date, zone: project.deadlineTimeZoneID))")
                    } else { Text("尚未设置截止") }
                }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let node = model.workspace.nodes.first(where: { $0.id == item.nodeID }) {
                Text("节点：\(node.name)").font(.caption).foregroundStyle(.secondary)
            }
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) { metadata }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack { metadata }
                    VStack(alignment: .leading, spacing: 4) { metadata }
                }
            }
        }.padding(.vertical, 6)
    }
    @ViewBuilder private var metadata: some View {
        Text(minutesLabel(item.remainingMinutes)).font(.caption.weight(.medium))
        Text(item.energy == .high ? "高专注" : item.energy == .low ? "低负荷" : "普通").font(.caption).foregroundStyle(.secondary)
        if item.isFocused == true { Text("关注").font(.caption).foregroundStyle(Color.cubicAccent) }
        if item.requiresContinuous { Text("需连续").font(.caption).foregroundStyle(.secondary) }
        if model.isBlocked(item.id) { Text("等待前置完成").font(.caption).foregroundStyle(.secondary) }
        if item.needsReview { Text("已有成果待复核").font(.caption).foregroundStyle(.secondary) }
        if let deadline = item.deadline { Text("截止 \(deadline.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
        if let tags = item.contextTags, !tags.isEmpty { Text(tags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
    }
}
struct RiskRow: View {
    @Environment(AppModel.self) private var model
    let risk: Risk
    var itemLinkIdentifierPrefix: String? = nil
    var additionalRisks: [Risk] = []
    var showsMissingInformation = true
    var usesVisibleScope = true
    var displayID: [String]? = nil
    private var isOverdue: Bool {
        if !proofs.isEmpty && proofs.allSatisfy({ $0.windowEnd < Date() }) {
            return [.provenCapacityShortfall, .sharedResourceConflict, .energyConstraint, .continuousConstraint].contains(risk.kind)
        }
        guard risk.kind == .provenCapacityShortfall, risk.shortageMinutes == nil,
              let project = model.workspace.projects.first(where: { $0.id == risk.projectID }) else { return false }
        return project.hasDeliveryCommitment && project.deadline.map { $0 < Date() } == true
    }
    private var hasDateConflict: Bool {
        proofs.contains { $0.elapsedDelaySeconds != nil }
    }
    private var proofGroups: [PlanningDisplay.CertificateGroup] {
        let proofs = ([risk] + additionalRisks).flatMap {
            (model.riskCertificateGroups[PlanningDisplay.riskKey($0)] ?? []).flatMap(\.proofs)
        }.reduce(into: [PlanningCertificate]()) { if !$0.contains($1) { $0.append($1) } }
        return PlanningDisplay.certificates(usesVisibleScope ? model.visiblePlanningCertificates(proofs) : proofs)
    }
    private var proofs: [PlanningCertificate] { proofGroups.flatMap(\.proofs) }
    private var missingInformation: [PlanningUnknown] {
        let unknowns = model.missingPlanningInformation(itemIDs: risk.itemIDs,
            projectIDs: (risk.projectID.map { [$0] } ?? []) + proofs.flatMap(\.projectIDs), conditionIDs: proofs.flatMap(\.conditionIDs))
        return usesVisibleScope ? model.visiblePlanningUnknowns(unknowns) : unknowns
    }
    private var sharedState: PlanningDisplay.SharedScheduleState {
        PlanningDisplay.sharedScheduleState(risk, proofs: proofs, unknowns: missingInformation)
    }
    private var isUnverified: Bool {
        risk.kind == .sharedResourceConflict && (sharedState == .unverified || sharedState == .missingInformation)
    }
    private var isCapacityOnly: Bool {
        risk.kind == .insufficientInformation && !missingInformation.isEmpty && missingInformation.allSatisfy { $0.objectID == "capacity" }
    }
    private var title: String {
        if isCapacityOnly { return "工作时间与日历占用待确认" }
        if isOverdue { return "截止已过，仍未交付" }
        if hasDateConflict { return "交付时间赶不上截止" }
        if risk.kind == .sharedResourceConflict {
            switch sharedState {
            case .shortfall(let minutes): return "截止前至少还差 \(minutesLabel(minutes))"
            case .missingInformation: return "还有信息需要补充，暂时排不出完整安排"
            case .unverified: return "暂时没排出完整安排"
            case .dateConflict: return "交付时间赶不上截止"
            }
        }
        return PlanningCopy.title(risk)
    }
    private var summary: String {
        if isCapacityOnly, let unknown = missingInformation.first { return PlanningCopy.unknown(unknown, in: model.workspace) }
        if isOverdue { return "当前记录显示截止已过，相关工作仍未交付。请核对实际进度、补齐遗漏记录，并确认真实截止是否已调整。" }
        if hasDateConflict { return "预计最早能交付的时间已晚于截止。请检查等待、验收日期和项目截止。" }
        if isUnverified {
            return missingInformation.isEmpty ? "目前还不能判断能否全部按时完成。请展开核对这些工作的前置、连续时间要求和日历空档。" : "请展开查看下面各项信息，并点击对应事项补充。"
        }
        return PlanningCopy.summary(risk)
    }
    var body: some View {
        DisclosureGroup {
            if showsMissingInformation {
                ForEach(PlanningDisplay.overviewUnknowns(missingInformation), id: \.objectID) { unknown in PlanningUnknownRow(unknown: unknown) }
            }
            ForEach(risk.itemIDs.compactMap { model.item($0) }, id: \.id) { item in
                NavigationLink { WorkDetailView(itemID: item.id) } label: { ActionRow(item: item) }
                    .accessibilityIdentifier((itemLinkIdentifierPrefix ?? "risk.item") + "." + item.id)
            }
            if model.planning != nil {
                let groups = proofGroups
                if !groups.isEmpty {
                    DisclosureGroup("查看日期与时间依据（\(groups.count) 组）") {
                        ForEach(groups) { group in PlanningCertificateRow(group: group) }
                    }
                }
            }
            PlanningTimeSourceLinks()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(isUnverified ? Color.secondary : risk.kind == .conditionalUnlock ? Color.cubicAccent : Color.cubicAmber)
            if let projectID = risk.projectID, let project = model.workspace.projects.first(where: { $0.id == projectID }) {
                Text(project.name).font(.subheadline.weight(.semibold))
            } else if !risk.itemIDs.isEmpty {
                Text(risk.itemIDs.prefix(3).compactMap { model.item($0)?.name }.joined(separator: "、"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let proof = proofs.filter({ $0.elapsedDelaySeconds == nil && $0.shortageMinutes > 0 }).max(by: { $0.shortageMinutes < $1.shortageMinutes }) {
                Text(isOverdue ? "当前记录仍有至少 \(minutesLabel(proof.demandMinutes)) 的工作要完成。" : "这些工作至少需要 \(minutesLabel(proof.demandMinutes))；这段时间符合工作要求的空档只有 \(minutesLabel(proof.capacityMinutes))。")
                    .font(.subheadline)
                Text(PlanningDateLabel.window(start: proof.windowStart, end: proof.windowEnd, zone: model.preferences.workTimeZone))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if isUnverified && showsMissingInformation {
                ForEach(Array(missingInformation.prefix(2).enumerated()), id: \.offset) { _, unknown in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(unknown.objectID == "capacity" ? "工作时间与日历占用" : model.businessIssue(unknown.objectID)).font(.caption.weight(.medium))
                        Text(PlanningCopy.unknown(unknown, in: model.workspace)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                if missingInformation.count > 2 { Text("还有 \(missingInformation.count - 2) 项信息需要确认").font(.caption).foregroundStyle(.secondary) }
            }
            Text(summary).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }.padding(.vertical, 5)
        }.id(displayID ?? [risk.kind.rawValue, risk.projectID ?? "", risk.message])
    }
}
