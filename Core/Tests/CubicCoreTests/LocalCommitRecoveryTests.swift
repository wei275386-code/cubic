import Foundation
import Testing
@testable import CubicCore

struct LocalCommitRecoveryTests {
    @Test func exactReceiptRecoversOnceAndGatesEveryManifestWriter() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let j = try SyncJournal(directory: url, workspaceID: "recovery", deviceID: "local")
        let base = Workspace(items: [WorkItem(id: "a", name: "A", remainingMinutes: 60)])
        let initial = try await j.bootstrap(workspace: base)
        try await j.ingest([], cursor: Data("safe".utf8))
        let manifest = url.appendingPathComponent("manifest.json")
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        var edit = base
        try edit.chooseNextAction(itemID: "a", now: Date())
        let failure: SyncLocalCommitFailure
        do { _ = try await j.record(workspace: edit, currentChoiceID: edit.currentChoiceID, expectedHeads: initial.heads); throw TestFailure.expectedFailure }
        catch let e as SyncLocalCommitFailure { failure = e }
        #expect(failure.receipt.durability == .verified)
        for operation in 0..<7 {
            do {
                switch operation {
                case 0: _ = try await j.snapshot()
                case 1: try await j.bindAccount("account")
                case 2: try await j.resetCursor()
                case 3: try await j.enqueueAllForRecovery()
                case 4: try await j.acknowledge([])
                case 5: try await j.ingest([], cursor: Data("unsafe".utf8))
                default: _ = try await j.recordPreferences(["test": .bool(true)])
                }
                Issue.record("Unrecovered manifest writer allowed: \(operation)")
            } catch let e as SyncLocalCommitFailure { #expect(e.receipt == failure.receipt) }
        }
        #expect(await j.cursor() == Data("safe".utf8))
        try FileManager.default.removeItem(at: manifest)
        guard case .committed(let recovered) = try await j.recoverLocalCommit(failure.receipt) else { throw TestFailure.expectedCommit }
        #expect((recovered.workspace.choices ?? []).count == 1)
        #expect(recovered.workspace.currentChoiceID == edit.currentChoiceID)
        #expect(await j.pending().count == 2)
        guard case .committed(let repeated) = try await j.recoverLocalCommit(failure.receipt) else { throw TestFailure.expectedCommit }
        #expect(repeated.heads == recovered.heads)
        #expect(await j.pending().count == 2)
        // A prepared workspace cannot acquire new heads and overwrite the recovered choice.
        do { _ = try await j.record(workspace: base, currentChoiceID: nil, expectedHeads: initial.heads); Issue.record("stale edit accepted") }
        catch is CoreError { }
    }
    enum TestFailure: Error { case expectedFailure, expectedCommit }
}
