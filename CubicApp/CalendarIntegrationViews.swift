import SwiftUI
import CubicCore

/// Calendar dates always use the workspace's work time zone, including dates
/// on another day. EventKit identifiers stay in the local bridge.
@MainActor enum CalendarIntegrationCopy {
    static func date(_ date: Date, model: AppModel) -> String {
        let zone = model.preferences.workTimeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, calendar: calendar, timeZone: zone))
    }

    static func interval(start: Date, end: Date, model: AppModel) -> String {
        "\(date(start, model: model)) – \(date(end, model: model))"
    }

    static func hasSyncConflict(_ block: WorkTimeBlock, model: AppModel) -> Bool {
        model.syncStatus.conflicts.contains { conflict in
            conflict.affectedItemIDs.contains(block.itemID) || conflict.paths.contains { $0.collection == "timeBlocks" && $0.entityID == block.id }
        }
    }
}

extension CalendarBridgePhase {
    var label: String {
        switch self {
        case .disabled: "未开启 Apple Calendar 同步"
        case .needsPermission: "需要日历完整访问权限"
        case .needsCalendar: "请选择专用日历"
        case .ready: "已与 Apple Calendar 核对一致"
        case .pending: "Cubic 已保存，等待写入 Apple Calendar"
        case .divergence: "Apple Calendar 时间需要确认"
        case .unavailable: "Cubic 日历暂不可用"
        }
    }
}

extension CalendarIntegrationCopy {
    static func blockStatus(_ block: WorkTimeBlock, model: AppModel) -> String {
        if hasSyncConflict(block, model: model) { return "同步冲突暂停" }
        guard let bridge = model.calendarBridge, bridge.enabled else { return "仅保存在 Cubic" }
        if !bridge.status.authorized { return "日历权限不可用" }
        if bridge.divergences.contains(where: { $0.blockID == block.id }) { return "Apple Calendar 修改待确认" }
        if bridge.status.phase == .unavailable || bridge.status.phase == .needsCalendar { return "日历不可用，等待核对" }
        if bridge.pendingBlockIDs.contains(block.id) { return "等待写入 Apple Calendar" }
        if bridge.pausedBlockIDs.contains(block.id) { return "时间块需要确认" }
        if bridge.status.lastReconciledAt == nil { return "等待核对 Apple Calendar" }
        return "Apple Calendar 已一致"
    }
}

struct CalendarSyncSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var sourceID = ""
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var confirmingDisable = false
    @State private var confirmingRepublish = false

    var body: some View {
        Section {
            if let bridge = model.calendarBridge {
                Label(bridge.status.phase.label, systemImage: bridge.status.phase == .ready ? "checkmark.circle" : "calendar.badge.exclamationmark")
                    .accessibilityIdentifier("calendar.sync.status")
                LabeledContent("完整访问权限", value: bridge.status.authorized ? "已允许" : "未允许")
                if let title = bridge.status.calendarTitle {
                    LabeledContent("绑定日历", value: title)
                }
                if let source = bridge.status.sourceName { LabeledContent("日历来源", value: source) }
                if let date = bridge.status.lastReconciledAt {
                    Text("最近核对：\(CalendarIntegrationCopy.date(date, model: model))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if bridge.enabled {
                    LabeledContent("待写入事件", value: "\(bridge.status.pendingCount)")
                    NavigationLink("处理日历时间与未关联事件（\(bridge.status.divergenceCount + bridge.status.unlinkedCount)）") {
                        CalendarIntegrationReviewView()
                    }.accessibilityIdentifier("calendar.sync.review")
                }
                if let message = bridge.status.message {
                    Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !bridge.status.authorized {
                    Button("允许日历完整访问", systemImage: "lock.open") {
                        perform {
                            if !(try await bridge.requestAccess()) { errorMessage = "尚未获得日历完整访问权限。请在系统设置中允许 Cubic 访问日历。" }
                        }
                    }.accessibilityIdentifier("calendar.sync.permission")
                    Button("打开系统设置") {
                        CubicSystemSettings.open()
                    }
                } else {
                    DisclosureGroup(bridge.enabled ? "创建或更换专用日历" : "选择专用日历并开启同步") {
                        if bridge.sources.isEmpty {
                            Text("没有可创建日历的来源。请在系统设置中检查 Calendar 账号。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Picker("新日历的来源", selection: $sourceID) {
                                Text("请选择来源").tag("")
                                ForEach(bridge.sources) { source in Text(source.displayName).tag(source.id) }
                            }.accessibilityIdentifier("calendar.sync.source")
                            Text("建议选择 iCloud Calendar 账号；其他来源的跨设备能力由该账号提供。请根据显示的账号名称确认来源。")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("创建 Cubic 日历并开启同步", systemImage: "calendar.badge.plus") {
                                perform { try await bridge.create(sourceID: sourceID) }
                            }.disabled(sourceID.isEmpty || !bridge.sources.contains(where: { $0.id == sourceID }))
                                .accessibilityIdentifier("calendar.sync.create")
                        }
                        if !bridge.calendars.isEmpty {
                            Text("或绑定已有的专用日历").font(.subheadline.weight(.semibold))
                            ForEach(bridge.calendars) { calendar in
                                Button {
                                    perform { try await bridge.bind(calendarID: calendar.id) }
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Label(calendar.title, systemImage: bridge.boundCalendarID == calendar.id ? "checkmark.circle" : "calendar")
                                        Text(calendar.sourceName).font(.caption).foregroundStyle(.secondary)
                                        if calendar.containsCubicEvents { Text("发现 Cubic 时间块标记").font(.caption) }
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                                }.accessibilityIdentifier("calendar.sync.bind.\(calendar.id)")
                            }
                        } else { Text("没有可写的日历。") }
                    }
                    if bridge.enabled {
                        Button("立即核对 Apple Calendar", systemImage: "arrow.triangle.2.circlepath") {
                            perform { await bridge.refresh() }
                        }.accessibilityIdentifier("calendar.sync.refresh")
                        Button("重新发布当前有效时间块") { confirmingRepublish = true }
                            .accessibilityIdentifier("calendar.sync.republish")
                    }
                }
                if bridge.enabled {
                    Button("关闭 Apple Calendar 同步", role: .destructive) { confirmingDisable = true }
                        .accessibilityIdentifier("calendar.sync.disable")
                }
                if busy { ProgressView("正在处理日历…") }
            } else { ProgressView("正在读取日历设置…") }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("calendar.sync.error")
            }
        } header: { Text("Apple Calendar 同步") } footer: {
            Text("日历绑定与同步操作立即生效。Cubic 只自动修改你指定的专用日历；Calendar 标题修改不会重命名工作。时间块仍不是实际投入或完成记录。")
        }
        .disabled(busy || model.saving)
        .task { model.ensureCalendarBridge(); await model.refreshCalendarBridge() }
        .confirmationDialog("关闭双向同步？", isPresented: $confirmingDisable, titleVisibility: .visible) {
            Button("关闭同步", role: .destructive) {
                model.calendarBridge?.disable()
                Task { await model.refreshCalendarBridge() }
            }
        } message: { Text("保留 Cubic 工作与时间块，以及 Apple Calendar 中的现有事件。") }
        .confirmationDialog("重新发布当前有效时间块？", isPresented: $confirmingRepublish, titleVisibility: .visible) {
            Button("重新发布") {
                if let bridge = model.calendarBridge { perform { try await bridge.republish() } }
            }
        } message: { Text("这会用 Cubic 当前时间和工作名称更新对应事件。存在 Cubic 数据同步冲突时，请先处理冲突。") }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; errorMessage = nil
        Task {
            defer { busy = false }
            do { try await operation(); await model.refreshCalendarBridge() }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct CalendarIntegrationSettingsView: View {
    var body: some View {
        Form { CalendarSyncSettingsSection() }.cubicNavigationTitle("Apple Calendar 同步")
    }
}

struct CalendarIntegrationStatusSection: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Section("工作时间块同步") {
            if let bridge = model.calendarBridge {
                NavigationLink { CalendarIntegrationSettingsView() } label: {
                    Label(bridge.status.phase.label, systemImage: "calendar.badge.clock")
                        .fixedSize(horizontal: false, vertical: true)
                }.accessibilityIdentifier("calendar.integration.settings")
                if bridge.enabled {
                    if bridge.status.divergenceCount > 0 || bridge.status.unlinkedCount > 0 {
                        NavigationLink { CalendarIntegrationReviewView() } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("需要确认 \(bridge.status.divergenceCount) 个时间块 · \(bridge.status.unlinkedCount) 个未关联事件")
                                Text("待确认时间块暂停未来进展；仍存在的日历事件继续占用时间。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.fixedSize(horizontal: false, vertical: true)
                        }.accessibilityIdentifier("calendar.integration.review")
                    }
                    if bridge.status.pendingCount > 0 {
                        Text("\(bridge.status.pendingCount) 个事件等待写入；Cubic 修改已保存在本机。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                NavigationLink("设置 Apple Calendar 同步") { CalendarIntegrationSettingsView() }
            }
        }
    }
}

struct CalendarTimeBlockIntegrationRow: View {
    let block: WorkTimeBlock
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(CalendarIntegrationCopy.blockStatus(block, model: model), systemImage: "calendar.badge.clock")
                .font(.subheadline).accessibilityIdentifier("calendar.block.sync.\(block.id)")
            if CalendarIntegrationCopy.hasSyncConflict(block, model: model) {
                NavigationLink("先处理 Cubic 数据同步冲突") { SyncConflictListView() }
            } else if model.calendarBridge?.pausedBlockIDs.contains(block.id) == true {
                NavigationLink("核对这个时间块") { CalendarIntegrationReviewView(focusBlockID: block.id) }
            } else {
                NavigationLink("查看 Apple Calendar 同步") { CalendarIntegrationSettingsView() }
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
}

struct CalendarIntegrationReviewView: View {
    var focusBlockID: String? = nil
    @Environment(AppModel.self) private var model
    private var divergences: [CalendarDivergence] {
        let all = model.calendarBridge?.divergences ?? []
        return focusBlockID.map { id in all.filter { $0.blockID == id } } ?? all
    }
    var body: some View {
        List {
            Section {
                Text("工作时区：\(model.preferences.workTimeZone.identifier)").font(.caption).foregroundStyle(.secondary)
                Text("核对日历时间只影响未来安排，不会记录实际投入、完成工作或修改工作名称。")
                    .font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
            if let bridge = model.calendarBridge {
                if !bridge.enabled || !bridge.status.authorized || bridge.status.phase == .unavailable {
                    Section {
                        Label(bridge.status.phase.label, systemImage: "calendar.badge.exclamationmark")
                        if let message = bridge.status.message { Text(message).font(.caption) }
                        NavigationLink("检查日历绑定与权限") { CalendarIntegrationSettingsView() }
                    }
                }
                if divergences.isEmpty {
                    Section("时间块核对") {
                        Text(focusBlockID == nil ? "没有等待确认的日历时间块。" : "这个时间块当前没有待确认的日历修改。")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(divergences) { divergence in
                        CalendarDivergenceSection(divergence: divergence, bridge: bridge)
                    }
                }
                if focusBlockID != nil {
                    Section { NavigationLink("查看全部日历时间与未关联事件") { CalendarIntegrationReviewView() } }
                } else {
                    Section("未关联的专用日历事件（\(bridge.unlinkedEvents.count)）") {
                        if bridge.unlinkedEvents.isEmpty { Text("没有未关联事件。").foregroundStyle(.secondary) }
                        ForEach(bridge.unlinkedEvents) { event in
                            CalendarUnlinkedEventRow(event: event, bridge: bridge)
                        }
                    }
                }
            } else { ProgressView("正在读取日历…") }
        }
        .cubicNavigationTitle("核对 Apple Calendar")
        .task { model.ensureCalendarBridge(); await model.refreshCalendarBridge() }
        .refreshable { await model.refreshCalendarBridge() }
    }
}

private struct CalendarDivergenceSection: View {
    let divergence: CalendarDivergence
    let bridge: CalendarBridge
    @Environment(AppModel.self) private var model
    @State private var busy = false
    @State private var confirmingCancel = false
    @State private var errorMessage: String?
    private var syncConflict: Bool {
        divergence.syncConflict || model.syncStatus.conflicts.contains { conflict in
            conflict.affectedItemIDs.contains(divergence.itemID) || conflict.paths.contains { $0.collection == "timeBlocks" && $0.entityID == divergence.blockID }
        }
    }
    var body: some View {
        Section {
            if model.item(divergence.itemID) != nil {
                NavigationLink(model.item(divergence.itemID)?.name ?? "工作") { WorkDetailView(itemID: divergence.itemID) }
            } else { Text("工作已不可用") }
            Label("时间块需要确认 · 未来进展已暂停", systemImage: "exclamationmark.triangle")
                .font(.subheadline).fixedSize(horizontal: false, vertical: true)
            Text(divergence.reason).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Cubic 当前时间").font(.caption.weight(.semibold))
                Text(CalendarIntegrationCopy.interval(start: divergence.cubicStart, end: divergence.cubicEnd, model: model))
                    .font(.subheadline).monospacedDigit()
            }
            if divergence.events.isEmpty {
                Label("Apple Calendar 事件已删除或暂时不可见", systemImage: "calendar.badge.minus")
                    .font(.subheadline)
            } else {
                ForEach(divergence.events) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Apple Calendar：\(event.title)").font(.caption.weight(.semibold))
                        Text(CalendarIntegrationCopy.interval(start: event.start, end: event.end, model: model))
                            .font(.subheadline).monospacedDigit()
                        if event.allDay { Text("全天事件").font(.caption) }
                        if event.recurring { Text("重复事件").font(.caption) }
                    }
                }
            }
            Text("发现于 \(CalendarIntegrationCopy.date(divergence.detectedAt, model: model))")
                .font(.caption).foregroundStyle(.secondary)
            if syncConflict {
                NavigationLink("先处理 Cubic 数据同步冲突") { SyncConflictListView() }
                    .accessibilityIdentifier("calendar.divergence.syncConflict.\(divergence.blockID)")
                Text("确认数据版本后再核对日历，Calendar 不会自行选择其中一方。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Button("接受 Apple Calendar 修改") { perform { try await bridge.accept(blockID: divergence.blockID) } }
                    .disabled(divergence.events.count != 1)
                    .accessibilityIdentifier("calendar.divergence.accept.\(divergence.blockID)")
                if divergence.events.count != 1 {
                    Text(divergence.events.isEmpty ? "事件已不在日历中。可恢复 Cubic 时间，或取消此时间块。" : "请先在 Apple Calendar 中保留一个对应事件，再接受修改。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("恢复 Cubic 时间") { perform { try await bridge.restore(blockID: divergence.blockID) } }
                    .accessibilityIdentifier("calendar.divergence.restore.\(divergence.blockID)")
                Button("取消 Cubic 时间块（保留工作）", role: .destructive) { confirmingCancel = true }
                    .accessibilityIdentifier("calendar.divergence.cancel.\(divergence.blockID)")
            }
            if busy { ProgressView("正在核对…") }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("calendar.divergence.error.\(divergence.blockID)")
            }
        } header: { Text("时间块需要确认") }
        .disabled(busy || model.saving)
        .confirmationDialog("取消这个 Cubic 时间块？", isPresented: $confirmingCancel, titleVisibility: .visible) {
            Button("取消时间块，保留工作", role: .destructive) {
                perform { try await bridge.cancel(blockID: divergence.blockID) }
            }
        } message: { Text("移除这个未来安排及其对应 Calendar 事件。工作、实际投入和历史保留。") }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; errorMessage = nil
        Task {
            defer { busy = false }
            do { try await operation(); await model.refreshCalendarBridge() }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct CalendarUnlinkedEventRow: View {
    let event: CalendarBridgeEvent
    let bridge: CalendarBridge
    @Environment(AppModel.self) private var model
    @State private var expanded = false
    @State private var selectedItemID = ""
    @State private var busy = false
    @State private var errorMessage: String?
    private var candidates: [WorkItem] {
        model.workspace.items.filter {
            !$0.archived && $0.effectiveDisposition == .active && $0.status != .completed
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if expanded {
            let availableItems = candidates
            Text(CalendarIntegrationCopy.interval(start: event.start, end: event.end, model: model))
                .font(.subheadline).monospacedDigit()
            if event.blockID != nil {
                Text("事件含 Cubic 时间块标记，但本机暂未收到对应数据。请先刷新 Cubic 数据同步；当前按普通日历占用处理。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("刷新 Cubic 数据同步") {
                    Task { await model.refreshSync(); await model.refreshCalendarBridge() }
                }
            } else if event.allDay || event.recurring {
                Text("全天或重复事件无法关联为单次工作时间块。请先在 Apple Calendar 中改成具体的单次时段。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if availableItems.isEmpty {
                Text("没有可安排的工作。先创建工作并补充剩余估计，事件会继续作为日历占用。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("关联到已有工作", selection: $selectedItemID) {
                    Text("请选择工作").tag("")
                    ForEach(availableItems, id: \.id) { item in Text(item.name).tag(item.id) }
                }.cubicSelectionPicker().accessibilityIdentifier("calendar.unlinked.item.\(event.id)")
                Button("关联并创建 Cubic 时间块") {
                    guard !busy else { return }
                    busy = true; errorMessage = nil
                    Task {
                        defer { busy = false }
                        do {
                            try await bridge.associate(eventID: event.id, itemID: selectedItemID)
                            await model.refreshCalendarBridge()
                        } catch { errorMessage = error.localizedDescription }
                    }
                }.disabled(selectedItemID.isEmpty || !availableItems.contains(where: { $0.id == selectedItemID }))
                    .accessibilityIdentifier("calendar.unlinked.associate.\(event.id)")
                Text("将先检查工作时段、精力、占用与剩余估计。校验失败时保留事件原样；成功后只计算一次时间占用。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if busy { ProgressView("正在关联…") }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("calendar.unlinked.error.\(event.id)")
            }
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label(event.title, systemImage: "calendar.badge.questionmark")
                Text(event.blockID == nil ? (event.busy ? "未关联工作 · 普通日历占用" : "未关联工作 · 日历空闲事件") : (event.busy ? "等待 Cubic 数据 · 普通日历占用" : "等待 Cubic 数据 · 日历空闲事件"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(CalendarIntegrationCopy.interval(start: event.start, end: event.end, model: model))
                    .font(.caption).foregroundStyle(.secondary)
            }.fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("calendar.unlinked.\(event.id)")
        }
        .disabled(busy || model.saving)
    }
}
