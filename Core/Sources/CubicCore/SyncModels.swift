import Foundation

/// JSON-preserving values allow additive Domain fields without changing the sync schema.
public enum SyncValue: Codable, Sendable, Equatable {
    case object([String: SyncValue]), array([SyncValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: SyncValue].self) { self = .object(v) }
        else { self = .array(try c.decode([SyncValue].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    var object: [String: SyncValue]? { if case .object(let v) = self { v } else { nil } }
    var string: String? { if case .string(let v) = self { v } else { nil } }
}

public struct SyncPath: Codable, Hashable, Sendable, Comparable {
    public let collection: String
    public let entityID: String
    public let field: String
    public init(collection: String, entityID: String, field: String) {
        self.collection = collection; self.entityID = entityID; self.field = field
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.collection != rhs.collection { return lhs.collection < rhs.collection }
        if lhs.entityID != rhs.entityID { return lhs.entityID < rhs.entityID }
        return lhs.field < rhs.field
    }
}
public struct SyncChange: Codable, Sendable, Equatable {
    public let path: SyncPath
    public let value: SyncValue
    public init(path: SyncPath, value: SyncValue) { self.path = path; self.value = value }
}

/// Format 1 decodes legacy snapshots. Format 2 persists only operations and causal parents.
public struct SyncRevision: Codable, Sendable, Equatable, Identifiable {
    public let formatVersion: Int
    public let id: String
    public let workspaceID: String
    public let deviceID: String
    public let parents: [String]
    public let createdAt: Date
    /// Legacy snapshot only. For format 2 use journal.materialize(revisionID:) instead.
    public let immutableWorkspace: Workspace
    public let currentChoiceID: String?
    public let changes: [SyncChange]
    public init(id: String = UUID().uuidString, workspaceID: String, deviceID: String,
                parents: [String], createdAt: Date = Date(), immutableWorkspace: Workspace,
                currentChoiceID: String?, changes: [SyncChange]) {
        self.formatVersion = 1; self.id = id; self.workspaceID = workspaceID; self.deviceID = deviceID
        self.parents = parents.sorted(); self.createdAt = createdAt; self.immutableWorkspace = immutableWorkspace
        self.currentChoiceID = currentChoiceID; self.changes = changes.sorted { $0.path < $1.path }
    }
    public init(id: String = UUID().uuidString, workspaceID: String, deviceID: String,
                parents: [String], createdAt: Date = Date(), changes: [SyncChange]) {
        self.formatVersion = 2; self.id = id; self.workspaceID = workspaceID; self.deviceID = deviceID
        self.parents = parents.sorted(); self.createdAt = createdAt; self.immutableWorkspace = .empty
        self.currentChoiceID = changes.first { $0.path == SyncDocument.choice }?.value.string
        self.changes = changes.sorted { $0.path < $1.path }
    }
    private enum CodingKeys: String, CodingKey {
        case formatVersion, id, workspaceID, deviceID, parents, createdAt, immutableWorkspace, currentChoiceID, changes
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        guard [1, 2].contains(formatVersion) else { throw SyncError.invalidJournal("revision format") }
        id = try c.decode(String.self, forKey: .id); workspaceID = try c.decode(String.self, forKey: .workspaceID)
        deviceID = try c.decode(String.self, forKey: .deviceID); parents = try c.decode([String].self, forKey: .parents)
        createdAt = try c.decode(Date.self, forKey: .createdAt); changes = try c.decode([SyncChange].self, forKey: .changes)
        currentChoiceID = formatVersion == 1 ? try c.decodeIfPresent(String.self, forKey: .currentChoiceID) : changes.first { $0.path == SyncDocument.choice }?.value.string
        immutableWorkspace = formatVersion == 1 ? try c.decode(Workspace.self, forKey: .immutableWorkspace) : .empty
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(formatVersion, forKey: .formatVersion); try c.encode(id, forKey: .id)
        try c.encode(workspaceID, forKey: .workspaceID); try c.encode(deviceID, forKey: .deviceID)
        try c.encode(parents, forKey: .parents); try c.encode(createdAt, forKey: .createdAt)
        try c.encode(changes, forKey: .changes)
        if formatVersion == 1 {
            try c.encode(immutableWorkspace, forKey: .immutableWorkspace)
            try c.encodeIfPresent(currentChoiceID, forKey: .currentChoiceID)
        }
    }
    /// Wire-version/snapshot/author configuration do not change the immutable operation identity.
    public func hasSameOperation(as other: SyncRevision) -> Bool {
        id == other.id && workspaceID == other.workspaceID && parents.sorted() == other.parents.sorted()
            && createdAt == other.createdAt && changes.sorted { $0.path < $1.path } == other.changes.sorted { $0.path < $1.path }
    }
    var delta: SyncRevision {
        SyncRevision(id: id, workspaceID: workspaceID, deviceID: deviceID, parents: parents, createdAt: createdAt, changes: changes)
    }
}

/// Budget failures never acknowledge/drop facts. Limits can be raised explicitly for large restores.
public struct SyncLimits: Sendable {
    public var maximumRevisionBytes = 32 * 1024 * 1024
    public var transferBatchBytes = 16 * 1024 * 1024
    public var maximumRecordsPerPage = 50
    public var maximumJournalBytes = 512 * 1024 * 1024
    public var maximumArchiveBytes = 256 * 1024 * 1024
    public var maximumRevisionCount = 100_000
    public init() {}
}

/// Backup entries deliberately contain no device, account, cursor or upload identity/configuration.
public struct SyncArchiveRevision: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let parents: [String]
    public let createdAt: Date
    public let changes: [SyncChange]
    public init(id: String, parents: [String], createdAt: Date, changes: [SyncChange]) {
        self.id = id; self.parents = parents.sorted(); self.createdAt = createdAt
        self.changes = changes.sorted { $0.path < $1.path }
    }
}
public struct SyncArchive: Codable, Sendable, Equatable {
    public let formatVersion: Int
    public let workspaceID: String
    public let revisions: [SyncArchiveRevision]
    /// Declared unresolved frontier: missing parents are legal only when explicitly represented here.
    public let stagedRevisionIDs: [String]
    public let missingParentIDs: [String]
    public init(workspaceID: String, revisions: [SyncArchiveRevision], stagedRevisionIDs: [String] = [], missingParentIDs: [String] = []) {
        formatVersion = 1; self.workspaceID = workspaceID; self.revisions = revisions.sorted { $0.id < $1.id }
        self.stagedRevisionIDs = stagedRevisionIDs.sorted(); self.missingParentIDs = missingParentIDs.sorted()
    }
}

public enum SyncConflictKind: String, Codable, Sendable {
    case concurrentValue, deletionReference, dependencyCycle, semanticRecord, invariant
}
public struct SyncCandidate: Codable, Sendable, Equatable {
    public let revisionID: String
    public let value: SyncValue
    public init(revisionID: String, value: SyncValue) { self.revisionID = revisionID; self.value = value }
}
public struct SyncConflict: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: SyncConflictKind
    public let paths: [SyncPath]
    public let candidates: [SyncCandidate]
    public let affectedItemIDs: [String]
    public let message: String
    public init(kind: SyncConflictKind, paths: [SyncPath], candidates: [SyncCandidate],
                affectedItemIDs: [String] = [], message: String) {
        self.kind = kind; self.paths = paths.sorted(); self.candidates = candidates.sorted { $0.revisionID < $1.revisionID }
        self.affectedItemIDs = affectedItemIDs.sorted(); self.message = message
        // Length-delimited JSON prevents user IDs containing punctuation from aliasing conflict identities.
        self.id = (try? SyncCoding.encode([kind.rawValue] + self.paths.map {
            (try? SyncCoding.encode($0).base64EncodedString()) ?? ""
        } + self.candidates.map(\.revisionID)).base64EncodedString()) ?? UUID().uuidString
    }
}
public struct SyncMergeResult: Sendable {
    /// Portable app preferences use the same causal journal and transport as domain facts.
    /// Unresolved registers are omitted; callers retain their last confirmed setting.
    public let preferences: [String: SyncValue]
    /// Complete tentative factual view. Unresolved conflicts MUST be displayed alongside this view.
    public let workspace: Workspace
    /// Acyclic computation view; history/decisions remain in workspace and journal, never discarded.
    public let planningWorkspace: Workspace
    public let currentChoiceID: String?
    public let conflicts: [SyncConflict]
    public let pausedItemIDs: Set<String>
    public let quarantinedDependencyIDs: Set<String>
    public let quarantinedWorkLinkIDs: Set<String>
    public let quarantinedRecordPaths: Set<SyncPath>
    public let projectionReviewItemIDs: Set<String>
    public let heads: [String]
    /// False means even the computation view cannot satisfy current Domain validation.
    public let planningIsValid: Bool
    // Resident causal register index, shared with journal for incremental local append.
    let registers: [SyncPath: [SyncCandidate]]
    let rawValues: [SyncPath: SyncValue]
}
public enum SyncError: Error, Sendable, Equatable {
    case invalidJournal(String), identityCollision(String), missingParent(String), wrongWorkspace(String)
    case staleConflict(String), accountChanged, requiresSigning(String), accountUnavailable(String)
    case transport(String), persistence(String), unresolvedEdit(SyncPath)
}
/// Transport-independent identity. Legacy CloudKit account strings remain readable on disk.
public struct RemoteBindingID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func file(_ id: String) -> Self { Self(rawValue: "file:" + id) }
    public static func cloudKit(_ id: String) -> Self { Self(rawValue: "cloudkit:" + id) }
}
public enum SyncPhase: String, Codable, Sendable { case localOnly, pending, syncing, synced, failed, requiresSigning, requiresAccount, accountChanged, conflict }
public struct SyncStatus: Sendable {
    public var phase: SyncPhase
    public var pendingCount: Int
    public var conflicts: [SyncConflict]
    public var stagedCount: Int
    public var missingParentIDs: [String]
    public var planningIsValid: Bool
    public var lastSuccessfulSync: Date?
    public var lastFullReconciliation: Date?
    public var remoteDataAt: Date?
    public var message: String?
    public init(phase: SyncPhase = .localOnly, pendingCount: Int = 0, conflicts: [SyncConflict] = [],
                lastSuccessfulSync: Date? = nil, remoteDataAt: Date? = nil, message: String? = nil,
                stagedCount: Int = 0, missingParentIDs: [String] = [], planningIsValid: Bool = true,
                lastFullReconciliation: Date? = nil) {
        self.phase = phase; self.pendingCount = pendingCount; self.conflicts = conflicts
        self.lastSuccessfulSync = lastSuccessfulSync; self.remoteDataAt = remoteDataAt; self.message = message
        self.stagedCount = stagedCount; self.missingParentIDs = missingParentIDs.sorted(); self.planningIsValid = planningIsValid
        self.lastFullReconciliation = lastFullReconciliation
    }
}
public enum SyncAvailability: Sendable, Equatable {
    case available(accountID: String), requiresSigning(String), requiresAccount(String)
    public static func available(remoteBindingID: RemoteBindingID) -> Self { .available(accountID: remoteBindingID.rawValue) }
}
public struct SyncPullPage: Sendable {
    public let revisions: [SyncRevision]
    public let cursor: Data?
    public let hasMore: Bool
    public let needsFullReconciliation: Bool
    public let fullReconciliationAt: Date?
    public init(revisions: [SyncRevision], cursor: Data?, hasMore: Bool, needsFullReconciliation: Bool = false,
                fullReconciliationAt: Date? = nil) {
        self.revisions = revisions; self.cursor = cursor; self.hasMore = hasMore
        self.needsFullReconciliation = needsFullReconciliation
        self.fullReconciliationAt = fullReconciliationAt
    }
}
public protocol SyncTransport: Sendable {
    var requiresPostPushPull: Bool { get }
    func availability() async throws -> SyncAvailability
    func pull(cursor: Data?) async throws -> SyncPullPage
    /// Returns only independently verified successful immutable record IDs.
    func push(_ revisions: [SyncRevision]) async throws -> Set<String>
    func pushFailureDescription() async -> String?
}
extension SyncTransport {
    public var requiresPostPushPull: Bool { true }
    public func pushFailureDescription() async -> String? { nil }
}
public enum SyncCoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder(); e.dateEncodingStrategy = .deferredToDate; e.outputFormatting = [.sortedKeys]
        return try e.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let d = JSONDecoder(); d.dateDecodingStrategy = .deferredToDate; return try d.decode(type, from: data)
    }
}
