import Foundation
import Testing
@testable import CubicCore

struct SharedScheduleExplanationTests {
    private let t = Date(timeIntervalSince1970: 1_800_000_000)
    private func proof(_ shortage: Int = 60) -> PlanningCertificate {
        PlanningCertificate(kind: .capacityShortfall, projectIDs: ["p", "q"], itemIDs: ["a", "b"],
            windowStart: t, windowEnd: t.addingTimeInterval(3600), energy: .normal,
            demandMinutes: 60 + shortage, capacityMinutes: 60, shortageMinutes: shortage,
            demandSeconds: Double(60 + shortage) * 60, capacitySeconds: 3600, shortageSeconds: Double(shortage) * 60,
            requiredReadyAt: nil, latestAllowedAt: nil, elapsedDelaySeconds: nil, conditionIDs: [], message: "cause")
    }
    @Test func incompleteCandidatesDoNotBecomeProvenShortages() {
        let risk = Risk(kind: .sharedResourceConflict, itemIDs: ["a", "b"], message: "unverified")
        #expect(PlanningDisplay.sharedScheduleState(risk, proofs: [], unknowns: []) == .unverified)
        #expect(PlanningDisplay.sharedScheduleState(risk, proofs: [], unknowns: [PlanningUnknown(objectID: "a", message: "missing")]) == .missingInformation)
        var zero = risk; zero.shortageMinutes = 0
        #expect(PlanningDisplay.sharedScheduleState(zero, proofs: [], unknowns: []) == .unverified)
    }
    @Test func provenShortagesRemainLowerBoundsDespiteUnknownScope() {
        let risk = Risk(kind: .sharedResourceConflict, shortageMinutes: 30, message: "cause")
        let unknowns = [PlanningUnknown(objectID: "p", message: "incomplete scope")]
        #expect(PlanningDisplay.sharedScheduleState(risk, proofs: [proof(60), proof(90)], unknowns: unknowns) == .shortfall(90))
        // Equivalent/overlapping proofs cannot be added together into a larger deficit.
        #expect(PlanningDisplay.sharedScheduleState(risk, proofs: [proof(60), proof(60)], unknowns: unknowns) == .shortfall(60))
    }
    @Test func dateDelayIsNotMissingLaborMinutes() {
        var date = proof(0); date.kind = .dependencyWindow
        date.requiredReadyAt = t.addingTimeInterval(7200); date.latestAllowedAt = t.addingTimeInterval(3600)
        date.elapsedDelaySeconds = 3600
        let risk = Risk(kind: .sharedResourceConflict, message: "date cause")
        #expect(PlanningDisplay.sharedScheduleState(risk, proofs: [date], unknowns: []) == .dateConflict)
    }
    @Test func relatedGapsIncludeUpstreamConditionsAndCapacityWithoutUnrelatedProjects() {
        let gaps = [PlanningUnknown(objectID: "a", message: "remaining"),
                    PlanningUnknown(objectID: "wait", message: "date"),
                    PlanningUnknown(objectID: "capacity", message: "calendar"),
                    PlanningUnknown(objectID: "unrelated", message: "scope"),
                    PlanningUnknown(objectID: "a", message: "remaining")]
        let condition = PlanningCondition(id: "c", kind: .externalResolution, objectID: "wait", expectedAt: nil, message: "assumption")
        let related = PlanningDisplay.relatedUnknowns(gaps, objectIDs: ["a"], conditions: [condition])
        #expect(related.map(\.objectID) == ["a", "wait", "capacity"])
        #expect(PlanningDisplay.sharedScheduleState(Risk(kind: .sharedResourceConflict, message: "candidate"), proofs: [], unknowns: related) == .missingInformation)
    }
    @Test func capturedMissingInformationDoesNotFollowLaterEdits() throws {
        let workspace = Workspace(projects: [Project(id: "p", name: "Original project", deadline: t.addingTimeInterval(3600), planningCompleteness: .complete)],
            items: [WorkItem(id: "a", name: "Original work", projectIDs: ["p"], remainingMinutes: nil)])
        var trial = try Engine.trial(workspace: workspace, request: PlanningTrialRequest(itemID: "a"),
            input: PlanningInput(slots: [CapacitySlot(start: t, end: t.addingTimeInterval(3600))], now: t))
        let context = PlanningDisplay.TrialContext(trial)
        #expect(context.unknowns.contains { $0.objectID == "a" })
        trial.source.items[0].name = "Later name"; trial.source.items[0].remainingMinutes = 30
        trial.baseline.unknowns = []
        #expect(context.source.items[0].name == "Original work")
        #expect(context.source.items[0].remainingMinutes == nil)
        #expect(context.unknowns.contains { $0.objectID == "a" })
        #expect(context.names["a"] == "Original work")
    }
}
