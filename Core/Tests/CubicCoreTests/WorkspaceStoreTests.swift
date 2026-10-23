import Foundation
import Testing
@testable import CubicCore

@Suite struct WorkspaceStoreTests {
    private let t0 = Date(timeIntervalSince1970: 1_900_000_000)
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CubicStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func workspace(_ name: String) -> Workspace {
        Workspace(items: [WorkItem(id: "work", name: name, remainingMinutes: 30)])
    }
    private func folderDocument(_ folder: URL) throws -> WorkspaceDocument {
        try JSONCoding.decode(WorkspaceDocument.self, from: Data(contentsOf: folder.appendingPathComponent(WorkspaceStore.folderFilename)))
    }
    private func conflictCopies(_ folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("Cubic-conflict-") }
    }

    @Test func newStoreStartsEmptyAndSavesSurviveReopen() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Cubic/workspace.json")
        let store = try WorkspaceStore(url: url, deviceID: "mac")
        #expect(store.isNew)
        #expect(await store.document.workspace == .empty)
        let saved = try await store.save(workspace: workspace("A"), preferences: ["calendarEnabled": .bool(true)], now: t0)
        #expect(saved.savedAt == t0 && saved.deviceID == "mac")
        let reopened = try WorkspaceStore(url: url, deviceID: "mac")
        #expect(!reopened.isNew)
        #expect(await reopened.document == saved)
    }

    @Test func unchangedSaveKeepsVersionAndStaleBaseIsRejected() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try WorkspaceStore(url: root.appendingPathComponent("workspace.json"), deviceID: "mac")
        let first = try await store.save(workspace: workspace("A"))
        #expect(try await store.save(workspace: workspace("A")).version == first.version)
        // Sync replaced the data after an editor captured `first`; that edit must not overwrite it.
        let newer = try await store.save(workspace: workspace("Remote"), basedOn: first.version)
        await #expect(throws: CoreError.self) { try await store.save(workspace: workspace("Stale"), basedOn: first.version) }
        #expect(await store.document == newer)
    }

    @Test func invalidWorkspaceIsNeverSaved() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try WorkspaceStore(url: root.appendingPathComponent("workspace.json"), deviceID: "mac")
        var invalid = workspace("A"); invalid.items.append(invalid.items[0])
        await #expect(throws: (any Error).self) { try await store.save(workspace: invalid) }
        #expect(await store.document.workspace == .empty)
    }

    @Test func changesTravelBetweenDevicesThroughTheFolder() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("iCloud"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mac = try WorkspaceStore(url: root.appendingPathComponent("mac.json"), deviceID: "mac")
        let phone = try WorkspaceStore(url: root.appendingPathComponent("phone.json"), deviceID: "phone")
        try await mac.save(workspace: workspace("From Mac"))
        #expect(try await mac.connect(folder: folder, start: .useThisDevice) == .uploaded)
        #expect(try await phone.connect(folder: folder, start: .useFolder) == .downloaded)
        #expect(await phone.document.workspace == workspace("From Mac"))
        #expect(try conflictCopies(folder).isEmpty, "An empty device has nothing worth backing up")

        try await phone.save(workspace: workspace("Edited on phone"))
        #expect(try await phone.sync(folder: folder) == .uploaded)
        #expect(try await mac.sync(folder: folder) == .downloaded)
        #expect(await mac.document.workspace == workspace("Edited on phone"))
        #expect(try await mac.sync(folder: folder) == .unchanged)
        #expect(try await phone.sync(folder: folder) == .unchanged)
    }

    @Test(arguments: [true, false]) func concurrentSameFieldEditsMergeAndBackUpTheOther(macIsNewer: Bool) async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("iCloud"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mac = try WorkspaceStore(url: root.appendingPathComponent("mac.json"), deviceID: "mac")
        let phone = try WorkspaceStore(url: root.appendingPathComponent("phone.json"), deviceID: "phone")
        try await mac.save(workspace: workspace("Base"))
        _ = try await mac.connect(folder: folder, start: .useThisDevice)
        _ = try await phone.connect(folder: folder, start: .useFolder)

        let macTime = macIsNewer ? t0.addingTimeInterval(60) : t0, phoneTime = macIsNewer ? t0 : t0.addingTimeInterval(60)
        let macEdit = try await mac.save(workspace: workspace("Mac edit"), now: macTime)
        let phoneEdit = try await phone.save(workspace: workspace("Phone edit"), now: phoneTime)
        #expect(try await phone.sync(folder: folder) == .uploaded)
        let outcome = try await mac.sync(folder: folder)
        guard case .merged(let backupName?) = outcome else { Issue.record("Expected a merge with backup, got \(outcome)"); return }
        let winner = macIsNewer ? macEdit : phoneEdit, loser = macIsNewer ? phoneEdit : macEdit
        let merged = await mac.document
        #expect(merged.workspace == winner.workspace)
        #expect(merged.version != winner.version && merged.deviceID == "mac")
        #expect(try folderDocument(folder) == merged)
        let backup = try JSONCoding.decode(WorkspaceDocument.self, from: Data(contentsOf: folder.appendingPathComponent(backupName)))
        #expect(backup == loser)

        #expect(try await phone.sync(folder: folder) == .downloaded)
        #expect(await phone.document == merged)
    }

    @Test func concurrentDifferentEditsConvergeAfterReopening() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("iCloud"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let macURL = root.appendingPathComponent("mac.json")
        var mac = try WorkspaceStore(url: macURL, deviceID: "mac")
        let phone = try WorkspaceStore(url: root.appendingPathComponent("phone.json"), deviceID: "phone")
        let base = Workspace(items: [WorkItem(id: "a", name: "A", remainingMinutes: 30), WorkItem(id: "b", name: "B", remainingMinutes: 30)])
        try await mac.save(workspace: base, preferences: ["base": .bool(true)])
        _ = try await mac.connect(folder: folder, start: .useThisDevice)
        _ = try await phone.connect(folder: folder, start: .useFolder)
        mac = try WorkspaceStore(url: macURL, deviceID: "mac")
        var mine = base, theirs = base
        mine.items[0].name = "Mac"; theirs.items[1].name = "Phone"
        try await mac.save(workspace: mine, preferences: ["base": .bool(true), "mac": .bool(true)])
        try await phone.save(workspace: theirs, preferences: ["base": .bool(true), "phone": .bool(true)])
        #expect(try await mac.sync(folder: folder) == .uploaded)
        #expect(try await phone.sync(folder: folder) == .merged(backupName: nil))
        #expect(try await mac.sync(folder: folder) == .downloaded)
        let merged = await mac.document
        #expect(await phone.document == merged)
        #expect(merged.workspace.items.map(\.name) == ["Mac", "Phone"])
        #expect(merged.preferences == ["base": .bool(true), "mac": .bool(true), "phone": .bool(true)])
        #expect(try conflictCopies(folder).isEmpty)
    }

    @Test func invalidMergedReferencesFallBackToNewestWins() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("iCloud"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mac = try WorkspaceStore(url: root.appendingPathComponent("mac.json"), deviceID: "mac")
        let phone = try WorkspaceStore(url: root.appendingPathComponent("phone.json"), deviceID: "phone")
        let base = Workspace(items: [WorkItem(id: "a", name: "A", remainingMinutes: 30), WorkItem(id: "b", name: "B", remainingMinutes: 30)])
        try await mac.save(workspace: base)
        _ = try await mac.connect(folder: folder, start: .useThisDevice)
        _ = try await phone.connect(folder: folder, start: .useFolder)
        var mine = base, theirs = base
        mine.items.removeFirst()
        theirs.dependencies.append(Dependency(id: "dependency", source: .item("a"), targetItemID: "b"))
        let winner = try await mac.save(workspace: mine, now: t0.addingTimeInterval(60))
        let loser = try await phone.save(workspace: theirs, now: t0)
        _ = try await phone.sync(folder: folder)
        guard case .conflict(keptThisDevice: true, let name) = try await mac.sync(folder: folder) else {
            Issue.record("Expected newest-wins fallback"); return
        }
        #expect(await mac.document == winner)
        #expect(try folderDocument(folder) == winner)
        #expect(try JSONCoding.decode(WorkspaceDocument.self, from: Data(contentsOf: folder.appendingPathComponent(name))) == loser)
        _ = try await phone.sync(folder: folder)
        #expect(await phone.document == winner)
    }

    @Test func connectingWithThisDeviceBacksUpTheFolderCopy() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("iCloud"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mac = try WorkspaceStore(url: root.appendingPathComponent("mac.json"), deviceID: "mac")
        let phone = try WorkspaceStore(url: root.appendingPathComponent("phone.json"), deviceID: "phone")
        let macDocument = try await mac.save(workspace: workspace("Mac"))
        _ = try await mac.connect(folder: folder, start: .useThisDevice)
        let phoneDocument = try await phone.save(workspace: workspace("Phone"))
        #expect(try await phone.connect(folder: folder, start: .useThisDevice) == .uploaded)
        #expect(try folderDocument(folder) == phoneDocument)
        let copies = try conflictCopies(folder)
        #expect(copies.count == 1)
        #expect(try JSONCoding.decode(WorkspaceDocument.self, from: Data(contentsOf: copies[0])) == macDocument)
    }

    @Test func missingFolderFileIsUploadedAgainAndDisconnectStopsTracking() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("iCloud"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mac = try WorkspaceStore(url: root.appendingPathComponent("mac.json"), deviceID: "mac")
        try await mac.save(workspace: workspace("Mac"))
        _ = try await mac.connect(folder: folder, start: .useThisDevice)
        try FileManager.default.removeItem(at: folder.appendingPathComponent(WorkspaceStore.folderFilename))
        #expect(try await mac.sync(folder: folder) == .uploaded)
        try await mac.disconnect()
        // After disconnecting, the folder copy is treated as unrelated data the next time it syncs.
        let phone = try WorkspaceStore(url: root.appendingPathComponent("phone.json"), deviceID: "phone")
        _ = try await phone.connect(folder: folder, start: .useFolder)
        try await phone.save(workspace: workspace("Phone"))
        _ = try await phone.sync(folder: folder)
        try await mac.save(workspace: workspace("Mac again"), now: Date().addingTimeInterval(60))
        guard case .conflict(keptThisDevice: true, _) = try await mac.sync(folder: folder) else { Issue.record("Expected newest-wins conflict"); return }
    }

    @Test func unreadableFolderFileIsReportedAndNothingChanges() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("iCloud"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: folder.appendingPathComponent(WorkspaceStore.folderFilename))
        let mac = try WorkspaceStore(url: root.appendingPathComponent("mac.json"), deviceID: "mac")
        let before = try await mac.save(workspace: workspace("Mac"))
        await #expect(throws: CoreError.self) { try await mac.connect(folder: folder, start: .useFolder) }
        #expect(await mac.document == before)
    }
}
