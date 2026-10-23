import Foundation
import Testing
@testable import CubicCore

// Sources only: run as part of the ONE independent unified QA session after the parent milestone.
private enum TemplateFixture {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    static var base: Workspace {
        Workspace(projects: [Project(id: "p", name: "Saved project name", deadline: now.addingTimeInterval(86_400),
                                     importance: 3, description: "Project description", calendarIdentifier: "old-calendar")],
                  nodes: [Node(id: "z", projectID: "p", name: "First", outcome: "Outcome"),
                          Node(id: "a", projectID: "p", name: "Second"), Node(id: "empty", projectID: "p", name: "Empty")],
                  items: [WorkItem(id: "work-z", name: "First work", nodeID: "z", projectIDs: ["p"], remainingMinutes: 25,
                                   initialMinutes: 999, description: "Work description", isFocused: true),
                          WorkItem(id: "work-a", name: "Parallel work", nodeID: "z", projectIDs: ["p"], remainingMinutes: 35),
                          WorkItem(id: "target", name: "Target", nodeID: "a", projectIDs: ["p"], remainingMinutes: 15),
                          WorkItem(id: "direct", name: "Direct", projectIDs: ["p"], remainingMinutes: nil)])
    }
    static func save(_ workspace: inout Workspace) throws -> String {
        try workspace.saveProjectTemplate(projectID: "p", title: "Display title", now: now)
    }
    static func instantiate(_ workspace: inout Workspace, _ id: String) throws -> String {
        try workspace.instantiateProjectTemplate(templateID: id, deadline: now.addingTimeInterval(172_800),
                                                 timeZoneID: "UTC", dateOnly: false, now: now.addingTimeInterval(10))
    }
    static func directory() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("TemplateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }
}

@Test func templateSavesCurrentDurationAndRestoresLatestUncorrectedConfiguredDuration() throws {
    var w = TemplateFixture.base
    try w.updateRemaining(itemID: "work-z", minutes: 47, now: TemplateFixture.now)
    w.items[1].status = .completed; w.items[1].remainingMinutes = 0; w.items[1].completedAt = TemplateFixture.now
    w.items[1].round = 2; w.items[1].initialMinutes = 900
    w.estimateRevisions = (w.estimateRevisions ?? []) + [
        EstimateRevision(id: "older-round", itemID: "work-a", date: TemplateFixture.now.addingTimeInterval(9), minutes: 777, round: 1),
        EstimateRevision(id: "superseded", itemID: "work-a", date: TemplateFixture.now, minutes: 55, round: 2),
        EstimateRevision(id: "correction", itemID: "work-a", date: TemplateFixture.now.addingTimeInterval(1), minutes: 61, round: 2, correctsRevisionID: "superseded"),
        EstimateRevision(id: "z-latest", itemID: "work-a", date: TemplateFixture.now.addingTimeInterval(2), minutes: 72, round: 2),
        EstimateRevision(id: "a-latest", itemID: "work-a", date: TemplateFixture.now.addingTimeInterval(2), minutes: 71, round: 2)]
    let preview = w.previewProjectTemplate(projectID: "p")
    let payload = try #require(preview.payload)
    #expect(payload.items.first { $0.name == "First work" }?.durationMinutes == 47)
    #expect(payload.items.first { $0.name == "Parallel work" }?.durationMinutes == 72)
    #expect(payload.items.first { $0.name == "Direct" }?.durationMinutes == 60)
    let json = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
    #expect(!json.contains("initialMinutes")); #expect(!json.contains("preStartMinutes")); #expect(!json.contains("estimate"))
    w.estimateRevisions?.removeAll { $0.itemID == "work-a" }
    let fallback = w.previewProjectTemplate(projectID: "p")
    #expect(fallback.payload?.items.first { $0.name == "Parallel work" }?.durationMinutes == 60)
    #expect(fallback.warnings.contains { $0.code == .durationFallback && $0.objectID == "work-a" })
}

@Test func templateSnapshotAndInstancesSurviveOriginalAndTemplateDeletion() throws {
    var w = TemplateFixture.base
    let id = try TemplateFixture.save(&w)
    let payload = try #require(w.projectTemplate(id: id)?.payload)
    let sourceIDs = Set(w.projects.map(\.id) + w.nodes.map(\.id) + w.items.map(\.id))
    let snapshotIDs = Set([payload.project.id] + payload.nodes.map(\.id) + payload.items.map(\.id))
    #expect(sourceIDs.isDisjoint(with: snapshotIDs))
    w.projects.removeAll(); w.nodes.removeAll(); w.items.removeAll()
    let first = try TemplateFixture.instantiate(&w, id)
    let second = try TemplateFixture.instantiate(&w, id)
    #expect(first != second)
    let firstWork = w.items.filter { $0.projectIDs == [first] }, secondWork = w.items.filter { $0.projectIDs == [second] }
    #expect(Set(firstWork.map(\.id)).isDisjoint(with: Set(secondWork.map(\.id))))
    #expect(Set(firstWork.map(\.id)).isDisjoint(with: snapshotIDs))
    try w.renameProjectTemplate(templateID: id, title: "Renamed display title", now: TemplateFixture.now)
    #expect(w.projects.allSatisfy { $0.name == "Saved project name" })
    let runtime = w.items
    try w.deleteProjectTemplate(templateID: id, now: TemplateFixture.now)
    #expect(w.items == runtime); #expect(w.availableProjectTemplates().isEmpty)
    let before = w
    #expect(throws: CoreError.self) { try TemplateFixture.instantiate(&w, id) }
    #expect(w == before)
    #expect(w.projectTemplate(id: id)?.payload == payload)
}

@Test func templateCopiesExactGraphAndResetsExecutionWithoutInventingSequentialEdges() throws {
    var w = TemplateFixture.base
    w.blockers = [Blocker(id: "block", name: "Approval", state: .resolved,
                         expectedResolution: TemplateFixture.now.addingTimeInterval(100), triggeredAt: TemplateFixture.now,
                         resolvedAt: TemplateFixture.now, resolutionCondition: "Signed", expectedDurationMinutes: 90,
                         followUpAt: TemplateFixture.now, contactNote: "Contact", followUpItemID: "direct", round: 4)]
    w.nodes[1].blockerIDs = ["block"]; w.nodes[0].needsReview = true; w.nodes[0].round = 7
    w.items[0].status = .completed; w.items[0].completedAt = TemplateFixture.now; w.items[0].remainingMinutes = 0
    w.items[0].started = TemplateFixture.now; w.items[0].preStartMinutes = 900; w.items[0].preStartCapturedAt = TemplateFixture.now
    w.estimateRevisions = [EstimateRevision(itemID: "work-z", date: TemplateFixture.now, minutes: 25)]
    w.dependencies = [Dependency(id: "item-edge", source: .item("direct"), targetItemID: "work-z"),
                      Dependency(id: "node-edge", source: .node("z"), targetItemID: "target"),
                      Dependency(id: "block-edge", source: .blocker("block"), targetItemID: "work-a"),
                      Dependency(id: "removed-edge", source: .item("work-z"), targetItemID: "work-a", removedAt: TemplateFixture.now)]
    w.acceptances = [Acceptance(id: "gate", subject: .item("work-z"), name: "Pass", state: .accepted, acceptedAt: TemplateFixture.now),
                     Acceptance(id: "node-gate", subject: .node("z"), name: "Node pass"),
                     Acceptance(id: "removed-gate", subject: .item("work-a"), name: "Old", removedAt: TemplateFixture.now)]
    let preview = w.previewProjectTemplate(projectID: "p")
    #expect(preview.warnings.contains { $0.code == .clearedBlockerDates })
    let id = try TemplateFixture.save(&w)
    let newProject = try TemplateFixture.instantiate(&w, id)
    let newNodes = w.nodes.filter { $0.projectID == newProject }, newItems = w.items.filter { $0.projectIDs == [newProject] }
    let newIDs = Set(newItems.map(\.id)), newNodeIDs = Set(newNodes.map(\.id))
    let edges = w.dependencies.filter { newIDs.contains($0.targetItemID) }
    #expect(edges.count == 3)
    #expect(edges.contains { if case .node(let id) = $0.source { return newNodeIDs.contains(id) }; return false })
    #expect(newNodes.allSatisfy { $0.sequentialDependenciesInitialized == true && $0.currentRound == 1 && $0.needsReview == false })
    #expect(newItems.allSatisfy { $0.status == .pending && $0.effectiveDisposition == .active && $0.isFocused == false && $0.started == nil && $0.preStartMinutes == nil })
    let newBlocker = try #require(w.blockers.first { $0.id != "block" })
    #expect(newBlocker.state == .inactive && newBlocker.round == 1 && newBlocker.expectedDurationMinutes == 90)
    #expect(newBlocker.followUpAt == nil && newBlocker.expectedResolution == nil && newBlocker.resolvedAt == nil)
    #expect(newIDs.contains(newBlocker.followUpItemID!))
    #expect(w.projects.first { $0.id == newProject }?.calendarIdentifier == nil)
    #expect(w.acceptances.filter { newIDs.contains($0.subject.id) || newNodeIDs.contains($0.subject.id) }.allSatisfy { $0.state == .pending && $0.round == 1 && $0.acceptedAt == nil })
    let newHistory = w.history.filter { newIDs.contains($0.objectID) || newNodeIDs.contains($0.objectID) }
    #expect(newHistory.allSatisfy { $0.kind == .created && $0.date == TemplateFixture.now.addingTimeInterval(10) })
    for item in newItems {
        let event = try #require(w.history.first { $0.id == item.initialEstimateEventID })
        #expect(event.minutes == item.remainingMinutes)
        #expect((w.estimateRevisions ?? []).contains { $0.itemID == item.id && $0.minutes == item.remainingMinutes && (event.relatedIDs ?? []).contains($0.id) })
    }
    let before = Set(w.dependencies.map(\.id))
    try w.initializeSequentialDependencies(projectID: newProject, now: TemplateFixture.now.addingTimeInterval(20))
    #expect(Set(w.dependencies.map(\.id)) == before)
}

@Test func templateCopiesSharedMembershipAndAliasesOnceWithStableHierarchy() throws {
    var w = TemplateFixture.base
    w.projects.append(Project(id: "other", name: "Other"))
    w.nodes.append(Node(id: "foreign", projectID: "other", name: "Foreign"))
    w.items[3].projectIDs = ["other", "p"]; w.items[3].nodeID = "foreign"
    w.workLinks = [WorkLink(id: "alias-z", source: .item("direct"), projectID: "p", nodeID: "z"),
                   WorkLink(id: "alias-a", source: .item("direct"), projectID: "p", nodeID: "a"),
                   WorkLink(id: "node-alias", source: .node("z"), projectID: "p", isRequired: false)]
    let id = try TemplateFixture.save(&w), payload = try #require(w.projectTemplate(id: id)?.payload)
    #expect(payload.items.count == 4 && payload.workLinks.count == 3)
    #expect(payload.structure.nodes.map(\.name) == ["First", "Second", "Empty"])
    #expect(payload.structure.membersByNode[payload.nodes[0].id]?.map(\.name) == ["First work", "Parallel work"])
    #expect(payload.structure.directItems.map(\.name) == ["Direct"])
    let copied = try TemplateFixture.instantiate(&w, id)
    let members = w.items.filter { $0.projectIDs.contains(copied) }
    #expect(members.count == 4 && members.allSatisfy { $0.projectIDs == [copied] })
    let shared = try #require(members.first { $0.name == "Direct" })
    #expect(shared.nodeID == nil)
    let aliases = (w.workLinks ?? []).filter { $0.projectID == copied && $0.source == .item(shared.id) }
    #expect(aliases.count == 2 && aliases.map(\.structureOrder) == [1, 2])
    let stored = try persistedCopy(w)
    #expect(stored.nodes.filter { $0.projectID == copied }.map(\.name) == ["First", "Second", "Empty"])
    #expect(stored.items.filter { $0.nodeID == members.first { $0.name == "First work" }?.nodeID && $0.projectIDs == [copied] }.map(\.name) == ["First work", "Parallel work"])
    #expect((stored.workLinks ?? []).filter { $0.projectID == copied }.map(\.structureOrder) == [1, 2, 3])
}

@Test func templateExclusionsNeverFlattenArchivedNodeMembersAndExternalRelationsBlockSave() throws {
    var w = TemplateFixture.base
    w.nodes[0].isArchived = true; w.items[2].disposition = .cancelled
    let preview = w.previewProjectTemplate(projectID: "p")
    #expect(preview.canSave)
    #expect(preview.payload?.items.map(\.name) == ["Direct"])
    #expect(preview.warnings.filter { $0.code == .excludedScope }.count == 4)
    w.workLinks = [WorkLink(source: .item("work-z"), projectID: "p", nodeID: "a")]
    #expect(w.previewProjectTemplate(projectID: "p").errors.contains { $0.code == .externalWorkLink })
    w.workLinks = nil
    w.dependencies = [Dependency(source: .item("work-z"), targetItemID: "direct")]
    let before = w
    #expect(w.previewProjectTemplate(projectID: "p").errors.contains { $0.code == .externalDependency })
    #expect(throws: CoreError.self) { try TemplateFixture.save(&w) }
    #expect(w == before)
    w.dependencies = [Dependency(source: .item("direct"), targetItemID: "work-z")]
    #expect(w.previewProjectTemplate(projectID: "p").errors.contains { $0.code == .externalDependency })
}

@Test func templateEmptyAndDirectProjectsRemainIndependentAndCannotCreatePlanningDemand() throws {
    var w = Workspace(projects: [Project(id: "p", name: "Empty")])
    let before = w
    let id = try TemplateFixture.save(&w)
    #expect(w.projects == before.projects && w.nodes == before.nodes && w.items == before.items)
    #expect(w.previewProjectTemplate(projectID: "p").payload?.items.isEmpty == true)
    let first = try TemplateFixture.instantiate(&w, id)
    #expect(w.projects.first { $0.id == first }?.effectiveStatus == .planning)
    #expect(w.nodes.isEmpty && w.items.isEmpty)
    var direct = Workspace(projects: [Project(id: "p", name: "Direct only")],
                           items: [WorkItem(name: "Direct", projectIDs: ["p"], remainingMinutes: 5)])
    let directID = try TemplateFixture.save(&direct)
    #expect(direct.projectTemplate(id: directID)?.payload?.structure.directItems.count == 1)
    #expect(direct.projectTemplate(id: directID)?.payload?.nodes.isEmpty == true)
    let graphBefore = try PlanningGraph(workspace: before, input: PlanningInput(slots: [], now: TemplateFixture.now, horizonEnd: TemplateFixture.now.addingTimeInterval(3600)))
    let graphAfter = try PlanningGraph(workspace: Workspace(projects: before.projects, projectTemplates: w.projectTemplates), input: PlanningInput(slots: [], now: TemplateFixture.now, horizonEnd: TemplateFixture.now.addingTimeInterval(3600)))
    #expect(graphBefore.vertices.keys.sorted() == graphAfter.vertices.keys.sorted())
    #expect(graphAfter.vertices.isEmpty)
}

@Test func templateDeadlineAnchorFailureIsAtomicAndSuppliedAnchorDoesNotEditOriginal() throws {
    var w = TemplateFixture.base; w.projects[0].deadline = nil
    w.items[0].deadline = TemplateFixture.now.addingTimeInterval(900)
    let preview = w.previewProjectTemplate(projectID: "p")
    #expect(preview.needsDeadlineAnchor && !preview.canSave)
    #expect(preview.errors.contains { $0.code == .needsDeadlineAnchor })
    let before = w
    #expect(throws: CoreError.self) { try TemplateFixture.save(&w) }
    #expect(w == before)
    let id = try w.saveProjectTemplate(projectID: "p", title: "Anchor", baselineDeadline: TemplateFixture.now,
                                      baselineTimeZoneID: "UTC", now: TemplateFixture.now)
    #expect(w.projects == before.projects && w.items == before.items)
    #expect(w.projectTemplate(id: id)?.payload?.items[0].deadlineRule == .seconds(900))
    let current = w
    #expect(throws: CoreError.self) { try w.instantiateProjectTemplate(templateID: id, deadline: TemplateFixture.now, timeZoneID: "bad-zone", dateOnly: true, now: TemplateFixture.now) }
    #expect(w == current)
}

@Test func templateCalendarDayOffsetsNormalizeDSTMonthAndYearAndExactIntervals() throws {
    let zone = "America/New_York"
    for (anchor, work, destination, expectedDay) in [
        ("2026-03-07T17:00:00Z", "2026-03-09T16:00:00Z", "2026-10-31T16:00:00Z", 2),
        ("2026-12-31T17:00:00Z", "2027-01-01T17:00:00Z", "2028-02-28T17:00:00Z", 1)] {
        var w = Workspace(projects: [Project(id: "p", name: "Dates",
            deadline: try Workspace.dateOnlyDeadline(on: TemplateFixture.date(anchor), timeZoneID: zone), deadlineTimeZoneID: zone, deadlineIsDateOnly: true)],
            items: [WorkItem(name: "Day work", projectIDs: ["p"], remainingMinutes: 1,
                deadline: try Workspace.dateOnlyDeadline(on: TemplateFixture.date(work), timeZoneID: zone), deadlineTimeZoneID: zone, deadlineIsDateOnly: true)])
        let sourceAnchor = w.projects[0].deadline!
        w.items.append(WorkItem(name: "Exact", projectIDs: ["p"], remainingMinutes: 2, deadline: sourceAnchor.addingTimeInterval(-123.25)))
        let id = try TemplateFixture.save(&w)
        #expect(w.projectTemplate(id: id)?.payload?.items[0].deadlineRule == .calendarDays(expectedDay))
        let project = try w.instantiateProjectTemplate(templateID: id, deadline: TemplateFixture.date(destination), timeZoneID: zone, dateOnly: true, now: TemplateFixture.now)
        let deadline = try #require(w.projects.first { $0.id == project }?.deadline)
        let created = w.items.filter { $0.projectIDs == [project] }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: zone)!
        let newDay = try #require(created.first { $0.name == "Day work" }?.deadline)
        #expect(calendar.dateComponents([.day], from: calendar.startOfDay(for: deadline), to: calendar.startOfDay(for: newDay)).day == expectedDay)
        #expect(abs(newDay.timeIntervalSince(try Workspace.dateOnlyDeadline(on: newDay, timeZoneID: zone))) < 0.002)
        #expect(created.first { $0.name == "Exact" }?.deadline?.timeIntervalSince(deadline) == -123.25)
        try w.validate()
    }
}

@Test func templateBadPayloadsRejectAtomicallyIncludingCombinedImplicitAndAliasCycles() throws {
    let p = ProjectTemplateProject(id: "p-template", name: "Bad")
    let node = ProjectTemplateNode(id: "n-template", name: "N", structureOrder: 1)
    let work = ProjectTemplateWork(id: "i-template", name: "I", nodeID: node.id, durationMinutes: 10, structureOrder: 1)
    let invalid: [ProjectTemplatePayload] = [
        .init(project: p, nodes: [node], items: [work], dependencies: [.init(source: .node(node.id), targetItemID: work.id)]),
        .init(project: p, nodes: [node], workLinks: [.init(source: .node(node.id), nodeID: node.id, structureOrder: 1)]),
        .init(project: p, items: [.init(name: "Negative", durationMinutes: -1, structureOrder: 1)]),
        .init(project: p, items: [.init(name: "Offset", durationMinutes: 1, deadlineRule: .seconds(.infinity), structureOrder: 1)]),
        .init(project: p, items: [.init(name: "Offset", durationMinutes: 1, deadlineRule: .calendarDays(36_501), structureOrder: 1)]),
        .init(project: p, items: [work]),
        .init(project: p, nodes: [node, node]),
        .init(version: 99, project: p),
        .init(project: p, acceptances: [.init(subject: .item("missing"), name: "Gate")])]
    for payload in invalid {
        let template = ProjectTemplate(title: "Bad", payload: payload)
        var w = Workspace(projectTemplates: [template])
        try w.validate() // quarantined template content never disables ordinary runtime commands/planning
        let before = w
        #expect(!template.canInstantiate)
        #expect(throws: CoreError.self) { try TemplateFixture.instantiate(&w, template.id) }
        #expect(w == before)
    }
}

@Test func templateLegacyWorkspaceAndMalformedContentRoundTrip() throws {
    let decoder = JSONDecoder(), encoder = JSONEncoder()
    let legacy = try encoder.encode(TemplateFixture.base)
    let old = try decoder.decode(Workspace.self, from: legacy)
    #expect(old.projectTemplates == nil)
    var w = old; _ = try TemplateFixture.save(&w)
    #expect(try persistedCopy(w) == w)
    var root = try #require(JSONSerialization.jsonObject(with: try encoder.encode(w)) as? [String: Any])
    var rows = try #require(root["projectTemplates"] as? [[String: Any]])
    rows[0]["payload"] = ["unrecognized": "content", "items": ["bad"]]; root["projectTemplates"] = rows
    let corrupt = try decoder.decode(Workspace.self, from: JSONSerialization.data(withJSONObject: root))
    #expect(corrupt.projectTemplates?.first?.payload == nil)
    try corrupt.validate()
    let preserved = try #require(JSONSerialization.jsonObject(with: try encoder.encode(corrupt)) as? [String: Any])
    let preservedRows = try #require(preserved["projectTemplates"] as? [[String: Any]])
    #expect((preservedRows[0]["payload"] as? [String: Any])?["unrecognized"] as? String == "content")
}

@Test func templateLargeSnapshotAndCreationScaleWithoutRepeatedGlobalScans() throws {
    func workload(_ count: Int) throws -> (Duration, Int) {
        var w = Workspace(projects: [Project(id: "p", name: "Large")], nodes: [Node(id: "n", projectID: "p", name: "Parallel")],
            items: (0..<count).map { WorkItem(id: "i-\($0)", name: "Work \($0)", nodeID: "n", projectIDs: ["p"], remainingMinutes: 2) })
        let clock = ContinuousClock(), start = clock.now
        let id = try TemplateFixture.save(&w)
        let created = try TemplateFixture.instantiate(&w, id)
        let elapsed = start.duration(to: clock.now)
        #expect(w.items.filter { $0.projectIDs == [created] }.count == count)
        #expect(w.dependencies.isEmpty)
        #expect(w.history.count == count + 2)
        #expect(w.estimateRevisions?.count == count)
        return (elapsed, try JSONEncoder().encode(w.projectTemplate(id: id)?.payload).count)
    }
    let small = try workload(1_000), large = try workload(4_000)
    // Four times the content must not grow quadratically. Generous fixed noise allowance avoids brittle timing.
    #expect(large.0 < small.0 * 12 + .seconds(1))
    #expect(large.1 < small.1 * 5)
}

@Test func templateMissingBlockerAndExternalFollowUpAreExplicitAndDoNotTrap() throws {
    var w = TemplateFixture.base
    w.nodes[0].blockerIDs = ["missing"]
    w.dependencies = [Dependency(source: .blocker("missing"), targetItemID: "direct")]
    let preview = w.previewProjectTemplate(projectID: "p")
    #expect(!preview.canSave && preview.errors.contains { $0.code == .missingBlocker })
    w.projects.append(Project(id: "external-p", name: "External"))
    w.items.append(WorkItem(id: "external", name: "External work", projectIDs: ["external-p"], remainingMinutes: 5))
    w.blockers = [Blocker(id: "missing", name: "Waiting", expectedDurationMinutes: 15, followUpItemID: "external")]
    let resolved = w.previewProjectTemplate(projectID: "p")
    #expect(resolved.canSave && resolved.warnings.contains { $0.code == .clearedExternalFollowUp })
    #expect(resolved.payload?.blockers.first?.followUpItemID == nil)
    w.items[3].isArchived = true
    #expect(w.previewProjectTemplate(projectID: "p").warnings.contains { $0.code == .excludedScope && $0.objectID == "direct" })
    #expect(w.previewProjectTemplate(projectID: "p").errors.contains { $0.code == .externalDependency })
}

@Test func templateArchiveLifecycleAndQuarantinePersist() throws {
    var w = TemplateFixture.base
    let id = try TemplateFixture.save(&w)
    try w.archiveProjectTemplate(templateID: id, now: TemplateFixture.now)
    #expect(w.availableProjectTemplates().isEmpty)
    #expect(w.availableProjectTemplates(includeArchived: true).count == 1)
    #expect(w.projectTemplate(id: id)?.archivedAt == TemplateFixture.now)
    #expect(throws: CoreError.self) { try TemplateFixture.instantiate(&w, id) }
    try w.archiveProjectTemplate(templateID: id, isArchived: false, now: TemplateFixture.now.addingTimeInterval(1))
    #expect(w.projectTemplate(id: id)?.canInstantiate == true)
    w.projectTemplates?[0].availabilityIssue = "Unresolved content conflict"
    let roundTrip = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(w))
    #expect(roundTrip.projectTemplate(id: id)?.canInstantiate == false)
    #expect(roundTrip.projectTemplate(id: id)?.availabilityIssue == "Unresolved content conflict")
}

private let fixNow = Date(timeIntervalSince1970: 1_800_000_000)
private func fixWorkspace() -> Workspace {
    Workspace(projects: [Project(id: "p", name: "Source")],
        items: [WorkItem(id: "i", name: "Deliver", projectIDs: ["p"], remainingMinutes: 30),
                WorkItem(id: "candidate", name: "Repair", projectIDs: ["p"], remainingMinutes: 15)],
        blockers: [Blocker(id: "b", name: "Approval", resolutionCondition: "Signed", expectedDurationMinutes: 60)],
        acceptances: [Acceptance(id: "a", subject: .item("i"), name: "Quality", state: .accepted, acceptedAt: fixNow,
                                candidateItemIDs: ["candidate"], candidateBlockerIDs: ["b"])])
}
@Test func fixTemplateCandidatesRemapAndPersistAcrossStorage() throws {
    var w = fixWorkspace(); try w.validate()
    let id = try w.saveProjectTemplate(projectID: "p", title: "Candidates", now: fixNow)
    let payload = try #require(w.projectTemplate(id: id)?.payload)
    let gate = try #require(payload.acceptances.first)
    #expect(gate.candidateItemIDs == [payload.items.first { $0.name == "Repair" }!.id])
    #expect(gate.candidateBlockerIDs == [payload.blockers.first!.id])
    #expect(Set(["b", "candidate"]).isDisjoint(with: Set((gate.candidateItemIDs ?? []) + (gate.candidateBlockerIDs ?? []))))
    let project = try w.instantiateProjectTemplate(templateID: id, deadline: fixNow, timeZoneID: "UTC", dateOnly: false, now: fixNow)
    let copied = w.items.filter { $0.projectIDs == [project] }
    let acceptance = try #require(w.acceptances.first { $0.subject == .item(copied.first { $0.name == "Deliver" }!.id) })
    #expect(acceptance.state == .pending && acceptance.acceptedAt == nil && acceptance.currentRound == 1)
    #expect(acceptance.candidateItemIDs == [copied.first { $0.name == "Repair" }!.id])
    let blockerID = try #require(acceptance.candidateBlockerIDs?.first)
    #expect(blockerID != "b" && blockerID != payload.blockers.first?.id)
    #expect(w.blockers.first { $0.id == blockerID }?.resolutionCondition == "Signed")
    let stored = try persistedCopy(w)
    #expect(stored == w)
    #expect(stored.projectTemplate(id: id)?.payload == payload)
    #expect(stored.acceptances.first { $0.id == acceptance.id }?.candidateItemIDs == acceptance.candidateItemIDs)
    #expect(stored.acceptances.first { $0.id == acceptance.id }?.candidateBlockerIDs == acceptance.candidateBlockerIDs)
}
@Test func fixTemplateExternalAndExcludedCandidatesBlockAtomicallyWithReadableNames() throws {
    for excluded in [false, true] {
        var w = fixWorkspace()
        if excluded { w.items[1].isArchived = true } else {
            w.projects.append(Project(id: "foreign", name: "Foreign")); w.items[1].projectIDs = ["foreign"]
        }
        let before = w, preview = w.previewProjectTemplate(projectID: "p")
        #expect(!preview.canSave && preview.payload == nil)
        #expect(preview.errors.contains { $0.message.contains("Quality") && $0.message.contains("Repair") })
        #expect(throws: CoreError.self) { try w.saveProjectTemplate(projectID: "p", title: "Blocked", now: fixNow) }
        #expect(w == before)
    }
    var w = fixWorkspace(); w.blockers[0].isArchived = true
    #expect(w.previewProjectTemplate(projectID: "p").errors.contains { $0.code == .missingBlocker })
}
@Test func fixTemplateLegacyAcceptanceDecodeAndMalformedCandidatesStayIsolated() throws {
    let data = Data(#"{"id":"old","subject":{"item":{"_0":"i"}},"name":"Legacy"}"#.utf8)
    let gate = try JSONDecoder().decode(ProjectTemplateAcceptance.self, from: data)
    #expect(gate.candidateItemIDs == nil && gate.candidateBlockerIDs == nil)
    let p = ProjectTemplateProject(id: "p", name: "Bad")
    let work = ProjectTemplateWork(id: "i", name: "I", durationMinutes: 1, structureOrder: 1)
    for candidates in [["missing"], ["i", "i"]] {
        let payload = ProjectTemplatePayload(project: p, items: [work], acceptances: [.init(subject: .item("i"), name: "Gate", candidateItemIDs: candidates)])
        #expect(throws: CoreError.self) { try payload.validate() }
        let template = ProjectTemplate(title: "Bad", payload: payload)
        var w = Workspace(projectTemplates: [template]); try w.validate()
        let before = w
        #expect(throws: CoreError.self) { try w.instantiateProjectTemplate(templateID: template.id, deadline: fixNow, timeZoneID: "UTC", dateOnly: false, now: fixNow) }
        #expect(w == before)
    }
}

/// Measures the corrected defaults-first command boundary, including candidate configuration.
/// Timing has no brittle absolute limit; topology, ID isolation and static configuration are checked.
@Test func fixTemplatePreparationScaleSamples() throws {
    let clock = ContinuousClock()
    func ms(_ start: ContinuousClock.Instant) -> Double {
        let c = start.duration(to: clock.now).components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }
    for count in [1500, 6000] {
        for sample in 1...3 {
            var w = Workspace(projects: [Project(id: "p", name: "Scale", deadline: fixNow), Project(id: "other", name: "Other")])
            w.nodes = (0..<(count / 100)).map { Node(id: "n\($0)", projectID: "p", name: "Node \($0)") }
            w.items = (0..<count).map { WorkItem(id: "i\($0)", name: "Work \($0)", nodeID: "n\($0 / 100)", projectIDs: ["p"], remainingMinutes: 2) }
            w.items += (0..<2000).map { WorkItem(id: "other\($0)", name: "Other \($0)", projectIDs: ["other"], remainingMinutes: 1) }
            w.dependencies = (0..<count).filter { $0 % 100 != 0 }.map { Dependency(source: .item("i\($0 - 1)"), targetItemID: "i\($0)") }
            w.blockers = [Blocker(id: "b", name: "Approval", expectedDurationMinutes: 60)]
            w.acceptances = (0..<(count / 100)).map { Acceptance(subject: .node("n\($0)"), name: "Quality \($0)", candidateItemIDs: ["i\($0 * 100)"], candidateBlockerIDs: ["b"]) }
            let saveStart = clock.now
            try w.applyDefaultRemainingEstimates(now: fixNow)
            let templateID = try w.saveProjectTemplate(projectID: "p", title: "Scale", now: fixNow)
            let saveMS = ms(saveStart)
            let defaultsStart = clock.now
            try w.applyDefaultRemainingEstimates(now: fixNow)
            let defaultsMS = ms(defaultsStart), commandStart = clock.now
            let projectID = try w.instantiateProjectTemplate(templateID: templateID, deadline: fixNow.addingTimeInterval(86400), timeZoneID: "UTC", dateOnly: false, now: fixNow)
            let createMS = ms(commandStart)
            let items = w.items.filter { $0.projectIDs == [projectID] }, ids = Set(items.map(\.id))
            let nodeIDs = Set(w.nodes.filter { $0.projectID == projectID }.map(\.id))
            let gates = w.acceptances.filter { if case .node(let id) = $0.subject { return nodeIDs.contains(id) }; return false }
            #expect(items.count == count && w.dependencies.filter { ids.contains($0.targetItemID) }.count == count - count / 100)
            #expect(gates.count == count / 100 && gates.allSatisfy { $0.state == .pending && ($0.candidateItemIDs ?? []).allSatisfy(ids.contains) })
            let blockerIDs = Set(gates.flatMap { $0.candidateBlockerIDs ?? [] })
            #expect(blockerIDs.count == 1 && !blockerIDs.contains("b"))
            #expect(w.blockers.first { blockerIDs.contains($0.id) }?.expectedDurationMinutes == 60)
            print(String(format: "TEMPLATE_FIX_PERF works=%d unrelated=2000 gates=%d sample=%d save_prepare_ms=%.3f defaults_ms=%.3f create_command_ms=%.3f total_prepare_ms=%.3f", count, gates.count, sample, saveMS, defaultsMS, createMS, defaultsMS + createMS))
        }
    }
}

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
            progress("storage", count, sample)
            let persistStart = clock.now
            let stored = try persistedCopy(w)
            #expect(stored.items == w.items && stored.projectTemplates == w.projectTemplates)
            let persistMS = ms(persistStart)
            print(String(format: "TEMPLATE_INDEPENDENT_PERF mode=debug/macOS works=%d unrelated=2000 sample=%d preview_ms=%.3f save_ms=%.3f create_ms=%.3f app_boundary_ms=%.3f encode_ms=%.3f storage_ms=%.3f bytes=%d", count, sample, previewMS, saveMS, createMS, boundaryMS, encodeMS, persistMS, bytes.count))
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

@Test func independentDateOnlyStorageRoundTripDiagnostic() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var w = Workspace(projects: [Project(id: "p", name: "Precision")], items: [WorkItem(id: "i", name: "Work", projectIDs: ["p"], remainingMinutes: 2)])
    let id = try w.saveProjectTemplate(projectID: "p", title: "Precision", now: now)
    let created = try w.instantiateProjectTemplate(templateID: id, deadline: now, timeZoneID: "Asia/Singapore", dateOnly: true, now: now)
    let loaded = try persistedCopy(w)
    let a = try #require(w.projects.first { $0.id == created }?.deadline)
    let b = try #require(loaded.projects.first { $0.id == created }?.deadline)
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970; encoder.outputFormatting = [.sortedKeys]
    let originalJSON = try encoder.encode(w), loadedJSON = try encoder.encode(loaded)
    print("TEMPLATE_STORAGE_PRECISION exact_equal=\(loaded == w) canonical_json_equal=\(originalJSON == loadedJSON) deadline_delta_seconds=\(b.timeIntervalSince(a)) templates_equal=\(loaded.projectTemplates == w.projectTemplates) items_equal=\(loaded.items == w.items) history_equal=\(loaded.history == w.history)")
    #expect(originalJSON == loadedJSON)
    #expect(abs(b.timeIntervalSince(a)) < 0.001)
    #expect(loaded.items == w.items && loaded.projectTemplates == w.projectTemplates)
}
