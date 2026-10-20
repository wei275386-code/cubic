import Foundation
import Testing
@testable import CubicCore

private actor EmptyOnboardingDirectoryGrant: FileSyncDirectoryAccess {
    let directory: URL
    init(_ directory: URL) { self.directory = directory }
    func acquireAccess() async throws -> URL { directory }
    func releaseAccess(to directory: URL) async {}
}

@Suite(.serialized) struct EmptyOnboardingQATests {
    private let workspaceID = "empty-onboarding-qa"
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CubicEmptyOnboardingQA-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func remoteRevisionCount(_ remote: URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(at: remote.appendingPathComponent("revisions"), includingPropertiesForKeys: nil)
            .flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            .filter { $0.pathExtension == "revision" }.count
    }

    @Test func freshEmptyJournalFirstRealEditExportsAndRestoresWithoutSampleFacts() async throws {
        let primary = try directory(), secondary = try directory()
        defer { for directory in [primary, secondary] { try? FileManager.default.removeItem(at: directory) } }
        let repository = try SQLiteWorkspaceRepository(url: primary.appendingPathComponent("workspace.sqlite"))
        #expect(try repository.load() == .empty)
        try repository.save(.empty)
        #expect(try repository.load() == .empty)
        let journal = try SyncJournal(directory: primary.appendingPathComponent("journal"), workspaceID: workspaceID, deviceID: "fresh-primary")
        #expect(try await journal.snapshot().workspace == .empty)
        #expect(await journal.pending().isEmpty)
        #expect(try await journal.exportArchive().revisions.isEmpty)

        // Mirrors the new onboarding path: skip an empty bootstrap and record the first real user work.
        let actual = Workspace(items: [WorkItem(id: "real-user-work", name: "My real work", remainingMinutes: 25)])
        let recorded = try await journal.record(workspace: actual, currentChoiceID: nil)
        #expect(recorded.workspace == actual && recorded.conflicts.isEmpty)
        let pending = await journal.pending()
        #expect(pending.count == 1 && pending[0].parents.isEmpty)
        let archive = try SyncCoding.decode(SyncArchive.self, from: SyncCoding.encode(await journal.exportArchive()))
        #expect(archive.revisions.count == 1)
        let example = Workspace.prdExample(start: Date(timeIntervalSince1970: 1_800_000_000))
        let sampleIDs = Set(example.items.map(\.id) + example.projects.map(\.id) + example.dependencies.map(\.id))
        #expect(archive.revisions.flatMap(\.changes).allSatisfy { !sampleIDs.contains($0.path.entityID) })

        let other = try SyncJournal(directory: secondary, workspaceID: workspaceID, deviceID: "fresh-secondary")
        let binding = RemoteBindingID.file(UUID().uuidString)
        try await other.bindRemote(binding)
        #expect(try await other.snapshot().workspace == .empty)
        let restored = try await other.restoreArchive(archive)
        #expect(restored.workspace == actual && restored.conflicts.isEmpty)
        #expect(restored.workspace.projects.isEmpty && restored.workspace.dependencies.isEmpty)
        #expect(restored.workspace.items.map(\.id) == ["real-user-work"])
        #expect(await other.boundRemoteBindingID() == binding)
        #expect(try await other.exportArchive().revisions == archive.revisions)
        #expect(await other.pending().count == 1)
    }

    @Test func existingRealWorkspaceBootstrapAndEmptyRemoteJoinRetainExistingDataAndBinding() async throws {
        let primary = try directory(), secondary = try directory(), remote = try directory()
        defer { for directory in [primary, secondary, remote] { try? FileManager.default.removeItem(at: directory) } }
        let actual = Workspace(projects: [Project(id: "real-project", name: "My project")],
                               items: [WorkItem(id: "real-work", name: "Existing real work", projectIDs: ["real-project"], remainingMinutes: 40)])
        let repository = try SQLiteWorkspaceRepository(url: primary.appendingPathComponent("workspace.sqlite"))
        try repository.save(actual)
        #expect(try repository.load() == actual)
        let first = try SyncJournal(directory: primary.appendingPathComponent("journal"), workspaceID: workspaceID, deviceID: "existing-primary")
        #expect(try await first.bootstrap(workspace: repository.load()).workspace == actual)
        let originalIDs = Set(await first.pending().map(\.id))
        #expect(originalIDs.count == 1)
        #expect(try await first.bootstrap(workspace: .empty).workspace == actual)
        #expect(Set(await first.pending().map(\.id)) == originalIDs)

        let marker = try FileSyncDirectoryIO.createMetadata(in: remote, workspaceID: workspaceID)
        try await first.bindRemote(marker.remoteBinding)
        let firstTransport = FileProviderSyncTransport(access: EmptyOnboardingDirectoryGrant(remote), workspaceID: workspaceID, remoteBindingID: marker.remoteBinding)
        #expect(await SyncCoordinator(journal: first, transport: firstTransport).refresh().phase == .synced)
        #expect(try remoteRevisionCount(remote) == 1)

        let joined = try SyncJournal(directory: secondary, workspaceID: workspaceID, deviceID: "fresh-joined")
        try await joined.bindRemote(marker.remoteBinding)
        #expect(try await joined.snapshot().workspace == .empty)
        #expect(try await joined.exportArchive().revisions.isEmpty)
        let joinedTransport = FileProviderSyncTransport(access: EmptyOnboardingDirectoryGrant(remote), workspaceID: workspaceID, remoteBindingID: marker.remoteBinding)
        #expect(await SyncCoordinator(journal: joined, transport: joinedTransport).refresh().phase == .synced)
        let result = try await joined.snapshot()
        #expect(result.workspace == actual && result.conflicts.isEmpty)
        #expect(Set(try await joined.exportArchive().revisions.map(\.id)) == originalIDs)
        #expect(await joined.boundRemoteBindingID() == marker.remoteBinding)
        #expect(await joined.pending().isEmpty)
        #expect(try remoteRevisionCount(remote) == 1)
        #expect(try repository.load() == actual)
    }
}
