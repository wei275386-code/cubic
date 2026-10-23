import SwiftUI
import CubicCore
import UniformTypeIdentifiers

enum SyncCopy {
    static func summary(_ conflict: SyncConflict) -> String {
        switch conflict.kind {
        case .concurrentValue: "同一内容被改成了不同值，请选择要使用的版本。"
        case .deletionReference: "已删除的内容仍被其他工作引用，请确认保留方式。"
        case .dependencyCycle: "这些工作互相等待，请移除其中一条前置关系。"
        case .semanticRecord: "同一条历史记录有不同版本，请选择要使用的记录。"
        case .invariant: "合并后的状态或关系不一致，请检查下列内容并调整。"
        }
    }
    static func guidance(_ status: SyncStatus) -> String? {
        if !status.missingParentIDs.isEmpty { return "部分云端记录还没下载完整，请稍后重新同步。" }
        switch status.phase {
        case .requiresSigning: return "当前安装的版本无法连接 CloudKit。你可以继续使用本机数据或选择 iCloud Drive 同步目录。"
        case .requiresAccount: return "请在系统设置中检查 iCloud 登录状态和使用权限，再重试。"
        case .accountChanged: return "请先选择新账号要使用的数据，再继续同步。"
        case .failed: return "暂时无法完成同步，请稍后重试。"
        case .conflict: return "请处理下方冲突。已保存的其他内容可以继续使用。"
        case .localOnly: return "尚未连接 iCloud，修改会保存在此设备。"
        case .pending, .syncing, .synced: return nil
        }
    }
}

extension SyncPhase {
    var label: String {
        switch self {
        case .localOnly: "已保存在此设备"
        case .pending: "待同步"
        case .syncing: "正在同步"
        case .synced: "已同步"
        case .failed: "同步失败，本机数据已保存"
        case .requiresSigning: "此版本暂不支持 CloudKit 同步"
        case .requiresAccount: "需要登录或允许使用 iCloud"
        case .accountChanged: "同步远端已变化，请选择数据"
        case .conflict: "有同步冲突需要处理"
        }
    }
}

struct SyncSettingsSection: View {
    @Environment(AppModel.self) private var model
    @Binding var selectedDirectoryURL: URL?
    let onSelectDirectory: () -> Void
    @State private var inspection: FileSyncDirectoryInspection?
    @State private var confirmingDirectory = false
    @State private var connecting = false
    var body: some View {
        Section("Cubic 数据同步") {
            statusRows
            syncActions
            Text("请选择 iCloud Drive 中同一个目录连接各设备。其他文件提供商未经完整验证。离线修改先保存在本机，恢复后自动重试。")
                .font(.caption).foregroundStyle(.secondary)
            Text("工作时段、时区、日期例外、日历排期与提醒偏好随 Cubic 数据同步。日历和通知的系统权限需在各设备授权。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(connecting)
        .onChange(of: selectedDirectoryURL) { _, url in
            guard let url else { return }
            selectedDirectoryURL = nil
            Task {
                inspection = await model.inspectFileSyncDirectory(url)
                confirmingDirectory = inspection != nil
            }
        }
        .confirmationDialog("连接此 Cubic 数据？", isPresented: $confirmingDirectory, titleVisibility: .visible) {
            if inspection?.connection != nil {
                Button("连接远端数据，保留本机旧数据") { connect(importLocal: false) }
                Button("明确合并本机数据到此远端") { connect(importLocal: true) }
            } else {
                Button("创建同步目录并上传本机数据") { connect(importLocal: true) }
            }
            Button("取消", role: .cancel) { inspection = nil }
        } message: { Text(directoryConfirmation) }
    }
    private var directoryConfirmation: String {
        guard let inspection else { return "" }
        if let connection = inspection.connection {
            return inspection.directoryLabel + "\n远端身份：" + connection.metadata.remoteBinding.rawValue + "\n连接将切换当前数据；合并会复制本机历史，冲突需确认。"
        }
        return inspection.directoryLabel + "\n这是新同步位置，将创建不可变的 workspace 身份。"
    }
    @ViewBuilder private var statusRows: some View {
            LabeledContent("同步方式", value: model.syncTransportLabel)
            Label(model.syncStatus.phase.label, systemImage: model.syncStatus.phase == .synced ? "checkmark.icloud" : "externaldrive")
                .accessibilityIdentifier("sync.status")
            if let location = model.syncDirectoryLabel {
                Text(location).font(.subheadline).textSelection(.enabled)
            }
            Text("待上传 \(model.syncStatus.pendingCount) · 待完整下载 \(model.syncStatus.stagedCount) · 冲突 \(model.syncStatus.conflicts.count)")
                .font(.caption).foregroundStyle(.secondary)
            if let date = model.syncStatus.lastSuccessfulSync {
                Text("上次同步：\(date.formatted(date: .abbreviated, time: .shortened))").font(.caption)
            }
            if let date = model.syncStatus.lastFullReconciliation {
                Text("完整核对：\(date.formatted(date: .abbreviated, time: .shortened))").font(.caption)
            }
            if let message = model.syncStatus.message {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !model.syncStatus.conflicts.isEmpty {
                NavigationLink("处理同步冲突（\(model.syncStatus.conflicts.count)）") { SyncConflictListView() }
                    .accessibilityIdentifier("sync.conflicts")
            }
    }
    @ViewBuilder private var syncActions: some View {
            Button("选择 iCloud Drive 同步目录") { onSelectDirectory() }
                .accessibilityIdentifier("sync.file.select")
            if model.syncDirectoryLabel != nil {
                Button("重新授权目录") { onSelectDirectory() }.accessibilityIdentifier("sync.file.reauthorize")
            }
            Button("立即同步") { Task { await model.refreshSync() } }
                .disabled(model.syncStatus.phase == .syncing).accessibilityIdentifier("sync.refresh")
            if model.syncTransportLabel != "仅本机" {
                Button("断开远端，保留本机数据") { Task { await model.disconnectRemoteSync() } }
                    .accessibilityIdentifier("sync.disconnect")
            }
    }
    private func connect(importLocal: Bool) {
        guard let inspection else { return }
        connecting = true
        Task {
            await model.connectFileSyncDirectory(inspection, importLocal: importLocal)
            connecting = false
            self.inspection = nil
        }
    }
}

struct SyncConflictListView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        List {
            Section { Text("同一内容有不同修改，请选择当前使用的版本。所有历史保留，其他工作可以继续。") }
            ForEach(model.syncStatus.conflicts) { conflict in
                NavigationLink { SyncConflictDetailView(conflict: conflict) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(SyncCopy.summary(conflict), systemImage: "arrow.triangle.branch")
                        Text(conflict.paths.map { model.syncRecordSummary(collection: $0.collection, id: $0.entityID) }.joined(separator: "\n"))
                            .font(.caption).foregroundStyle(.secondary)
                    }.fixedSize(horizontal: false, vertical: true)
                }
            }
        }.cubicNavigationTitle("同步冲突")
    }
}

private struct SyncConflictDetailView: View {
    let conflict: SyncConflict
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selectedRevision: String?
    @State private var revisions: [String: RevisionContext] = [:]
    @State private var resolving = false
    private struct RevisionContext { var deviceID: String; var createdAt: Date }
    private var hasCurrentConflict: Bool { model.syncStatus.conflicts.contains { $0.id == conflict.id } }
    private var currentConflict: SyncConflict { model.syncStatus.conflicts.first { $0.id == conflict.id } ?? conflict }
    @State private var removingEdges: Set<String> = []
    @State private var confirming = false
    var body: some View {
        let conflict = currentConflict
        List {
            Section {
                Text(SyncCopy.summary(conflict))
                Text("请选择现在要使用的内容，其他版本仍保留在历史中。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("哪里不一致") {
                ForEach(conflict.paths, id: \.self) { path in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.syncRecordSummary(collection: path.collection, id: path.entityID))
                        Text(fieldTitle(path.field)).font(.caption).foregroundStyle(.secondary)
                    }.fixedSize(horizontal: false, vertical: true)
                }
            }
            if conflict.kind == .concurrentValue {
                Section("选择要使用的版本") {
                    ForEach(conflict.candidates, id: \.revisionID) { candidate in
                        Button {
                            selectedRevision = candidate.revisionID; confirming = true
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("版本 \(candidate.revisionID.prefix(8))").font(.headline)
                                if let context = revisions[candidate.revisionID] {
                                    Text(context.deviceID == "archive-restored" ? "来源设备未记录（从备份恢复）" : "来源设备：" + context.deviceID)
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text("记录于 \(context.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else { Text("正在读取版本来源…").font(.caption).foregroundStyle(.secondary) }
                                Text(candidateDescription(candidate.value, field: conflict.paths.count == 1 ? conflict.paths[0].field : "")).font(.subheadline)
                            }.fixedSize(horizontal: false, vertical: true).frame(minHeight: 44)
                        }.accessibilityIdentifier("sync.choose.\(candidate.revisionID)")
                    }
                }
            } else if conflict.kind == .dependencyCycle {
                Section("循环中的关系") {
                    ForEach(conflict.paths, id: \.self) { path in
                        Toggle(model.syncRecordSummary(collection: path.collection, id: path.entityID), isOn: Binding(get: { removingEdges.contains(path.entityID) }, set: { selected in
                            if selected { removingEdges.insert(path.entityID) } else { removingEdges.remove(path.entityID) }
                        }))
                    }
                    Button("移除所选前置关系") { confirming = true }.disabled(removingEdges.isEmpty)
                }
            } else if conflict.kind == .deletionReference {
                Section("这项内容仍被引用") {
                    Text("其他工作或历史仍引用这项内容，请选择保留或归档。")
                    Button("保留这项内容") { performResolution { await model.resolveSyncDeletion(conflict, archive: false) } }
                    Button("保留记录并归档") { performResolution { await model.resolveSyncDeletion(conflict, archive: true) } }
                }
            } else if conflict.kind == .semanticRecord {
                Section("选择要使用的历史记录") {
                    Text("这些记录有不同的修改，请选择当前要使用的一条。")
                    ForEach(conflict.paths, id: \.self) { path in
                        Button { performResolution { await model.resolveSyncRecord(conflict, entityID: path.entityID) } } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(model.syncRecordSummary(collection: path.collection, id: path.entityID))
                                Text("采用这个版本 · \(path.entityID.prefix(8))").font(.caption)
                            }.fixedSize(horizontal: false, vertical: true).frame(minHeight: 44)
                        }
                    }
                }
            } else if conflict.kind == .invariant && conflict.affectedItemIDs.contains(where: { model.item($0)?.needsReview == true }) {
                Section("确认已有成果是否可用") {
                    Text("原进度保留。请确认已有成果是否仍可使用；新增工作仍需满足当前前置条件。")
                    Button("确认成果仍可用") { performResolution { await model.resolveSyncReview(conflict, outcome: .stillValid) } }
                    Button("等待前置恢复") { performResolution { await model.resolveSyncReview(conflict, outcome: .waitForUpstream) } }
                }
            } else {
                Section { Text("暂时无法排期。请检查下列内容的归属、状态和日期，原记录已保留。") }
            }
            Section("受影响的工作") {
                ForEach(conflict.affectedItemIDs.compactMap { model.item($0) }, id: \.id) { item in
                    NavigationLink { WorkDetailView(itemID: item.id) } label: { ActionRow(item: item) }
                }
            }
        }.cubicNavigationTitle("处理冲突")
            .disabled(resolving || !hasCurrentConflict)
            .onChange(of: model.syncStatus.conflicts.map(\.id)) { _, _ in
                if !hasCurrentConflict { dismiss() }
            }
            .task(id: "\(conflict.id):\(model.dataVersion)") {
                guard hasCurrentConflict else { dismiss(); return }
                var loaded: [String: RevisionContext] = [:]
                for id in Set(conflict.candidates.map(\.revisionID)) {
                    if let revision = await model.syncRevision(id: id) {
                        loaded[id] = RevisionContext(deviceID: revision.deviceID, createdAt: revision.createdAt)
                    }
                }
                guard !Task.isCancelled, hasCurrentConflict else { return }
                revisions = loaded
            }
            .confirmationDialog("确认采用所选内容？", isPresented: $confirming, titleVisibility: .visible) {
                Button("确认") { performResolution { await model.resolveSyncConflict(conflict, revisionID: selectedRevision, removingDependencyIDs: removingEdges) } }
                Button("取消", role: .cancel) { }
            }
    }
    private func performResolution(_ operation: @escaping @MainActor () async -> Void) {
        Task { @MainActor in
            guard !resolving, hasCurrentConflict else { return }
            resolving = true
            defer { resolving = false }
            await operation()
            if !hasCurrentConflict { dismiss() }
        }
    }
    private func fieldTitle(_ field: String) -> String {
        switch field {
        case "workSchedule": "工作时间与时区"
        case "workStartHour": "开始小时"
        case "workEndHour": "结束小时"
        case "workWeekends": "周末也可工作"
        case "workTimeZoneID": "工作时区"
        case "workScheduleConfigured": "工作时段已确认"
        case "workPeriods", "periods": "工作时段"
        case "startMinute": "开始（当天分钟）"
        case "endMinute": "结束（当天分钟）"
        case "slotEnergy": "时段精力"
        case "dayOverrides": "单日工作时间"
        case "unavailable": "这一天不安排工作"
        case "calendarEnabled": "将 Apple 日历事件计入排期"
        case "calendarSelection": "所选日历与占用规则"
        case "remindersEnabled": "开启通知提醒"
        case "disabledReminderCategories": "关闭的提醒类型"
        case "@execution": "工作进度与成果"
        case "@deadline": "截止时间与时区"
        case "@nodeSequence": "节点顺序与默认前置"
        case "@fact", "@effective": "当前使用的历史记录"
        case "currentChoiceID": "当前下一步"
        case "@exists": "是否保留这项内容"
        default: HistoryFactDetails.fieldTitle(field)
        }
    }
    private func candidateDescription(_ value: SyncValue, field: String = "") -> String {
        switch value {
        case .string(let text):
            if Self.textFields.contains(field) { return text }
            return Self.stateFields.contains(field) ? (Self.states[text] ?? text) : model.businessIssue(text)
        case .number(let value):
            if Self.dateFields.contains(field) { return ProjectUI.dateLabel(Date(timeIntervalSinceReferenceDate: value)) }
            if field.lowercased().contains("minutes"), let minutes = Int(exactly: value) { return minutesLabel(minutes) }
            return String(format: "%g", value)
        case .bool(let value): return value ? "是" : "否"
        case .null: return "未填写或已清除"
        case .object(let fields): return fields.sorted { $0.key < $1.key }.map { "\(fieldTitle($0.key))：\(candidateDescription($0.value, field: $0.key))" }.joined(separator: "\n")
        case .array(let values): return values.isEmpty ? "无" : values.map { candidateDescription($0, field: field) }.joined(separator: "、")
        }
    }
    private static let textFields: Set<String> = ["name", "title", "description", "detail", "note", "notes", "reason", "outcome", "contactNote", "resolutionCondition"]
    private static let stateFields: Set<String> = ["status", "state", "disposition", "planningCompleteness", "energy"]
    private static let dateFields: Set<String> = ["deadline", "started", "completedAt", "preStartCapturedAt", "triggeredAt", "resolvedAt", "expectedResolution", "followUpAt", "acceptedAt", "failedAt", "removedAt", "createdAt", "date", "effectiveAt"]
    private static let states = ["pending": "待处理", "inProgress": "已开始", "completed": "已完成", "active": "进行中 / 等待中", "resolved": "等待已结束", "inactive": "尚未发起", "planning": "待拆分", "deferred": "暂缓", "cancelled": "已取消", "accepted": "验收已通过", "failed": "验收未通过", "complete": "工作已列全", "incomplete": "还没拆完", "normal": "普通精力", "high": "高专注", "low": "低负荷"]
}

/// Reuses Settings selection/import flows; dismissing this card needs no authorization.
struct WorkspaceStartOptions: View {
    let openSettings: (WorkspaceStartRoute) -> Void
    @State private var skipped = false
    var body: some View {
        if !skipped {
            VStack(alignment: .leading, spacing: 8) {
                Text("开始你的工作空间").font(.headline)
                Text("可以离线从空白开始，也可以连接已有 iCloud Drive 数据或恢复 JSON 备份。日历和通知权限可稍后设置。")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Button("从空白开始") { skipped = true }.accessibilityIdentifier("workspace.start.local")
                    Button("连接已有数据") { openSettings(.directory) }.accessibilityIdentifier("workspace.start.directory")
                    Button("从备份恢复") { openSettings(.backup) }.accessibilityIdentifier("workspace.start.backup")
                }.buttonStyle(.bordered)
            }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial)
        }
    }
}
