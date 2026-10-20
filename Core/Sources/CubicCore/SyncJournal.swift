import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Reject a second actor/process writer; no SQLITE schema changes or shared-workspace file edits.
private final class SyncJournalLease: @unchecked Sendable {
    let descriptor: Int32
    init(directory: URL) throws {
        let lock = directory.appendingPathComponent("journal.lock").path
        descriptor = open(lock, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw SyncError.persistence("journal lock open errno=\(errno)") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor); throw SyncError.persistence("journal already owned by another writer")
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

private struct SyncJournalState: Codable {
    var formatVersion = 1
    var workspaceID: String
    var deviceID: String
    var accountID: String?
    var pendingIDs: Set<String> = []
    var uploadedIDs: Set<String> = []
    var receivedIDs: Set<String> = []
    var cursor: Data?
    var lastSuccessfulSync: Date?
    var lastFullReconciliation: Date?
    var remoteDataAt: Date?
}

/// One actor owns one sidecar directory. Root must not create multiple writers for the same directory.
/// Revision files are immutable and individually atomic; manifest advances only after all files persist.
public actor SyncJournal {
    public let directory: URL
    public let workspaceID: String
    public let deviceID: String
    private let lease: SyncJournalLease
    private var state: SyncJournalState
    private var revisions: [String: SyncRevision]
    private var cached: SyncMergeResult?
    private var frontier: SyncCausalFrontier
    private let limits: SyncLimits
    private var byteCounts: [String: Int]
    private var pendingLocalCommit: (revision: SyncRevision, failure: SyncLocalCommitFailure)?
    public init(directory: URL, workspaceID: String, deviceID: String, limits: SyncLimits = SyncLimits()) throws {
        guard directory.isFileURL, !workspaceID.isEmpty, !deviceID.isEmpty else { throw SyncError.invalidJournal("directory/identity") }
        guard limits.maximumRevisionBytes > 0, limits.transferBatchBytes > 0,
              limits.maximumJournalBytes > 0, limits.maximumArchiveBytes > 0,
              limits.maximumRevisionCount > 0, limits.maximumRecordsPerPage > 0 else { throw SyncError.invalidJournal("limits") }
        self.directory = directory; self.workspaceID = workspaceID; self.deviceID = deviceID; self.limits = limits
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        lease = try SyncJournalLease(directory: directory)
        let manifest = directory.appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: manifest.path) {
            state = try SyncCoding.decode(SyncJournalState.self, from: Data(contentsOf: manifest))
            guard state.formatVersion == 1, state.workspaceID == workspaceID else { throw SyncError.wrongWorkspace(workspaceID) }
            // Device identity survives reinstall/reopen of a journal. Caller cannot reuse a foreign journal.
            guard state.deviceID == deviceID else { throw SyncError.invalidJournal("deviceID mismatch") }
        } else { state = SyncJournalState(workspaceID: workspaceID, deviceID: deviceID) }
        revisions = [:]; byteCounts = [:]
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "revision" {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= limits.maximumRevisionBytes else { throw SyncError.invalidJournal("revision byte budget: \(file.lastPathComponent)") }
            let envelope = try SyncCoding.decode(SyncOperationEnvelope.self, from: Data(contentsOf: file))
            guard [1, 2].contains(envelope.formatVersion) else { throw SyncError.invalidJournal("revision format") }
            let r = envelope.revision
            guard r.workspaceID == workspaceID else { throw SyncError.wrongWorkspace(r.workspaceID) }
            if let old = revisions[r.id], !old.hasSameOperation(as: r) { throw SyncError.identityCollision(r.id) }
            try SyncCausalFrontier.validate(r, workspaceID: workspaceID)
            if envelope.formatVersion == 1 {
                // One-time wire migration; the immutable operation (ID/parents/changes/date) is
                // unchanged. Future opens never scan/decode redundant historical snapshots.
                let delta = try SyncCoding.encode(r)
                guard delta.count <= limits.maximumRevisionBytes else { throw SyncError.invalidJournal("migrated delta byte budget") }
                try delta.write(to: file, options: .atomic); byteCounts[r.id] = delta.count
            } else { byteCounts[r.id] = size }
            revisions[r.id] = r
        }
        guard revisions.count <= limits.maximumRevisionCount,
              byteCounts.values.reduce(0, +) <= limits.maximumJournalBytes else { throw SyncError.invalidJournal("journal budget") }
        frontier = try SyncCausalFrontier(revisions, workspaceID: workspaceID)
        // Crash after revision-file commit but before manifest commit: recover local work into outbox.
        var recovered = state
        for r in revisions.values where r.deviceID == deviceID && !recovered.uploadedIDs.contains(r.id) && !recovered.receivedIDs.contains(r.id) {
            recovered.pendingIDs.insert(r.id)
        }
        let intentURL = directory.appendingPathComponent("restore-intent.json")
        if FileManager.default.fileExists(atPath: intentURL.path) {
            let ids = try SyncCoding.decode([String].self, from: Data(contentsOf: intentURL))
            let presentIDs = Set(revisions.keys)
            recovered.pendingIDs.formUnion(ids.filter { presentIDs.contains($0) })
            recovered.receivedIDs.formUnion(ids.filter { presentIDs.contains($0) })
        }
        state = recovered
        guard state.pendingIDs.isSubset(of: Set(revisions.keys)) else { throw SyncError.invalidJournal("manifest references missing revision") }
        try SyncCoding.encode(state).write(to: manifest, options: .atomic)
        try? FileManager.default.removeItem(at: intentURL)
    }
    public func snapshot() throws -> SyncMergeResult {
        try recoverOutstandingWrites()
        if let cached { return cached }
        let value = try SyncMerge.merge(revisions: frontier.closedIDs.compactMap { revisions[$0] }, workspaceID: workspaceID)
        cached = value; return value
    }
    public func bootstrap(workspace: Workspace, currentChoiceID: String? = nil) throws -> SyncMergeResult {
        guard frontier.closedIDs.isEmpty else { return try snapshot() }
        return try record(workspace: workspace, currentChoiceID: currentChoiceID)
    }
    public func record(workspace: Workspace, currentChoiceID: String?, expectedHeads: [String]? = nil) throws -> SyncMergeResult {
        try recoverOutstandingWrites()
        let prior = frontier.closedIDs.isEmpty ? nil : try snapshot()
        // No await in this actor boundary: verification and append cannot interleave with ingest.
        if let expectedHeads, Set(expectedHeads) != Set(prior?.heads ?? []) {
            throw CoreError.blocked("数据在准备期间已同步更新。请重新查看预览后保存，草稿仍保留。")
        }
        try workspace.validate()
        let changes: [SyncChange]
        if let prior { changes = try editChanges(workspace: workspace, currentChoiceID: currentChoiceID, prior: prior) }
        else { changes = SyncDocument.changes(from: nil, to: try SyncDocument(workspace, choice: currentChoiceID)) }
        if let prior {
            let blocked = Set(prior.conflicts.flatMap(\.paths))
            for change in changes where blocked.contains(change.path) { throw SyncError.unresolvedEdit(change.path) }
        }
        if changes.isEmpty { return try snapshot() }
        let r = SyncRevision(workspaceID: workspaceID, deviceID: deviceID, parents: prior?.heads ?? [],
            changes: changes)
        try appendLocal(r)
        return try snapshot()
    }
    /// A patch writes only explicitly edited settings. Domain saves never clear these registers.
    public func recordPreferences(_ values: [String: SyncValue]) throws -> SyncMergeResult {
        try recoverOutstandingWrites()
        let prior = try snapshot()
        let blocked = Set(prior.conflicts.flatMap(\.paths))
        let changes = try values.keys.sorted().compactMap { field -> SyncChange? in
            guard !field.isEmpty else { throw SyncError.invalidJournal("empty preference field") }
            let path = SyncDocument.preference(field), value = values[field]!
            guard !blocked.contains(path) else { throw SyncError.unresolvedEdit(path) }
            return prior.rawValues[path] == value ? nil : SyncChange(path: path, value: value)
        }
        guard !changes.isEmpty else { return prior }
        try appendLocal(SyncRevision(workspaceID: workspaceID, deviceID: deviceID, parents: prior.heads, changes: changes))
        return try snapshot()
    }
    /// Resolves only the selected register conflict, observing ALL current heads.
    /// Unrelated unresolved fields receive no writes and remain conflicted.
    public func resolve(conflictID: String, choosingRevisionID: String) throws -> SyncMergeResult {
        let prior = try snapshot()
        guard let conflict = prior.conflicts.first(where: { $0.id == conflictID }),
              conflict.kind == .concurrentValue, conflict.paths.count == 1,
              let chosen = conflict.candidates.first(where: { $0.revisionID == choosingRevisionID }) else {
            throw SyncError.staleConflict(conflictID)
        }
        let path = conflict.paths[0]
        let r = SyncRevision(workspaceID: workspaceID, deviceID: deviceID, parents: prior.heads,
            changes: [SyncChange(path: path, value: chosen.value)])
        try appendLocal(r); return try snapshot()
    }
    /// Explicit nil means clear the disputed choice; record's unchanged projection nil is no edit.
    public func resolveCurrentChoice(conflictID: String, choosingChoiceID: String?) throws -> SyncMergeResult {
        let prior = try snapshot()
        guard let conflict = prior.conflicts.first(where: { $0.id == conflictID }),
              conflict.kind == .concurrentValue, conflict.paths == [SyncDocument.choice],
              choosingChoiceID == nil || (prior.workspace.choices ?? []).contains(where: { $0.id == choosingChoiceID }) else {
            throw SyncError.staleConflict(conflictID)
        }
        let value = choosingChoiceID.map(SyncValue.string) ?? .null
        let revision = SyncRevision(workspaceID: workspaceID, deviceID: deviceID, parents: prior.heads,
            changes: [SyncChange(path: SyncDocument.choice, value: value)])
        try appendLocal(revision); return try snapshot()
    }
    /// Explicit graph edits append facts; every prior relationship operation remains in the audit.
    public func resolveRelationships(conflictID: String, removingDependencyIDs: Set<String>, removingWorkLinkIDs: Set<String> = []) throws -> SyncMergeResult {
        let prior = try snapshot()
        guard let conflict = prior.conflicts.first(where: { $0.id == conflictID }), conflict.kind == .dependencyCycle,
              !(removingDependencyIDs.isEmpty && removingWorkLinkIDs.isEmpty),
              removingDependencyIDs.isSubset(of: Set(conflict.paths.filter { $0.collection == "dependencies" }.map(\.entityID))),
              removingWorkLinkIDs.isSubset(of: Set(conflict.paths.filter { $0.collection == "workLinks" }.map(\.entityID))) else { throw SyncError.staleConflict(conflictID) }
        var workspace = prior.workspace
        let now = Date()
        for index in workspace.dependencies.indices where removingDependencyIDs.contains(workspace.dependencies[index].id) {
            workspace.dependencies[index].removedAt = now
        }
        if var links = workspace.workLinks {
            for index in links.indices where removingWorkLinkIDs.contains(links[index].id) { links[index].removedAt = now }
            workspace.workLinks = links
        }
        let before = try SyncDocument(prior.workspace, choice: prior.currentChoiceID)
        let after = try SyncDocument(workspace, choice: prior.currentChoiceID)
        let changes = SyncDocument.changes(from: before, to: after)
        let r = SyncRevision(workspaceID: workspaceID, deviceID: deviceID, parents: prior.heads,
            changes: changes)
        try appendLocal(r); return try snapshot()
    }
    /// Deletion with retained history/reference resolves by retaining (optionally archiving) the object.
    /// Physical purge requires a separate reviewed export/deletion workflow and is never a sync shortcut.
    public func resolveDeletion(conflictID: String, archive: Bool = false) throws -> SyncMergeResult {
        let prior = try snapshot()
        guard let conflict = prior.conflicts.first(where: { $0.id == conflictID }), conflict.kind == .deletionReference,
              let path = conflict.paths.first else { throw SyncError.staleConflict(conflictID) }
        var changes = [SyncChange(path: path, value: .bool(true))]
        if archive && ["projects", "nodes", "items", "blockers"].contains(path.collection) {
            let archivePath = SyncPath(collection: path.collection, entityID: path.entityID, field: "isArchived")
            changes.append(SyncChange(path: archivePath, value: .bool(true)))
        }
        let r = SyncRevision(workspaceID: workspaceID, deviceID: deviceID, parents: prior.heads,
            changes: changes)
        try appendLocal(r); return try snapshot()
    }
    /// Explicit domain repair for a cross-register invariant, preserving all unchanged disputed paths.
    public func resolveInvariant(conflictID: String, workspace: Workspace) throws -> SyncMergeResult {
        let prior = try snapshot()
        guard let conflict = prior.conflicts.first(where: { $0.id == conflictID }), conflict.kind == .invariant else { throw SyncError.staleConflict(conflictID) }
        try workspace.validate()
        let changes = try editChanges(workspace: workspace, currentChoiceID: workspace.currentChoiceID, prior: prior)
        guard !changes.isEmpty else { throw SyncError.staleConflict(conflictID) }
        let allowed = Set(conflict.paths)
        guard changes.allSatisfy({ allowed.contains($0.path) || SyncDocument.facts.contains($0.path.collection) }) else {
            throw SyncError.invalidJournal("invariant repair modifies unrelated fields")
        }
        let r = SyncRevision(workspaceID: workspaceID, deviceID: deviceID, parents: prior.heads,
            changes: changes)
        try appendLocal(r); return try snapshot()
    }
    /// Select the effective record among parallel round/correction UUIDs. Other versions stay in immutable revision audit.
    public func resolveSemanticRecord(conflictID: String, choosingEntityID: String) throws -> SyncMergeResult {
        let prior = try snapshot()
        guard let conflict = prior.conflicts.first(where: { $0.id == conflictID }), conflict.kind == .semanticRecord,
              conflict.paths.contains(where: { $0.entityID == choosingEntityID }) else { throw SyncError.staleConflict(conflictID) }
        let changes = conflict.paths.map { path in SyncChange(path: path, value: .bool(path.entityID == choosingEntityID)) }
        let r = SyncRevision(workspaceID: workspaceID, deviceID: deviceID, parents: prior.heads,
            changes: changes)
        try appendLocal(r); return try snapshot()
    }
    /// Deltas are the authoritative audit; materialize an individual operation's ancestor closure on demand.
    public func revision(id: String) -> SyncRevision? { revisions[id] }
    public func materialize(revisionID: String) throws -> SyncMergeResult {
        try recoverOutstandingWrites()
        guard revisions[revisionID] != nil else { throw SyncError.invalidJournal("unknown revision") }
        var included = Set<String>(), queue = [revisionID], position = 0
        while position < queue.count {
            let id = queue[position]; position += 1
            guard included.insert(id).inserted else { continue }
            guard let revision = revisions[id] else { throw SyncError.missingParent(id) }
            queue.append(contentsOf: revision.parents)
        }
        return try SyncMerge.merge(revisions: included.compactMap { revisions[$0] }, workspaceID: workspaceID)
    }
    public func pending(limit: Int = 100) -> [SyncRevision] {
        // Only parent-closed records are publishable. Restored staging remains queued until closure.
        let pending = state.pendingIDs.intersection(frontier.closedIDs)
        var ordered: [SyncRevision] = [], remaining = pending, emitted = Set<String>(), bytes = 0
        let count = min(max(1, limit), limits.maximumRecordsPerPage)
        while !remaining.isEmpty && ordered.count < count {
            let ready = remaining.filter { id in revisions[id]!.parents.allSatisfy { !pending.contains($0) || emitted.contains($0) } }.sorted()
            guard !ready.isEmpty else { break }
            for id in ready where ordered.count < count {
                let r = revisions[id]!, size = (try? SyncCoding.encode(r).count) ?? limits.maximumRevisionBytes
                // One large initial delta is allowed, bounded by maximumRevisionBytes.
                if !ordered.isEmpty && bytes + size > limits.transferBatchBytes { return ordered }
                ordered.append(r); bytes += size; emitted.insert(id); remaining.remove(id)
            }
        }
        return ordered
    }
    public func cursor() -> Data? { state.cursor }
    public func boundAccountID() -> String? { state.accountID }
    public func boundRemoteBindingID() -> RemoteBindingID? { state.accountID.map(RemoteBindingID.init(rawValue:)) }
    public func bindRemote(_ binding: RemoteBindingID) throws { try bindAccount(binding.rawValue) }
    /// Explicit binding; cannot move an already bound local partition to a different account.
    public func bindAccount(_ accountID: String) throws {
        try recoverOutstandingWrites()
        guard !accountID.isEmpty else { throw SyncError.accountUnavailable("empty account") }
        guard state.accountID == nil || state.accountID == accountID else { throw SyncError.accountChanged }
        var next = state; next.accountID = accountID; try persist(next); state = next
    }
    public func ingest(_ incoming: [SyncRevision], cursor: Data?, at: Date = Date(),
                       needsFullReconciliation: Bool = false, fullReconciliationAt: Date? = nil) throws {
        try recoverOutstandingWrites()
        var next = state, candidate = revisions
        for r in incoming {
            try SyncCausalFrontier.validate(r, workspaceID: workspaceID)
            if let old = candidate[r.id], !old.hasSameOperation(as: r) { throw SyncError.identityCollision(r.id) }
            candidate[r.id] = r.delta; next.receivedIDs.insert(r.id)
        }
        let newFrontier = try SyncCausalFrontier(candidate, workspaceID: workspaceID)
        try validateBudget(candidate, incoming: incoming)
        // Write every record before advancing the token. Staged facts survive failure/restart.
        for r in incoming { try writeRevision(r.delta) }
        next.cursor = cursor; next.remoteDataAt = at
        if let fullReconciliationAt { next.lastFullReconciliation = fullReconciliationAt }
        // The recovery obligation and the new scan cursor have ONE durable commit. A failure
        // preserves the old cursor, so an expired-token page cannot consume an unqueued recovery.
        if needsFullReconciliation { next.pendingIDs.formUnion(candidate.keys) }
        try persist(next)
        if newFrontier.closedIDs != frontier.closedIDs { cached = nil }
        revisions = candidate; frontier = newFrontier; state = next
    }
    public func exportArchive() throws -> SyncArchive {
        try recoverOutstandingWrites()
        let archive = SyncArchive(workspaceID: workspaceID, revisions: revisions.values.map {
            SyncArchiveRevision(id: $0.id, parents: $0.parents, createdAt: $0.createdAt, changes: $0.changes)
        }, stagedRevisionIDs: frontier.stagedIDs.sorted(), missingParentIDs: frontier.missingParentIDs.sorted())
        guard try SyncCoding.encode(archive).count <= limits.maximumArchiveBytes else { throw SyncError.invalidJournal("archive byte budget") }
        return archive
    }
    public func restoreArchive(_ archive: SyncArchive) throws -> SyncMergeResult {
        // Never overwrite a previous failed restore's responsibility, even in the same actor.
        // If its manifest still cannot commit, reject this restore and leave the old intent intact.
        try recoverOutstandingWrites()
        guard archive.formatVersion == 1, archive.workspaceID == workspaceID,
              archive.revisions.count <= limits.maximumRevisionCount,
              try SyncCoding.encode(archive).count <= limits.maximumArchiveBytes else { throw SyncError.invalidJournal("archive version/workspace/budget") }
        var restored: [String: SyncRevision] = [:]
        for entry in archive.revisions {
            let r = SyncRevision(id: entry.id, workspaceID: workspaceID, deviceID: "archive-restored",
                parents: entry.parents, createdAt: entry.createdAt, changes: entry.changes)
            guard restored[r.id] == nil else { throw SyncError.identityCollision(r.id) }
            restored[r.id] = r
        }
        let declared = try SyncCausalFrontier(restored, workspaceID: workspaceID)
        guard archive.stagedRevisionIDs.sorted() == declared.stagedIDs.sorted(),
              archive.missingParentIDs.sorted() == declared.missingParentIDs.sorted() else { throw SyncError.invalidJournal("archive causal closure declaration") }
        var candidate = revisions
        for r in restored.values {
            if let old = candidate[r.id], !old.hasSameOperation(as: r) { throw SyncError.identityCollision(r.id) }
            else if candidate[r.id] == nil { candidate[r.id] = r }
        }
        let newFrontier = try SyncCausalFrontier(candidate, workspaceID: workspaceID)
        // Structural validation precedes writes; unresolved Domain invariants remain visible in result.
        let result = try SyncMerge.merge(revisions: newFrontier.closedIDs.compactMap { candidate[$0] }, workspaceID: workspaceID)
        try validateBudget(candidate, incoming: Array(restored.values))
        // Recovery intent survives a crash before the main manifest is published.
        let intentURL = directory.appendingPathComponent("restore-intent.json")
        try SyncCoding.encode(restored.keys.sorted()).write(to: intentURL, options: .atomic)
        for r in restored.values { try writeRevision(r) }
        var next = state; next.pendingIDs.formUnion(restored.keys); next.receivedIDs.formUnion(restored.keys)
        try persist(next); revisions = candidate; frontier = newFrontier; state = next; cached = result
        try? FileManager.default.removeItem(at: intentURL)
        return result
    }
    public func resetCursor() throws { try recoverOutstandingWrites(); var next = state; next.cursor = nil; next.pendingIDs.formUnion(revisions.keys); try persist(next); state = next }
    public func enqueueAllForRecovery() throws { try recoverOutstandingWrites(); var next = state; next.pendingIDs.formUnion(revisions.keys); try persist(next); state = next }
    public func acknowledge(_ ids: Set<String>, at: Date? = nil) throws {
        try recoverOutstandingWrites()
        guard ids.isSubset(of: Set(revisions.keys)) else { throw SyncError.invalidJournal("ack unknown revision") }
        var next = state; next.pendingIDs.subtract(ids); next.uploadedIDs.formUnion(ids)
        if let at { next.lastSuccessfulSync = at }
        try persist(next); state = next
    }
    public func syncStatus() throws -> SyncStatus {
        let result = try snapshot()
        return SyncStatus(phase: result.conflicts.isEmpty ? (state.pendingIDs.isEmpty && frontier.stagedIDs.isEmpty ? .localOnly : .pending) : .conflict,
            pendingCount: state.pendingIDs.count, conflicts: result.conflicts, lastSuccessfulSync: state.lastSuccessfulSync, remoteDataAt: state.remoteDataAt,
            message: frontier.stagedIDs.isEmpty ? nil : "缺少 causal parents，\(frontier.stagedIDs.count) 条修订已持久 staging；已有本地工作继续。",
            stagedCount: frontier.stagedIDs.count, missingParentIDs: frontier.missingParentIDs.sorted(), planningIsValid: result.planningIsValid,
            lastFullReconciliation: state.lastFullReconciliation)
    }
    /// Diff actual UI intent against its prior projection, then apply it to raw registers.
    /// Unchanged nil choice/sentinels/excluded branches never become synthetic factual operations.
    private func editChanges(workspace: Workspace, currentChoiceID: String?, prior: SyncMergeResult) throws -> [SyncChange] {
        let projection = try SyncDocument(prior.planningWorkspace, choice: prior.planningWorkspace.currentChoiceID)
        var edited = try SyncDocument(workspace, choice: currentChoiceID)
        let raw = prior.rawValues
        // A grouped execution edit must not copy an unchanged synthetic needsReview flag.
        for id in prior.projectionReviewItemIDs {
            let path = SyncPath(collection: "items", entityID: id, field: SyncDocument.execution)
            if var group = edited.values[path]?.object,
               group["needsReview"] == projection.values[path]?.object?["needsReview"] {
                group["needsReview"] = raw[path]?.object?["needsReview"]
                edited.values[path] = .object(group)
            }
        }
        var intended = SyncDocument.changes(from: projection, to: edited)
        // An older journal has only per-node sequence fields. Seed its complete sequence
        // before an execution edit replaces that old group, without turning a no-op into a write.
        let changedNodes = Set(intended.filter { $0.path.collection == "nodes" && $0.path.field == SyncDocument.execution }.map { $0.path.entityID })
        let migrateProjects = Set(workspace.nodes.filter { changedNodes.contains($0.id) }.map(\.projectID))
        let intendedPaths = Set(intended.map(\.path))
        for projectID in migrateProjects {
            let path = SyncPath(collection: "projects", entityID: projectID, field: SyncDocument.nodeSequence)
            if raw[path] == nil, !intendedPaths.contains(path), let value = edited.values[path] {
                intended.append(SyncChange(path: path, value: value))
            }
        }
        // The normalization above can differ from projection by itself; compare raw group fields
        // after applying only actual changes, omitting unchanged synthetic flags.
        intended.removeAll { change in
            if prior.projectionReviewItemIDs.contains(change.path.entityID), change.path.collection == "items",
               change.path.field == SyncDocument.execution {
                return change.value == raw[change.path]
            }
            return false
        }
        let quarantined = prior.quarantinedRecordPaths
        for change in intended {
            if quarantined.contains(where: { $0.collection == change.path.collection && $0.entityID == change.path.entityID }) {
                throw SyncError.unresolvedEdit(change.path)
            }
            if (change.path.collection == "dependencies" && prior.quarantinedDependencyIDs.contains(change.path.entityID)) ||
               (change.path.collection == "workLinks" && prior.quarantinedWorkLinkIDs.contains(change.path.entityID)) {
                throw SyncError.unresolvedEdit(change.path)
            }
        }
        // Filter writes equal to the raw register (e.g. clearing a projection-only review flag).
        return intended.filter { raw[$0.path] != $0.value }
    }
    private func appendLocal(_ revision: SyncRevision) throws {
        var candidate = revisions; candidate[revision.id] = revision.delta
        let newFrontier = try SyncCausalFrontier(candidate, workspaceID: workspaceID)
        let prior = try snapshot()
        var registers = prior.registers
        // New local operation observes every materializable head, so it dominates all earlier
        // candidates on its changed paths. No full historical delta replay for a title edit.
        for change in revision.changes { registers[change.path] = [SyncCandidate(revisionID: revision.id, value: change.value)] }
        let result = try SyncMerge.merge(revisions: newFrontier.closedIDs.compactMap { candidate[$0] },
            workspaceID: workspaceID, preparedRegisters: registers)
        try validateBudget(candidate, incoming: [revision])
        // Encoding/limits/identity checks above precede I/O. After an attempted write,
        // verify the exact target before making any claim that the edit was not saved.
        do { try writeRevision(revision.delta) }
        catch {
            let original = error
            do {
                let stored = try SyncOperationEnvelope.decode(Data(contentsOf: revisionURL(id: revision.id)))
                guard stored.hasSameOperation(as: revision) else { throw SyncError.identityCollision(revision.id) }
            } catch let readError as CocoaError where readError.code == .fileReadNoSuchFile {
                throw original
            } catch {
                let failure = localFailure(revision, durability: .unknown, reason: original.localizedDescription)
                pendingLocalCommit = (revision, failure); throw failure
            }
            let failure = localFailure(revision, durability: .verified, reason: original.localizedDescription)
            pendingLocalCommit = (revision, failure); throw failure
        }
        var next = state; next.pendingIDs.insert(revision.id)
        do { try persist(next) }
        catch {
            let failure = localFailure(revision, durability: .verified, reason: error.localizedDescription)
            pendingLocalCommit = (revision, failure); throw failure
        }
        revisions = candidate; frontier = newFrontier; state = next; cached = result
    }

    private func localFailure(_ revision: SyncRevision, durability: SyncLocalCommitReceipt.Durability,
                              reason: String) -> SyncLocalCommitFailure {
        SyncLocalCommitFailure(receipt: SyncLocalCommitReceipt(
            journalDirectory: directory.standardizedFileURL.path, workspaceID: workspaceID,
            deviceID: deviceID, revisionID: revision.id, durability: durability), reason: reason)
    }

    /// Settles the ORIGINAL operation, including after reopen. A successful query never creates a revision.
    public func recoverLocalCommit(_ receipt: SyncLocalCommitReceipt) throws -> SyncLocalCommitRecovery {
        guard receipt.journalDirectory == directory.standardizedFileURL.path,
              receipt.workspaceID == workspaceID, receipt.deviceID == deviceID else {
            throw SyncError.invalidJournal("local receipt belongs to another journal")
        }
        if let pendingLocalCommit {
            guard pendingLocalCommit.revision.id == receipt.revisionID else { throw pendingLocalCommit.failure }
            if try !recoverPendingLocalCommit() { return .notSaved }
        }
        try recoverRestoreIntent()
        guard revisions[receipt.revisionID] != nil else {
            if receipt.durability == .verified {
                throw SyncLocalCommitFailure(receipt: receipt, reason: "已核实的修订文件缺失，请检查本机存储。")
            }
            // A receipt from a previous actor whose attempted atomic write did not leave a file.
            do { _ = try Data(contentsOf: revisionURL(id: receipt.revisionID)) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { return .notSaved }
            catch { throw SyncLocalCommitFailure(receipt: receipt, reason: error.localizedDescription) }
            throw SyncLocalCommitFailure(receipt: receipt, reason: "修订尚未载入，请重新打开数据。")
        }
        return .committed(try snapshot())
    }

    private func recoverOutstandingWrites() throws {
        _ = try recoverPendingLocalCommit()
        try recoverRestoreIntent()
    }

    /// No awaits: recover the immutable operation and its outbox obligation before any other manifest writer.
    @discardableResult private func recoverPendingLocalCommit() throws -> Bool {
        guard let pending = pendingLocalCommit else { return true }
        let revision = pending.revision
        do {
            let file = try revisionURL(id: revision.id)
            let bytes: Data
            do { bytes = try Data(contentsOf: file) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                if pending.failure.receipt.durability == .unknown {
                    pendingLocalCommit = nil; byteCounts[revision.id] = nil; return false
                }
                throw error
            }
            let stored = try SyncOperationEnvelope.decode(bytes)
            try SyncCausalFrontier.validate(stored, workspaceID: workspaceID)
            guard stored.hasSameOperation(as: revision) else { throw SyncError.identityCollision(revision.id) }
            var candidate = revisions; candidate[revision.id] = stored.delta
            let newFrontier = try SyncCausalFrontier(candidate, workspaceID: workspaceID)
            try validateBudget(candidate, incoming: [stored])
            let result = try SyncMerge.merge(revisions: newFrontier.closedIDs.compactMap { candidate[$0] }, workspaceID: workspaceID)
            var next = state
            if !next.uploadedIDs.contains(revision.id), !next.receivedIDs.contains(revision.id) {
                next.pendingIDs.insert(revision.id)
            }
            try persist(next)
            revisions = candidate; frontier = newFrontier; state = next; cached = result
            byteCounts[revision.id] = bytes.count; pendingLocalCommit = nil
            return true
        } catch {
            throw SyncLocalCommitFailure(receipt: pending.failure.receipt, reason: error.localizedDescription)
        }
    }
    /// Recover the successfully written portion of an interrupted restore BEFORE another
    /// transaction can replace its intent. Missing files were never committed and aren't invented.
    /// The intent survives every validation/I/O failure until its outbox obligation is durable.
    private func recoverRestoreIntent() throws {
        let intentURL = directory.appendingPathComponent("restore-intent.json")
        guard FileManager.default.fileExists(atPath: intentURL.path) else { return }
        let ids = try SyncCoding.decode([String].self, from: Data(contentsOf: intentURL))
        guard ids.count <= limits.maximumRevisionCount, Set(ids).count == ids.count else {
            throw SyncError.invalidJournal("restore intent count/identity")
        }
        var candidate = revisions, sizes = byteCounts, presentIDs = Set<String>()
        for id in ids {
            let file = try revisionURL(id: id)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= limits.maximumRevisionBytes else { throw SyncError.invalidJournal("restore intent revision byte budget") }
            let revision = try SyncOperationEnvelope.decode(Data(contentsOf: file))
            guard revision.id == id else { throw SyncError.identityCollision(id) }
            try SyncCausalFrontier.validate(revision, workspaceID: workspaceID)
            if let old = candidate[id] {
                guard old.hasSameOperation(as: revision) else { throw SyncError.identityCollision(id) }
            } else { candidate[id] = revision }
            sizes[id] = size; presentIDs.insert(id)
        }
        guard candidate.count <= limits.maximumRevisionCount,
              sizes.values.reduce(0, +) <= limits.maximumJournalBytes else { throw SyncError.invalidJournal("restore intent journal budget") }
        let newFrontier = try SyncCausalFrontier(candidate, workspaceID: workspaceID)
        var next = state
        next.pendingIDs.formUnion(presentIDs); next.receivedIDs.formUnion(presentIDs)
        try persist(next)
        if newFrontier.closedIDs != frontier.closedIDs { cached = nil }
        revisions = candidate; frontier = newFrontier; byteCounts = sizes; state = next
        try? FileManager.default.removeItem(at: intentURL)
    }
    private func revisionURL(id: String) throws -> URL {
        // Record IDs are opaque. Both restore recovery and writes use the same safe filename.
        let name = Data(id.utf8).map { String(format: "%02x", $0) }.joined()
        guard !name.isEmpty, name.count <= 220 else { throw SyncError.invalidJournal("revision ID too long/empty") }
        return directory.appendingPathComponent(name + ".revision")
    }
    private func validateBudget(_ candidate: [String: SyncRevision], incoming: [SyncRevision]) throws {
        guard candidate.count <= limits.maximumRevisionCount else { throw SyncError.invalidJournal("revision count budget") }
        var sizes = byteCounts
        for r in incoming where sizes[r.id] == nil {
            let size = try SyncCoding.encode(r.delta).count
            guard size <= limits.maximumRevisionBytes else { throw SyncError.invalidJournal("revision byte budget: \(r.id)") }
            sizes[r.id] = size
        }
        guard sizes.values.reduce(0, +) <= limits.maximumJournalBytes else { throw SyncError.invalidJournal("journal byte budget") }
    }
    private func writeRevision(_ revision: SyncRevision) throws {
        let target = try revisionURL(id: revision.id)
        if FileManager.default.fileExists(atPath: target.path) {
            if let old = revisions[revision.id] {
                guard old.hasSameOperation(as: revision) else { throw SyncError.identityCollision(revision.id) }
            } else {
                let old = try SyncOperationEnvelope.decode(Data(contentsOf: target))
                guard old.hasSameOperation(as: revision) else { throw SyncError.identityCollision(revision.id) }
            }
        } else {
            let data = try SyncCoding.encode(revision.delta)
            guard data.count <= limits.maximumRevisionBytes else { throw SyncError.invalidJournal("revision byte budget") }
            try data.write(to: target, options: .atomic); byteCounts[revision.id] = data.count
        }
    }
    private func persist(_ value: SyncJournalState) throws {
        try SyncCoding.encode(value).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
    }
}
