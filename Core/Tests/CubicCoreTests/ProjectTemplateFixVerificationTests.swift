import Foundation
import Testing
@testable import CubicCore

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
