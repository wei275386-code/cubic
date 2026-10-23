import SwiftUI
import UniformTypeIdentifiers
import CubicCore

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

enum WorkspaceStartRoute { case directory, backup }

struct SettingsView: View {
    var initialRoute: WorkspaceStartRoute? = nil
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var preferences = UserPreferences()
    @State private var draftLoaded = false
    @State private var originalPreferences: [String: JSONValue] = [:]
    @State private var exporting = false
    @State private var importing = false
    @State private var selectingSyncDirectory = false
    @State private var syncDirectoryURL: URL?
    @State private var document = BackupDocument()
    @State private var resetConfirm = false
    @State private var pendingImport: Data?
    @State private var importConfirm = false
    @State private var busy = false
    @State private var backupMessageContext: Int?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("安排你的工作时间", systemImage: "cube.transparent")
                    Text("设置工作时段、日历和提醒。所有项目会一起参与排期。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if !model.serviceIssues.isEmpty {
                    Section("需要检查的状态") {
                        ForEach(model.serviceIssues.keys.sorted(), id: \.self) { title in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(title).font(.headline)
                                Text(model.serviceIssues[title] ?? "").font(.subheadline).foregroundStyle(.secondary)
                            }.fixedSize(horizontal: false, vertical: true)
                        }
                        Button("重新检查") { Task { await model.refresh(background: true); await model.refreshSync() } }
                    }.accessibilityIdentifier("settings.serviceIssues")
                }
                CapacitySettingsSection(preferences: $preferences)
                Section {
                    Toggle("将 Apple 日历事件计入排期", isOn: Binding(get: { preferences.calendarEnabled }, set: { enabled in
                            preferences.calendarEnabled = enabled
                            if enabled {
                                if preferences.selectedCalendarIDs == nil { preferences.selectedCalendarIDs = [] }
                                Task { await model.enableCalendar() }
                            }
                        }))
                        .accessibilityIdentifier("settings.calendarEnabled")
                    if preferences.calendarEnabled {
                        if model.calendar.authorized {
                            ForEach(model.calendar.calendars.filter { $0.id != model.calendarBridge?.boundCalendarID }) { calendar in
                                Toggle(calendar.title, isOn: Binding(get: {
                                    preferences.selectedCalendarIDs?.contains(calendar.id) ?? false
                                }, set: { selected in
                                    var ids = preferences.selectedCalendarIDs ?? []
                                    if selected { ids.insert(calendar.id) } else { ids.remove(calendar.id) }
                                    preferences.selectedCalendarIDs = ids
                                }))
                            }
                            ForEach(model.calendar.calendars.filter { preferences.selectedCalendarIDs?.contains($0.id) == true && $0.id != model.calendarBridge?.boundCalendarID }) { calendar in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(calendar.title).font(.subheadline.weight(.semibold))
                                    Picker("全天事件", selection: ruleBinding(calendar.id, allDay: true)) {
                                        ForEach(CalendarOccupancyPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
                                    }
                                    Picker("事件未说明忙闲时", selection: ruleBinding(calendar.id, allDay: false)) {
                                        ForEach(CalendarOccupancyPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
                                    }
                                }
                            }
                            if model.calendar.calendars.isEmpty { Text("没有可选择的日历。") }
                        } else {
                            Text("尚无日历权限。请到系统设置允许访问日历。")
                                .foregroundStyle(.secondary)
                            Button("打开系统设置") { openSettings() }
                        }
                    }
                } header: { Text("系统日历") } footer: {
                    Text("只读取所选日历。空闲事件不占时间，重叠的忙碌事件只计算一次。")
                }
                Section("提醒") {
                    Toggle("开启通知提醒", isOn: Binding(get: { preferences.remindersEnabled }, set: { enabled in
                            preferences.remindersEnabled = enabled
                            if enabled { Task { await model.enableReminders() } }
                        }))
                        .accessibilityIdentifier("settings.remindersEnabled")
                    ForEach(ReminderCategory.allCases, id: \.self) { category in
                        Toggle(category.label, isOn: Binding(get: {
                            !(preferences.disabledReminderCategories ?? []).contains(category.rawValue)
                        }, set: { enabled in
                            var disabled = preferences.disabledReminderCategories ?? []
                            if enabled { disabled.remove(category.rawValue) } else { disabled.insert(category.rawValue) }
                            preferences.disabledReminderCategories = disabled
                        }))
                        .disabled(!preferences.remindersEnabled)
                        .accessibilityIdentifier("settings.reminders.\(category.rawValue)")
                    }
                    Text("按未来的跟进或预计结束时间提醒；其他事项仅在选择“明天提醒”后发送通知。已过期事项不补发，使用 App 时不弹出通知。类型选择保存后生效，App 内始终可查看待处理事项。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                SyncSettingsSection(selectedDirectoryURL: $syncDirectoryURL, onSelectDirectory: {
                    selectingSyncDirectory = true
                    importing = true
                })
                CalendarSyncSettingsSection()
                Section("数据与备份") {
                    Button("导出备份", systemImage: "square.and.arrow.up") {
                        backupMessageContext = model.messageContextVersion
                        Task {
                            busy = true
                            if let data = await model.exportBackup(), backupMessageContext == model.messageContextVersion { document = BackupDocument(data: data); exporting = true }
                            busy = false
                        }
                    }
                    Button("导入并合并备份", systemImage: "square.and.arrow.down") { selectingSyncDirectory = false; backupMessageContext = model.messageContextVersion; importing = true }
                    Text("建议定期将备份保存到“文件”。卸载 App 会移除本机数据。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("归档全部工作，重新开始", role: .destructive) { resetConfirm = true }
                }
                Section("关于") {
                    LabeledContent("版本", value: AppVersion.display).accessibilityIdentifier("settings.version")
                    LabeledContent("存储", value: "此设备")
                    Text("数据同步与 Apple Calendar 同步可分别设置。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .cubicNavigationTitle("设置")
            .cubicInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task { if await model.savePreferences(preferences) { dismiss() } }
                    }.disabled(busy)
                }
            }
            .onAppear {
                guard !draftLoaded else { return }
                preferences = model.preferences
                originalPreferences = (try? preferences.syncValues(calendars: model.calendar.calendars)) ?? [:]
                draftLoaded = true
                if let initialRoute {
                    selectingSyncDirectory = initialRoute == .directory
                    backupMessageContext = model.messageContextVersion
                    importing = true
                }
            }
            .onChange(of: model.preferences) { _, received in
                guard draftLoaded,
                      let draft = try? preferences.syncValues(calendars: model.calendar.calendars),
                      let updated = try? received.syncValues(calendars: model.calendar.calendars) else { return }
                let untouched = updated.filter { draft[$0.key] == originalPreferences[$0.key] }
                if let merged = try? preferences.applyingSyncValues(untouched, calendars: model.calendar.calendars) {
                    preferences = merged
                    originalPreferences.merge(untouched) { _, new in new }
                }
            }
            .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "Cubic-备份-\(Date().formatted(.iso8601.year().month().day()))") { result in
                guard backupMessageContext == model.messageContextVersion else { return }
                if case .failure(let error) = result { model.reportFailure("备份未能导出", message: error.localizedDescription, context: backupMessageContext) }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: selectingSyncDirectory ? [.folder] : [.json]) { result in
                if selectingSyncDirectory {
                    if case .success(let url) = result { syncDirectoryURL = url }
                    else if case .failure(let error) = result, (error as NSError).code != NSUserCancelledError {
                        model.reportFailure("目录未能选择", message: error.localizedDescription)
                    }
                    return
                }
                guard backupMessageContext == model.messageContextVersion else { return }
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url)
                    pendingImport = data; importConfirm = true
                } catch { model.reportFailure("备份未能读取", message: error.localizedDescription, context: backupMessageContext) }
            }
            .confirmationDialog("用备份替换当前数据？当前数据会被覆盖，建议先导出一份备份。", isPresented: $importConfirm, titleVisibility: .visible) {
                Button("用备份替换", role: .destructive) {
                    if let data = pendingImport { Task { if await model.importBackup(data) { dismiss() } } }
                }
                Button("取消", role: .cancel) { pendingImport = nil }
            }
            .confirmationDialog("归档全部工作并取消未完成项目？历史会保留，之后可从归档恢复。", isPresented: $resetConfirm, titleVisibility: .visible) {
                Button("归档工作并取消未完成项目", role: .destructive) { Task { if await model.resetWorkspace() { dismiss() } } }
            }
        }
        .modifier(ModalMessages())
    }
    private func ruleBinding(_ id: String, allDay: Bool) -> Binding<CalendarOccupancyPolicy> {
        Binding(get: {
            let rule = preferences.rule(for: id)
            return allDay ? rule.allDay : rule.unknownAvailability
        }, set: { value in
            var rule = preferences.rule(for: id)
            if allDay { rule.allDay = value } else { rule.unknownAvailability = value }
            if preferences.calendarOccupancyRules == nil { preferences.calendarOccupancyRules = [:] }
            preferences.calendarOccupancyRules?[id] = rule
        })
    }
    private func openSettings() {
        CubicSystemSettings.open()
    }
}
