import Foundation
import Testing
@testable import CubicCore

@Suite(.serialized) struct WorkspaceSyncScenarioTests {
    private let t0 = Date(timeIntervalSince1970: 1_900_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    private struct Pair {
        let root: URL, folder: URL, mac: WorkspaceStore, phone: WorkspaceStore
    }
    private func pair(_ base: Workspace, preferences: [String: JSONValue] = [:]) async throws -> Pair {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CubicSyncScenario-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("iCloud")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mac = try WorkspaceStore(url: root.appendingPathComponent("mac.json"), deviceID: "mac")
        let phone = try WorkspaceStore(url: root.appendingPathComponent("phone.json"), deviceID: "phone")
        try await mac.save(workspace: base, preferences: preferences, now: t0)
        _ = try await mac.connect(folder: folder, start: .useThisDevice)
        _ = try await phone.connect(folder: folder, start: .useFolder)
        return Pair(root: root, folder: folder, mac: mac, phone: phone)
    }
    /// Alternating syncs until both sides report unchanged.
    @discardableResult
    private func settle(_ p: Pair, first: String = "mac") async throws -> [FolderSyncOutcome] {
        var outcomes: [FolderSyncOutcome] = []
        let order = first == "mac" ? [p.mac, p.phone] : [p.phone, p.mac]
        for _ in 0..<4 {
            for store in order {
                let outcome = try await store.sync(folder: p.folder)
                outcomes.append(outcome)
            }
        }
        return outcomes
    }
    private func backups(_ folder: URL) throws -> [WorkspaceDocument] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("Cubic-conflict-") }
            .map { try JSONCoding.decode(WorkspaceDocument.self, from: Data(contentsOf: $0)) }
    }
    private func folderDocument(_ folder: URL) throws -> WorkspaceDocument {
        try JSONCoding.decode(WorkspaceDocument.self, from: Data(contentsOf: folder.appendingPathComponent(WorkspaceStore.folderFilename)))
    }
    /// Both devices and the folder hold the same valid document.
    @discardableResult
    private func expectConverged(_ p: Pair, sourceLocation: SourceLocation = #_sourceLocation) async throws -> WorkspaceDocument {
        let mac = await p.mac.document, phone = await p.phone.document
        #expect(mac == phone, "devices differ", sourceLocation: sourceLocation)
        #expect(try folderDocument(p.folder) == mac, "folder differs", sourceLocation: sourceLocation)
        #expect(throws: Never.self, sourceLocation: sourceLocation) { try mac.workspace.validate() }
        return mac
    }
    /// The fact is either in the merged result or in a backup file.
    private func expectKept(_ p: Pair, _ label: String, sourceLocation: SourceLocation = #_sourceLocation,
                            _ fact: (WorkspaceDocument) -> Bool) async throws {
        let merged = await p.mac.document
        let inBackup = try backups(p.folder).contains(where: fact)
        #expect(fact(merged) || inBackup, "lost without backup: \(label)", sourceLocation: sourceLocation)
    }
    private func projectBase() throws -> Workspace {
        var w = Workspace.empty
        try w.addProject(Project(id: "p", name: "P"), now: t0)
        for id in ["n1", "n2", "n3"] { try w.addNode(Node(id: id, projectID: "p", name: id.uppercased()), now: t0) }
        try w.addItem(WorkItem(id: "w", name: "Work", nodeID: "n1", projectIDs: ["p"], remainingMinutes: 120), now: t0)
        try w.addItem(WorkItem(id: "x", name: "Other", projectIDs: ["p"], remainingMinutes: 60), now: t0)
        return w
    }

    // MARK: Scenarios

    @Test(arguments: [true, false]) func bothRecordWorkOnSameItem(macNewer: Bool) async throws {
        let base = try projectBase()
        let p = try await pair(base); defer { try? FileManager.default.removeItem(at: p.root) }
        var mine = base, theirs = base
        try mine.recordWork(itemID: "w", start: at(10), end: at(40), actualMinutes: 30, remainingMinutes: 90)
        try theirs.recordWork(itemID: "w", start: at(50), end: at(70), actualMinutes: 20, remainingMinutes: 100)
        try await p.mac.save(workspace: mine, now: at(macNewer ? 200 : 100))
        try await p.phone.save(workspace: theirs, now: at(macNewer ? 100 : 200))
        let outcomes = try await settle(p, first: "phone")
        let merged = try await expectConverged(p)
        for session in mine.workSessions + theirs.workSessions {
            #expect(merged.workspace.workSessions.contains(session))
        }
        #expect(outcomes.contains { if case .merged = $0 { true } else { false } })
        #expect(!outcomes.contains { if case .conflict = $0 { true } else { false } })
        #expect(Set(merged.workspace.workSessions.map(\.actualMinutes)) == [20, 30], "both sessions merged")
    }

    @Test(arguments: [true, false]) func deleteVersusRecordWork(macNewer: Bool) async throws {
        let base = try projectBase()
        let p = try await pair(base); defer { try? FileManager.default.removeItem(at: p.root) }
        var mine = base, theirs = base
        try mine.deleteItem(id: "w", now: at(10))
        try theirs.recordWork(itemID: "w", start: at(10), end: at(40), actualMinutes: 30, remainingMinutes: 60)
        try await p.mac.save(workspace: mine, now: at(macNewer ? 200 : 100))
        try await p.phone.save(workspace: theirs, now: at(macNewer ? 100 : 200))
        _ = try await settle(p, first: "mac")
        _ = try await expectConverged(p)
        try await expectKept(p, "work session") { $0.workspace.workSessions.contains(theirs.workSessions[0]) }
        try await expectKept(p, "deletion") { $0.workspace.deletedItems?.contains { $0.id == "w" } == true }
    }

    @Test func reorderVersusRenameDifferentNodes() async throws {
        let base = try projectBase()
        let p = try await pair(base); defer { try? FileManager.default.removeItem(at: p.root) }
        var mine = base, theirs = base
        try mine.reorderProjectNodes(projectID: "p", orderedNodeIDs: ["n3", "n1", "n2"], now: at(10))
        var node = theirs.nodes.first { $0.id == "n2" }!; node.name = "Renamed"
        try theirs.updateNode(node, now: at(10))
        try await p.mac.save(workspace: mine, now: at(100))
        try await p.phone.save(workspace: theirs, now: at(200))
        _ = try await settle(p, first: "mac")
        let merged = try await expectConverged(p)
        let structure = merged.workspace.projectStructure(projectID: "p").nodes.map(\.id)
        #expect(structure == ["n3", "n1", "n2"], "intent: reorder kept, got \(structure)")
        #expect(merged.workspace.nodes.first { $0.id == "n2" }?.name == "Renamed", "intent: rename kept")
    }

    /// Two stores syncing at the same moment must not both upload over the common version.
    @Test func simultaneousSyncsKeepBothEdits() async throws {
        let base = try projectBase()
        for _ in 0..<20 {
            let p = try await pair(base); defer { try? FileManager.default.removeItem(at: p.root) }
            var mine = base, theirs = base
            try mine.addItem(WorkItem(id: "a", name: "A", projectIDs: ["p"], remainingMinutes: 30), now: at(10))
            try theirs.addItem(WorkItem(id: "b", name: "B", projectIDs: ["p"], remainingMinutes: 30), now: at(10))
            try await p.mac.save(workspace: mine, now: at(100))
            try await p.phone.save(workspace: theirs, now: at(200))
            async let macSync = p.mac.sync(folder: p.folder)
            async let phoneSync = p.phone.sync(folder: p.folder)
            _ = try await (macSync, phoneSync)
            try await settle(p)
            let merged = try await expectConverged(p)
            #expect(Set(merged.workspace.items.map(\.id)).isSuperset(of: ["a", "b"]))
        }
    }

    @Test(arguments: [true, false]) func bothReorderSameProjectDifferently(macNewer: Bool) async throws {
        let base = try projectBase()
        let p = try await pair(base); defer { try? FileManager.default.removeItem(at: p.root) }
        var mine = base, theirs = base
        try mine.reorderProjectNodes(projectID: "p", orderedNodeIDs: ["n2", "n1", "n3"], now: at(10))
        try theirs.reorderProjectNodes(projectID: "p", orderedNodeIDs: ["n1", "n3", "n2"], now: at(10))
        let macEdit = try await p.mac.save(workspace: mine, now: at(macNewer ? 200 : 100))
        let phoneEdit = try await p.phone.save(workspace: theirs, now: at(macNewer ? 100 : 200))
        let outcomes = try await settle(p, first: "phone")
        let merged = try await expectConverged(p)
        let orders = merged.workspace.nodes.map { "\($0.id):\($0.structureOrder ?? -1)<-\($0.sequentialPredecessorNodeID ?? "-")" }
        let structure = merged.workspace.projectStructure(projectID: "p").nodes.map(\.id)
        let winner = macNewer ? ["n2", "n1", "n3"] : ["n1", "n3", "n2"]
        // A field-by-field mix of two orderings should resolve to one of them, with the other in a backup.
        #expect(structure == winner, "intent: newer ordering wins as a whole, got \(structure) / \(orders)")
        let orderValues = merged.workspace.nodes.compactMap(\.structureOrder)
        #expect(Set(orderValues).count == orderValues.count, "duplicate structureOrder values \(orders)")
        #expect(outcomes.contains { if case .conflict(keptThisDevice: macNewer, _) = $0 { true } else { false } })
        #expect(merged == (macNewer ? macEdit : phoneEdit))
        #expect(try backups(p.folder).contains(macNewer ? phoneEdit : macEdit))
    }

    @Test(arguments: [true, false]) func bothChangeSameSetting(macNewer: Bool) async throws {
        let p = try await pair(try projectBase(), preferences: ["theme": .string("system"), "dayStart": .number(9)])
        defer { try? FileManager.default.removeItem(at: p.root) }
        try await p.mac.save(preferences: ["theme": .string("dark"), "dayStart": .number(9)], now: at(macNewer ? 200 : 100))
        try await p.phone.save(preferences: ["theme": .string("light"), "dayStart": .number(8)], now: at(macNewer ? 100 : 200))
        _ = try await settle(p, first: "mac")
        let merged = try await expectConverged(p)
        #expect(merged.preferences["theme"] == .string(macNewer ? "dark" : "light"))
        #expect(merged.preferences["dayStart"] == .number(8))
        let loser: JSONValue = .string(macNewer ? "light" : "dark")
        #expect(try backups(p.folder).contains { $0.preferences["theme"] == loser })
    }

    @Test func threeRoundsOfAlternatingOfflineEdits() async throws {
        let base = try projectBase()
        let p = try await pair(base); defer { try? FileManager.default.removeItem(at: p.root) }
        var expectedItems: Set<String> = ["w", "x"]
        var clock = 100.0
        for round in 1...3 {
            var mine = await p.mac.document.workspace, theirs = await p.phone.document.workspace
            try mine.addItem(WorkItem(id: "mac-\(round)", name: "Mac \(round)", projectIDs: ["p"], remainingMinutes: 10 * round), now: at(clock))
            try theirs.addItem(WorkItem(id: "phone-\(round)", name: "Phone \(round)", projectIDs: ["p"], remainingMinutes: 5 * round), now: at(clock))
            var x = mine.items.first { $0.id == "x" }!; x.name = "Other by mac \(round)"; try mine.updateItem(x, now: at(clock))
            var w = theirs.items.first { $0.id == "w" }!; w.description = "phone note \(round)"; try theirs.updateItem(w, now: at(clock))
            clock += 10
            try await p.mac.save(workspace: mine, now: at(clock)); clock += 10
            try await p.phone.save(workspace: theirs, now: at(clock)); clock += 10
            // Sync only one side mid-round, then the other edits again before seeing it.
            _ = try await (round % 2 == 0 ? p.mac : p.phone).sync(folder: p.folder)
            let late = round % 2 == 0 ? p.phone : p.mac
            var extra = await late.document.workspace
            try extra.addItem(WorkItem(id: "late-\(round)", name: "Late \(round)", projectIDs: ["p"], remainingMinutes: 15), now: at(clock))
            try await late.save(workspace: extra, now: at(clock)); clock += 10
            expectedItems.formUnion(["mac-\(round)", "phone-\(round)", "late-\(round)"])
            _ = try await settle(p, first: round % 2 == 0 ? "phone" : "mac")
            let merged = try await expectConverged(p)
            #expect(Set(merged.workspace.items.map(\.id)) == expectedItems, "round \(round)")
            #expect(merged.workspace.items.first { $0.id == "x" }?.name == "Other by mac \(round)")
            #expect(merged.workspace.items.first { $0.id == "w" }?.description == "phone note \(round)")
        }
        #expect(try backups(p.folder).isEmpty, "no conflicts were expected")
    }

    @Test(arguments: [true, false]) func invalidMergeFallsBackWithoutCorruption(macNewer: Bool) async throws {
        let base = try projectBase()
        let p = try await pair(base); defer { try? FileManager.default.removeItem(at: p.root) }
        var mine = base, theirs = base
        try mine.deleteItem(id: "x", now: at(10))
        try theirs.addDependency(Dependency(id: "dep", source: .item("x"), targetItemID: "w"), now: at(10))
        try await p.mac.save(workspace: mine, now: at(macNewer ? 200 : 100))
        try await p.phone.save(workspace: theirs, now: at(macNewer ? 100 : 200))
        _ = try await settle(p, first: "phone")
        let merged = try await expectConverged(p)
        #expect(merged.workspace == (macNewer ? mine : theirs))
        try await expectKept(p, "dependency") { $0.workspace.dependencies.contains { $0.id == "dep" } }
        try await expectKept(p, "deletion") { $0.workspace.deletedItems?.contains { $0.id == "x" } == true }
    }

    @Test(arguments: [true, false]) func bothChooseDifferentNextAction(macNewer: Bool) async throws {
        let base = try projectBase()
        let p = try await pair(base); defer { try? FileManager.default.removeItem(at: p.root) }
        var mine = base, theirs = base
        try mine.chooseNextAction(itemID: "w", now: at(10))
        try theirs.chooseNextAction(itemID: "x", now: at(11))
        try await p.mac.save(workspace: mine, now: at(macNewer ? 200 : 100))
        try await p.phone.save(workspace: theirs, now: at(macNewer ? 100 : 200))
        _ = try await settle(p, first: "mac")
        let merged = try await expectConverged(p)
        #expect(merged.workspace.currentChoiceID == (macNewer ? mine : theirs).currentChoiceID)
        #expect(merged.workspace.choices?.count == 2)
    }

    @Test(arguments: [true, false]) func completeVersusRecordWork(macNewer: Bool) async throws {
        let base = try projectBase()
        let p = try await pair(base); defer { try? FileManager.default.removeItem(at: p.root) }
        var mine = base, theirs = base
        try mine.startItem(id: "x", now: at(5)); try mine.completeItem(id: "x", now: at(20))
        try theirs.recordWork(itemID: "x", start: at(30), end: at(50), actualMinutes: 20, remainingMinutes: 40)
        try await p.mac.save(workspace: mine, now: at(macNewer ? 200 : 100))
        try await p.phone.save(workspace: theirs, now: at(macNewer ? 100 : 200))
        _ = try await settle(p, first: "phone")
        _ = try await expectConverged(p)
        try await expectKept(p, "session") { $0.workspace.workSessions.contains(theirs.workSessions[0]) }
        try await expectKept(p, "completion") { $0.workspace.items.first { $0.id == "x" }?.status == .completed }
    }

    @Test func templateSavedWhileProjectEdited() async throws {
        let base = try projectBase()
        let p = try await pair(base); defer { try? FileManager.default.removeItem(at: p.root) }
        var mine = base, theirs = base
        let templateID = try mine.saveProjectTemplate(projectID: "p", title: "T", now: at(10))
        var project = theirs.projects[0]; project.name = "Renamed P"; try theirs.updateProject(project, now: at(10))
        try theirs.addItem(WorkItem(id: "added", name: "Added", nodeID: "n2", projectIDs: ["p"], remainingMinutes: 5), now: at(10))
        try await p.mac.save(workspace: mine, now: at(100))
        try await p.phone.save(workspace: theirs, now: at(200))
        _ = try await settle(p, first: "mac")
        let merged = try await expectConverged(p)
        #expect(merged.workspace.projectTemplate(id: templateID) != nil)
        #expect(merged.workspace.projects[0].name == "Renamed P")
        #expect(merged.workspace.items.contains { $0.id == "added" })
    }

    // MARK: Direct merge probes

    @Test func smallNumbersSurviveJSONValueRoundTrip() throws {
        let w = Workspace(projects: [Project(id: "p", name: "P", importance: 1)],
                          items: [WorkItem(id: "a", name: "A", projectIDs: ["p"], remainingMinutes: 0, initialMinutes: 1)])
        let value = try JSONCoding.decode(JSONValue.self, from: JSONCoding.encode(w))
        #expect(try JSONCoding.decode(Workspace.self, from: JSONCoding.encode(value)) == w)
    }

    // MARK: Node lifecycle and concurrent round scenarios

    @Test func nodeOrderLifecycle() throws {
        let t = Date(timeIntervalSince1970: 1_900_000_000)
        var w = Workspace.empty
        try w.addProject(Project(id: "p", name: "P"), now: t)
        for id in ["a", "b", "c"] { try w.addNode(Node(id: id, projectID: "p", name: id), now: t) }
        try w.setArchived(.node("b"), archived: true, now: t)
        try w.addNode(Node(id: "d", projectID: "p", name: "D"), now: t)
        try w.reorderProjectNodes(projectID: "p", orderedNodeIDs: ["d", "c", "a"], now: t)
        try w.setArchived(.node("b"), archived: false, now: t)
        try w.addNode(Node(id: "e", projectID: "p", name: "E"), now: t)
        try w.reorderProjectNodes(projectID: "p", orderedNodeIDs: ["b", "e", "a", "c", "d"], now: t)
        try w.setProjectArchived(id: "p", archived: true, now: t)
        try w.setProjectArchived(id: "p", archived: false, now: t)
        try w.archiveCurrentWorkspace(now: t)
        try w.addNode(Node(id: "f", projectID: "p", name: "F"), now: t)
        try w.validate()
        #expect(Set(w.nodes.compactMap(\.structureOrder)).count == w.nodes.count)
    }

    @Test func moveAndCopyWorkAcrossProjects() throws {
        let t = Date(timeIntervalSince1970: 1_900_000_000)
        var w = Workspace(projects: [Project(id: "p", name: "P"), Project(id: "q", name: "Q")],
                          nodes: [Node(id: "a", projectID: "p", name: "A"), Node(id: "b", projectID: "p", name: "B"),
                                  Node(id: "c", projectID: "q", name: "C"), Node(id: "d", projectID: "q", name: "D", isArchived: true)])
        try w.addItem(WorkItem(id: "work", name: "Work", nodeID: "a", projectIDs: ["p"], remainingMinutes: 30), now: t)
        try w.moveNode(id: "a", projectID: "q", now: t)
        try w.validate()
        #expect(w.items[0].projectIDs == ["q"])
        var item = w.items[0]; item.nodeID = "b"; item.projectIDs = ["p"]
        try w.updateItem(item, now: t)
        _ = try w.copyItem(id: "work", newID: "copy", projectID: "q", nodeID: "c", now: t)
        try w.setArchived(.item("copy"), archived: true, now: t)
        try w.setArchived(.item("copy"), archived: false, now: t)
        try w.deleteItem(id: "copy", now: t)
        try w.moveNode(id: "d", projectID: "p", now: t)
        try w.setArchived(.node("d"), archived: false, now: t)
        try w.addNode(Node(id: "new", projectID: "q", name: "New"), now: t)
        try w.validate()
    }

    @Test func markdownAndTemplateCopies() throws {
        let t = Date(timeIntervalSince1970: 1_900_000_000)
        var w = Workspace.empty
        let p = try w.addMarkdownProject("Project\n- First\n  - Work, 30min\n- Second\n  - More, 15min\n- Third", now: t)
        let ids = w.nodes.map(\.id)
        try w.setArchived(.node(ids[2]), archived: true, now: t)
        try w.reorderProjectNodes(projectID: p, orderedNodeIDs: [ids[1], ids[0]], now: t)
        let template = try w.saveProjectTemplate(projectID: p, title: "Copy", now: t)
        for _ in 0..<2 {
            let copy = try w.instantiateProjectTemplate(templateID: template, deadline: t.addingTimeInterval(86400), timeZoneID: "Asia/Singapore", dateOnly: false, now: t)
            try w.addNode(Node(projectID: copy, name: "Extra"), now: t)
            try w.validate()
        }
        try w.setArchived(.node(ids[2]), archived: false, now: t)
        try w.addNode(Node(projectID: p, name: "Extra original"), now: t)
        try w.validate()
        #expect(w.projects.count == 3)
    }

    @Test(arguments: [0, 1, 2, 3], [true, false])
    func concurrentRounds(mode: Int, firstIsNewer: Bool) async throws {
        let t = Date(timeIntervalSince1970: 1_900_000_000)
        let root = URL(fileURLWithPath: "/tmp/cubic-verify3").appendingPathComponent("rounds-\(mode)-\(firstIsNewer)-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let a = try WorkspaceStore(url: root.appendingPathComponent("a.json"), deviceID: "a")
        let b = try WorkspaceStore(url: root.appendingPathComponent("b.json"), deviceID: "b")
        var base = Workspace(items: [WorkItem(id: "w", name: "Work", remainingMinutes: 100)], blockers: [Blocker(id: "wait", name: "Wait")])
        if mode == 2 { try base.triggerBlocker(id: "wait", now: t) }
        try await a.save(workspace: base, now: t)
        _ = try await a.connect(folder: folder, start: .useThisDevice)
        _ = try await b.connect(folder: folder, start: .useFolder)
        var left = base, right = base
        switch mode {
        case 0:
            try left.recordWork(itemID: "w", start: t.addingTimeInterval(60), end: t.addingTimeInterval(660), actualMinutes: 10, remainingMinutes: 90)
            try right.recordWork(itemID: "w", start: t.addingTimeInterval(1200), end: t.addingTimeInterval(2400), actualMinutes: 20, remainingMinutes: 80)
        case 1:
            try left.reworkItem(id: "w", remainingMinutes: 50, now: t.addingTimeInterval(60), note: "left rework")
            try left.recordWork(itemID: "w", start: t.addingTimeInterval(120), end: t.addingTimeInterval(720), actualMinutes: 10, remainingMinutes: 40)
            try right.recordWork(itemID: "w", start: t.addingTimeInterval(1200), end: t.addingTimeInterval(2400), actualMinutes: 20, remainingMinutes: 80)
        case 2:
            var lb = left.blockers[0]; lb.expectedDurationMinutes = 30
            try left.updateBlocker(lb, now: t.addingTimeInterval(60))
            var rb = right.blockers[0]; rb.expectedDurationMinutes = 60; rb.followUpAt = t.addingTimeInterval(86400)
            try right.updateBlocker(rb, now: t.addingTimeInterval(120))
        default:
            try left.reworkItem(id: "w", remainingMinutes: 50, now: t.addingTimeInterval(60), note: "left rework")
            try right.reworkItem(id: "w", remainingMinutes: 70, now: t.addingTimeInterval(120), note: "right rework")
        }
        let leftDoc = try await a.save(workspace: left, now: t.addingTimeInterval(firstIsNewer ? 5000 : 4000))
        let rightDoc = try await b.save(workspace: right, now: t.addingTimeInterval(firstIsNewer ? 4000 : 5000))
        for _ in 0..<2 { _ = try await a.sync(folder: folder); _ = try await b.sync(folder: folder) }
        let result = await a.document
        #expect(await b.document == result)
        let disk = try JSONCoding.decode(WorkspaceDocument.self, from: Data(contentsOf: folder.appendingPathComponent("Cubic.json")))
        #expect(disk == result)
        try result.workspace.validate()
        let backups = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("Cubic-conflict-") }
            .map { try JSONCoding.decode(WorkspaceDocument.self, from: Data(contentsOf: $0)) }
        for session in left.workSessions + right.workSessions {
            #expect(result.workspace.workSessions.contains(session) || backups.contains { $0.workspace.workSessions.contains(session) })
            if mode == 0 { #expect(result.workspace.workSessions.contains(session)) }
        }
        for doc in [leftDoc, rightDoc] {
            for event in doc.workspace.history { #expect(result.workspace.history.contains(event) || backups.contains { $0.workspace.history.contains(event) }) }
            for round in doc.workspace.workRounds ?? [] { #expect(result.workspace.workRounds?.contains(round) == true || backups.contains { $0.workspace.workRounds?.contains(round) == true }) }
            for round in doc.workspace.blockerRounds ?? [] {
                let candidates = [result] + backups
                #expect(candidates.contains { $0.workspace.blockerRounds?.contains { $0.id == round.id && $0.expectedDurationMinutes == round.expectedDurationMinutes } == true })
                if let followUp = round.followUpAt {
                    #expect(candidates.contains { $0.workspace.blockerRounds?.contains { $0.id == round.id && $0.followUpAt == followUp } == true })
                }
            }
        }
        if mode == 0 { #expect(result.workspace.workRounds?.map(\.id) == ["w.round1"]) }
        if mode == 2 { #expect(result.workspace.blockerRounds?.map(\.id) == ["wait.round1"]) }
        if mode == 3 { #expect(Set(result.workspace.workRounds?.map(\.id) ?? []) == ["w.round1", "w.round2"]) }
    }
}
