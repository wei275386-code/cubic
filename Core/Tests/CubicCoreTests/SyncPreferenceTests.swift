import Foundation
import Testing
@testable import CubicCore

@Suite struct SyncPreferenceTests {
    private func journal(_ name: String) throws -> SyncJournal {
        try SyncJournal(directory: FileManager.default.temporaryDirectory.appendingPathComponent("CubicPreferences-\(UUID().uuidString)"), workspaceID: "preferences", deviceID: name)
    }
    @Test func settingsOnlySaveIsDurableAndSurvivesDomainSaveAndArchiveRestore() async throws {
        let j = try journal("phone")
        let fields: [String: SyncValue] = ["workSchedule": .object(["workTimeZoneID": .string("Asia/Singapore"), "workWeekends": .bool(true)]), "calendarEnabled": .bool(false)]
        let saved = try await j.recordPreferences(fields)
        #expect(saved.preferences == fields && saved.workspace == .empty)
        #expect(try await j.syncStatus().pendingCount == 1)
        let same = try await j.recordPreferences(fields)
        #expect(same.heads == saved.heads)
        _ = try await j.record(workspace: Workspace(items: [WorkItem(id: "a", name: "A", remainingMinutes: 30)]), currentChoiceID: nil)
        #expect(try await j.snapshot().preferences == fields)
        let archive = try await j.exportArchive()
        let restored = try journal("restore")
        let result = try await restored.restoreArchive(archive)
        #expect(result.preferences == fields && result.workspace.items.count == 1)
    }
    @Test func independentSettingEditsMergeAndSameGroupConflictRequiresResolution() async throws {
        let a = try journal("a"), b = try journal("b")
        _ = try await a.recordPreferences(["workSchedule": .object(["zone": .string("UTC")]), "remindersEnabled": .bool(false)])
        try await b.ingest(await a.pending(limit: 50), cursor: nil)
        _ = try await a.recordPreferences(["workSchedule": .object(["zone": .string("Asia/Singapore")])])
        _ = try await b.recordPreferences(["remindersEnabled": .bool(true)])
        try await a.ingest(await b.pending(limit: 50), cursor: nil)
        let independent = try await a.snapshot()
        #expect(independent.conflicts.isEmpty && independent.preferences["remindersEnabled"] == .bool(true))
        try await b.ingest(await a.pending(limit: 50), cursor: nil)
        _ = try await a.recordPreferences(["workSchedule": .object(["zone": .string("Asia/Tokyo")])])
        _ = try await b.recordPreferences(["workSchedule": .object(["zone": .string("Europe/London")])])
        try await a.ingest(await b.pending(limit: 50), cursor: nil)
        let conflict = try #require(try await a.snapshot().conflicts.first)
        #expect(conflict.paths == [SyncDocument.preference("workSchedule")])
        #expect(try await a.snapshot().preferences["workSchedule"] == nil)
        await #expect(throws: SyncError.self) { try await a.recordPreferences(["workSchedule": .null]) }
        _ = try await a.recordPreferences(["calendarEnabled": .bool(true)])
        let resolved = try await a.resolve(conflictID: conflict.id, choosingRevisionID: conflict.candidates[0].revisionID)
        #expect(resolved.conflicts.isEmpty && resolved.preferences["calendarEnabled"] == .bool(true))
        #expect(resolved.preferences["workSchedule"] == conflict.candidates[0].value)
    }
    @Test func legacyDomainRevisionsDoNotClearNewPreferences() async throws {
        let j = try journal("phone")
        let w = Workspace(items: [WorkItem(id: "a", name: "A", remainingMinutes: 30)])
        let root = try SyncRevision.recording(workspace: w, id: "root", workspaceID: "preferences", deviceID: "legacy", parents: [])
        try await j.ingest([root], cursor: nil)
        _ = try await j.recordPreferences(["remindersEnabled": .bool(true)])
        var updated = w; updated.items[0].name = "Legacy edit"
        let oldClient = try SyncRevision.recording(workspace: updated, comparedTo: w, id: "old-client", workspaceID: "preferences", deviceID: "legacy", parents: [root.id])
        try await j.ingest([oldClient], cursor: nil)
        let result = try await j.snapshot()
        #expect(result.preferences["remindersEnabled"] == .bool(true))
        #expect(result.workspace.items[0].name == "Legacy edit" && result.conflicts.isEmpty)
    }
}
