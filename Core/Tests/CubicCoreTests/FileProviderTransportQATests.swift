import Foundation
import Testing
@testable import CubicCore

// Exercises production FileProviderSyncTransport against isolated local directories.
// NSFileCoordinator is real; these tests do not claim iCloud/provider propagation coverage.
private actor LocalDirectoryGrant: FileSyncDirectoryAccess {
    let url: URL
    private var acquisitions = 0
    private var releases = 0
    init(_ url: URL) { self.url = url }
    func acquireAccess() async throws -> URL { acquisitions += 1; return url }
    func releaseAccess(to directory: URL) async { releases += 1 }
    func balanced() -> Bool { acquisitions == releases }
}

private enum FileProviderQA {
    static let date = Date(timeIntervalSince1970: 1_800_000_000)
    static let workspaceID = "file-provider-qa"
    static var base: Workspace {
        Workspace(items: [WorkItem(id: "a", name: "A", remainingMinutes: 60),
                          WorkItem(id: "b", name: "B", remainingMinutes: 30)])
    }
    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CubicFileProviderQA-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func revision(_ workspace: Workspace = base, old: Workspace? = nil, id: String = "root",
                         parents: [String] = [], device: String = "A") throws -> SyncRevision {
        try .recording(workspace: workspace, comparedTo: old, id: id, workspaceID: workspaceID,
                       deviceID: device, parents: parents, createdAt: date)
    }
    static func transport(_ remote: URL, marker: FileSyncWorkspaceMetadata, pageSize: Int = 100) -> FileProviderSyncTransport {
        FileProviderSyncTransport(access: LocalDirectoryGrant(remote), workspaceID: workspaceID,
                                  remoteBindingID: marker.remoteBinding, pageSize: pageSize)
    }
    static func files(in remote: URL) throws -> [URL] {
        let revisions = remote.appendingPathComponent("revisions")
        return try FileManager.default.contentsOfDirectory(at: revisions, includingPropertiesForKeys: nil).flatMap {
            try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
        }.filter { $0.pathExtension == "revision" }
    }
}

@Suite(.serialized) struct FileProviderTransportQATests {
    @Test func immutableReplayIgnoresAuthorConfigurationAndReportsPayloadCollision() async throws {
        let remote = try FileProviderQA.directory(); defer { try? FileManager.default.removeItem(at: remote) }
        let marker = try FileSyncDirectoryIO.createMetadata(in: remote, workspaceID: FileProviderQA.workspaceID)
        #expect(try FileSyncDirectoryIO.createMetadata(in: remote, workspaceID: FileProviderQA.workspaceID) == marker)
        let grant = LocalDirectoryGrant(remote)
        let transport = FileProviderSyncTransport(access: grant, workspaceID: FileProviderQA.workspaceID, remoteBindingID: marker.remoteBinding)
        let original = try FileProviderQA.revision()
        let reauthor = SyncRevision(id: original.id, workspaceID: original.workspaceID, deviceID: "restored-device",
                                   parents: original.parents, createdAt: original.createdAt, changes: original.changes)
        #expect(try await transport.push([original]) == ["root"])
        #expect(try await transport.push([reauthor]) == ["root"])
        #expect(try FileProviderQA.files(in: remote).count == 1)
        var altered = FileProviderQA.base; altered.items[0].name = "collision"
        #expect(try await transport.push([FileProviderQA.revision(altered)]) == [])
        #expect(await transport.pushFailureDescription()?.contains("identityCollision") == true)
        let page = try await transport.pull(cursor: nil)
        #expect(page.revisions.count == 1 && page.revisions[0].hasSameOperation(as: original))
        #expect(await grant.balanced())
    }

    @Test func conflictCopiesDeduplicateOperationAndRejectDifferentPayloadWithSameID() async throws {
        let remote = try FileProviderQA.directory(); defer { try? FileManager.default.removeItem(at: remote) }
        let marker = try FileSyncDirectoryIO.createMetadata(in: remote, workspaceID: FileProviderQA.workspaceID)
        let transport = FileProviderQA.transport(remote, marker: marker, pageSize: 1)
        let original = try FileProviderQA.revision()
        #expect(try await transport.push([original]) == [original.id])
        let file = try #require(FileProviderQA.files(in: remote).first)
        let conflict = file.deletingLastPathComponent().appendingPathComponent("root.revision (conflicted copy)")
        let reauthor = SyncRevision(id: original.id, workspaceID: original.workspaceID, deviceID: "other",
                                   parents: original.parents, createdAt: original.createdAt, changes: original.changes)
        try SyncCoding.encode(reauthor).write(to: conflict)
        var cursor: Data?, received: [SyncRevision] = []
        repeat {
            let page = try await transport.pull(cursor: cursor); cursor = page.cursor; received += page.revisions
            if !page.hasMore { break }
        } while true
        #expect(try SyncMerge.merge(revisions: received, workspaceID: FileProviderQA.workspaceID).heads == ["root"])
        var altered = FileProviderQA.base; altered.items[0].name = "different operation"
        try SyncCoding.encode(FileProviderQA.revision(altered)).write(to: conflict)
        do {
            repeat {
                let page = try await transport.pull(cursor: cursor); cursor = page.cursor
                if !page.hasMore { break }
            } while true
            Issue.record("Changed conflict copy must fail identity validation")
        }
        catch { #expect(error as? SyncError == .identityCollision("root")) }
    }

    @Test func twoOfflineJournalsConvergeThroughProductionTransportWithoutLosingEdits() async throws {
        let remote = try FileProviderQA.directory(), left = try FileProviderQA.directory(), right = try FileProviderQA.directory()
        defer { for url in [remote, left, right] { try? FileManager.default.removeItem(at: url) } }
        let marker = try FileSyncDirectoryIO.createMetadata(in: remote, workspaceID: FileProviderQA.workspaceID)
        let a = try SyncJournal(directory: left, workspaceID: FileProviderQA.workspaceID, deviceID: "A")
        let b = try SyncJournal(directory: right, workspaceID: FileProviderQA.workspaceID, deviceID: "B")
        try await a.bindRemote(marker.remoteBinding); try await b.bindRemote(marker.remoteBinding)
        let ca = SyncCoordinator(journal: a, transport: FileProviderQA.transport(remote, marker: marker))
        let cb = SyncCoordinator(journal: b, transport: FileProviderQA.transport(remote, marker: marker))
        _ = try await a.bootstrap(workspace: FileProviderQA.base)
        #expect(await ca.refresh().phase == .synced); #expect(await cb.refresh().phase == .synced)
        var wa = try await a.snapshot().workspace, wb = try await b.snapshot().workspace
        wa.items[0].name = "offline A"; wb.items[1].name = "offline B"
        async let recordedA = a.record(workspace: wa, currentChoiceID: nil)
        async let recordedB = b.record(workspace: wb, currentChoiceID: nil)
        _ = try await (recordedA, recordedB)
        let pendingA = await a.pending(), pendingB = await b.pending()
        #expect(pendingA.count == 1 && pendingB.count == 1)
        async let syncedA = ca.refresh(); async let syncedB = cb.refresh()
        _ = await (syncedA, syncedB)
        #expect(await ca.refresh().phase == .synced); #expect(await cb.refresh().phase == .synced)
        let resultA = try await a.snapshot(), resultB = try await b.snapshot()
        #expect(resultA.workspace == resultB.workspace && resultA.conflicts.isEmpty)
        #expect(resultA.workspace.items.first { $0.id == "a" }?.name == "offline A")
        #expect(resultA.workspace.items.first { $0.id == "b" }?.name == "offline B")
    }

    @Test func missingRemoteRevisionIsRepairedFromDurableJournalAfterRestart() async throws {
        let remote = try FileProviderQA.directory(), local = try FileProviderQA.directory()
        defer { for url in [remote, local] { try? FileManager.default.removeItem(at: url) } }
        let marker = try FileSyncDirectoryIO.createMetadata(in: remote, workspaceID: FileProviderQA.workspaceID)
        func firstProcess() async throws -> String {
            let journal = try SyncJournal(directory: local, workspaceID: FileProviderQA.workspaceID, deviceID: "A")
            try await journal.bindRemote(marker.remoteBinding)
            _ = try await journal.bootstrap(workspace: FileProviderQA.base)
            let id = try #require(await journal.pending().first?.id)
            let coordinator = SyncCoordinator(journal: journal, transport: FileProviderQA.transport(remote, marker: marker))
            #expect(await coordinator.refresh().phase == .synced)
            #expect(await journal.pending().isEmpty)
            return id
        }
        let id = try await firstProcess()
        for file in try FileProviderQA.files(in: remote) { try FileManager.default.removeItem(at: file) }
        let reopened = try SyncJournal(directory: local, workspaceID: FileProviderQA.workspaceID, deviceID: "A")
        let restarted = SyncCoordinator(journal: reopened, transport: FileProviderQA.transport(remote, marker: marker))
        #expect(await restarted.refresh().phase == .synced)
        let repaired = try FileProviderQA.files(in: remote)
        #expect(repaired.count == 1)
        #expect(try SyncCoding.decode(SyncRevision.self, from: Data(contentsOf: repaired[0])).id == id)
        #expect(try await reopened.snapshot().workspace.items.count == 2)
    }

    @Test func wrongWorkspaceAndChangedBindingFailBeforeRemoteWrites() async throws {
        let remote = try FileProviderQA.directory(); defer { try? FileManager.default.removeItem(at: remote) }
        let marker = try FileSyncDirectoryIO.createMetadata(in: remote, workspaceID: "foreign")
        let wrongWorkspace = FileProviderQA.transport(remote, marker: marker)
        do { _ = try await wrongWorkspace.availability(); Issue.record("Wrong marker workspace accepted") }
        catch { #expect(error as? SyncError == .wrongWorkspace("foreign")) }
        let wrongBinding = FileProviderSyncTransport(access: LocalDirectoryGrant(remote), workspaceID: "foreign", remoteBindingID: .file(UUID().uuidString))
        do { _ = try await wrongBinding.availability(); Issue.record("Changed binding accepted") }
        catch { #expect(error as? SyncError == .accountChanged) }
        #expect(try FileProviderQA.files(in: remote).isEmpty)
    }

    @Test func boundedRepairBeyondFiveHundredRevisionsSurvivesTransportRestartAndReachesTail() async throws {
        let remote = try FileProviderQA.directory(), local = try FileProviderQA.directory()
        defer { for url in [remote, local] { try? FileManager.default.removeItem(at: url) } }
        let marker = try FileSyncDirectoryIO.createMetadata(in: remote, workspaceID: FileProviderQA.workspaceID)
        let root = try FileProviderQA.revision(id: "r0000")
        let chain = (1...600).map { index in
            SyncRevision(id: String(format: "r%04d", index), workspaceID: FileProviderQA.workspaceID, deviceID: "A",
                         parents: [String(format: "r%04d", index - 1)], createdAt: FileProviderQA.date, changes: [])
        }
        let journal = try SyncJournal(directory: local, workspaceID: FileProviderQA.workspaceID, deviceID: "A")
        try await journal.bindRemote(marker.remoteBinding)
        try await journal.ingest([root] + chain, cursor: nil, needsFullReconciliation: true)
        let transport = FileProviderQA.transport(remote, marker: marker, pageSize: 1000)
        let coordinator = SyncCoordinator(journal: journal, transport: transport)
        #expect(await coordinator.refresh().phase == .pending)
        #expect(await coordinator.refresh().phase == .synced)
        #expect(await coordinator.refresh().phase == .synced)
        let tail = try #require(FileProviderQA.files(in: remote).first { $0.lastPathComponent == "r0600.revision" })
        try FileManager.default.removeItem(at: tail)
        let oldCursor = await journal.cursor()
        let uncommitted = try await transport.pull(cursor: oldCursor)
        #expect(uncommitted.needsFullReconciliation)
        // A pull request that never commits to journal must remain replayable with the old token.
        #expect(try await transport.pull(cursor: oldCursor).needsFullReconciliation)
        #expect(await coordinator.refresh().phase == .pending)
        #expect(try await journal.syncStatus().pendingCount == 101)
        #expect(!FileManager.default.fileExists(atPath: tail.path))
        // Simulate process-local transport replacement with the durable pending set and scan cursor preserved.
        let restartedTransport = FileProviderQA.transport(remote, marker: marker, pageSize: 1000)
        let restartedCoordinator = SyncCoordinator(journal: journal, transport: restartedTransport)
        #expect(await restartedCoordinator.refresh().phase == .synced)
        #expect(FileManager.default.fileExists(atPath: tail.path))
        #expect(await journal.pending().isEmpty)
        #expect(await restartedCoordinator.refresh().phase == .synced)
        #expect(await journal.pending().isEmpty)
        let laterMissing = try #require(FileProviderQA.files(in: remote).first { $0.lastPathComponent == "r0599.revision" })
        try FileManager.default.removeItem(at: laterMissing)
        #expect(try await restartedTransport.pull(cursor: journal.cursor()).needsFullReconciliation)
    }

    @Test func tenThousandFileScanIsPagedAndUnchangedPayloadsAreSkipped() async throws {
        let remote = try FileProviderQA.directory(); defer { try? FileManager.default.removeItem(at: remote) }
        let marker = try FileSyncDirectoryIO.createMetadata(in: remote, workspaceID: FileProviderQA.workspaceID)
        let shard = remote.appendingPathComponent("revisions/aa")
        try FileManager.default.createDirectory(at: shard, withIntermediateDirectories: true)
        func progress(_ phase: String) {
            let data = Data("FILE-PROVIDER-QA \(phase)\n".utf8)
            FileHandle.standardOutput.write(data)
            if let path = ProcessInfo.processInfo.environment["CUBIC_QA_PROGRESS_FILE"], let handle = FileHandle(forWritingAtPath: path) {
                defer { try? handle.close() }; handle.seekToEndOfFile(); handle.write(data)
            }
        }
        for index in 0..<10_000 {
            let revision = SyncRevision(id: "scan-\(index)", workspaceID: FileProviderQA.workspaceID, deviceID: "A", parents: [], createdAt: FileProviderQA.date, changes: [])
            try SyncCoding.encode(revision).write(to: shard.appendingPathComponent("scan-\(index).revision"))
            if (index + 1) % 1000 == 0 { progress("fixture files=\(index + 1)") }
        }
        let transport = FileProviderQA.transport(remote, marker: marker, pageSize: 257)
        var cursor: Data?, total = 0, pages = 0
        let started = Date()
        repeat {
            let page = try await transport.pull(cursor: cursor)
            #expect(page.revisions.count <= 257)
            total += page.revisions.count; pages += 1; cursor = page.cursor
            progress("first scan page=\(pages) records=\(total)")
            if !page.hasMore { #expect(page.fullReconciliationAt != nil); break }
        } while true
        #expect(total == 10_000 && pages == 39)
        var unchangedPages = 0
        repeat {
            let page = try await transport.pull(cursor: cursor); cursor = page.cursor; unchangedPages += 1
            progress("unchanged scan page=\(unchangedPages)")
            #expect(page.revisions.isEmpty)
            if !page.hasMore { #expect(!page.needsFullReconciliation); break }
        } while true
        #expect(unchangedPages == 39)
        print("FILE-PROVIDER-QA local scan files=10000 pageSize=257 pages=\(pages) unchangedPages=\(unchangedPages) seconds=\(Date().timeIntervalSince(started))")
    }

    @Test func sameTimeBlockEqualValuesCoalesceAndDifferentValuesRemainExplicit() throws {
        var base = FileProviderQA.base
        base.timeBlocks = [WorkTimeBlock(id: "block", itemID: "a", start: FileProviderQA.date, end: FileProviderQA.date.addingTimeInterval(1800))]
        var left = base, right = base
        left.timeBlocks?[0].start = FileProviderQA.date.addingTimeInterval(600)
        left.timeBlocks?[0].end = FileProviderQA.date.addingTimeInterval(2400)
        right.timeBlocks = left.timeBlocks
        let root = try FileProviderQA.revision(base)
        let a = try FileProviderQA.revision(left, old: base, id: "left", parents: ["root"])
        let equal = try FileProviderQA.revision(right, old: base, id: "equal", parents: ["root"], device: "B")
        let coalesced = try SyncMerge.merge(revisions: [root, a, equal], workspaceID: FileProviderQA.workspaceID)
        #expect(coalesced.conflicts.isEmpty && coalesced.workspace.timeBlocks == left.timeBlocks)
        right.timeBlocks?[0].start = FileProviderQA.date.addingTimeInterval(1200)
        right.timeBlocks?[0].end = FileProviderQA.date.addingTimeInterval(3000)
        let different = try FileProviderQA.revision(right, old: base, id: "different", parents: ["root"], device: "B")
        let disputed = try SyncMerge.merge(revisions: [root, a, different], workspaceID: FileProviderQA.workspaceID)
        #expect(disputed.conflicts.contains { $0.kind == .concurrentValue && $0.paths.contains { $0.collection == "timeBlocks" && $0.entityID == "block" } })
        #expect(Set(disputed.conflicts.flatMap(\.candidates).map(\.revisionID)) == ["left", "different"])
        #expect(try SyncMerge.merge(revisions: [different, a, root], workspaceID: FileProviderQA.workspaceID).conflicts == disputed.conflicts)
    }
}
