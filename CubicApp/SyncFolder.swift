import Foundation
import CubicCore

/// A saved grant to the user's chosen sync folder. Device-local; never synced.
struct FileSyncConnection: Codable, Sendable, Equatable {
    let bookmark: Data
    let directoryLabel: String
}

struct FileSyncDirectoryInspection: Sendable {
    let directory: URL
    let directoryLabel: String
    let hasCubicData: Bool
}

struct SyncState: Equatable {
    enum Phase { case localOnly, pending, synced, waiting, failed }
    var phase = Phase.localOnly
    var lastSyncedAt: Date?
    var message: String?
    var label: String {
        switch phase {
        case .localOnly: "已保存在此设备"
        case .pending: "待同步"
        case .synced: "已同步"
        case .waiting: "等待 iCloud 下载"
        case .failed: "同步失败，本机数据已保存"
        }
    }
}

enum SyncFolder {
    static func inspect(_ directory: URL) throws -> FileSyncDirectoryInspection {
        try withAccess(to: directory) { url in
            guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw CoreError.blocked("请选择 Files 中的一个目录。")
            }
            let names = [WorkspaceStore.folderFilename, ".\(WorkspaceStore.folderFilename).icloud"]
            let exists = names.contains { FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }
            return FileSyncDirectoryInspection(directory: directory, directoryLabel: label(url), hasCubicData: exists)
        }
    }
    static func connection(for directory: URL) throws -> FileSyncConnection {
        try withAccess(to: directory) { url in
            #if os(macOS)
            let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            #else
            let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            #endif
            return FileSyncConnection(bookmark: bookmark, directoryLabel: label(url))
        }
    }
    /// Resolves the saved grant and keeps the folder accessible while `body` runs.
    @MainActor static func withAccess<T>(_ connection: FileSyncConnection, _ body: (URL) async throws -> T) async throws -> T {
        var stale = false
        #if os(macOS)
        let url = try URL(resolvingBookmarkData: connection.bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        #else
        let url = try URL(resolvingBookmarkData: connection.bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
        guard !stale else { throw CoreError.blocked("同步目录访问授权已失效，请重新选择同一目录；本机数据已保留。") }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try await body(url)
    }
    private static func withAccess<T>(to url: URL, _ body: (URL) throws -> T) throws -> T {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try body(url)
    }
    private static func label(_ directory: URL) -> String {
        (try? directory.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? directory.lastPathComponent
    }
}
