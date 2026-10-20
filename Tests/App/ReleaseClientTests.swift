import XCTest
import CryptoKit
import CubicCore

@MainActor final class ReleaseClientTests: XCTestCase {
    private func fixture() async throws -> (URL, UserDefaults, AppModel) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CubicReleaseClient-\(UUID())")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: root.lastPathComponent))
        defaults.set("release-test-device", forKey: "cubic.sync.deviceID")
        let journal = try SyncJournal(directory: root.appendingPathComponent("initial"), workspaceID: "cubic.primary", deviceID: "release-test-device")
        let projection = try await journal.snapshot()
        let model = try await AppModel(testDirectory: root, journal: journal, projection: projection, defaults: defaults)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: root.lastPathComponent)
            try? FileManager.default.removeItem(at: root)
        }
        return (root, defaults, model)
    }
    private func legacyDirectory(_ root: URL, account: String) -> URL {
        let partition = SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("Sync").appendingPathComponent(partition)
    }
    /// Return values only, releasing the writer lease before AppModel reopens this partition.
    private func seedLegacy(_ directory: URL, account: String, deviceID: String = "release-test-device") async throws -> SyncArchive {
        let journal = try SyncJournal(directory: directory, workspaceID: "cubic.primary", deviceID: deviceID)
        try await journal.bindAccount(account)
        let base = Workspace(items: [WorkItem(id: "legacy-work", name: "Downloaded work", remainingMinutes: 60)])
        _ = try await journal.bootstrap(workspace: base)
        var updated = base; updated.items[0].description = "Retained local fact"
        _ = try await journal.record(workspace: updated, currentChoiceID: nil)
        return try await journal.exportArchive()
    }
    private func envelope(_ archive: SyncArchive?, version: Int = 1, marker: String? = nil) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(Workspace.empty)) as? [String: Any])
        object = ["schemaVersion": version, "workspace": object,
                  "preferences": try JSONSerialization.jsonObject(with: encoder.encode(UserPreferences()))]
        if let archive {
            let data = marker == "deferredToDate" ? try SyncCoding.encode(archive) : try encoder.encode(archive)
            object["syncArchive"] = try JSONSerialization.jsonObject(with: data)
        }
        if let marker { object["syncArchiveDateEncoding"] = marker }
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testPolicyRejectsReleaseAndOverridesAndFailsClosed() {
        XCTAssertFalse(ReleaseCapabilities.permitsCloudKit(configuration: "Release", capability: "development", releaseBuild: true))
        XCTAssertFalse(ReleaseCapabilities.permitsCloudKit(configuration: "Debug", capability: "development", releaseBuild: true))
        XCTAssertFalse(ReleaseCapabilities.permitsCloudKit(configuration: "Release", capability: "development", releaseBuild: false))
        XCTAssertFalse(ReleaseCapabilities.permitsCloudKit(configuration: nil, capability: nil, releaseBuild: false))
        XCTAssertTrue(ReleaseCapabilities.permitsCloudKit(configuration: "Debug", capability: "development", releaseBuild: false))
        XCTAssertFalse(ReleaseCapabilities.cloudKitEnabled, "Unit-test bundle has no explicit development capability")
    }
    func testTransportAndDirectConnectionCannotBypassPolicy() async throws {
        let (_, defaults, model) = try await fixture()
        let transport = CloudSyncAdapter(containerID: "invalid.must.not.construct.container", accountID: "probe", workspaceID: "cubic.primary")
        guard case .requiresSigning(let reason) = try await transport.availability() else { return XCTFail("Policy must block before signature or CKContainer") }
        XCTAssertEqual(reason, ReleaseCapabilities.cloudKitUnavailableMessage)
        do { _ = try await transport.pull(cursor: nil); XCTFail("Pull must be blocked") }
        catch { guard case SyncError.requiresSigning = error else { return XCTFail("Unexpected error: \(error)") } }
        let upload = try SyncRevision.recording(
            workspace: Workspace(items: [WorkItem(id: "blocked-work", name: "Must remain local", remainingMinutes: 60)]),
            comparedTo: .empty, id: "blocked-upload", workspaceID: "cubic.primary",
            deviceID: "release-test-device", parents: [])
        do { _ = try await transport.push([upload]); XCTFail("Push must be blocked") }
        catch { guard case SyncError.requiresSigning = error else { return XCTFail("Unexpected error: \(error)") } }
        let original = model.cloudSync
        await model.connectCloudAccount(importLocal: true)
        let switched = await model.prepareSync(accountID: "new-account", transportKind: "cloudkit")
        XCTAssertFalse(switched)
        XCTAssertTrue(model.cloudSync === original)
        XCTAssertNil(defaults.string(forKey: "cubic.sync.activeAccount"))
        XCTAssertEqual(defaults.string(forKey: "cubic.sync.deviceID"), "release-test-device")
    }
    func testLegacyReopenWriteBackupDisconnectRetainPartitionAndOperations() async throws {
        let (root, defaults, model) = try await fixture(), account = "legacy-account"
        let directory = legacyDirectory(root, account: account)
        let original = try await seedLegacy(directory, account: account)
        defaults.set(account, forKey: "cubic.sync.activeAccount")
        // Older installs can lack the explicit transport key.
        let reopened = await model.prepareSync(importLocal: false)
        guard reopened else { return XCTFail("Legacy partition must reopen on the same device") }
        let first = try XCTUnwrap(model.workspace.items.first)
        XCTAssertEqual(first.id, "legacy-work")
        XCTAssertTrue(model.cloudKitLegacyBlocked)
        XCTAssertEqual(model.syncTransportLabel, "CloudKit")
        XCTAssertEqual(model.workspace.items.first?.id, "legacy-work")
        XCTAssertEqual(model.workspace.items.first?.description, "Retained local fact")
        let saved = await model.mutate { workspace in
            guard let index = workspace.items.firstIndex(where: { $0.id == first.id }) else { return }
            workspace.items[index].name = "Edited in Release"
        }
        XCTAssertTrue(saved)
        let exported = await model.exportBackup()
        XCTAssertNotNil(exported)
        let retained = try await XCTUnwrap(model.cloudSync).exportArchive()
        for operation in original.revisions { XCTAssertEqual(retained.revisions.first { $0.id == operation.id }, operation) }
        let controller = model.cloudSync
        await model.disconnectRemoteSync()
        XCTAssertEqual(model.syncTransportLabel, "仅本机")
        XCTAssertEqual(defaults.string(forKey: "cubic.sync.activeAccount"), account)
        XCTAssertEqual(defaults.string(forKey: "cubic.sync.transport"), "local")
        XCTAssertEqual(model.workspace.items.first?.name, "Edited in Release")
        let disconnected = try await XCTUnwrap(model.cloudSync).exportArchive()
        XCTAssertEqual(disconnected, retained)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        await controller?.refresh() // Retired controller must not rebind or publish.
        XCTAssertEqual(model.syncTransportLabel, "仅本机")
    }
    func testLegacyIdentityMismatchRetainsPreviousControllerAndDefaults() async throws {
        let (root, defaults, model) = try await fixture(), account = "legacy-account"
        _ = try await seedLegacy(legacyDirectory(root, account: account), account: "other-account")
        defaults.set(account, forKey: "cubic.sync.activeAccount")
        defaults.set("cloudkit", forKey: "cubic.sync.transport")
        let previous = model.cloudSync
        let reopened = await model.prepareSync(importLocal: false)
        XCTAssertFalse(reopened)
        XCTAssertTrue(model.cloudSync === previous)
        XCTAssertEqual(model.workspace, .empty)
        XCTAssertEqual(defaults.string(forKey: "cubic.sync.activeAccount"), account)
        XCTAssertEqual(defaults.string(forKey: "cubic.sync.transport"), "cloudkit")
        XCTAssertNotNil(model.serviceIssues["账号数据未能切换"])
    }
    func testLegacyDeviceMismatchRetainsPreviousControllerAndFacts() async throws {
        let (root, defaults, model) = try await fixture(), account = "legacy-account"
        let directory = legacyDirectory(root, account: account)
        let original = try await seedLegacy(directory, account: account, deviceID: "other-device")
        defaults.set(account, forKey: "cubic.sync.activeAccount")
        defaults.set("cloudkit", forKey: "cubic.sync.transport")
        let previous = model.cloudSync
        let reopened = await model.prepareSync(importLocal: false)
        XCTAssertFalse(reopened)
        XCTAssertTrue(model.cloudSync === previous)
        XCTAssertEqual(model.workspace, .empty)
        XCTAssertEqual(defaults.string(forKey: "cubic.sync.deviceID"), "release-test-device")
        XCTAssertEqual(defaults.string(forKey: "cubic.sync.activeAccount"), account)
        XCTAssertEqual(defaults.string(forKey: "cubic.sync.transport"), "cloudkit")
        let journal = try SyncJournal(directory: directory, workspaceID: "cubic.primary", deviceID: "other-device")
        let retained = try await journal.exportArchive()
        XCTAssertEqual(retained, original)
    }
    func testArchivePayloadControlsSuccessCopyAndCanonicalOperations() async throws {
        let (root, _, model) = try await fixture()
        let archive = try await seedLegacy(root.appendingPathComponent("source"), account: "source")
        for version in [1, 2] {
            let imported = await model.importBackup(try envelope(archive, version: version, marker: "deferredToDate"))
            XCTAssertTrue(imported)
            XCTAssertEqual(model.statusMessage, "备份已合并。有不同版本的内容时，请到设置处理同步冲突。")
            let actual = try await XCTUnwrap(model.cloudSync).exportArchive()
            for operation in archive.revisions { XCTAssertEqual(actual.revisions.first { $0.id == operation.id }, operation) }
        }
        let before = try await XCTUnwrap(model.cloudSync).exportArchive()
        let rejected = await model.importBackup(try envelope(archive, marker: "unknown"))
        XCTAssertFalse(rejected)
        let after = try await XCTUnwrap(model.cloudSync).exportArchive()
        XCTAssertEqual(after, before)
    }
    func testLegacyEnvelopeWithoutMarkerAndSnapshotCopy() async throws {
        let (root, _, model) = try await fixture()
        let archive = try await seedLegacy(root.appendingPathComponent("source"), account: "source")
        let imported = await model.importBackup(try envelope(archive))
        XCTAssertTrue(imported)
        XCTAssertEqual(model.statusMessage, "备份已合并。有不同版本的内容时，请到设置处理同步冲突。")
        let actual = try await XCTUnwrap(model.cloudSync).exportArchive()
        for operation in archive.revisions {
            let found = try XCTUnwrap(actual.revisions.first { $0.id == operation.id })
            XCTAssertEqual(found.parents, operation.parents)
            XCTAssertEqual(found.changes, operation.changes)
            XCTAssertEqual(found.createdAt.timeIntervalSinceReferenceDate, operation.createdAt.timeIntervalSinceReferenceDate, accuracy: 0.000001)
        }
        let snapshot = await model.importBackup(try envelope(nil))
        XCTAssertTrue(snapshot)
        XCTAssertEqual(model.statusMessage, "旧版备份已导入。这个格式不包含完整的同步修改历史。")
    }
    func testVersionUsesBundleVersionAndBuild() {
        XCTAssertEqual(AppVersion.display(info: ["CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "47"]), "1.2.3 (47)")
        XCTAssertEqual(AppVersion.display(info: [:]), "未知版本 (未知 build)")
    }
}
