import Foundation
import Testing
@testable import CubicCore

private func finalJournal(_ name: String) throws -> (SyncJournal, URL) {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("TemplateFinalQA-\(name)-\(UUID().uuidString)")
    return (try SyncJournal(directory: path, workspaceID: name, deviceID: "qa"), path)
}
private func finalSource() -> Workspace { Workspace(projects: [Project(id: "p", name: "Source")]) }

@Test func finalTemplateHeadGuardHandlesEmptyJournalBeforeValidation() async throws {
    let (journal, path) = try finalJournal("empty")
    defer { try? FileManager.default.removeItem(at: path) }
    var invalid = finalSource(); invalid.projects.append(invalid.projects[0])
    do {
        _ = try await journal.record(workspace: invalid, currentChoiceID: nil, expectedHeads: ["missing"])
        Issue.record("Stale expected heads must reject before validation or append")
    } catch CoreError.blocked(let message) {
        #expect(message.contains("同步更新"))
    }
    #expect(try await journal.snapshot().heads.isEmpty)
    let first = try await journal.record(workspace: finalSource(), currentChoiceID: nil, expectedHeads: [])
    #expect(first.heads.count == 1 && first.workspace.projects.count == 1)
    var stale = first.planningWorkspace
    _ = try stale.saveProjectTemplate(projectID: "p", title: "Must not append", now: Date(timeIntervalSince1970: 1_800_000_000))
    do {
        _ = try await journal.record(workspace: stale, currentChoiceID: nil, expectedHeads: [])
        Issue.record("Empty expected heads cannot match an initialized journal")
    } catch CoreError.blocked { }
    let after = try await journal.snapshot()
    #expect(after.heads == first.heads && after.workspace.projectTemplates?.isEmpty != false)
}

@Test func finalTemplateSameHeadAndLegacyNilContractSucceed() async throws {
    let (journal, path) = try finalJournal("same")
    defer { try? FileManager.default.removeItem(at: path) }
    let root = try await journal.bootstrap(workspace: finalSource())
    var edit = root.planningWorkspace
    _ = try edit.saveProjectTemplate(projectID: "p", title: "Same head", now: Date(timeIntervalSince1970: 1_800_000_000))
    let saved = try await journal.record(workspace: edit, currentChoiceID: nil, expectedHeads: root.heads)
    #expect(saved.workspace.projectTemplates?.count == 1 && saved.heads != root.heads)
    let noop = try await journal.record(workspace: saved.planningWorkspace, currentChoiceID: nil, expectedHeads: saved.heads)
    #expect(noop.heads == saved.heads)
    var ordinary = noop.planningWorkspace; ordinary.projects[0].name = "Ordinary caller"
    let result = try await journal.record(workspace: ordinary, currentChoiceID: nil)
    #expect(result.workspace.projects[0].name == "Ordinary caller" && result.workspace.projectTemplates?.count == 1)
}

@Test func finalTemplateHeadGuardUsesWholeFrontierSet() async throws {
    let (journal, path) = try finalJournal("frontier")
    defer { try? FileManager.default.removeItem(at: path) }
    let root = try await journal.bootstrap(workspace: finalSource())
    var left = root.planningWorkspace; left.projects[0].name = "Remote title"
    var right = root.planningWorkspace; right.projects[0].importance = 4
    let a = try SyncRevision.recording(workspace: left, comparedTo: root.workspace, workspaceID: "frontier", deviceID: "a", parents: root.heads)
    let b = try SyncRevision.recording(workspace: right, comparedTo: root.workspace, workspaceID: "frontier", deviceID: "b", parents: root.heads)
    try await journal.ingest([a, b], cursor: nil)
    let prior = try await journal.snapshot()
    #expect(Set(prior.heads) == Set([a.id, b.id]))
    var edit = prior.planningWorkspace
    _ = try edit.saveProjectTemplate(projectID: "p", title: "Whole frontier", now: Date(timeIntervalSince1970: 1_800_000_000))
    do {
        _ = try await journal.record(workspace: edit, currentChoiceID: nil, expectedHeads: [a.id])
        Issue.record("A partial frontier cannot commit")
    } catch CoreError.blocked { }
    #expect(try await journal.snapshot().heads == prior.heads)
    let saved = try await journal.record(workspace: edit, currentChoiceID: nil, expectedHeads: [b.id, a.id, b.id])
    #expect(saved.workspace.projects[0].name == "Remote title" && saved.workspace.projects[0].importance == 4)
    #expect(saved.workspace.projectTemplates?.count == 1)
}

@Test func finalTemplateConcurrentSameBaseOnlyOneAppendSucceeds() async throws {
    let (journal, path) = try finalJournal("concurrent")
    defer { try? FileManager.default.removeItem(at: path) }
    let root = try await journal.bootstrap(workspace: finalSource())
    let candidates = try ["A", "B"].map { title -> Workspace in
        var w = root.planningWorkspace
        _ = try w.saveProjectTemplate(projectID: "p", title: title, now: Date(timeIntervalSince1970: 1_800_000_000))
        return w
    }
    let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
        for candidate in candidates {
            group.addTask {
                do { _ = try await journal.record(workspace: candidate, currentChoiceID: nil, expectedHeads: root.heads); return true }
                catch CoreError.blocked { return false }
                catch { Issue.record("Unexpected error: \(error)"); return false }
            }
        }
        var count = 0; for await value in group { if value { count += 1 } }; return count
    }
    let result = try await journal.snapshot()
    #expect(successes == 1 && result.heads.count == 1 && result.workspace.projectTemplates?.count == 1)
    #expect(result.workspace.projects[0].name == "Source")
}
