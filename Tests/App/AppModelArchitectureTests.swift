import XCTest
import CubicCore

@MainActor final class AppModelArchitectureTests: XCTestCase {
    private var base: Workspace { Workspace(items: [WorkItem(id: "a", name: "A", remainingMinutes: 60), WorkItem(id: "b", name: "B", remainingMinutes: 60)]) }
    private func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func model(_ name: String, workspace: Workspace = .empty) async throws -> AppModel {
        let directory = try temporaryDirectory(name)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: directory.lastPathComponent))
        addTeardownBlock { defaults.removePersistentDomain(forName: directory.lastPathComponent) }
        return try await AppModel(testDirectory: directory, defaults: defaults, workspace: workspace)
    }
    private func storedWorkspace(_ directory: URL) async throws -> Workspace {
        try await WorkspaceStore(url: directory.appendingPathComponent("workspace.json"), deviceID: "reader").document.workspace
    }

    func testEditsReachAnotherDeviceThroughTheSyncFolder() async throws {
        let folder = try temporaryDirectory("CubicSyncFolder")
        let mac = try await model("CubicMac", workspace: base), phone = try await model("CubicPhone")
        await mac.connectSyncDirectory(try XCTUnwrap(mac.inspectSyncDirectory(folder)), start: .useThisDevice)
        let inspection = try XCTUnwrap(phone.inspectSyncDirectory(folder))
        XCTAssertTrue(inspection.hasCubicData)
        await phone.connectSyncDirectory(inspection, start: .useFolder)
        XCTAssertEqual(phone.workspace, base)
        XCTAssertEqual(phone.syncState.phase, .synced)

        let placeholder = folder.appendingPathComponent(".Cubic.json.icloud")
        try Data().write(to: placeholder)
        let saved = await mac.mutate { $0.items[0].name = "Renamed on Mac" }
        XCTAssertTrue(saved)
        let phoneSaved = await phone.mutate { $0.items[1].name = "Renamed on Phone" }
        XCTAssertTrue(phoneSaved)
        await mac.refreshSync()
        var settings = mac.preferences; settings.workWeekends = false
        let savedSettings = await mac.savePreferences(settings)
        XCTAssertTrue(savedSettings)
        for _ in 0..<50 {
            if mac.syncState.phase == .waiting && phone.syncState.phase == .waiting { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(mac.syncState.phase, .waiting)
        XCTAssertEqual(phone.syncState.phase, .waiting)
        XCTAssertEqual(mac.workspace.items.map(\.name), ["Renamed on Mac", "B"])
        XCTAssertEqual(phone.workspace.items.map(\.name), ["A", "Renamed on Phone"])
        try FileManager.default.removeItem(at: placeholder)
        for _ in 0..<50 {
            await mac.refreshSync()
            await phone.refreshSync()
            if mac.workspace == phone.workspace && !phone.preferences.workWeekends { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(phone.workspace.items[0].name, "Renamed on Mac")
        XCTAssertFalse(phone.preferences.workWeekends)
        await mac.refreshSync()
        await phone.refreshSync()
        XCTAssertEqual(mac.workspace, phone.workspace)
        XCTAssertEqual(mac.workspace.items.map(\.name), ["Renamed on Mac", "Renamed on Phone"])

        await phone.disconnectSync()
        XCTAssertNil(phone.syncDirectoryLabel)
        XCTAssertEqual(phone.syncState.phase, .localOnly)
    }

    func testRealConfirmationKeepsPreciseEvidenceAcrossReopen() async throws {
        let directory = try temporaryDirectory("CubicChoiceAdapter")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: directory.lastPathComponent))
        addTeardownBlock { defaults.removePersistentDomain(forName: directory.lastPathComponent) }
        let model = try await AppModel(testDirectory: directory, defaults: defaults, workspace: base)
        let start = Date().addingTimeInterval(3600)
        let calculated = await model.planningTrial(itemID: "a", minutes: 30, start: start)
        var displayed = try XCTUnwrap(calculated)
        let presentation = UUID()
        var outcome = await model.confirmDisplayedTrial(presentationID: presentation, displayed: displayed, request: displayed.request, note: "first", isCurrent: { true })
        if case .redisplay(let latest) = outcome {
            displayed = latest
            outcome = await model.confirmDisplayedTrial(presentationID: presentation, displayed: displayed, request: displayed.request, note: "first", isCurrent: { true })
        }
        guard case .confirmed = outcome else { return XCTFail("Actual adapter did not confirm") }
        XCTAssertEqual(model.workspace.choices?.count, 1)
        let choiceID = try XCTUnwrap(model.workspace.currentChoiceID)
        let detail = try XCTUnwrap(model.workspace.history.first { $0.objectID == choiceID && $0.detail != nil }?.detail)
        let precise = try JSONCoding.decode(PlanningTrialResult.self, from: Data(detail.utf8))
        XCTAssertEqual(precise.request, displayed.request)
        XCTAssertEqual(precise.source.input.revision.workspace, displayed.source.input.revision.workspace)
        XCTAssertGreaterThanOrEqual(precise.source.input.now, displayed.source.input.now)
        XCTAssertEqual(precise.request.minutes, 30)
        let reproduced = try Engine.trial(workspace: base, request: precise.request, input: precise.source.input)
        XCTAssertEqual(precise, reproduced, "Saved latest evidence preserves full precision and the complete Engine result")
        _ = await model.confirmDisplayedTrial(presentationID: presentation, displayed: displayed, request: displayed.request, note: "duplicate", isCurrent: { true })
        XCTAssertEqual(model.workspace.choices?.count, 1, "A completed presentation never records a second choice")

        let reopened = try await storedWorkspace(directory)
        XCTAssertEqual(reopened.currentChoiceID, choiceID)
        XCTAssertTrue(reopened.history.contains { $0.objectID == choiceID && $0.detail == detail })
    }
}
