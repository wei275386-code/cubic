import Foundation
import Testing
@testable import CubicCore

@Test func independentTemplatePerformanceSamples() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = ContinuousClock()
    func ms(_ start: ContinuousClock.Instant) -> Double {
        let c = start.duration(to: clock.now).components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }
    func progress(_ phase: String, _ count: Int, _ sample: Int) {
        let data = Data("TEMPLATE_INDEPENDENT_PERF works=\(count) sample=\(sample) phase=\(phase)\n".utf8)
        FileHandle.standardOutput.write(data)
        if let path = ProcessInfo.processInfo.environment["CUBIC_QA_PROGRESS_FILE"], let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }; handle.seekToEndOfFile(); handle.write(data)
        }
    }
    for count in [1500, 6000] {
        for sample in 1...3 {
            var w = Workspace(projects: [Project(id: "p", name: "Scale", deadline: now), Project(id: "other", name: "Unrelated")])
            w.nodes = (0..<(count / 100)).map { Node(id: "n\($0)", projectID: "p", name: "Node \($0)") }
            w.items = (0..<count).map { WorkItem(id: "i\($0)", name: "Work \($0)", nodeID: "n\($0 / 100)", projectIDs: ["p"], remainingMinutes: 2) }
            w.items += (0..<2000).map { WorkItem(id: "other\($0)", name: "Unrelated \($0)", projectIDs: ["other"], remainingMinutes: 1) }
            w.dependencies = (0..<count).filter { $0 % 100 != 0 }.map { Dependency(source: .item("i\($0 - 1)"), targetItemID: "i\($0)") }
            progress("preview", count, sample)
            let startPreview = clock.now
            let preview = w.previewProjectTemplate(projectID: "p")
            let previewMS = ms(startPreview)
            #expect(preview.canSave && preview.payload?.items.count == count)
            progress("save", count, sample)
            let startSave = clock.now
            let id = try w.saveProjectTemplate(projectID: "p", title: "Scale", now: now)
            let saveMS = ms(startSave)
            progress("create", count, sample)
            let startCreate = clock.now
            let created = try w.instantiateProjectTemplate(templateID: id, deadline: now.addingTimeInterval(86400), timeZoneID: "Asia/Singapore", dateOnly: true, now: now)
            let createMS = ms(startCreate)
            let copied = w.items.filter { $0.projectIDs == [created] }
            let copiedIDs = Set(copied.map(\.id))
            #expect(copied.count == count)
            #expect(w.dependencies.filter { copiedIDs.contains($0.targetItemID) }.count == count - count / 100)
            #expect(w.history.count == count + count / 100 + 1 + count - count / 100)
            progress("boundary", count, sample)
            let boundaryStart = clock.now
            try w.applyDefaultRemainingEstimates(now: now)
            try w.validate()
            let boundaryMS = ms(boundaryStart)
            progress("encode", count, sample)
            let encodeStart = clock.now
            let bytes = try JSONEncoder().encode(w)
            let encodeMS = ms(encodeStart)
            progress("sync", count, sample)
            let syncStart = clock.now
            let revision = try SyncRevision.recording(workspace: w, comparedTo: nil, workspaceID: "independent-scale", deviceID: "qa", parents: [], createdAt: now)
            let syncMS = ms(syncStart)
            #expect(!revision.changes.isEmpty)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TemplateIndependentQA-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let repo = try SQLiteWorkspaceRepository(url: dir.appendingPathComponent("qa.sqlite"))
            progress("sqlite", count, sample)
            let persistStart = clock.now
            try repo.save(w)
            let stored = try repo.load()
            let canonical = JSONEncoder(); canonical.dateEncodingStrategy = .millisecondsSince1970; canonical.outputFormatting = [.sortedKeys]
            #expect(try canonical.encode(stored) == canonical.encode(w))
            #expect(stored.items == w.items && stored.projectTemplates == w.projectTemplates)
            let persistMS = ms(persistStart)
            print(String(format: "TEMPLATE_INDEPENDENT_PERF mode=debug/macOS works=%d unrelated=2000 sample=%d preview_ms=%.3f save_ms=%.3f create_ms=%.3f app_boundary_ms=%.3f encode_ms=%.3f sync_ms=%.3f sqlite_save_load_ms=%.3f bytes=%d", count, sample, previewMS, saveMS, createMS, boundaryMS, encodeMS, syncMS, persistMS, bytes.count))
        }
    }
}

@Test func independentAcceptanceStaticWaitingRulesMustSurviveTemplate() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var w = Workspace(projects: [Project(id: "p", name: "Approval")],
        items: [WorkItem(id: "i", name: "Deliver", projectIDs: ["p"], remainingMinutes: 30)],
        blockers: [Blocker(id: "b", name: "Await approval", resolutionCondition: "Signed", expectedDurationMinutes: 60)],
        acceptances: [Acceptance(id: "a", subject: .item("i"), name: "Quality pass", candidateBlockerIDs: ["b"])])
    try w.validate()
    let preview = w.previewProjectTemplate(projectID: "p")
    #expect(preview.canSave)
    #expect(preview.payload?.blockers.count == 1, "The saved acceptance's static waiting rule must include its blocker definition")
    let id = try w.saveProjectTemplate(projectID: "p", title: "Approval", now: now)
    let created = try w.instantiateProjectTemplate(templateID: id, deadline: now, timeZoneID: "UTC", dateOnly: false, now: now)
    let copied = try #require(w.items.first { $0.projectIDs == [created] })
    let acceptance = try #require(w.acceptances.first { $0.subject == .item(copied.id) })
    #expect(acceptance.candidateBlockerIDs?.count == 1, "Only execution state should reset; the configured waiting candidates must remap")
    print("TEMPLATE_ACCEPTANCE_PROBE source_candidates=\(w.acceptances[0].candidateBlockerIDs ?? []) preview_blockers=\(preview.payload?.blockers.count ?? -1) copied_candidates=\(acceptance.candidateBlockerIDs ?? [])")
}

@Test func independentDateOnlySQLiteRoundTripDiagnostic() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var w = Workspace(projects: [Project(id: "p", name: "Precision")], items: [WorkItem(id: "i", name: "Work", projectIDs: ["p"], remainingMinutes: 2)])
    let id = try w.saveProjectTemplate(projectID: "p", title: "Precision", now: now)
    let created = try w.instantiateProjectTemplate(templateID: id, deadline: now, timeZoneID: "Asia/Singapore", dateOnly: true, now: now)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TemplatePrecisionQA-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let repo = try SQLiteWorkspaceRepository(url: dir.appendingPathComponent("qa.sqlite"))
    try repo.save(w); let loaded = try repo.load()
    let a = try #require(w.projects.first { $0.id == created }?.deadline)
    let b = try #require(loaded.projects.first { $0.id == created }?.deadline)
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970; encoder.outputFormatting = [.sortedKeys]
    let originalJSON = try encoder.encode(w), loadedJSON = try encoder.encode(loaded)
    print("TEMPLATE_SQLITE_PRECISION exact_equal=\(loaded == w) canonical_json_equal=\(originalJSON == loadedJSON) deadline_delta_seconds=\(b.timeIntervalSince(a)) templates_equal=\(loaded.projectTemplates == w.projectTemplates) items_equal=\(loaded.items == w.items) history_equal=\(loaded.history == w.history)")
    #expect(originalJSON == loadedJSON)
    #expect(abs(b.timeIntervalSince(a)) < 0.001)
    #expect(loaded.items == w.items && loaded.projectTemplates == w.projectTemplates)
}
