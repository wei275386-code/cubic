import Foundation
import CryptoKit

/// Access grants are local credentials and never belong in the remote workspace.
public protocol FileSyncDirectoryAccess: Sendable {
    func acquireAccess() async throws -> URL
    func releaseAccess(to directory: URL) async
}

public struct FileSyncWorkspaceMetadata: Codable, Sendable, Equatable {
    public let formatVersion: Int
    public let workspaceID: String
    public let remoteBindingID: String
    public var remoteBinding: RemoteBindingID { .file(remoteBindingID) }
    public init(workspaceID: String, remoteBindingID: String = UUID().uuidString) {
        self.formatVersion = 1; self.workspaceID = workspaceID; self.remoteBindingID = remoteBindingID
    }
    public func validate(workspaceID expected: String) throws {
        guard formatVersion == 1, UUID(uuidString: remoteBindingID) != nil else { throw SyncError.invalidJournal("文件同步目录 identity 格式无效") }
        guard workspaceID == expected else { throw SyncError.wrongWorkspace(workspaceID) }
    }
}

/// Shared by the app's explicit directory setup and the transport. Every provider read/write is coordinated.
public enum FileSyncDirectoryIO {
    public static let metadataFilename = "workspace.cubic-sync.json"
    public static func coordinatedRead<T>(at url: URL, _ body: (URL) throws -> T) throws -> T {
        var result: Result<T, any Error>?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { coordinated in
            result = Result { try body(coordinated) }
        }
        if let error { throw error }
        guard let result else { throw SyncError.transport("文件 Provider 未完成读取协调") }
        return try result.get()
    }
    public static func coordinatedWrite<T>(at url: URL, _ body: (URL) throws -> T) throws -> T {
        var result: Result<T, any Error>?
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &error) { coordinated in
            result = Result { try body(coordinated) }
        }
        if let error { throw error }
        guard let result else { throw SyncError.transport("文件 Provider 未完成写入协调") }
        return try result.get()
    }
    public static func readMetadata(in directory: URL, workspaceID: String) throws -> FileSyncWorkspaceMetadata {
        try coordinatedRead(at: directory.appendingPathComponent(metadataFilename)) { file in
            let metadata = try SyncCoding.decode(FileSyncWorkspaceMetadata.self, from: readRegularFile(file, maximumBytes: 65_536))
            try metadata.validate(workspaceID: workspaceID)
            return metadata
        }
    }
    public static func createMetadata(in directory: URL, workspaceID: String) throws -> FileSyncWorkspaceMetadata {
        let proposed = FileSyncWorkspaceMetadata(workspaceID: workspaceID)
        let data = try SyncCoding.encode(proposed)
        // Coordinate the containing directory: concurrent first-time setup may adopt the winner's immutable identity.
        return try coordinatedWrite(at: directory) { coordinated in
            let marker = coordinated.appendingPathComponent(metadataFilename)
            if FileManager.default.fileExists(atPath: marker.path) {
                let existing = try SyncCoding.decode(FileSyncWorkspaceMetadata.self, from: readRegularFile(marker, maximumBytes: 65_536))
                try existing.validate(workspaceID: workspaceID)
                return existing
            }
            try writeImmutableData(data, to: marker)
            try FileManager.default.createDirectory(at: coordinated.appendingPathComponent("revisions"), withIntermediateDirectories: true)
            let saved = try SyncCoding.decode(FileSyncWorkspaceMetadata.self, from: readRegularFile(marker, maximumBytes: 65_536))
            guard saved == proposed else { throw SyncError.identityCollision("workspace metadata") }
            return saved
        }
    }
    static func readRegularFile(_ file: URL, maximumBytes: Int) throws -> Data {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw SyncError.transport("同步目录包含不安全的文件链接：\(file.lastPathComponent)") }
        guard let size = values.fileSize, size > 0, size <= maximumBytes else { throw SyncError.invalidJournal("文件大小超出同步预算：\(file.lastPathComponent)") }
        let data = try Data(contentsOf: file)
        guard data.count <= maximumBytes else { throw SyncError.invalidJournal("revision byte budget") }
        return data
    }
    /// Stage under an ignored name, then rename within the provider directory. Never expose a partial final file.
    static func writeImmutableData(_ data: Data, to destination: URL) throws {
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".cubic-upload-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        try data.write(to: staging, options: .atomic)
        guard try Data(contentsOf: staging) == data else { throw SyncError.transport("Provider 暂存文件校验失败") }
        // FileManager move refuses an existing destination; it cannot replace another immutable operation.
        try FileManager.default.moveItem(at: staging, to: destination)
    }
}

private struct FileRevisionIndexEntry: Codable, Sendable {
    let id: String
    let operationDigest: String
    let bytes: Int
    let modifiedAt: Date?
}
private struct FileSyncScanCursor: Codable {
    var formatVersion = 1
    let binding: String
    var paths: [String]
    var offset = 0
    var previous: [String: FileRevisionIndexEntry]
    var scanned: [String: FileRevisionIndexEntry] = [:]
    var complete = false
    /// Durable recovery obligations travel with the same cursor commit that requeues journal history.
    /// Optional for compatibility with cursors written before missing-file recovery was tracked.
    var repairRequestedIDs: Set<String>?
    var completedProcessID: String?
}
private struct FileOperationIdentity: Encodable {
    let id: String
    let workspaceID: String
    let parents: [String]
    let createdAt: Date
    let changes: [SyncChange]
}

/// Immutable revisions are the only shared facts. A completed cursor starts a fresh full scan on the next cycle.
public actor FileProviderSyncTransport: SyncTransport {
    public nonisolated let requiresPostPushPull = false
    public let workspaceID: String
    public let remoteBindingID: RemoteBindingID
    private let access: any FileSyncDirectoryAccess
    private let limits: SyncLimits
    private var failure: String?
    private var confirmedUploads: Set<String> = []
    private let processID = UUID().uuidString
    /// An exact committed-cursor continuation can reuse decoded metadata. Older cursors always replay from disk bytes.
    private var returnedPageCache: (data: Data, scan: FileSyncScanCursor, operations: [String: String])?
    public init(access: any FileSyncDirectoryAccess, workspaceID: String, remoteBindingID: RemoteBindingID,
                pageSize: Int = 100, limits: SyncLimits = SyncLimits()) {
        self.access = access; self.workspaceID = workspaceID; self.remoteBindingID = remoteBindingID
        var bounded = limits; bounded.maximumRecordsPerPage = max(1, min(pageSize, limits.maximumRevisionCount))
        self.limits = bounded
    }
    public func availability() async throws -> SyncAvailability {
        try await withDirectory { directory in
            try verify(directory)
            return .available(remoteBindingID: remoteBindingID)
        }
    }
    public func pull(cursor: Data?) async throws -> SyncPullPage {
        try await withDirectory { directory in
            try verify(directory)
            var scan: FileSyncScanCursor
            var operations: [String: String] = [:]
            var reusingIndex = false
            if let cursor {
                guard cursor.count <= limits.maximumJournalBytes else { throw SyncError.invalidJournal("file scan cursor budget") }
                if let cached = returnedPageCache, cursor == cached.data {
                    scan = cached.scan; operations = cached.operations; reusingIndex = true
                    // Release cached dictionary owners before page mutation to preserve copy-on-write uniqueness.
                    returnedPageCache = nil
                } else {
                    returnedPageCache = nil
                    scan = try SyncCoding.decode(FileSyncScanCursor.self, from: cursor)
                }
                guard scan.formatVersion == 1, scan.binding == remoteBindingID.rawValue,
                      scan.paths.count <= limits.maximumRevisionCount, scan.offset >= 0, scan.offset <= scan.paths.count else {
                    throw SyncError.invalidJournal("file scan cursor identity/budget")
                }
                if scan.complete {
                    scan = FileSyncScanCursor(binding: remoteBindingID.rawValue, paths: try revisionPaths(in: directory), previous: scan.scanned,
                        repairRequestedIDs: scan.repairRequestedIDs, completedProcessID: scan.completedProcessID)
                    operations.removeAll(keepingCapacity: true); reusingIndex = false
                }
            } else {
                returnedPageCache = nil
                scan = FileSyncScanCursor(binding: remoteBindingID.rawValue, paths: try revisionPaths(in: directory), previous: [:])
            }
            var revisions: [SyncRevision] = [], bytes = 0, processed = 0
            // Only metadata for the directory is resident; payloads are read one at a time under byte budgets.
            if !reusingIndex {
                for entry in scan.previous.values { operations[entry.id] = entry.operationDigest }
                for entry in scan.scanned.values { operations[entry.id] = entry.operationDigest }
            }
            while scan.offset < scan.paths.count && processed < limits.maximumRecordsPerPage {
                try Task.checkCancellation()
                let path = scan.paths[scan.offset]
                guard safeRelativePath(path) else { throw SyncError.invalidJournal("unsafe file cursor path") }
                let file = directory.appendingPathComponent("revisions").appendingPathComponent(path)
                let pair: (FileRevisionIndexEntry, SyncRevision?)
                do { pair = try FileSyncDirectoryIO.coordinatedRead(at: file) { coordinated in
                    let attributes = try coordinated.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
                    guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw SyncError.transport("同步 revision 不是普通文件") }
                    let size = attributes.fileSize ?? 0
                    guard size > 0, size <= limits.maximumRevisionBytes else { throw SyncError.invalidJournal("revision byte budget") }
                    // A known immutable file can skip payload downloading. New paths/conflict copies are always decoded.
                    if let known = scan.previous[path], known.bytes == size, known.modifiedAt != nil,
                       known.modifiedAt == attributes.contentModificationDate {
                        return (known, nil)
                    }
                    let revision = try SyncCoding.decode(SyncRevision.self, from: FileSyncDirectoryIO.readRegularFile(coordinated, maximumBytes: limits.maximumRevisionBytes))
                    try SyncCausalFrontier.validate(revision, workspaceID: workspaceID)
                    let identity = FileOperationIdentity(id: revision.id, workspaceID: revision.workspaceID, parents: revision.parents.sorted(),
                        createdAt: revision.createdAt, changes: revision.changes.sorted { $0.path < $1.path })
                    let digest = Self.hexDigest(SHA256.hash(data: try SyncCoding.encode(identity)))
                    return (FileRevisionIndexEntry(id: revision.id, operationDigest: digest, bytes: size, modifiedAt: attributes.contentModificationDate), revision.delta)
                } } catch {
                    let failure = error as NSError
                    if failure.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code)
                        || failure.domain == NSPOSIXErrorDomain && failure.code == 2 {
                        // A disappearing file is not a deletion fact. Finish the scan, then requeue complete local history.
                        scan.offset += 1; processed += 1; continue
                    }
                    throw error
                }
                if let previousDigest = operations[pair.0.id], previousDigest != pair.0.operationDigest { throw SyncError.identityCollision(pair.0.id) }
                if pair.1 != nil && !revisions.isEmpty && bytes + pair.0.bytes > limits.transferBatchBytes { break }
                operations[pair.0.id] = pair.0.operationDigest
                scan.scanned[path] = pair.0; scan.offset += 1; processed += 1
                if let revision = pair.1 { revisions.append(revision); bytes += pair.0.bytes }
            }
            scan.complete = scan.offset == scan.paths.count
            var reconcile = false
            if scan.complete {
                let seenIDs = Set(scan.scanned.values.map(\.id))
                let requested = scan.repairRequestedIDs ?? []
                let expected = Set(scan.previous.values.map(\.id)).union(confirmedUploads).union(requested)
                let missing = expected.subtracting(seenIDs)
                // Repeated scans of the SAME missing history must not reset a bounded push's progress.
                // The cursor and journal pending set are committed together by ingest, so a failed commit retries the request.
                reconcile = !missing.subtracting(requested).isEmpty
                    || (scan.completedProcessID != processID && requested.isEmpty)
                scan.repairRequestedIDs = requested.subtracting(seenIDs).union(missing)
                scan.completedProcessID = processID
                confirmedUploads.formUnion(seenIDs)
            }
            // Local scan cursors have no immutable operation identity; canonical sorted-key JSON is unnecessary here.
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .deferredToDate
            let encoded = try encoder.encode(scan)
            returnedPageCache = (encoded, scan, operations)
            return SyncPullPage(revisions: revisions, cursor: encoded, hasMore: !scan.complete,
                needsFullReconciliation: reconcile, fullReconciliationAt: scan.complete ? Date() : nil)
        }
    }
    public func push(_ revisions: [SyncRevision]) async throws -> Set<String> {
        failure = nil
        return try await withDirectory { directory in
            try verify(directory)
            var acknowledged: Set<String> = []
            for revision in revisions {
                try Task.checkCancellation()
                do {
                    try SyncCausalFrontier.validate(revision, workspaceID: workspaceID)
                    guard safeRevisionID(revision.id) else { throw SyncError.invalidJournal("unsafe revision ID") }
                    let data = try SyncCoding.encode(revision.delta)
                    guard data.count <= limits.maximumRevisionBytes else { throw SyncError.invalidJournal("revision byte budget") }
                    let shard = String(Self.hexDigest(SHA256.hash(data: Data(revision.id.utf8))).prefix(2))
                    let parent = directory.appendingPathComponent("revisions").appendingPathComponent(shard)
                    try FileSyncDirectoryIO.coordinatedWrite(at: directory) { root in
                        let shardDirectory = root.appendingPathComponent("revisions").appendingPathComponent(shard)
                        if FileManager.default.fileExists(atPath: shardDirectory.path) {
                            let values = try shardDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                            guard values.isDirectory == true, values.isSymbolicLink != true else { throw SyncError.transport("revision 分片目录不是普通目录") }
                        } else {
                            try FileManager.default.createDirectory(at: shardDirectory, withIntermediateDirectories: true)
                        }
                    }
                    let destination = parent.appendingPathComponent(revision.id + ".revision")
                    try FileSyncDirectoryIO.coordinatedWrite(at: parent) { coordinatedParent in
                        let file = coordinatedParent.appendingPathComponent(destination.lastPathComponent)
                        if !FileManager.default.fileExists(atPath: file.path) {
                            try FileSyncDirectoryIO.writeImmutableData(data, to: file)
                        }
                        let saved = try SyncCoding.decode(SyncRevision.self, from: FileSyncDirectoryIO.readRegularFile(file, maximumBytes: limits.maximumRevisionBytes))
                        guard saved.hasSameOperation(as: revision) else { throw SyncError.identityCollision(revision.id) }
                    }
                    // Read again through provider coordination; an interrupted/partial write cannot be acknowledged.
                    try FileSyncDirectoryIO.coordinatedRead(at: destination) { file in
                        let saved = try SyncCoding.decode(SyncRevision.self, from: FileSyncDirectoryIO.readRegularFile(file, maximumBytes: limits.maximumRevisionBytes))
                        guard saved.hasSameOperation(as: revision) else { throw SyncError.identityCollision(revision.id) }
                    }
                    acknowledged.insert(revision.id); confirmedUploads.insert(revision.id)
                } catch {
                    failure = String(describing: error)
                    // Return prior acknowledgements even for collisions; coordinator commits these before reporting failure.
                    break
                }
            }
            return acknowledged
        }
    }
    public func pushFailureDescription() async -> String? { failure }
    private func verify(_ directory: URL) throws {
        try FileSyncDirectoryIO.coordinatedRead(at: directory) { root in
            let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { throw SyncError.transport("同步目录不是普通目录") }
            let revisions = root.appendingPathComponent("revisions")
            if FileManager.default.fileExists(atPath: revisions.path) {
                let values = try revisions.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { throw SyncError.transport("revision 目录包含不安全的链接") }
            }
        }
        let identity = try FileSyncDirectoryIO.readMetadata(in: directory, workspaceID: workspaceID)
        guard identity.remoteBinding == remoteBindingID else { throw SyncError.accountChanged }
    }
    private func revisionPaths(in directory: URL) throws -> [String] {
        try FileSyncDirectoryIO.coordinatedRead(at: directory) { root in
            let revisions = root.appendingPathComponent("revisions")
            guard FileManager.default.fileExists(atPath: revisions.path) else { return [] }
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
            var paths: [String] = []
            for entry in try FileManager.default.contentsOfDirectory(at: revisions, includingPropertiesForKeys: keys) {
                let attributes = try entry.resourceValues(forKeys: Set(keys))
                guard attributes.isSymbolicLink != true else { throw SyncError.transport("同步目录包含文件链接") }
                if attributes.isDirectory == true {
                    for file in try FileManager.default.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil) where file.lastPathComponent.contains(".revision") {
                        paths.append(entry.lastPathComponent + "/" + file.lastPathComponent)
                    }
                } else if entry.lastPathComponent.contains(".revision") { paths.append(entry.lastPathComponent) }
                guard paths.count <= limits.maximumRevisionCount else { throw SyncError.invalidJournal("revision count budget") }
            }
            return paths.sorted()
        }
    }
    private func safeRelativePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return (1...2).contains(parts.count) && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") }
    }
    private static func hexDigest(_ digest: SHA256.Digest) -> String {
        let alphabet = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []; bytes.reserveCapacity(64)
        for byte in digest {
            bytes.append(alphabet[Int(byte >> 4)]); bytes.append(alphabet[Int(byte & 15)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
    private func safeRevisionID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 200 && !id.contains("/") && !id.contains("\\") && id != "." && id != ".."
            && !id.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    private func withDirectory<T: Sendable>(_ body: (URL) throws -> T) async throws -> T {
        let directory = try await access.acquireAccess()
        do { let value = try body(directory); await access.releaseAccess(to: directory); return value }
        catch { await access.releaseAccess(to: directory); throw error }
    }
}

/// The local journal remains active when the user disconnects its remote transport.
public struct LocalOnlySyncTransport: SyncTransport {
    public init() {}
    public func availability() async throws -> SyncAvailability { .requiresAccount("当前仅保存在本机。") }
    public func pull(cursor: Data?) async throws -> SyncPullPage { SyncPullPage(revisions: [], cursor: cursor, hasMore: false) }
    public func push(_ revisions: [SyncRevision]) async throws -> Set<String> { [] }
}
