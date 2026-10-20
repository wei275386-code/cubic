import Foundation

/// Identifies one attempted immutable operation, never a request to repeat its business command.
public struct SyncLocalCommitReceipt: Codable, Sendable, Equatable {
    public enum Durability: String, Codable, Sendable { case verified, unknown }
    public let journalDirectory: String
    public let workspaceID: String
    public let deviceID: String
    public let revisionID: String
    public let durability: Durability
}

/// A file may already contain the fact even though its outbox manifest has not completed.
/// Only recoverLocalCommit may settle this receipt; callers must not replay the original edit.
public struct SyncLocalCommitFailure: Error, LocalizedError, Sendable {
    public let receipt: SyncLocalCommitReceipt
    public let reason: String
    public var errorDescription: String? {
        "保存结果需要恢复核对，请勿重复提交。原记录保留。\(reason)"
    }
}

public enum SyncLocalCommitRecovery: Sendable {
    case committed(SyncMergeResult)
    case notSaved
}
