import Foundation
import XCTest
@testable import CubicCore

private actor SettingsCloudGrant: FileSyncDirectoryAccess {
    let directory: URL
    init(_ directory: URL) { self.directory = directory }
    func acquireAccess() async throws -> URL { directory }
    func releaseAccess(to directory: URL) async {}
}

/// Uses the real provider and production journal. Never creates remote metadata or another root revision.
final class RealICloudSettingsQATests: XCTestCase, @unchecked Sendable {
    private func run(_ phase: String, operation: (SyncJournal, FileProviderSyncTransport) async throws -> Void) async throws {
        guard ProcessInfo.processInfo.environment["CUBIC_SETTINGS_SYNC_QA_PHASE"] == phase,
              let path = ProcessInfo.processInfo.environment["CUBIC_SETTINGS_SYNC_QA_DIRECTORY"] else {
            throw XCTSkip("Real settings sync is opt-in for the dedicated QA directory")
        }
        let root = URL(fileURLWithPath: path).standardizedFileURL
        let cloud = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        XCTAssertEqual(root.deletingLastPathComponent().path, cloud.path)
        guard root.deletingLastPathComponent().path == cloud.path, root.lastPathComponent.hasPrefix("Cubic Settings QA ") else { throw SyncError.invalidJournal("QA path") }
        let workspaceID = "cubic.work-calendar.qa", directory = root.appendingPathComponent(workspaceID)
        let metadata = try FileSyncDirectoryIO.readMetadata(in: directory, workspaceID: workspaceID)
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("CubicSettingsObserver-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: local) }
        let journal = try SyncJournal(directory: local, workspaceID: workspaceID, deviceID: "settings-mac-\(UUID().uuidString)")
        try await journal.bindRemote(metadata.remoteBinding)
        let transport = FileProviderSyncTransport(access: SettingsCloudGrant(directory), workspaceID: workspaceID, remoteBindingID: metadata.remoteBinding)
        var pages = 0, remoteIDs = Set<String>()
        repeat {
            let page = try await transport.pull(cursor: await journal.cursor())
            try await journal.ingest(page.revisions, cursor: page.cursor, needsFullReconciliation: page.needsFullReconciliation, fullReconciliationAt: page.fullReconciliationAt)
            remoteIDs.formUnion(page.revisions.map(\.id))
            pages += 1; guard pages < 100 else { throw SyncError.transport("QA page budget") }
            if !page.hasMore { break }
        } while true
        // A full provider scan queues recovery uploads. The observer acknowledges only facts
        // actually read, leaving the publish phase's outbox limited to its new setting revision.
        try await journal.acknowledge(remoteIDs)
        let result = try await journal.snapshot()
        XCTAssertTrue(result.conflicts.isEmpty && result.planningIsValid)
        XCTAssertTrue(result.workspace.items.contains { $0.id == "qa-drag" })
        let status = try await journal.syncStatus()
        XCTAssertEqual(status.stagedCount, 0)
        try await operation(journal, transport)
    }
    func testRead17ProSettingsUpload() async throws {
        try await run("read") { journal, _ in
            let fields = try await journal.snapshot().preferences
            XCTAssertEqual(fields["workSchedule"]?.object?["workTimeZoneID"], .string("Asia/Singapore"))
            XCTAssertEqual(fields["workSchedule"]?.object?["workWeekends"], .bool(true))
            XCTAssertEqual(fields["calendarEnabled"], .bool(false))
            XCTAssertEqual(fields["remindersEnabled"], .bool(false))
            XCTAssertEqual(Set(fields.keys), ["workSchedule", "dayOverrides", "calendarEnabled", "calendarSelection", "remindersEnabled", "disabledReminderCategories"])
            print("SETTINGS_ICLOUD phase=17pro-upload verified=6 conflicts=0")
        }
    }
    func testPublishMacSettingsFor17Pro() async throws {
        try await run("publish") { journal, transport in
            let before = try await journal.snapshot()
            guard var schedule = before.preferences["workSchedule"]?.object else { throw SyncError.invalidJournal("QA schedule missing") }
            schedule["workTimeZoneID"] = .string("Asia/Tokyo"); schedule["workWeekends"] = .bool(false)
            schedule["workPeriods"] = .array([.object(["id": .string("qa-all-day"), "startMinute": .number(600), "endMinute": .number(960), "energy": .string("high")])])
            let changed = try await journal.recordPreferences(["workSchedule": .object(schedule),
                "dayOverrides": .array([.object(["id": .string("2026-10-07"), "unavailable": .bool(true), "periods": .array([])])]),
                "calendarEnabled": .bool(true), "calendarSelection": .object(["selected": .array([]), "countAllDayEvents": .bool(true)]),
                "remindersEnabled": .bool(true), "disabledReminderCategories": .array([.string("results"), .string("waiting")])])
            let pending = await journal.pending(limit: 50)
            XCTAssertEqual(pending.count, 1)
            let acknowledged = try await transport.push(pending)
            XCTAssertEqual(acknowledged, Set(pending.map(\.id)))
            try await journal.acknowledge(acknowledged)
            XCTAssertNotEqual(changed.heads, before.heads)
            print("SETTINGS_ICLOUD phase=mac-publish acknowledged=\(acknowledged.count)")
        }
    }
    func testVerify17ProReturnEditPreservesOtherSettings() async throws {
        try await run("verify") { journal, _ in
            let fields = try await journal.snapshot().preferences
            let schedule = fields["workSchedule"]?.object
            XCTAssertEqual(schedule?["workTimeZoneID"], .string("Asia/Tokyo"))
            XCTAssertEqual(schedule?["workWeekends"], .bool(true))
            XCTAssertEqual(schedule?["workPeriods"], .array([.object(["id": .string("qa-all-day"), "startMinute": .number(600), "endMinute": .number(960), "energy": .string("high")])]))
            XCTAssertEqual(fields["calendarEnabled"], .bool(true))
            XCTAssertEqual(fields["remindersEnabled"], .bool(true))
            XCTAssertEqual(fields["disabledReminderCategories"], .array([.string("results"), .string("waiting")]))
            XCTAssertEqual(fields["dayOverrides"], .array([.object(["id": .string("2026-10-07"), "unavailable": .bool(true), "periods": .array([])])]))
            print("SETTINGS_ICLOUD phase=17pro-return settings-preserved=6 conflicts=0")
        }
    }
}
