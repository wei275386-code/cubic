import SwiftUI
import CubicCore

/// 待处理: everything that should come to the user, grouped by how soon it needs a decision.
/// Rows can be handled in place; handled rows leave the list.
struct AttentionView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigation.self) private var navigation
    @State private var sheet: ProjectUISheet?
    var body: some View {
        let summary = model.attention
        List {
            if summary.dueFollowUps.isEmpty && summary.lateProjects.isEmpty && summary.reviewItems.isEmpty && summary.inboxItems.isEmpty {
                Section {
                    EmptyMessage(symbol: "checkmark.seal", title: "没有需要马上处理的事", detail: "跟进、风险和新记录的事项会出现在这里。")
                }
            }
            if !summary.dueFollowUps.isEmpty || !summary.lateProjects.isEmpty {
                Section("今天需要处理") {
                    ForEach(summary.dueFollowUps, id: \.id) { FollowUpRow(blocker: $0, sheet: $sheet) }
                    ForEach(summary.lateProjects, id: \.id) { ProjectRiskRow(project: $0) }
                }
            }
            if !summary.inboxItems.isEmpty {
                Section {
                    ForEach(summary.inboxItems, id: \.id) { InboxTriageRow(item: $0, sheet: $sheet) }
                } header: { Text("需要整理") } footer: {
                    Text("补充说明、放进项目或安排时间后，事项会离开这里。")
                }
            }
            if !summary.reviewItems.isEmpty {
                Section("前置有变化，需要复核") {
                    ForEach(summary.reviewItems, id: \.id) { item in
                        NavigationLink { WorkDetailView(itemID: item.id) } label: { ActionRow(item: item) }
                            .accessibilityIdentifier("attention.review.\(item.id)")
                    }
                }
            }
            if !summary.tightProjects.isEmpty {
                Section("时间紧张") {
                    ForEach(summary.tightProjects, id: \.id) { ProjectRiskRow(project: $0) }
                }
            }
            if !summary.laterWaits.isEmpty {
                Section("稍后") {
                    ForEach(summary.laterWaits, id: \.id) { blocker in
                        NavigationLink { BlockerDetailView(blockerID: blocker.id) } label: { WaitSummary(blocker: blocker) }
                            .accessibilityIdentifier("attention.wait.\(blocker.id)")
                    }
                }
            }
            Section("全部") {
                NavigationLink { InboxView() } label: { Label("全部事项", systemImage: "tray.full") }
                    .accessibilityIdentifier("attention.allItems")
                NavigationLink { WaitingView() } label: { Label("外部等待", systemImage: "hourglass") }
                    .accessibilityIdentifier("inbox.waiting")
                NavigationLink { ReviewView() } label: { Label("回顾与待确认", systemImage: "checklist") }
                    .accessibilityIdentifier("inbox.review")
                NavigationLink { NoticeListView() } label: {
                    Label("提醒", systemImage: "bell.badge").badge(summary.unreadNotices.count)
                }.accessibilityIdentifier("actions.notices")
                NavigationLink { RiskOverviewView() } label: { Label("排期与风险说明", systemImage: "chart.bar.xaxis") }
                    .accessibilityIdentifier("attention.risks")
            }
        }
        .cubicNavigationTitle("待处理")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("记录一件事", systemImage: "plus") { navigation.capture = true }
                    .accessibilityIdentifier("attention.capture")
            }
        }
        .sheet(item: $sheet) { ProjectUISheetContent(sheet: $0) }
        .refreshable { await model.refresh(background: false) }
    }
}

private struct FollowUpRow: View {
    let blocker: Blocker
    @Binding var sheet: ProjectUISheet?
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink { BlockerDetailView(blockerID: blocker.id) } label: { WaitSummary(blocker: blocker) }
            HStack(spacing: 8) {
                if blocker.state == .active {
                    Button("已结束") { Task { _ = await model.mutate { try $0.resolveBlocker(id: blocker.id, now: Date()) } } }
                        .accessibilityIdentifier("attention.followUp.resolve.\(blocker.id)")
                } else {
                    Button("已发起") { Task { _ = await model.mutate { try $0.triggerBlocker(id: blocker.id, now: Date()) } } }
                        .accessibilityIdentifier("attention.followUp.trigger.\(blocker.id)")
                }
                Button("明天再跟进") {
                    var value = blocker
                    value.followUpAt = model.workCalendar.date(byAdding: .day, value: 1, to: max(Date(), blocker.followUpAt ?? Date()))
                    Task { _ = await model.mutate { try $0.updateBlocker(value, now: Date(), note: "推迟跟进") } }
                }.accessibilityIdentifier("attention.followUp.postpone.\(blocker.id)")
                Button("新建跟进工作") { sheet = .newItem(projectID: nil, nodeID: nil) }
            }
            .buttonStyle(.bordered).controlSize(.small).disabled(model.saving)
        }.padding(.vertical, 4)
    }
}

struct WaitSummary: View {
    let blocker: Blocker
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "flag.fill").foregroundStyle(Color.cubicAmber).frame(width: 20).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(blocker.name).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var detail: String {
        let affected = model.workspace.affectedItemIDs(by: .blocker(blocker.id)).compactMap { model.item($0) }
        let projects = Set(affected.flatMap { model.relatedProjectIDs(for: $0) })
            .compactMap { id in model.workspace.projects.first { $0.id == id }?.name }.sorted()
        var parts: [String] = []
        if !projects.isEmpty { parts.append(projects.joined(separator: "、")) }
        if blocker.state == .inactive { parts.append("尚未发起") }
        if let date = blocker.followUpAt { parts.append("跟进 \(ProjectUI.dateLabel(date))") }
        else if let date = blocker.estimatedResolution { parts.append("预计结束 \(ProjectUI.dateLabel(date))") }
        return parts.joined(separator: " · ")
    }
}

private struct ProjectRiskRow: View {
    let project: Project
    @Environment(AppModel.self) private var model
    var body: some View {
        NavigationLink { CubicProjectDetailView(projectID: project.id, initialMode: .schedule) } label: {
            HStack(spacing: 10) {
                let health = model.health(ofProject: project.id)
                Image(systemName: health.symbol).foregroundStyle(health.tint).frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(health == .late ? "\(project.name) 来不及" : "\(project.name) 时间紧张").font(.body.weight(.medium))
                    Text(gapText).font(.caption).foregroundStyle(.secondary)
                }
            }
        }.accessibilityIdentifier("attention.project.\(project.id)")
    }
    private var gapText: String {
        guard let assessment = model.planning?.projects.first(where: { $0.projectID == project.id }) else { return "查看排期" }
        let gap = (assessment.totalDemandMinutes ?? assessment.knownDemandMinutes) - assessment.knownCapacityMinutes
        return gap > 0 ? "缺口约 \(shortMinutesLabel(gap)) · 查看排期" : "余量很少 · 查看排期"
    }
}

private struct InboxTriageRow: View {
    let item: WorkItem
    @Binding var sheet: ProjectUISheet?
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink { WorkDetailView(itemID: item.id) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "tray").foregroundStyle(.secondary).frame(width: 20)
                    Text(item.name).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                }
            }.accessibilityIdentifier("inbox.item.\(item.id)")
            HStack(spacing: 8) {
                Button("整理") { sheet = .clarify(item) }.accessibilityIdentifier("attention.clarify.\(item.id)")
                Button("以后再做") {
                    Task { _ = await model.mutate { try $0.setItemDisposition(id: item.id, disposition: .deferred, now: Date()) } }
                }.accessibilityIdentifier("attention.defer.\(item.id)")
            }.buttonStyle(.bordered).controlSize(.small).disabled(model.saving)
        }.padding(.vertical, 4)
    }
}

/// Compact attention list for the Mac 今天 column.
struct AttentionDigest: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigation.self) private var navigation
    var body: some View {
        let summary = model.attention
        VStack(alignment: .leading, spacing: 8) {
            Text("需要关注").font(.headline)
            if summary.headline == nil {
                Text("没有需要马上处理的事").font(.callout).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(summary.dueFollowUps, id: \.id) { blocker in
                    row(symbol: "flag.fill", tint: .cubicAmber, title: blocker.name, detail: blocker.followUpAt.map { "跟进 \(CalendarFormat.time($0, calendar: model.workCalendar))" } ?? "需要确认是否结束")
                }
                ForEach(summary.lateProjects + summary.tightProjects, id: \.id) { project in
                    let health = model.health(ofProject: project.id)
                    Button { navigation.openProject(project.id) } label: {
                        rowLabel(symbol: health.symbol, tint: health.tint, title: "\(project.name) \(health.label)", detail: "查看排期")
                    }.buttonStyle(.plain)
                }
                ForEach(summary.reviewItems.prefix(3), id: \.id) { item in
                    row(symbol: "arrow.triangle.2.circlepath", tint: .cubicAmber, title: "\(item.name) 需要复核", detail: "前置已变更")
                }
                if !summary.inboxItems.isEmpty {
                    row(symbol: "tray", tint: .secondary, title: "\(summary.inboxItems.count) 项待整理",
                        detail: summary.inboxItems.prefix(2).map(\.name).joined(separator: "、"))
                }
            }.glassCard()
        }.accessibilityIdentifier("attention.digest")
    }
    private func row(symbol: String, tint: Color, title: String, detail: String) -> some View {
        Button { navigation.section = .attention } label: { rowLabel(symbol: symbol, tint: tint, title: title, detail: detail) }
            .buttonStyle(.plain)
    }
    private func rowLabel(symbol: String, tint: Color, title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium)).lineLimit(1)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }.padding(.vertical, 6).contentShape(Rectangle())
    }
}

// MARK: - Quick capture

/// One sentence is enough; project and duration are optional. Without a project the item waits in 待处理.
struct QuickCaptureView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var projectID: String?
    @State private var minutes: Int?
    @FocusState private var focused: Bool
    private let durations = [15, 30, 60, 120, 240]
    var body: some View {
        NavigationStack {
            Form {
                TextField("记下要做的事", text: $name, axis: .vertical)
                    .focused($focused).font(.title3)
                    .accessibilityIdentifier("inbox.quick.title")
                    .onSubmit { Task { await save() } }
                Picker("项目", selection: $projectID) {
                    Text("先放进待处理").tag(String?.none)
                    ForEach(model.workspace.projects.filter { !$0.archived }, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                }.accessibilityIdentifier("capture.project")
                Picker("预计用时", selection: $minutes) {
                    Text("稍后估计").tag(Int?.none)
                    ForEach(durations, id: \.self) { Text(shortMinutesLabel($0)).tag(Optional($0)) }
                }.accessibilityIdentifier("capture.minutes")
            }
            .formStyle(.grouped)
            .cubicNavigationTitle("记录一件事").cubicInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }
                        .disabled(ProjectUI.trim(name).isEmpty || model.saving)
                        .accessibilityIdentifier("inbox.quick.save")
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
        .cubicSheetSize()
    }
    private func save() async {
        let title = ProjectUI.trim(name)
        guard !title.isEmpty else { return }
        let item = WorkItem(name: title, projectIDs: projectID.map { [$0] } ?? [], remainingMinutes: minutes, initialMinutes: minutes)
        if await model.mutate({ try $0.addItem(item, now: Date()) }) { dismiss() }
    }
}
