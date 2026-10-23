import SwiftUI
import CubicCore

struct SyncSettingsSection: View {
    @Environment(AppModel.self) private var model
    @Binding var selectedDirectoryURL: URL?
    let onSelectDirectory: () -> Void
    @State private var inspection: FileSyncDirectoryInspection?
    @State private var confirmingDirectory = false
    @State private var connecting = false
    var body: some View {
        Section("Cubic 数据同步") {
            LabeledContent("同步方式", value: model.syncDirectoryLabel == nil ? "仅本机" : "iCloud Drive 目录")
            Label(model.syncState.label, systemImage: model.syncState.phase == .synced ? "checkmark.icloud" : "externaldrive")
                .accessibilityIdentifier("sync.status")
            if let location = model.syncDirectoryLabel {
                Text(location).font(.subheadline).textSelection(.enabled)
            }
            if let date = model.syncState.lastSyncedAt {
                Text("上次同步：\(date.formatted(date: .abbreviated, time: .shortened))").font(.caption)
            }
            if let message = model.syncState.message {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button("选择 iCloud Drive 同步目录") { onSelectDirectory() }
                .accessibilityIdentifier("sync.file.select")
            if model.syncDirectoryLabel != nil {
                Button("立即同步") { Task { await model.refreshSync() } }
                    .accessibilityIdentifier("sync.refresh")
                Button("断开同步，保留本机数据") { Task { await model.disconnectSync() } }
                    .accessibilityIdentifier("sync.disconnect")
            }
            Text("在各设备选择 iCloud Drive 中的同一个目录。两台设备都修改过时保留较新的版本，另一份以 Cubic-conflict 开头保存在同一目录中。")
                .font(.caption).foregroundStyle(.secondary)
            Text("工作时段、时区、日期例外、日历排期与提醒偏好随 Cubic 数据同步。日历和通知的系统权限需在各设备授权。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(connecting)
        .onChange(of: selectedDirectoryURL) { _, url in
            guard let url else { return }
            selectedDirectoryURL = nil
            inspection = model.inspectSyncDirectory(url)
            confirmingDirectory = inspection != nil
        }
        .confirmationDialog("连接此目录？", isPresented: $confirmingDirectory, titleVisibility: .visible) {
            if inspection?.hasCubicData == true {
                Button("使用目录中的数据") { connect(.useFolder) }
                Button("用本机数据覆盖目录") { connect(.useThisDevice) }
            } else {
                Button("上传本机数据到此目录") { connect(.useThisDevice) }
            }
            Button("取消", role: .cancel) { inspection = nil }
        } message: {
            if let inspection {
                Text(inspection.directoryLabel + (inspection.hasCubicData
                    ? "\n目录中已有 Cubic 数据。被替换的一份会保存为同一目录中的 Cubic-conflict 文件。"
                    : "\n这是新的同步目录。"))
            }
        }
    }
    private func connect(_ start: FolderSyncStart) {
        guard let inspection else { return }
        connecting = true
        Task {
            await model.connectSyncDirectory(inspection, start: start)
            connecting = false
            self.inspection = nil
        }
    }
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
