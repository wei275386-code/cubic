import Foundation
import CubicCore

struct WorkspaceWriteToken: Sendable {
    let sessionID: UUID
    let heads: [String]
}

enum WorkspaceCommitOutcome: Sendable {
    case committed(SyncMergeResult, cacheIssue: String?)
    case recoveryRequired(SyncLocalCommitFailure)
}

/// Local submission protocol. Transport, account switching and observable UI publication stay with their owners.
/// A token comes from the same published workspace as the edit; a newer journal token cannot rebase that edit.
actor WorkspaceSession {
    nonisolated let id = UUID()
    private let journal: SyncJournal
    private let cacheProjection: @Sendable (Workspace) async throws -> Void
    private var submitting = false
    private var pendingReceipt: SyncLocalCommitReceipt?

    init(journal: SyncJournal, cacheProjection: @escaping @Sendable (Workspace) async throws -> Void) {
        self.journal = journal; self.cacheProjection = cacheProjection
    }

    func submit(_ candidate: Workspace, basedOn token: WorkspaceWriteToken, now: Date = Date()) async throws -> WorkspaceCommitOutcome {
        guard token.sessionID == id else { throw CoreError.blocked("数据来源已切换，请重新打开编辑页面。") }
        guard !submitting else { throw CoreError.blocked("正在保存，请稍后重试。") }
        guard pendingReceipt == nil else {
            throw CoreError.blocked("原保存结果尚待核对，请先恢复原记录，不要重复提交。")
        }
        // Actor isolation does not serialize across cache awaits; reserve this complete local operation.
        submitting = true
        defer { submitting = false }
        var value = candidate
        try value.applyDefaultRemainingEstimates(now: now)
        try value.validate()
        let projection: SyncMergeResult
        do {
            projection = try await journal.record(workspace: value, currentChoiceID: value.currentChoiceID,
                                                   expectedHeads: token.heads)
        } catch let failure as SyncLocalCommitFailure {
            pendingReceipt = failure.receipt
            return .recoveryRequired(failure)
        }
        return await completed(projection)
    }

    func recover(_ receipt: SyncLocalCommitReceipt) async throws -> WorkspaceCommitOutcome? {
        guard !submitting else { throw CoreError.blocked("正在保存，请稍后重试。") }
        guard pendingReceipt == nil || pendingReceipt == receipt else { throw CoreError.blocked("请先核对原保存记录。") }
        submitting = true
        defer { submitting = false }
        do {
            switch try await journal.recoverLocalCommit(receipt) {
            case .committed(let projection):
                pendingReceipt = nil
                return await completed(projection)
            case .notSaved:
                pendingReceipt = nil
                return nil
            }
        } catch let failure as SyncLocalCommitFailure {
            pendingReceipt = failure.receipt
            return .recoveryRequired(failure)
        }
    }

    private func completed(_ projection: SyncMergeResult) async -> WorkspaceCommitOutcome {
        // SQLite is a disposable projection. Conflicted planning must not replace the last legal cache.
        guard projection.planningIsValid else { return .committed(projection, cacheIssue: nil) }
        do {
            try await cacheProjection(projection.planningWorkspace)
            return .committed(projection, cacheIssue: nil)
        } catch {
            return .committed(projection, cacheIssue: "修改已保存，本机页面缓存未能更新；请重新打开 app。")
        }
    }
}

/// A completed fact whose current canonical projection cannot be used for domain/UI follow-up.
/// Calendar callers retain their original Event intent; this error never means the command was rejected.
struct WorkspaceCommittedProjectionUnavailable: Error, LocalizedError, Sendable {
    var errorDescription: String? { "修改已记录，还有同步冲突需要处理。日历写入已暂停，请在设置核对。" }
}
