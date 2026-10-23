import Foundation

/// Everything Cubic saves and syncs: domain facts plus portable settings.
/// `version` changes on every save; sync compares it with the last version both sides agreed on.
public struct WorkspaceDocument: Codable, Sendable, Equatable {
    public var workspace: Workspace
    public var preferences: [String: JSONValue]
    public var version: String
    public var savedAt: Date
    public var deviceID: String
    public init(workspace: Workspace = .empty, preferences: [String: JSONValue] = [:],
                version: String = UUID().uuidString, savedAt: Date = Date(), deviceID: String) {
        self.workspace = workspace; self.preferences = preferences
        self.version = version; self.savedAt = savedAt; self.deviceID = deviceID
    }
}

public enum FolderSyncOutcome: Sendable, Equatable {
    case unchanged
    case uploaded
    case downloaded
    case merged(backupName: String?)
    /// Both devices changed the data. The newer copy won; the other one was saved in the folder as `backupName`.
    case conflict(keptThisDevice: Bool, backupName: String)
    /// iCloud has not finished downloading the folder's copy yet.
    case waitingForDownload
}

/// Which copy wins when connecting a folder that already contains Cubic data.
public enum FolderSyncStart: Sendable {
    case useFolder, useThisDevice
}

/// Owns the local workspace file and keeps it in step with `Cubic.json` in a sync folder.
/// Concurrent edits merge from the last agreed document; conflicting values prefer the newer save.
public actor WorkspaceStore {
    public static let folderFilename = "Cubic.json"
    private struct LocalFile: Codable {
        var document: WorkspaceDocument
        /// Version both this device and the sync folder last agreed on; nil when not connected.
        var syncedVersion: String?
        var base: WorkspaceDocument?
    }
    public nonisolated let url: URL
    public nonisolated let deviceID: String
    /// True when this store created a new, empty workspace file.
    public nonisolated let isNew: Bool
    private var local: LocalFile

    public init(url: URL, deviceID: String) throws {
        self.url = url; self.deviceID = deviceID
        if FileManager.default.fileExists(atPath: url.path) {
            local = try JSONCoding.decode(LocalFile.self, from: Data(contentsOf: url))
            try local.document.workspace.validate()
            isNew = false
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            local = LocalFile(document: WorkspaceDocument(deviceID: deviceID))
            try JSONCoding.encode(local).write(to: url, options: .atomic)
            isNew = true
        }
    }

    public var document: WorkspaceDocument { local.document }

    /// Saves a new version. `basedOn` rejects an edit prepared from a version that sync has since replaced.
    @discardableResult
    public func save(workspace: Workspace? = nil, preferences: [String: JSONValue]? = nil,
                     basedOn version: String? = nil, now: Date = Date()) throws -> WorkspaceDocument {
        if let version, version != local.document.version {
            throw CoreError.blocked("数据刚刚同步更新，请重新查看后保存。")
        }
        var next = local
        if let workspace { try workspace.validate(); next.document.workspace = workspace }
        if let preferences { next.document.preferences = preferences }
        guard next.document != local.document else { return local.document }
        next.document.version = UUID().uuidString
        next.document.savedAt = now
        next.document.deviceID = deviceID
        try write(next)
        return next.document
    }

    /// Connects a folder for the first time. Any copy that gets replaced is kept in the folder.
    /// The caller must hold security-scoped access to `folder`.
    public func connect(folder: URL, start: FolderSyncStart) throws -> FolderSyncOutcome {
        switch try readRemote(folder) {
        case .downloading:
            throw CoreError.blocked("同步目录中的 Cubic 数据还在从 iCloud 下载，请稍后再连接。")
        case .missing:
            try upload(to: folder)
            return .uploaded
        case .document(let remote):
            if remote.version == local.document.version { try markSynced(remote.version); return .unchanged }
            switch start {
            case .useFolder:
                if local.document.workspace != .empty { try backup(local.document, in: folder) }
                try adopt(remote)
                return .downloaded
            case .useThisDevice:
                try backup(remote, in: folder)
                try upload(to: folder)
                return .uploaded
            }
        }
    }

    public func disconnect() throws {
        var next = local
        next.syncedVersion = nil
        next.base = nil
        try write(next)
    }

    /// Exchanges changes with a connected folder. The caller must hold security-scoped access to `folder`.
    public func sync(folder: URL) throws -> FolderSyncOutcome {
        let remote: WorkspaceDocument
        switch try readRemote(folder) {
        case .downloading: return .waitingForDownload
        case .missing: try upload(to: folder); return .uploaded
        case .document(let value): remote = value
        }
        if remote.version == local.document.version {
            if local.syncedVersion != remote.version { try markSynced(remote.version) }
            return .unchanged
        }
        let localChanged = local.document.version != local.syncedVersion
        let remoteChanged = remote.version != local.syncedVersion
        switch (localChanged, remoteChanged) {
        case (false, false): return .unchanged
        case (true, false): try upload(to: folder); return .uploaded
        case (false, true): try adopt(remote); return .downloaded
        case (true, true):
            let mine = local.document
            let keepMine = (mine.savedAt, mine.deviceID) > (remote.savedAt, remote.deviceID)
            if let merged = try? mergedDocument(mine, remote, preferLocal: keepMine) {
                let name = merged.conflicted ? try backup(keepMine ? remote : mine, in: folder) : nil
                var next = local; next.document = merged.document
                try write(next)
                try upload(to: folder)
                return .merged(backupName: name)
            }
            let name = try backup(keepMine ? remote : mine, in: folder)
            if keepMine { try upload(to: folder) } else { try adopt(remote) }
            return .conflict(keptThisDevice: keepMine, backupName: name)
        }
    }

    private func mergedDocument(_ mine: WorkspaceDocument, _ remote: WorkspaceDocument, preferLocal: Bool) throws -> (document: WorkspaceDocument, conflicted: Bool) {
        guard let base = local.base else { throw CoreError.invalid("缺少共同版本") }
        let workspace = WorkspaceMerge.merge(
            base: try JSONCoding.decode(JSONValue.self, from: JSONCoding.encode(base.workspace)),
            local: try JSONCoding.decode(JSONValue.self, from: JSONCoding.encode(mine.workspace)),
            remote: try JSONCoding.decode(JSONValue.self, from: JSONCoding.encode(remote.workspace)), preferLocal: preferLocal)
        let preferences = WorkspaceMerge.merge(base: .object(base.preferences), local: .object(mine.preferences),
                                               remote: .object(remote.preferences), preferLocal: preferLocal)
        let value = try JSONCoding.decode(Workspace.self, from: JSONCoding.encode(workspace.value))
        try value.validate()
        return (WorkspaceDocument(workspace: value, preferences: preferences.value.object!, deviceID: deviceID),
                workspace.conflicted || preferences.conflicted)
    }

    private func write(_ next: LocalFile) throws {
        try JSONCoding.encode(next).write(to: url, options: .atomic)
        local = next
    }
    private func markSynced(_ version: String) throws {
        var next = local
        next.syncedVersion = version
        next.base = next.document
        try write(next)
    }
    private func adopt(_ remote: WorkspaceDocument) throws {
        try write(LocalFile(document: remote, syncedVersion: remote.version, base: remote))
    }
    private func upload(to folder: URL) throws {
        let data = try JSONCoding.encode(local.document)
        try coordinatedWrite(folder.appendingPathComponent(Self.folderFilename)) { try data.write(to: $0, options: .atomic) }
        try markSynced(local.document.version)
    }
    @discardableResult
    private func backup(_ document: WorkspaceDocument, in folder: URL) throws -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "Cubic-conflict-\(formatter.string(from: document.savedAt))-\(document.version.prefix(8)).json"
        let data = try JSONCoding.encode(document)
        try coordinatedWrite(folder.appendingPathComponent(name)) { try data.write(to: $0, options: .atomic) }
        return name
    }

    private enum RemoteState { case missing, downloading, document(WorkspaceDocument) }
    private func readRemote(_ folder: URL) throws -> RemoteState {
        let file = folder.appendingPathComponent(Self.folderFilename)
        // An iCloud file that is not on this device yet appears as a hidden ".Cubic.json.icloud" placeholder.
        let placeholder = folder.appendingPathComponent(".\(Self.folderFilename).icloud")
        if FileManager.default.fileExists(atPath: placeholder.path) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: file)
            return .downloading
        }
        if let status = try? file.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus,
           status != .current {
            try? FileManager.default.startDownloadingUbiquitousItem(at: file)
            return .downloading
        }
        var result: Result<RemoteState, any Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &coordinationError) { url in
            result = Result {
                guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
                let document = try JSONCoding.decode(WorkspaceDocument.self, from: Data(contentsOf: url))
                try document.workspace.validate()
                return .document(document)
            }
        }
        if let coordinationError { throw coordinationError }
        do {
            guard case .document(var remote) = try result!.get() else { return try result!.get() }
            let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: file) ?? []
            var handled: [NSFileVersion] = []
            for version in versions {
                guard let data = try? Data(contentsOf: version.url) else { continue }
                if let other = try? JSONCoding.decode(WorkspaceDocument.self, from: data),
                   (try? other.workspace.validate()) != nil {
                    let keepRemote = (remote.savedAt, remote.deviceID) > (other.savedAt, other.deviceID)
                    try backup(keepRemote ? other : remote, in: folder)
                    if !keepRemote { remote = other }
                } else {
                    let copy = folder.appendingPathComponent("Cubic-conflict-\(UUID().uuidString).json")
                    try coordinatedWrite(copy) { try data.write(to: $0, options: .atomic) }
                }
                handled.append(version)
            }
            if !handled.isEmpty {
                let data = try JSONCoding.encode(remote)
                try coordinatedWrite(file) { try data.write(to: $0, options: .atomic) }
                for version in handled { version.isResolved = true; try? version.remove() }
            }
            return .document(remote)
        }
        catch let error as CoreError { throw error }
        catch { throw CoreError.blocked("同步目录中的 Cubic.json 无法读取，本机数据未改变。") }
    }
    private func coordinatedWrite(_ file: URL, _ body: (URL) throws -> Void) throws {
        var result: Result<Void, any Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &coordinationError) { url in
            result = Result { try body(url) }
        }
        if let coordinationError { throw coordinationError }
        try result!.get()
    }
}
