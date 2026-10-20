import SwiftUI
import EventKit
import UserNotifications

@main struct CubicApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    init() { UNUserNotificationCenter.current().delegate = CubicNotificationDelegate.shared }
    var body: some Scene {
        WindowGroup {
            RootView().environment(model).tint(.cubicAccent)
                .task {
                    await model.boot()
                    if let id = CubicNotificationRoute.shared.takePendingNoticeID() { model.openingNoticeID = id }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active && !model.loading {
                        model.cloudSync?.start()
                        model.calendarBridge?.start()
                        Task { await model.refresh(background: true); await model.refreshSync() }
                    } else if phase == .background {
                        model.cloudSync?.stop()
                        model.calendarBridge?.stop()
                    }
                }
                .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
                    if scenePhase == .active && !model.loading && !model.saving { Task { await model.refresh(background: true) } }
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
    }
}
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selected = 1
    @State private var settings = false
    @State private var startupRoute: WorkspaceStartRoute?
    var body: some View {
        @Bindable var model = model
        Group {
            if model.loading {
                VStack(spacing: 18) {
                    Image(systemName: "cube.transparent.fill").font(.system(size: 52)).foregroundStyle(Color.cubicAccent)
                    Text("Cubic").font(.largeTitle.weight(.semibold))
                    ProgressView("正在读取工作记录…")
                }
            } else if let failure = model.loadFailure {
                VStack(spacing: 20) {
                    ContentUnavailableView("暂时无法读取本机数据", systemImage: "externaldrive.badge.exclamationmark", description: Text(failure))
                    Button("重新读取") { Task { await model.retryLoad() } }.buttonStyle(.borderedProminent).foregroundStyle(Color.cubicOnAccent)
                }
            } else {
                TabView(selection: $selected) {
                    Tab("收件箱", systemImage: "tray", value: 0) { navigation { InboxView() } }
                    Tab("行动", systemImage: "circle.hexagongrid", value: 1) { navigation { ActionsView() } }
                    Tab("日历", systemImage: "calendar", value: 2) { navigation { CalendarView() } }
                    Tab("项目", systemImage: "square.stack.3d.up", value: 3) { navigation { ProjectsView() } }
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if !model.loading, model.loadFailure == nil, model.activeModalCount == 0, let issue = model.primaryServiceIssue {
                Button { startupRoute = nil; settings = true } label: {
                    HStack {
                        Label(issue, systemImage: "exclamationmark.circle")
                        Spacer()
                        Text("查看").font(.subheadline)
                    }.padding(.horizontal).padding(.vertical, 8)
                }
                .background(.regularMaterial)
                .accessibilityIdentifier("serviceIssue.openSettings")
            } else if !model.loading, model.loadFailure == nil, model.activeModalCount == 0,
                      model.syncTransportLabel == "仅本机", model.workspace == .empty {
                WorkspaceStartOptions { route in startupRoute = route; settings = true }
            }
        }
        .sheet(isPresented: $settings) { SettingsView(initialRoute: startupRoute) }
        .sheet(isPresented: Binding(get: { model.openingNoticeID != nil }, set: { if !$0 { model.openingNoticeID = nil } })) {
            NavigationStack {
                if let id = model.openingNoticeID { NoticeDetailView(noticeID: id) }
            }
        }
        .alert(model.errorMessage == nil ? "Cubic" : model.errorTitle, isPresented: Binding(
            get: { model.activeModalCount == 0 && (model.errorMessage != nil || model.statusMessage != nil) },
            set: { if !$0 && model.activeModalCount == 0 { model.errorMessage = nil; model.statusMessage = nil } }
        )) {
            Button("知道了") { model.errorMessage = nil; model.statusMessage = nil }
        } message: { Text(model.errorMessage ?? model.statusMessage ?? "") }
    }
    private func navigation<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content()
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("设置", systemImage: "slider.horizontal.3") { startupRoute = nil; settings = true }
                            .accessibilityIdentifier("open-settings")
                    }
                }
        }
    }
}
