import SwiftUI
import EventKit
import UserNotifications

@main struct CubicMacApp: App {
    @State private var model = AppModel()
    @State private var navigation = MacNavigation()

    init() { UNUserNotificationCenter.current().delegate = CubicNotificationDelegate.shared }

    var body: some Scene {
        // One workspace window avoids competing drafts and duplicated sync timers.
        Window("Cubic", id: "workspace") {
            MacWorkspaceView().environment(model).environment(navigation)
                .tint(.cubicAccent)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建工作") { navigation.editor = .newItem(projectID: nil, nodeID: nil) }
                    .keyboardShortcut("n").disabled(!canEdit)
                Button("从 Markdown 创建项目…") {
                    navigation.editor = .markdownProject { _ in navigation.section = .projects }
                }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(!canEdit)
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { navigation.startupRoute = nil; navigation.settings = true }.keyboardShortcut(",")
                    .disabled(!canEdit)
            }
            CommandMenu("前往") {
                ForEach(MacSection.allCases) { section in
                    Button(section.title) { navigation.section = section }
                        .keyboardShortcut(section.shortcut).disabled(model.activeModalCount > 0)
                }
            }
            CommandMenu("同步") {
                Button("立即同步") { Task { await model.refreshSync() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.loading || model.saving || model.syncStatus.phase == .syncing)
            }
            SidebarCommands()
        }
    }

    private var canEdit: Bool {
        !model.loading && model.loadFailure == nil && !model.saving && model.activeModalCount == 0 &&
            navigation.editor == nil && !navigation.settings
    }
}

enum MacSection: String, CaseIterable, Identifiable {
    case inbox, actions, calendar, projects
    var id: Self { self }
    var title: String {
        switch self {
        case .inbox: "收件箱"
        case .actions: "行动"
        case .calendar: "日历"
        case .projects: "项目"
        }
    }
    var symbol: String {
        switch self {
        case .inbox: "tray"
        case .actions: "circle.hexagongrid"
        case .calendar: "calendar"
        case .projects: "square.stack.3d.up"
        }
    }
    var shortcut: KeyEquivalent {
        switch self {
        case .inbox: "1"
        case .actions: "2"
        case .calendar: "3"
        case .projects: "4"
        }
    }
}

@MainActor @Observable final class MacNavigation {
    var section: MacSection? = .actions
    var settings = false
    var startupRoute: WorkspaceStartRoute?
    var editor: ProjectUISheet?
}

struct MacWorkspaceView: View {
    @Environment(AppModel.self) private var model
    @Environment(MacNavigation.self) private var navigation
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var navigation = navigation
        Group {
            if model.loading {
                VStack(spacing: 18) {
                    Image(systemName: "cube.transparent.fill").font(.system(size: 52)).foregroundStyle(Color.cubicAccent)
                    Text("Cubic").font(.largeTitle.weight(.semibold))
                    ProgressView("正在读取工作记录…")
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failure = model.loadFailure {
                VStack(spacing: 20) {
                    ContentUnavailableView("暂时无法读取本机数据", systemImage: "externaldrive.badge.exclamationmark", description: Text(failure))
                    Button("重新读取") { Task { await model.retryLoad() } }.buttonStyle(.borderedProminent)
                }
            } else {
                NavigationSplitView {
                    sidebar
                } detail: {
                    NavigationStack {
                        detail
                    }.id(navigation.section)
                        .formStyle(.grouped)
                        .safeAreaInset(edge: .top, spacing: 0) { serviceBanner }
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .sheet(isPresented: $navigation.settings) { SettingsView(initialRoute: navigation.startupRoute) }
        .sheet(item: $navigation.editor) { ProjectUISheetContent(sheet: $0) }
        .sheet(isPresented: Binding(get: { model.openingNoticeID != nil }, set: { if !$0 { model.openingNoticeID = nil } })) {
            NavigationStack {
                if let id = model.openingNoticeID { NoticeDetailView(noticeID: id) }
            }.cubicSheetSize()
        }
        .alert(model.errorMessage == nil ? "Cubic" : model.errorTitle, isPresented: Binding(
            get: { model.activeModalCount == 0 && (model.errorMessage != nil || model.statusMessage != nil) },
            set: { if !$0 && model.activeModalCount == 0 { model.errorMessage = nil; model.statusMessage = nil } }
        )) {
            Button("知道了") { model.errorMessage = nil; model.statusMessage = nil }
        } message: { Text(model.errorMessage ?? model.statusMessage ?? "") }
        .task {
            await model.boot()
            if let id = CubicNotificationRoute.shared.takePendingNoticeID() { model.openingNoticeID = id }
        }
        .onChange(of: scenePhase) { _, phase in
            guard !model.loading else { return }
            if phase == .active {
                model.cloudSync?.start()
                model.calendarBridge?.start()
                Task { await model.refresh(background: true); await model.refreshSync() }
            }
            // A Mac app remains useful while another app has focus. Keep its
            // bounded sync loop running until the process exits or sleeps.
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            if scenePhase == .active && !model.loading && !model.saving {
                Task { await model.refresh(background: true) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            if !model.loading { Task { await model.refresh(background: true) } }
        }
        .onChange(of: model.calendarBridge?.busyEvents ?? []) { _, _ in
            if !model.loading { Task { await model.refresh(background: true) } }
        }
        .onChange(of: model.calendarBridge?.pausedBlockIDs ?? []) { _, _ in
            if !model.loading { Task { await model.refresh(background: true) } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cubicNotificationOpened)) { message in
            guard !model.loading else { return }
            if let id = CubicNotificationRoute.shared.takePendingNoticeID() ?? (message.object as? String) {
                model.openingNoticeID = id
            }
        }
    }

    private var sidebar: some View {
        @Bindable var navigation = navigation
        return VStack(spacing: 0) {
            List(selection: $navigation.section) {
                Section("工作空间") {
                    ForEach(MacSection.allCases) { section in
                        Label(section.title, systemImage: section.symbol)
                            .badge(section == .inbox ? model.pendingInboxItems.count : 0)
                            .tag(section)
                            .accessibilityIdentifier("mac.sidebar.\(section.rawValue)")
                    }
                }
            }.listStyle(.sidebar)
            VStack(alignment: .leading, spacing: 10) {
                Button { navigation.startupRoute = nil; navigation.settings = true } label: {
                    Label(model.syncStatus.phase.label, systemImage: model.syncStatus.phase == .synced ? "checkmark.icloud" : "icloud")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).accessibilityIdentifier("mac.syncStatus")
                Button { navigation.startupRoute = nil; navigation.settings = true } label: {
                    Label("设置", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).accessibilityIdentifier("open-settings")
            }.padding(16)
        }
        .navigationTitle("Cubic")
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
    }

    @ViewBuilder private var detail: some View {
        switch navigation.section ?? .actions {
        case .inbox: InboxView()
        case .actions: ActionsView()
        case .calendar: CalendarView()
        case .projects: ProjectsView()
        }
    }

    @ViewBuilder private var serviceBanner: some View {
        if model.activeModalCount == 0, let issue = model.primaryServiceIssue {
            Button { navigation.startupRoute = nil; navigation.settings = true } label: {
                HStack {
                    Label(issue, systemImage: "exclamationmark.circle")
                    Spacer()
                    Text("查看设置")
                }.padding(.horizontal, 20).padding(.vertical, 10)
            }.buttonStyle(.plain).background(.regularMaterial)
                .accessibilityIdentifier("serviceIssue.openSettings")
        } else if model.activeModalCount == 0, model.syncTransportLabel == "仅本机", model.workspace == .empty {
            WorkspaceStartOptions { route in
                navigation.startupRoute = route; navigation.settings = true
            }
        }
    }
}
