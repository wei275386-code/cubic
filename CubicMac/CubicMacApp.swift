import SwiftUI
import EventKit
import UserNotifications

@main struct CubicMacApp: App {
    @State private var model = AppModel()
    @State private var navigation = AppNavigation()

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
                Button("记录一件事") { navigation.capture = true }
                    .keyboardShortcut("n").disabled(!canEdit)
                Button("新建工作…") { navigation.editor = .newItem(projectID: nil, nodeID: nil) }
                    .keyboardShortcut("n", modifiers: [.command, .option]).disabled(!canEdit)
                Button("从 Markdown 创建项目…") {
                    navigation.editor = .markdownProject { navigation.openProject($0) }
                }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(!canEdit)
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { navigation.openSettings() }.keyboardShortcut(",")
                    .disabled(!canEdit)
            }
            CommandMenu("前往") {
                ForEach(AppSection.allCases) { section in
                    Button(section.title) { navigation.section = section; navigation.selectedProjectID = nil }
                        .keyboardShortcut(section.shortcut).disabled(model.activeModalCount > 0)
                }
            }
            CommandMenu("同步") {
                Button("立即同步") { Task { await model.refreshSync() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.loading || model.syncDirectoryLabel == nil)
            }
            SidebarCommands()
        }
    }

    private var canEdit: Bool {
        !model.loading && model.loadFailure == nil && !model.saving && model.activeModalCount == 0 &&
            navigation.editor == nil && !navigation.settings && !navigation.capture
    }
}

/// Sidebar rows: the four sections plus each active project under 项目.
private enum MacSidebarItem: Hashable {
    case section(AppSection), project(String)
}

struct MacWorkspaceView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigation.self) private var navigation
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
                    }.id(sidebarSelection)
                        .formStyle(.grouped)
                        .safeAreaInset(edge: .top, spacing: 0) { serviceBanner }
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .sheet(isPresented: $navigation.settings) { SettingsView(initialRoute: navigation.startupRoute) }
        .sheet(item: $navigation.editor) { ProjectUISheetContent(sheet: $0) }
        .sheet(isPresented: $navigation.capture) { QuickCaptureView() }
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
                model.startSync()
                model.calendarBridge?.start()
                Task { await model.refresh(background: true) }
            }
            // A Mac app remains useful while another app has focus, so its sync loop keeps running.
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

    private var sidebarSelection: MacSidebarItem {
        if navigation.section == .projects, let id = navigation.selectedProjectID { return .project(id) }
        return .section(navigation.section)
    }

    private var sidebar: some View {
        let selection = Binding<MacSidebarItem?>(get: { sidebarSelection }, set: { item in
            switch item {
            case .section(let section): navigation.section = section; navigation.selectedProjectID = nil
            case .project(let id): navigation.openProject(id)
            case nil: break
            }
        })
        let projects = model.workspace.projects.filter { !$0.archived }
        return VStack(spacing: 0) {
            List(selection: selection) {
                ForEach(AppSection.allCases) { section in
                    Label(section.title, systemImage: section.symbol)
                        .badge(section == .attention ? model.attention.count : 0)
                        .tag(MacSidebarItem.section(section))
                        .accessibilityIdentifier("mac.sidebar.\(section.rawValue)")
                    if section == .projects {
                        ForEach(projects, id: \.id) { project in
                            Label { Text(project.name).lineLimit(1) } icon: { HealthDot(health: model.health(ofProject: project.id)) }
                                .padding(.leading, 14)
                                .tag(MacSidebarItem.project(project.id))
                                .accessibilityIdentifier("mac.sidebar.project.\(project.id)")
                        }
                    }
                }
            }.listStyle(.sidebar)
            VStack(alignment: .leading, spacing: 10) {
                Button { navigation.openSettings() } label: {
                    Label(model.syncState.label, systemImage: model.syncState.phase == .synced ? "checkmark.icloud" : "icloud")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).accessibilityIdentifier("mac.syncStatus")
                Button { navigation.openSettings() } label: {
                    Label("设置", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).accessibilityIdentifier("open-settings")
            }.padding(16)
        }
        .navigationTitle("Cubic")
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
    }

    @ViewBuilder private var detail: some View {
        switch sidebarSelection {
        case .section(.today): TodayView()
        case .section(.calendar): CalendarHomeView()
        case .section(.projects): ProjectsView()
        case .section(.attention): AttentionView()
        case .project(let id): CubicProjectDetailView(projectID: id)
        }
    }

    @ViewBuilder private var serviceBanner: some View {
        if model.activeModalCount == 0, let issue = model.primaryServiceIssue {
            Button { navigation.openSettings() } label: {
                HStack {
                    Label(issue, systemImage: "exclamationmark.circle")
                    Spacer()
                    Text("查看设置")
                }.padding(.horizontal, 20).padding(.vertical, 10)
            }.buttonStyle(.plain).background(.regularMaterial)
                .accessibilityIdentifier("serviceIssue.openSettings")
        } else if model.activeModalCount == 0, model.syncDirectoryLabel == nil, model.workspace == .empty {
            WorkspaceStartOptions { route in
                navigation.startupRoute = route; navigation.settings = true
            }
        }
    }
}
