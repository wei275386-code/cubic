import SwiftUI
import CubicCore

/// Compact work row: state, name, where it belongs and the few facts that change what to do.
struct ActionRow: View {
    @Environment(AppModel.self) private var model
    let item: WorkItem
    var showsContext = true
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.body).foregroundStyle(symbolTint).frame(width: 20).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                ProjectListTitle(text: item.name).layoutPriority(1)
                if showsContext {
                    Text(model.workContext(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { chips }
                    VStack(alignment: .leading, spacing: 4) { chips }
                }
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 3)
    }
    private var symbol: String {
        if item.status == .completed { return "checkmark.circle.fill" }
        if item.needsReview { return "arrow.triangle.2.circlepath" }
        if model.isBlocked(item.id) { return "lock.circle" }
        return item.status == .inProgress ? "circle.lefthalf.filled" : "circle"
    }
    private var symbolTint: Color {
        if item.needsReview { return .cubicAmber }
        if model.isBlocked(item.id) { return .secondary }
        return model.health(ofItem: item) == .late ? .cubicLate : .cubicAccent
    }
    @ViewBuilder private var chips: some View {
        DurationChip(minutes: item.remainingMinutes)
        if item.energy != .normal { StatusChip(text: ProjectUI.energyLabel(item.energy)) }
        if item.isFocused == true { StatusChip(text: "关注", tint: .cubicAccent, symbol: "star.fill") }
        if item.requiresContinuous { StatusChip(text: "需连续") }
        if model.isBlocked(item.id) { StatusChip(text: "等待前置", symbol: "lock") }
        if item.needsReview { StatusChip(text: "待复核", tint: .cubicAmber) }
        if let deadline = item.deadline {
            StatusChip(text: "截止 \(deadline.formatted(.dateTime.month(.defaultDigits).day()))", tint: deadline < Date() ? .cubicLate : .secondary)
        }
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
