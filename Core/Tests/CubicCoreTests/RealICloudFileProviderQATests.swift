import Foundation
import XCTest
@testable import CubicCore

private actor RealICloudQADirectoryGrant: FileSyncDirectoryAccess {
    let directory: URL
    init(directory: URL) { self.directory = directory }
    func acquireAccess() async throws -> URL { directory }
    func releaseAccess(to directory: URL) async {}
}

/// Opt-in hardware/provider acceptance. Normal test runs skip all phases and never access CloudDocs.
/// The macOS process already has filesystem access; the iPhone still obtains its grant through Files UI.
final class RealICloudFileProviderQATests: XCTestCase, @unchecked Sendable {
    private static let workspaceID = "cubic.work-calendar.qa"
    private static let runID = "20261007-0235"
    private static let macName = "QA Mac iCloud " + runID
    private static let phoneName = "QA mini iCloud " + runID
    private struct Configuration {
        let workspaceDirectory: URL
        let metadata: FileSyncWorkspaceMetadata
    }
    private enum HarnessError: Error {
        case directoryMustBeUniqueCloudDocsQA, unexpectedWorkspace, noPhoneRevisions
        case unexpectedFixture, scanBudgetExceeded, invalidProjection, writeDidNotCreateOneRevision, writeNotConfirmed
    }

    func testReadPhoneUpload() async throws {
        let config = try configuration()
        try await withImportedPhoneJournal(config) { journal, _, count in
            let result = try await journal.snapshot()
            XCTAssertTrue(result.workspace.items.contains { $0.id == "qa-drag" })
            XCTAssertTrue(result.workspace.items.contains { $0.id == "qa-keep" })
            print("REAL_ICLOUD_QA phase=read run=\(Self.runID) revisions=\(count) conflicts=\(result.conflicts.count)")
        }
    }

    /// Read-only audit of the one QA workspace misplaced by the initial Files picker acceptance attempt.
    func testAuditMisplacedPhoneWorkspace() async throws {
        guard ProcessInfo.processInfo.environment["CUBIC_REAL_ICLOUD_QA_ACTION"] == "audit-misplaced" else {
            throw XCTSkip("The specifically authorized misplaced-QA audit is opt-in.")
        }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/" + Self.workspaceID, isDirectory: true)
        let metadata = try FileSyncDirectoryIO.readMetadata(in: directory, workspaceID: Self.workspaceID)
        let config = Configuration(workspaceDirectory: directory, metadata: metadata)
        try await withImportedPhoneJournal(config) { journal, _, count in
            let workspace = try await journal.snapshot().workspace
            let allowed: Set<String> = ["qa-drag", "qa-delete", "qa-keep"]
            XCTAssertTrue(workspace.projects.allSatisfy { $0.id == "qa-project" })
            XCTAssertTrue(workspace.nodes.allSatisfy { $0.id == "qa-node" && $0.projectID == "qa-project" })
            XCTAssertTrue(workspace.items.allSatisfy { allowed.contains($0.id) && $0.projectIDs.allSatisfy { $0 == "qa-project" } })
            XCTAssertTrue((workspace.timeBlocks ?? []).allSatisfy { allowed.contains($0.itemID) })
            XCTAssertTrue((workspace.deletedItems ?? []).allSatisfy { allowed.contains($0.id) })
            let archive = try await journal.exportArchive()
            let changes = archive.revisions.flatMap(\.changes)
            XCTAssertTrue(changes.filter { ["items", "deletedItems"].contains($0.path.collection) }.allSatisfy { allowed.contains($0.path.entityID) })
            XCTAssertTrue(changes.filter { $0.path.collection == "projects" }.allSatisfy { $0.path.entityID == "qa-project" })
            print("REAL_ICLOUD_QA phase=audit-misplaced run=\(Self.runID) revisions=\(count) remote-binding=\(metadata.remoteBindingID)")
        }
    }

    func testPublishMacEdit() async throws {
        guard ProcessInfo.processInfo.environment["CUBIC_REAL_ICLOUD_QA_ACTION"] == "publish" else {
            throw XCTSkip("Real iCloud writes require CUBIC_REAL_ICLOUD_QA_ACTION=publish.")
        }
        let config = try configuration()
        try await withImportedPhoneJournal(config) { journal, transport, _ in
            let original = try await journal.snapshot()
            var workspace = original.workspace
            guard let index = workspace.items.firstIndex(where: { $0.id == "qa-drag" }) else { throw HarnessError.unexpectedFixture }
            if workspace.items[index].name == Self.macName {
                // Rerunning the phase is harmless: do not create another revision or bootstrap competing roots.
                print("REAL_ICLOUD_QA phase=publish run=\(Self.runID) already-confirmed=1")
                return
            }
            workspace.items[index].name = Self.macName
            _ = try await journal.record(workspace: workspace, currentChoiceID: original.currentChoiceID)
            let pending = await journal.pending(limit: 50)
            guard pending.count == 1 else { throw HarnessError.writeDidNotCreateOneRevision }
            let acknowledged = try await transport.push(pending)
            guard acknowledged == Set(pending.map(\.id)) else { throw HarnessError.writeNotConfirmed }
            try await journal.acknowledge(acknowledged)
            // A subsequent full production-transport scan verifies the published immutable fact is readable.
            _ = try await pullCompleteCycle(into: journal, transport: transport)
            let confirmed = try await journal.snapshot()
            XCTAssertEqual(confirmed.workspace.items.first { $0.id == "qa-drag" }?.name, Self.macName)
            XCTAssertTrue(confirmed.conflicts.isEmpty)
            print("REAL_ICLOUD_QA phase=publish run=\(Self.runID) acknowledged=\(acknowledged.count)")
        }
    }

    func testVerifyPhoneEditAfterRestart() async throws {
        guard ProcessInfo.processInfo.environment["CUBIC_REAL_ICLOUD_QA_ACTION"] == "verify" else {
            throw XCTSkip("Run after the iPhone restarts and edits qa-drag: CUBIC_REAL_ICLOUD_QA_ACTION=verify.")
        }
        let config = try configuration()
        try await withImportedPhoneJournal(config) { journal, _, count in
            let result = try await journal.snapshot()
            let expected = ProcessInfo.processInfo.environment["CUBIC_REAL_ICLOUD_QA_EXPECTED_ITEM_NAME"] ?? Self.phoneName
            // Expected labels must remain in this isolated run's QA namespace.
            guard expected.hasPrefix("QA "), expected.contains(Self.runID) else { throw HarnessError.unexpectedFixture }
            XCTAssertEqual(result.workspace.items.first { $0.id == "qa-drag" }?.name, expected)
            XCTAssertTrue(result.conflicts.isEmpty)
            print("REAL_ICLOUD_QA phase=verify run=\(Self.runID) revisions=\(count) conflicts=\(result.conflicts.count)")
        }
    }

    private func configuration() throws -> Configuration {
        guard let path = ProcessInfo.processInfo.environment["CUBIC_REAL_ICLOUD_QA_DIRECTORY"], !path.isEmpty else {
            throw XCTSkip("Real iCloud acceptance is opt-in: set CUBIC_REAL_ICLOUD_QA_DIRECTORY to the isolated QA root.")
        }
        let selected = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let cloudDocs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let root = selected.lastPathComponent == Self.workspaceID ? selected.deletingLastPathComponent() : selected
        guard path.hasPrefix("/"), root.path.hasPrefix(cloudDocs.path + "/"),
              root.lastPathComponent == "Cubic Sync QA " + Self.runID else { throw HarnessError.directoryMustBeUniqueCloudDocsQA }
        let workspace = root.appendingPathComponent(Self.workspaceID, isDirectory: true)
        // Metadata must originate from the iPhone flow. This harness never creates a remote workspace.
        let metadata = try FileSyncDirectoryIO.readMetadata(in: workspace, workspaceID: Self.workspaceID)
        guard metadata.workspaceID == Self.workspaceID else { throw HarnessError.unexpectedWorkspace }
        return Configuration(workspaceDirectory: workspace, metadata: metadata)
    }

    private func withImportedPhoneJournal<T: Sendable>(_ config: Configuration,
        _ operation: (SyncJournal, FileProviderSyncTransport, Int) async throws -> T) async throws -> T {
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("CubicRealICloudQA-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: local) }
        let journal = try SyncJournal(directory: local, workspaceID: Self.workspaceID, deviceID: "qa-mac-" + UUID().uuidString)
        try await journal.bindRemote(config.metadata.remoteBinding)
        let transport = FileProviderSyncTransport(access: RealICloudQADirectoryGrant(directory: config.workspaceDirectory),
            workspaceID: Self.workspaceID, remoteBindingID: config.metadata.remoteBinding, pageSize: 50)
        let count = try await pullCompleteCycle(into: journal, transport: transport)
        guard count > 0 else { throw HarnessError.noPhoneRevisions }
        let result = try await journal.snapshot()
        guard result.conflicts.isEmpty, result.planningIsValid,
              result.workspace.projects.contains(where: { $0.id == "qa-project" }),
              result.workspace.items.contains(where: { $0.id == "qa-drag" }),
              result.workspace.items.contains(where: { $0.id == "qa-keep" }) else { throw HarnessError.unexpectedFixture }
        let status = try await journal.syncStatus()
        guard status.stagedCount == 0 else { throw HarnessError.invalidProjection }
        return try await operation(journal, transport, count)
    }

    @discardableResult private func pullCompleteCycle(into journal: SyncJournal, transport: FileProviderSyncTransport) async throws -> Int {
        var remoteIDs: Set<String> = [], pages = 0
        repeat {
            try Task.checkCancellation()
            let page = try await transport.pull(cursor: await journal.cursor())
            try await journal.ingest(page.revisions, cursor: page.cursor, needsFullReconciliation: page.needsFullReconciliation,
                fullReconciliationAt: page.fullReconciliationAt)
            remoteIDs.formUnion(page.revisions.map(\.id)); pages += 1
            guard pages <= 200 else { throw HarnessError.scanBudgetExceeded }
            if !page.hasMore { break }
        } while true
        // This import only acknowledges facts read from the provider; it performs no remote writes.
        // Clearing imported pending facts lets phase 2 publish exactly its newly recorded local edit.
        try await journal.acknowledge(remoteIDs)
        return remoteIDs.count
    }
}
