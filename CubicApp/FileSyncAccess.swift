import Foundation
import CubicCore

struct FileSyncConnection: Codable, Sendable, Equatable {
    let bookmark: Data
    /// Relative child of the user-selected directory; nil when that directory is the workspace itself.
    let workspaceFolder: String?
    let directoryLabel: String
    let metadata: FileSyncWorkspaceMetadata
}

struct FileSyncDirectoryInspection: Sendable {
    let directory: URL
    let directoryLabel: String
    let connection: FileSyncConnection?
}

enum FileSyncDirectoryManager {
    /// Inspect never creates or mutates a remote identity. UI must confirm an existing connection explicitly.
    static func inspect(directory: URL, workspaceID: String) throws -> FileSyncDirectoryInspection {
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        try validateDirectory(directory)
        let selection = try workspaceSelection(directory: directory, workspaceID: workspaceID)
        let exists = try FileSyncDirectoryIO.coordinatedRead(at: directory) { _ in
            FileManager.default.fileExists(atPath: selection.workspaceURL.appendingPathComponent(FileSyncDirectoryIO.metadataFilename).path)
        }
        let connection: FileSyncConnection?
        if exists {
            let metadata = try FileSyncDirectoryIO.readMetadata(in: selection.workspaceURL, workspaceID: workspaceID)
            connection = try makeConnection(directory: directory, folder: selection.folder, metadata: metadata)
        } else { connection = nil }
        return FileSyncDirectoryInspection(directory: directory, directoryLabel: directoryLabel(directory), connection: connection)
    }
    static func create(directory: URL, workspaceID: String) throws -> FileSyncConnection {
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        try validateDirectory(directory)
        let selection = try workspaceSelection(directory: directory, workspaceID: workspaceID)
        try FileSyncDirectoryIO.coordinatedWrite(at: directory) { root in
            if let folder = selection.folder {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: false)
            }
        }
        let metadata = try FileSyncDirectoryIO.createMetadata(in: selection.workspaceURL, workspaceID: workspaceID)
        return try makeConnection(directory: directory, folder: selection.folder, metadata: metadata)
    }
    private static func workspaceSelection(directory: URL, workspaceID: String) throws -> (workspaceURL: URL, folder: String?) {
        try FileSyncDirectoryIO.coordinatedRead(at: directory) { root in
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(FileSyncDirectoryIO.metadataFilename).path) { return (root, nil) }
            guard !workspaceID.isEmpty, workspaceID != ".", workspaceID != "..",
                  !workspaceID.contains("/"), !workspaceID.contains("\\"), workspaceID.utf8.count <= 200 else {
                throw SyncError.invalidJournal("workspace folder identity")
            }
            let candidate = root.appendingPathComponent(workspaceID)
            if FileManager.default.fileExists(atPath: candidate.path) {
                let values = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { throw SyncError.transport("workspace 目录不是普通目录") }
            }
            return (candidate, workspaceID)
        }
    }
    private static func makeConnection(directory: URL, folder: String?, metadata: FileSyncWorkspaceMetadata) throws -> FileSyncConnection {
        #if os(macOS)
        let bookmark = try directory.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        let bookmark = try directory.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
        return FileSyncConnection(bookmark: bookmark, workspaceFolder: folder, directoryLabel: directoryLabel(directory), metadata: metadata)
    }
    private static func directoryLabel(_ directory: URL) -> String {
        (try? directory.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? directory.lastPathComponent
    }
    fileprivate static func validateDirectory(_ directory: URL) throws {
        guard directory.isFileURL else { throw SyncError.transport("请选择 Files 中的同步目录") }
        try FileSyncDirectoryIO.coordinatedRead(at: directory) { coordinated in
            let values = try coordinated.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw SyncError.transport("请选择可访问的普通目录") }
        }
    }
}

extension Notification.Name {
    static let cubicFileSyncDirectoryChanged = Notification.Name("CubicFileSyncDirectoryChanged")
}

/// File presenter notifications are only refresh hints, never authoritative sync facts.
private final class FileSyncDirectoryPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue = {
        let queue = OperationQueue(); queue.name = "Cubic file sync changes"; queue.maxConcurrentOperationCount = 1
        return queue
    }()
    init(directory: URL) { presentedItemURL = directory; super.init() }
    func presentedItemDidChange() { notify() }
    func presentedSubitemDidAppear(at url: URL) { notify() }
    func presentedSubitemDidChange(at url: URL) { notify() }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { notify() }
    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        notify(); completionHandler(nil)
    }
    private func notify() { NotificationCenter.default.post(name: .cubicFileSyncDirectoryChanged, object: nil) }
}

actor SecurityScopedFileSyncAccess: FileSyncDirectoryAccess {
    private let connection: FileSyncConnection
    private var roots: [String: (url: URL, count: Int, scoped: Bool)] = [:]
    private var presenter: FileSyncDirectoryPresenter?
    init(connection: FileSyncConnection) { self.connection = connection }
    deinit {
        if let presenter { NSFileCoordinator.removeFilePresenter(presenter) }
        for grant in roots.values where grant.scoped { grant.url.stopAccessingSecurityScopedResource() }
    }
    func acquireAccess() async throws -> URL {
        var stale = false
        #if os(macOS)
        let root = try URL(resolvingBookmarkData: connection.bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        #else
        let root = try URL(resolvingBookmarkData: connection.bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
        guard !stale else { throw SyncError.transport("同步目录访问授权已失效，请重新选择同一目录；本机数据已保留。") }
        let directory: URL
        if let folder = connection.workspaceFolder {
            guard folder != ".", folder != "..", !folder.contains("/"), !folder.contains("\\") else { throw SyncError.invalidJournal("bookmark workspace path") }
            directory = root.appendingPathComponent(folder)
        } else { directory = root }
        if var existing = roots[directory.path] {
            existing.count += 1; roots[directory.path] = existing
            return directory
        }
        let scoped = root.startAccessingSecurityScopedResource()
        do {
            try FileSyncDirectoryManager.validateDirectory(root)
            try FileSyncDirectoryManager.validateDirectory(directory)
            roots[directory.path] = (root, 1, scoped)
            if presenter == nil {
                let observer = FileSyncDirectoryPresenter(directory: directory)
                NSFileCoordinator.addFilePresenter(observer); presenter = observer
            }
            return directory
        } catch {
            if scoped { root.stopAccessingSecurityScopedResource() }
            throw SyncError.transport("同步目录暂不可用或需重新授权：\(error.localizedDescription)。本机数据已保留。")
        }
    }
    func releaseAccess(to directory: URL) async {
        guard var grant = roots[directory.path] else { return }
        grant.count -= 1
        if grant.count == 0 {
            roots.removeValue(forKey: directory.path)
            if grant.scoped { grant.url.stopAccessingSecurityScopedResource() }
        } else { roots[directory.path] = grant }
    }
}
