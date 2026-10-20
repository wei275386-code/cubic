import Foundation

/// Sync orchestration is separate from storage and transport, so QA can inject a deterministic transport.
public actor SyncCoordinator {
    public let journal: SyncJournal
    private let transport: any SyncTransport
    private var latest = SyncStatus()
    private var running = false
    public init(journal: SyncJournal, transport: any SyncTransport) { self.journal = journal; self.transport = transport }
    public func status() -> SyncStatus { latest }
    public func snapshot() async throws -> SyncMergeResult { try await journal.snapshot() }
    public func bindAccount(_ accountID: String) async throws { try await journal.bindAccount(accountID) }
    public func bindRemote(_ binding: RemoteBindingID) async throws { try await journal.bindRemote(binding) }
    public func record(workspace: Workspace, currentChoiceID: String?, expectedHeads: [String]? = nil) async throws -> SyncMergeResult {
        let result = try await journal.record(workspace: workspace, currentChoiceID: currentChoiceID, expectedHeads: expectedHeads)
        if let stored = try? await journal.syncStatus() { latest = stored }; return result
    }
    public func resolve(conflictID: String, choosingRevisionID: String) async throws -> SyncMergeResult {
        let result = try await journal.resolve(conflictID: conflictID, choosingRevisionID: choosingRevisionID)
        if let stored = try? await journal.syncStatus() { latest = stored }; return result
    }
    public func recordPreferences(_ values: [String: SyncValue]) async throws -> SyncMergeResult {
        let result = try await journal.recordPreferences(values)
        if let stored = try? await journal.syncStatus() { latest = stored }; return result
    }
    public func resolveCurrentChoice(conflictID: String, choosingChoiceID: String?) async throws -> SyncMergeResult {
        let result = try await journal.resolveCurrentChoice(conflictID: conflictID, choosingChoiceID: choosingChoiceID)
        if let stored = try? await journal.syncStatus() { latest = stored }; return result
    }
    public func resolveRelationships(conflictID: String, removingDependencyIDs: Set<String>, removingWorkLinkIDs: Set<String> = []) async throws -> SyncMergeResult {
        let result = try await journal.resolveRelationships(conflictID: conflictID, removingDependencyIDs: removingDependencyIDs, removingWorkLinkIDs: removingWorkLinkIDs)
        if let stored = try? await journal.syncStatus() { latest = stored }; return result
    }
    public func resolveDeletion(conflictID: String, archive: Bool = false) async throws -> SyncMergeResult {
        let result = try await journal.resolveDeletion(conflictID: conflictID, archive: archive)
        if let stored = try? await journal.syncStatus() { latest = stored }; return result
    }
    public func resolveInvariant(conflictID: String, workspace: Workspace) async throws -> SyncMergeResult {
        let result = try await journal.resolveInvariant(conflictID: conflictID, workspace: workspace)
        if let stored = try? await journal.syncStatus() { latest = stored }; return result
    }
    public func resolveSemanticRecord(conflictID: String, choosingEntityID: String) async throws -> SyncMergeResult {
        let result = try await journal.resolveSemanticRecord(conflictID: conflictID, choosingEntityID: choosingEntityID)
        if let stored = try? await journal.syncStatus() { latest = stored }; return result
    }
    public func exportArchive() async throws -> SyncArchive { try await journal.exportArchive() }
    public func restoreArchive(_ archive: SyncArchive) async throws -> SyncMergeResult {
        let result = try await journal.restoreArchive(archive)
        if let stored = try? await journal.syncStatus() { latest = stored }; return result
    }
    @discardableResult public func refresh() async -> SyncStatus {
        guard !running else { return latest }
        running = true; defer { running = false }
        if let stored = try? await journal.syncStatus() { latest = stored }
        latest.phase = .syncing; latest.message = nil
        do {
            // Recovery is a prerequisite for networking; nonthrowing cursor/pending are only the last completed state.
            _ = try await journal.snapshot()
            // Journal-bound accounts are never silently changed or merged into another account.
            let account = try await checkedAccount()
            guard let account else { return latest }
            // Pull first to see competing facts. New local mutations during network awaits remain queued.
            var more = true, pageCount = 0
            while more {
                try Task.checkCancellation()
                try await requireAccount(account)
                let page = try await transport.pull(cursor: await journal.cursor())
                try await requireAccount(account)
                try await journal.ingest(page.revisions, cursor: page.cursor,
                    needsFullReconciliation: page.needsFullReconciliation, fullReconciliationAt: page.fullReconciliationAt)
                more = page.hasMore; pageCount += 1
                // Bound one refresh turn; durable cursor continues on next automatic trigger.
                if pageCount >= 50 && more {
                    latest = try await journal.syncStatus()
                    latest.phase = .pending; latest.message = "远端分页仍在继续，下次自动刷新接续；staged=\(latest.stagedCount)。"; return latest
                }
            }
            _ = try await journal.snapshot() // Only parent-closed frontier participates; staging never blocks local edits.
            var batches = 0
            while batches < 10 {
                let pending = await journal.pending(limit: 50)
                guard !pending.isEmpty else { break }
                try Task.checkCancellation()
                try await requireAccount(account)
                let acknowledged = try await transport.push(pending)
                try await requireAccount(account)
                try await journal.acknowledge(acknowledged)
                guard acknowledged.count == pending.count else {
                    throw SyncError.transport(await transport.pushFailureDescription() ?? "部分远端修订未确认，离线队列已保留。")
                }
                batches += 1
            }
            // Pull once more after push to include racing devices. Pull's next token is committed with its facts.
            try await requireAccount(account)
            let page = transport.requiresPostPushPull
                ? try await transport.pull(cursor: await journal.cursor())
                : SyncPullPage(revisions: [], cursor: await journal.cursor(), hasMore: false)
            try await requireAccount(account)
            try await journal.ingest(page.revisions, cursor: page.cursor,
                needsFullReconciliation: page.needsFullReconciliation, fullReconciliationAt: page.fullReconciliationAt)
            let result = try await journal.snapshot()
            let stored = try await journal.syncStatus()
            if !page.hasMore && stored.pendingCount == 0 && stored.stagedCount == 0 && stored.planningIsValid { try await journal.acknowledge([], at: Date()) }
            latest = try await journal.syncStatus()
            latest.phase = !result.conflicts.isEmpty ? .conflict : (page.hasMore || latest.pendingCount > 0 || latest.stagedCount > 0 ? .pending : .synced)
        } catch {
            // Do not retry inside a failed turn; automatic foreground refresh honors CloudKit retry timing in adapter.
            let previous = latest
            if let stored = try? await journal.syncStatus() { latest = stored }
            else { latest = previous }
            switch error {
            case SyncError.accountChanged: latest.phase = .accountChanged
            case SyncError.requiresSigning: latest.phase = .requiresSigning
            case SyncError.accountUnavailable: latest.phase = .requiresAccount
            default: latest.phase = .failed
            }
            latest.message = String(describing: error)
        }
        return latest
    }
    private func requireAccount(_ expected: String) async throws {
        guard let current = try await checkedAccount() else {
            if latest.phase == .requiresSigning { throw SyncError.requiresSigning(latest.message ?? "signed entitlement") }
            if latest.phase == .requiresAccount { throw SyncError.accountUnavailable(latest.message ?? "iCloud account") }
            throw SyncError.accountChanged
        }
        guard current == expected else { throw SyncError.accountChanged }
    }
    private func checkedAccount() async throws -> String? {
        switch try await transport.availability() {
        case .requiresSigning(let message): latest.phase = .requiresSigning; latest.message = message; return nil
        case .requiresAccount(let message): latest.phase = .requiresAccount; latest.message = message; return nil
        case .available(let id):
            guard await journal.boundAccountID() == id else {
                latest.phase = .accountChanged
                latest.message = "同步远端尚未绑定或已切换。请明确选择对应的独立 workspace，原离线 journal 保留。"
                return nil
            }
            return id
        }
    }
}
