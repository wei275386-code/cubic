import Foundation
import CloudKit
import CryptoKit
import CubicCore

/// Real private CloudKit transport; container construction happens ONLY after signed-entitlement verification.
/// One adapter is permanently scoped to one account + workspace, never rebound after account switching.
private struct CloudSyncPendingAsset: Codable {
    let id: String
    let bytes: Int?
}
private struct CloudSyncCursor: Codable {
    let formatVersion: Int
    let token: Data?
    var remaining: [CloudSyncPendingAsset]
    let remoteHasMore: Bool
}

actor CloudSyncAdapter: SyncTransport {
    let containerID: String
    let accountID: String
    let workspaceID: String
    private let zoneName: String
    private let subscribeToPush: Bool
    private var container: CKContainer?
    private var prepared = false
    private var retryAfter: Date?
    private var subscriptionError: String?
    private var pushErrors: [String] = []
    private let limits: SyncLimits
    init(containerID: String, accountID: String, workspaceID: String, subscribeToPush: Bool = false, limits: SyncLimits = SyncLimits()) {
        self.containerID = containerID; self.accountID = accountID; self.workspaceID = workspaceID
        self.zoneName = "Cubic-" + Self.digest(Data(workspaceID.utf8))
        self.subscribeToPush = subscribeToPush; self.limits = limits
    }
    func availability() async throws -> SyncAvailability {
        guard ReleaseCapabilities.cloudKitEnabled else { return .requiresSigning(ReleaseCapabilities.cloudKitUnavailableMessage) }
        if let reason = CloudSyncEntitlements.requirement(containerID: containerID) { return .requiresSigning(reason) }
        let c = signedContainer()
        do {
            let status = try await c.accountStatus()
            guard status == .available else { return .requiresAccount("iCloud accountStatus=\(status.rawValue)，本地 journal 保留。") }
            let current = try await c.userRecordID().recordName
            if current != accountID { prepared = false }
            return .available(accountID: current)
        } catch { remember(error); throw error }
    }
    func pull(cursor: Data?) async throws -> SyncPullPage {
        let database = try await checkedDatabase()
        try await prepare(database)
        var page: CloudSyncCursor
        if let cursor, let wrapped = try? SyncCoding.decode(CloudSyncCursor.self, from: cursor) {
            guard wrapped.formatVersion == 1, wrapped.remaining.count <= limits.maximumRecordsPerPage else { throw SyncError.invalidJournal("CloudKit cursor") }
            page = wrapped
        } else { page = CloudSyncCursor(formatVersion: 1, token: cursor, remaining: [], remoteHasMore: false) }
        var reconciliation = false
        do {
            if page.remaining.isEmpty {
                let token = try decodeToken(page.token)
                // Fetch headers only. CKAsset is intentionally absent from desiredKeys so a 50-record
                // metadata page cannot eagerly download 50 full payloads before byte budgeting.
                let changes: (modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, any Error>],
                              deletions: [CKDatabase.RecordZoneChange.Deletion], changeToken: CKServerChangeToken, moreComing: Bool)
                do {
                    changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token,
                        desiredKeys: Self.headerKeys, resultsLimit: limits.maximumRecordsPerPage)
                } catch let error as CKError where error.code == .changeTokenExpired {
                    reconciliation = true
                    changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: nil,
                        desiredKeys: Self.headerKeys, resultsLimit: limits.maximumRecordsPerPage)
                }
                try await verifyAccount()
                guard changes.deletions.isEmpty else { throw SyncError.transport("CloudKit immutable revision 被删除；本地事实保留，需恢复远端 zone。") }
                let remaining = try changes.modificationResultsByID.sorted { $0.key.recordName < $1.key.recordName }.map { id, result in
                    let record = try result.get().record
                    try checkHeader(record, expectedID: id.recordName)
                    let bytes = (record["payloadBytes"] as? NSNumber)?.intValue
                    if let bytes, bytes <= 0 || bytes > limits.maximumRevisionBytes { throw SyncError.invalidJournal("CloudKit payload byte budget") }
                    return CloudSyncPendingAsset(id: id.recordName, bytes: bytes)
                }
                page = CloudSyncCursor(formatVersion: 1,
                    token: try NSKeyedArchiver.archivedData(withRootObject: changes.changeToken, requiringSecureCoding: true),
                    remaining: remaining, remoteHasMore: changes.moreComing)
            }
            var selected: [CloudSyncPendingAsset] = [], total = 0
            for entry in page.remaining {
                // Legacy headers lack bytes: fetch one bounded-check record, never a 100-asset batch.
                let estimate = entry.bytes ?? limits.maximumRevisionBytes
                if !selected.isEmpty && (total + estimate > limits.transferBatchBytes || selected.count >= limits.maximumRecordsPerPage) { break }
                selected.append(entry); total += estimate
            }
            var revisions: [SyncRevision] = []
            if !selected.isEmpty {
                let records = try await database.records(for: selected.map { CKRecord.ID(recordName: $0.id, zoneID: zoneID) })
                try await verifyAccount()
                for entry in selected {
                    let id = CKRecord.ID(recordName: entry.id, zoneID: zoneID)
                    guard let result = records[id] else { throw SyncError.transport("CloudKit asset page omitted \(entry.id)") }
                    revisions.append(try read(result.get(), expectedID: entry.id))
                }
            }
            page.remaining.removeFirst(selected.count)
            // Cursor persists the unconsumed ID page. A failed asset fetch advances neither offset
            // nor server token in the journal; next refresh safely replays the same page.
            return SyncPullPage(revisions: revisions, cursor: try SyncCoding.encode(page),
                hasMore: !page.remaining.isEmpty || page.remoteHasMore, needsFullReconciliation: reconciliation)
        } catch { remember(error); throw error }
    }
    func push(_ revisions: [SyncRevision]) async throws -> Set<String> {
        pushErrors = []
        guard !revisions.isEmpty else { return [] }
        guard revisions.count <= limits.maximumRecordsPerPage, Set(revisions.map(\.id)).count == revisions.count, revisions.allSatisfy({ $0.workspaceID == workspaceID }) else { throw SyncError.wrongWorkspace(workspaceID) }
        let payloads = try Dictionary(uniqueKeysWithValues: revisions.map { revision in
            let delta = SyncRevision(id: revision.id, workspaceID: revision.workspaceID, deviceID: revision.deviceID,
                parents: revision.parents, createdAt: revision.createdAt, changes: revision.changes)
            let data = try SyncCoding.encode(delta)
            guard data.count <= limits.maximumRevisionBytes else { throw SyncError.invalidJournal("CloudKit revision byte budget") }
            return (revision.id, data)
        })
        guard payloads.count == revisions.count,
              revisions.count == 1 || payloads.values.reduce(0, { $0 + $1.count }) <= limits.transferBatchBytes else { throw SyncError.invalidJournal("CloudKit push byte budget") }
        let database = try await checkedDatabase()
        try await prepare(database)
        var acknowledged = Set<String>(), saving: [CKRecord] = [], temporaryFiles: [URL] = []
        defer { for file in temporaryFiles { try? FileManager.default.removeItem(at: file) } }
        do {
            // Preflight makes timeout retries idempotent and never overwrites an existing immutable record.
            let ids = revisions.map { CKRecord.ID(recordName: $0.id, zoneID: zoneID) }
            let existing = try await database.records(for: ids, desiredKeys: Self.headerKeys)
            try await verifyAccount()
            for revision in revisions {
                let id = CKRecord.ID(recordName: revision.id, zoneID: zoneID)
                guard let result = existing[id] else { throw SyncError.transport("CloudKit preflight omitted \(revision.id)") }
                switch result {
                case .success(let record):
                    try checkHeader(record, expectedID: revision.id)
                    if let hash = record["operationHash"] as? String {
                        guard hash == (try operationHash(revision)) else { throw SyncError.identityCollision(revision.id) }
                    } else {
                        // Legacy immutable record: verify once, fetching a single asset only.
                        let full = try await database.record(for: id)
                        try await verifyAccount()
                        guard try read(full, expectedID: revision.id).hasSameOperation(as: revision) else { throw SyncError.identityCollision(revision.id) }
                    }
                    acknowledged.insert(revision.id)
                case .failure(let error):
                    guard (error as? CKError)?.code == .unknownItem else { throw error }
                    let data = payloads[revision.id]!
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent("cloudsync-\(UUID().uuidString).json")
                    try data.write(to: file, options: .atomic); temporaryFiles.append(file)
                    let record = CKRecord(recordType: "CubicRevision", recordID: id)
                    record["workspaceID"] = workspaceID as CKRecordValue
                    record["revisionID"] = revision.id as CKRecordValue
                    record["payloadHash"] = Self.digest(data) as CKRecordValue
                    record["payloadBytes"] = NSNumber(value: data.count)
                    record["operationHash"] = try operationHash(revision) as CKRecordValue
                    record["payload"] = CKAsset(fileURL: file)
                    saving.append(record)
                }
            }
            if !saving.isEmpty {
                try await verifyAccount()
                let results = try await database.modifyRecords(saving: saving, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
                try await verifyAccount()
                for (id, result) in results.saveResults {
                    switch result {
                    case .success: acknowledged.insert(id.recordName)
                    case .failure(let error):
                        if let ck = error as? CKError, ck.code == .serverRecordChanged,
                           let server = ck.serverRecord,
                           let original = revisions.first(where: { $0.id == id.recordName }),
                           try read(server, expectedID: id.recordName).hasSameOperation(as: original) {
                            acknowledged.insert(id.recordName)
                        } else {
                            if let ck = error as? CKError, ck.code == .serverRecordChanged { throw SyncError.identityCollision(id.recordName) }
                            pushErrors.append("\(id.recordName): \(error)"); remember(error)
                        }
                    }
                }
            }
            return acknowledged
        } catch { remember(error); throw error }
    }
    func pushSubscriptionError() -> String? { subscriptionError }
    func pushFailureDescription() -> String? { pushErrors.isEmpty ? nil : pushErrors.joined(separator: "\n") }
    private var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName) }
    private func signedContainer() -> CKContainer {
        if let container { return container }
        // Only availability(), after entitlement validation, calls this initializer.
        let value = CKContainer(identifier: containerID); container = value; return value
    }
    private func checkedDatabase() async throws -> CKDatabase {
        if let retryAfter, retryAfter > Date() { throw SyncError.transport("CloudKit 要求稍后重试：\(retryAfter)") }
        try await verifyAccount()
        guard let container else { throw SyncError.requiresSigning("CloudKit container unavailable") }
        return container.privateCloudDatabase
    }
    private func verifyAccount() async throws {
        switch try await availability() {
        case .available(let current): guard current == accountID else { throw SyncError.accountChanged }
        case .requiresSigning(let message): throw SyncError.requiresSigning(message)
        case .requiresAccount(let message): throw SyncError.accountUnavailable(message)
        }
    }
    private func prepare(_ database: CKDatabase) async throws {
        guard !prepared else { return }
        do {
            let result = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
            guard let saved = result.saveResults[zoneID] else { throw SyncError.transport("CloudKit zone omitted") }
            _ = try saved.get(); try await verifyAccount()
            if subscribeToPush {
                do {
                    let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: zoneName + "-changes")
                    let info = CKSubscription.NotificationInfo(); info.shouldSendContentAvailable = true
                    subscription.notificationInfo = info
                    _ = try await database.save(subscription)
                    try await verifyAccount(); subscriptionError = nil
                } catch { subscriptionError = String(describing: error); remember(error) }
            }
            prepared = true
        } catch { remember(error); throw error }
    }
    private static let headerKeys = ["workspaceID", "revisionID", "payloadHash", "payloadBytes", "operationHash"]
    private func decodeToken(_ data: Data?) throws -> CKServerChangeToken? {
        guard let data else { return nil }
        guard let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data) else { throw SyncError.invalidJournal("CloudKit change token") }
        return token
    }
    private func operationHash(_ revision: SyncRevision) throws -> String {
        Self.digest(try SyncCoding.encode(SyncArchiveRevision(id: revision.id, parents: revision.parents,
            createdAt: revision.createdAt, changes: revision.changes)))
    }
    private func checkHeader(_ record: CKRecord, expectedID: String) throws {
        guard record.recordType == "CubicRevision", record["workspaceID"] as? String == workspaceID,
              record["revisionID"] as? String == expectedID else { throw SyncError.invalidJournal("CloudKit record header") }
    }
    private func read(_ record: CKRecord, expectedID: String) throws -> SyncRevision {
        try checkHeader(record, expectedID: expectedID)
        guard let asset = record["payload"] as? CKAsset, let file = asset.fileURL else { throw SyncError.invalidJournal("CloudKit asset") }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= limits.maximumRevisionBytes else { throw SyncError.invalidJournal("CloudKit asset byte budget") }
        let data = try Data(contentsOf: file)
        guard record["payloadHash"] as? String == Self.digest(data),
              (record["payloadBytes"] as? NSNumber).map({ $0.intValue == data.count }) ?? true else { throw SyncError.invalidJournal("CloudKit payload hash/length mismatch") }
        // Skip legacy Workspace decoding just as the journal loader does. Operation changes are
        // complete across the retained parent chain, and format 2 is the new transport representation.
        let revision = try SyncCoding.decode(CloudSyncOperationEnvelope.self, from: data).revision
        guard revision.id == expectedID, revision.workspaceID == workspaceID else { throw SyncError.identityCollision(expectedID) }
        if let hash = record["operationHash"] as? String, hash != (try operationHash(revision)) { throw SyncError.identityCollision(expectedID) }
        return revision
    }
    private func remember(_ error: any Error) {
        if let ck = error as? CKError, let interval = ck.retryAfterSeconds {
            retryAfter = Date().addingTimeInterval(max(1, interval))
        }
        if let ck = error as? CKError, [.zoneNotFound, .userDeletedZone, .notAuthenticated].contains(ck.code) { prepared = false }
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// No legacy snapshots are materialized during CloudKit import.
private struct CloudSyncOperationEnvelope: Decodable {
    let formatVersion: Int
    let id: String
    let workspaceID: String
    let deviceID: String
    let parents: [String]
    let createdAt: Date
    let changes: [SyncChange]
    var revision: SyncRevision {
        get throws {
            guard [1, 2].contains(formatVersion) else { throw SyncError.invalidJournal("CloudKit revision format") }
            return SyncRevision(id: id, workspaceID: workspaceID, deviceID: deviceID, parents: parents, createdAt: createdAt, changes: changes)
        }
    }
}
