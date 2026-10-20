import SwiftUI
import CubicCore

struct NoticeListView: View {
    @Environment(AppModel.self) private var model
    @State private var showResolved = false
    var body: some View {
        List {
            Section {
                Toggle("显示已处理提醒", isOn: $showResolved)
                Text("已读表示看过提醒。选择“明天提醒”只推迟通知，不改变工作进度和截止。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            let notices = model.notices.filter { showResolved || !$0.isResolved }
            if notices.isEmpty { ContentUnavailableView("暂无待处理提醒", systemImage: "bell.badge") }
            ForEach(notices) { notice in
                NavigationLink { NoticeDetailView(noticeID: notice.id) } label: { NoticeRow(notice: notice) }
                    .accessibilityIdentifier("notice.row.\(notice.id)")
            }
        }.cubicNavigationTitle("待处理提醒")
    }
}

struct NoticeRow: View {
    let notice: RiskNotice
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(NoticeCopy.title(notice), systemImage: notice.isResolved ? "checkmark.circle" : notice.isRead ? "bell" : "bell.badge")
                .font(.headline).fixedSize(horizontal: false, vertical: true)
            Text(NoticeCopy.summary(notice)).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if ["capacityConflict", "projectRisk", "review", "syncConflict"].contains(notice.kind) {
                ForEach(notice.projectIDs, id: \.self) { id in
                    if let project = model.workspace.projects.first(where: { $0.id == id }) {
                        Text("项目：\(project.name)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            if notice.isResolved { Text("已处理").font(.caption) }
            if let date = notice.snoozedUntil {
                Text("下次提醒 \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption)
            }
        }.padding(.vertical, 6)
    }
}

struct NoticeDetailView: View {
    let noticeID: String
    @Environment(AppModel.self) private var model
    private var notice: RiskNotice? { model.notices.first { $0.id == noticeID } }
    var body: some View {
        List {
            if let notice {
                Section { NoticeRow(notice: notice) }
                Section("当前状态") {
                    Text(notice.isResolved ? "相关问题已处理，这条提醒仅供查看。" : "请查看下方当前工作状态，再确认如何处理。")
                        .foregroundStyle(.secondary)
                    if model.calculationIsStale || model.isRefreshing { Label("正在核对最新影响", systemImage: "arrow.triangle.2.circlepath") }
                }
                if !notice.isResolved {
                    Section("提醒设置") {
                        Button("标为已读") { Task { await model.markNoticeRead(noticeID) } }
                            .accessibilityIdentifier("notice.markRead")
                        Button("明天提醒") { Task { await model.snoozeNotice(noticeID, until: Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date().addingTimeInterval(86400)) } }
                            .accessibilityIdentifier("notice.snoozeTomorrow")
                    }
                }
                Section("去哪里处理") {
                    if let blocker = model.workspace.blockers.first(where: { $0.id == notice.rootObjectID }) {
                        NavigationLink { BlockerDetailView(blockerID: blocker.id) } label: {
                            Label("检查等待：\(blocker.name)", systemImage: "hourglass").frame(minHeight: 44)
                        }.accessibilityIdentifier("notice.root.blocker")
                    } else if let gate = model.workspace.acceptances.first(where: { $0.id == notice.rootObjectID && $0.removedAt == nil }) {
                        WorkReferenceLink(subject: gate.subject, label: "检查验收：\(gate.name)", identifier: "notice.root.acceptance")
                    } else if notice.kind == "syncConflict" {
                        NavigationLink("处理同步冲突") { SyncConflictListView() }
                            .accessibilityIdentifier("notice.root.sync")
                    } else if let item = model.item(notice.rootObjectID) {
                        NavigationLink { WorkDetailView(itemID: item.id) } label: {
                            Label("检查工作：\(item.name)", systemImage: "checklist").frame(minHeight: 44)
                        }.accessibilityIdentifier("notice.root.item")
                    } else if let project = model.workspace.projects.first(where: { $0.id == notice.rootObjectID }) {
                        NavigationLink("检查项目：\(project.name)") { CubicProjectDetailView(projectID: project.id) }
                            .accessibilityIdentifier("notice.root.project")
                    } else {
                        Text("原事项已不可用，请查看下方关联的工作和项目。")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("受影响的工作") {
                    ForEach(notice.itemIDs.compactMap { model.item($0) }, id: \.id) { item in
                        NavigationLink { WorkDetailView(itemID: item.id) } label: { ActionRow(item: item) }
                    }
                }
                Section("受影响的项目") {
                    ForEach(model.workspace.projects.filter { notice.projectIDs.contains($0.id) }, id: \.id) { project in
                        NavigationLink(project.name) { CubicProjectDetailView(projectID: project.id) }
                    }
                }
                Text("更新于 \(notice.changedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ContentUnavailableView("提醒已不存在", systemImage: "bell.slash", description: Text("请返回提醒列表查看当前待处理事项。"))
            }
        }
        .cubicNavigationTitle("提醒详情")
        .cubicInlineNavigationTitle()
        .task { await model.refresh() }
    }
}
