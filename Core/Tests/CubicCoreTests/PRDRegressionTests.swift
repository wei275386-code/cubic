import Foundation
import Testing
@testable import CubicCore

/// Independent fix-milestone regressions. Parse alone is not a test PASS.
/// Fixtures express PRD outcomes and inspect public facts; no synthetic dependency ID is hard-coded.
@Suite(.serialized) struct PRDRegressionTests {
    private let origin = ISO8601DateFormatter().date(from: "2026-10-04T14:00:00+08:00")!
    private func at(_ minutes: Int) -> Date { origin.addingTimeInterval(Double(minutes) * 60) }
    private func project(_ id: String) -> Project {
        Project(id: id, name: id, deadline: at(240), planningCompleteness: .complete)
    }
    private func item(_ id: String, in workspace: Workspace) throws -> WorkItem {
        try #require(workspace.items.first { $0.id == id })
    }
    private func round(_ id: String, _ number: Int, in workspace: Workspace) throws -> WorkRound {
        try #require(workspace.workRounds?.first { $0.itemID == id && $0.round == number })
    }
    private func gate(_ id: String, in workspace: Workspace) throws -> Acceptance {
        try #require(workspace.acceptances.first { $0.id == id })
    }
    private func inheritedWaitWorkspace() -> Workspace {
        Workspace(projects: [project("P"), project("Q"), project("unrelated")],
                  nodes: [Node(id: "N", projectID: "P", name: "N", planningCompleteness: .complete, blockerIDs: ["wait"])],
                  items: [WorkItem(id: "member", name: "member", nodeID: "N", projectIDs: ["P"], remainingMinutes: 20),
                          WorkItem(id: "used", name: "used result", projectIDs: ["Q"], remainingMinutes: 10),
                          WorkItem(id: "future", name: "future consumer", projectIDs: ["Q"], remainingMinutes: 10),
                          WorkItem(id: "independent", name: "independent", projectIDs: ["unrelated"], remainingMinutes: 10)],
                  blockers: [Blocker(id: "wait", name: "whole node prerequisite")],
                  dependencies: [Dependency(id: "member-used", source: .item("member"), targetItemID: "used"),
                                 Dependency(id: "member-future", source: .item("member"), targetItemID: "future")],
                  acceptances: [Acceptance(id: "node-gate", subject: .node("N"), name: "manual check")])
    }
    private func finishInheritedWaitFixture() throws -> Workspace {
        var w = inheritedWaitWorkspace()
        try w.triggerBlocker(id: "wait", now: at(0))
        try w.resolveBlocker(id: "wait", now: at(1))
        try w.recordWork(itemID: "member", start: at(2), end: at(12), actualMinutes: 10)
        try w.completeItem(id: "member", now: at(13))
        try w.accept(id: "node-gate", now: at(14))
        try w.completeNode(id: "N", now: at(15))
        try w.recordWork(itemID: "used", start: at(16), end: at(21), actualMinutes: 5)
        try w.completeItem(id: "used", now: at(22))
        try w.completeItem(id: "independent", now: at(23))
        return w
    }

    // R2: node-only condition use must reach item-granularity consumers in another project.
    @Test func r2WholeNodeReopenPreservesConsumedRoundAndReviewsItemConsumers() throws {
        var w = try finishInheritedWaitFixture()
        let old = w
        let consumed = try #require(try round("member", 1, in: w).sources?.first { $0.source == .blocker("wait") })
        #expect(consumed.sourceRound == 1)
        let downstreamUse = try #require(try round("used", 1, in: w).sources?.first { $0.source == .item("member") })
        #expect(downstreamUse.sourceRound == 1)
        // No explicit blocker->member dependency: only N.blockerIDs declares this use.
        #expect(!w.dependencies.contains { $0.source == .blocker("wait") })
        try w.triggerBlocker(id: "wait", now: at(30))
        #expect(w.blockers[0].currentRound == 2)
        #expect(try item("member", in: w).status == .completed)
        #expect(try item("member", in: w).completedAt == item("member", in: old).completedAt)
        #expect(try item("member", in: w).needsReview)
        #expect(try item("used", in: w).status == .completed && item("used", in: w).needsReview)
        #expect(try item("future", in: w).status == .pending && !item("future", in: w).needsReview)
        #expect(try item("independent", in: w) == item("independent", in: old))
        #expect(!w.sourceSatisfied(.item("member")))
        #expect(!w.sourceSatisfied(.item("used")))
        #expect(!w.sourceSatisfied(.node("N")))
        #expect(try gate("node-gate", in: w).state != .accepted)
        #expect(try round("member", 1, in: w).sources == round("member", 1, in: old).sources)
        #expect(w.workSessions == old.workSessions)
        #expect(w.history.starts(with: old.history))
        #expect(w.acceptanceResults?.contains { $0.acceptanceID == "node-gate" && $0.state == .accepted } == true)
        let input = PlanningInput(slots: [CapacitySlot(start: at(30), end: at(240))], now: at(30))
        let plan = try Engine.plan(workspace: w, input: input)
        #expect(plan.summary.itemStates.first { $0.itemID == "future" }?.isBlocked == true)
    }

    // R2: a stillValid review distinguishes consumed round 1 from checked context round 2.
    @Test func r2StillValidBindsNewBlockerContextAndExpiresOnNextReopen() throws {
        var w = try finishInheritedWaitFixture()
        try w.triggerBlocker(id: "wait", now: at(30))
        try w.reviewItem(id: "member", outcome: .stillValid, now: at(31), note: "old result still applies")
        let review = try #require(w.reviews?.last { $0.itemID == "member" })
        let consumed = try #require(review.sources.first { $0.source == .blocker("wait") })
        let checked = try #require(review.currentSources?.first { $0.source == .blocker("wait") })
        #expect(consumed.sourceRound == 1)
        #expect(checked.sourceRound == 2)
        #expect(checked.dependencyID == consumed.dependencyID)
        #expect(review.round == 1)
        #expect(w.sourceSatisfied(.item("member")))
        #expect(!w.sourceSatisfied(.blocker("wait")))
        #expect(!w.sourceSatisfied(.node("N")))
        try w.reviewItem(id: "used", outcome: .stillValid, now: at(32))
        #expect(w.sourceSatisfied(.item("used")))
        try w.resolveBlocker(id: "wait", now: at(33))
        #expect(w.sourceSatisfied(.item("member")))
        try w.triggerBlocker(id: "wait", now: at(34))
        #expect(w.blockers[0].currentRound == 3)
        #expect(!w.sourceSatisfied(.item("member")))
        #expect(!w.sourceSatisfied(.item("used")))
        #expect(try item("member", in: w).status == .completed && item("member", in: w).needsReview)
        #expect(w.reviews?.contains { $0.id == review.id && $0.currentSources == review.currentSources } == true)
    }

    // R2/R4: accepting an old inProgress result does not grant current labor permission.
    @Test func r2StillValidInProgressDoesNotExemptExactApproximateOrComplete() throws {
        var w = inheritedWaitWorkspace()
        try w.triggerBlocker(id: "wait", now: at(0))
        try w.resolveBlocker(id: "wait", now: at(1))
        try w.recordWork(itemID: "member", start: at(2), end: at(7), actualMinutes: 5)
        try w.triggerBlocker(id: "wait", now: at(8))
        #expect(try item("member", in: w).needsReview)
        try w.reviewItem(id: "member", outcome: .stillValid, now: at(9))
        #expect(try !item("member", in: w).needsReview)
        let reviewed = w
        #expect(throws: CoreError.self) {
            try w.recordWork(itemID: "member", start: at(10), end: at(11), actualMinutes: 1, remaining: .minutes(19))
        }
        #expect(w == reviewed)
        #expect(throws: CoreError.self) {
            try w.recordApproximateWork(itemID: "member", occurredOn: at(11), recordedAt: at(11), actualMinutes: 1, remaining: .minutes(19))
        }
        #expect(w == reviewed)
        #expect(throws: CoreError.self) { try w.completeItem(id: "member", now: at(11)) }
        #expect(w == reviewed)
        // Positive control: restore the actual prerequisite, then ordinary labor is allowed.
        try w.resolveBlocker(id: "wait", now: at(12))
        try w.recordApproximateWork(itemID: "member", occurredOn: at(13), recordedAt: at(13), actualMinutes: 1, remaining: .minutes(19))
        #expect(try item("member", in: w).remainingMinutes == 19)
        #expect(w.workSessions.count == reviewed.workSessions.count + 1)
        #expect(try round("member", 1, in: w).sources == round("member", 1, in: reviewed).sources)
    }

    // R4: a restored source does not clear a pending review. All new-labor formats agree.
    @Test func r4RestoredWaitStillRequiresReviewButHistoricalSupplementPreservesFacts() throws {
        var w = inheritedWaitWorkspace()
        try w.triggerBlocker(id: "wait", now: at(0))
        try w.resolveBlocker(id: "wait", now: at(1))
        try w.recordWork(itemID: "member", start: at(2), end: at(7), actualMinutes: 5)
        try w.triggerBlocker(id: "wait", now: at(8))
        try w.resolveBlocker(id: "wait", now: at(9))
        #expect(w.sourceSatisfied(.blocker("wait")))
        #expect(try item("member", in: w).needsReview)
        let before = w
        #expect(throws: CoreError.self) {
            try w.recordWork(itemID: "member", start: at(10), end: at(11), actualMinutes: 1)
        }
        #expect(w == before)
        #expect(throws: CoreError.self) {
            try w.recordApproximateWork(itemID: "member", occurredOn: at(11), recordedAt: at(11), actualMinutes: 1, remaining: .minutes(19))
        }
        #expect(w == before)
        // Explicitly supplement a real old round, not new labor after invalidation.
        try w.recordHistoricalApproximateWork(itemID: "member", occurredOn: at(4), round: 1, recordedAt: at(12), actualMinutes: 2, note: "missed old fact")
        #expect(w.items == before.items)
        #expect(w.nodes == before.nodes && w.blockers == before.blockers)
        #expect(w.workSessions.count == before.workSessions.count + 1)
        let supplement = try #require(w.workSessions.last)
        #expect(supplement.round == 1 && supplement.occurredOn == at(4))
        #expect(!supplement.hasExactInterval)
        #expect(try item("member", in: w).needsReview)
        #expect(w.history.last?.kind == .effortRecorded && w.history.last?.round == 1)
    }

    private func completedSharedNodeChain() throws -> Workspace {
        var w = Workspace(projects: [project("P0"), project("P1"), project("P2"), project("P3")],
                          nodes: [Node(id: "N1", projectID: "P1", name: "first shared result", planningCompleteness: .complete),
                                  Node(id: "N2", projectID: "P2", name: "second shared result", planningCompleteness: .complete)],
                          items: [WorkItem(id: "source", name: "source", projectIDs: ["P0"], remainingMinutes: 60)],
                          acceptances: [Acceptance(id: "g1", subject: .node("N1"), name: "first manual gate"),
                                        Acceptance(id: "g2", subject: .node("N2"), name: "second manual gate")],
                          workLinks: [WorkLink(id: "source-N1", source: .item("source"), projectID: "P1", nodeID: "N1"),
                                      WorkLink(id: "N1-N2", source: .node("N1"), projectID: "P2", nodeID: "N2"),
                                      WorkLink(id: "N2-P3", source: .node("N2"), projectID: "P3")])
        try w.recordWork(itemID: "source", start: at(0), end: at(10), actualMinutes: 10)
        try w.completeItem(id: "source", now: at(11))
        try w.accept(id: "g1", now: at(12))
        try w.completeNode(id: "N1", now: at(13))
        try w.accept(id: "g2", now: at(14))
        try w.completeNode(id: "N2", now: at(15))
        for id in ["P0", "P1", "P2", "P3"] { try w.completeProject(id: id, now: at(16)) }
        return w
    }

    // R3: empty shared-result nodes are real graph vertices, not disposable traversal glue.
    @Test func r3MultiLevelEmptyWorkLinksReopenAllCompletedDeliveriesOnce() throws {
        var w = try completedSharedNodeChain()
        let old = w
        #expect(!w.items.contains { $0.nodeID == "N1" || $0.nodeID == "N2" })
        try w.reworkItem(id: "source", remainingMinutes: 60, now: at(20))
        for id in ["N1", "N2"] {
            let node = try #require(w.nodes.first { $0.id == id })
            let previous = try #require(old.nodes.first { $0.id == id })
            #expect(node.completedAt == nil)
            #expect(node.currentRound == previous.currentRound + 1)
            #expect(!w.sourceSatisfied(.node(id)))
        }
        for id in ["g1", "g2"] {
            #expect(try gate(id, in: w).state != .accepted)
            #expect(try gate(id, in: w).acceptedAt == nil)
            #expect(w.acceptanceResults?.contains { $0.acceptanceID == id && $0.state == .accepted } == true)
        }
        #expect(w.projects.allSatisfy { $0.effectiveStatus != .completed && $0.completedAt == nil && $0.hasDeliveryCommitment })
        #expect(w.workLinks == old.workLinks)
        #expect(w.workSessions == old.workSessions)
        #expect(w.history.starts(with: old.history))
        let plan = try Engine.plan(workspace: w, input: PlanningInput(slots: [CapacitySlot(start: at(20), end: at(240))], now: at(20)))
        #expect(Set(plan.projects.map(\.projectID)) == Set(["P0", "P1", "P2", "P3"]))
        #expect(plan.committedDemandMinutes == 60)
    }

    // R3: rebuilding source/N1 never silently reuses N2's old gate or completedProject.
    @Test func r3SourceRestorationCannotAutoRestoreIndirectOldGate() throws {
        var w = try completedSharedNodeChain()
        let oldG2 = try #require(w.acceptanceResults?.last { $0.acceptanceID == "g2" && $0.state == .accepted })
        try w.reworkItem(id: "source", remainingMinutes: 30, now: at(20))
        try w.startItem(id: "source", now: at(21))
        try w.completeItem(id: "source", now: at(22))
        try w.accept(id: "g1", now: at(23))
        try w.completeNode(id: "N1", now: at(24))
        #expect(w.sourceSatisfied(.node("N1")))
        #expect(!w.sourceSatisfied(.node("N2")))
        #expect(try gate("g2", in: w).state != .accepted)
        #expect(w.projects.first { $0.id == "P2" }?.effectiveStatus != .completed)
        #expect(w.projects.first { $0.id == "P3" }?.effectiveStatus != .completed)
        let before = w
        #expect(throws: CoreError.self) { try w.completeNode(id: "N2", now: at(25)) }
        #expect(w == before)
        #expect(throws: CoreError.self) { try w.completeProject(id: "P2", now: at(25)) }
        #expect(w == before)
        #expect(throws: CoreError.self) { try w.completeProject(id: "P3", now: at(25)) }
        #expect(w == before)
        // Reuse must be a new explicit human fact linked to the original result.
        try w.reuseAcceptanceResult(id: "g2", resultID: oldG2.id, now: at(26), note: "checked indirect result still applies")
        #expect(w.sourceSatisfied(.node("N2")))
        let reuse = try #require(w.acceptanceResults?.last { $0.acceptanceID == "g2" })
        #expect(reuse.reusedResultID == oldG2.id)
        #expect(reuse.round == w.nodes.first { $0.id == "N2" }?.currentRound)
        #expect(reuse.id != oldG2.id)
        try w.completeNode(id: "N2", now: at(27))
        try w.completeProject(id: "P2", now: at(28))
        try w.completeProject(id: "P3", now: at(28))
    }

    @Test func r5InitialCorrectionTargetsFirst60NotLater90Or120() throws {
        var w = Workspace(items: [WorkItem(id: "estimate", name: "initially unknown")])
        try w.updateRemaining(itemID: "estimate", minutes: 60, now: at(0))
        let first60 = try #require(w.history.last { $0.objectID == "estimate" && $0.kind == .remainingUpdated })
        try w.updateRemaining(itemID: "estimate", minutes: 90, now: at(1))
        try w.updateRemaining(itemID: "estimate", minutes: 120, now: at(2))
        let last120 = try #require(w.history.last { $0.objectID == "estimate" && $0.kind == .remainingUpdated })
        let revisions = w.estimateRevisions
        try w.correctEstimateBaseline(itemID: "estimate", baseline: .initial, minutes: 50, now: at(3), note: "correct only the first estimate")
        let correction = try #require(w.history.last)
        #expect(first60.minutes == 60 && last120.minutes == 120)
        #expect(correction.correctsEventID == first60.id)
        #expect(correction.correctsEventID != last120.id)
        #expect(correction.previousMinutes == 60 && correction.minutes == 50)
        #expect(correction.changeReason == .correction)
        #expect(try item("estimate", in: w).initialMinutes == 60 && item("estimate", in: w).remainingMinutes == 120)
        #expect(w.estimateRevisions == revisions)
        let fact = try #require(w.baselineCorrections(itemID: "estimate").first)
        #expect(fact.originalMinutes == 60 && fact.correctedMinutes == 50 && fact.baseline == .initial)
        try w.correctEstimateBaseline(itemID: "estimate", baseline: .initial, minutes: 55, now: at(4), note: "refine correction")
        #expect(w.history.last?.correctsEventID == correction.id)
        #expect(w.baselineCorrections(itemID: "estimate").map(\.originalMinutes) == [60, 60])
        #expect(try item("estimate", in: w).remainingMinutes == 120)
    }

    @Test func r5PreStartCorrectionTargetsRound1_60NotRound2_30() throws {
        var w = Workspace(items: [WorkItem(id: "estimate", name: "estimate")])
        try w.updateRemaining(itemID: "estimate", minutes: 60, now: at(0))
        try w.startItem(id: "estimate", now: at(1))
        let firstStart = try #require(w.history.last { $0.objectID == "estimate" && $0.kind == .baselineCaptured })
        try w.completeItem(id: "estimate", now: at(2))
        try w.reworkItem(id: "estimate", remainingMinutes: 30, now: at(3))
        try w.startItem(id: "estimate", now: at(4))
        let secondStart = try #require(w.history.last { $0.objectID == "estimate" && $0.kind == .baselineCaptured })
        let roundsBefore = w.workRounds
        try w.correctEstimateBaseline(itemID: "estimate", baseline: .preStart, minutes: 55, now: at(5), note: "round one only")
        let correction = try #require(w.history.last)
        #expect(firstStart.minutes == 60 && firstStart.round == 1)
        #expect(secondStart.minutes == 30 && secondStart.round == 2)
        #expect(correction.correctsEventID == firstStart.id)
        #expect(correction.correctsEventID != secondStart.id)
        #expect(correction.round == 1 && correction.previousMinutes == 60)
        #expect(try item("estimate", in: w).preStartMinutes == 60 && item("estimate", in: w).preStartCapturedAt == at(1))
        #expect(try item("estimate", in: w).remainingMinutes == 30 && item("estimate", in: w).currentRound == 2)
        #expect(w.workRounds == roundsBefore)
        #expect(try round("estimate", 2, in: w).preStartMinutes == 30)
        let detail = try #require(w.baselineCorrections(itemID: "estimate").first)
        #expect(detail.baseline == .preStart && detail.originalMinutes == 60 && detail.correctedMinutes == 55)
    }

    @Test func ac008NodeRequiredScopeChangeRecordsHistoryWithoutPassingGate() throws {
        var w = Workspace(projects: [project("P")],
                          nodes: [Node(id: "N", projectID: "P", name: "optional candidate", planningCompleteness: .complete)],
                          items: [WorkItem(id: "work", name: "unfinished", nodeID: "N", projectIDs: ["P"], remainingMinutes: 30)],
                          acceptances: [Acceptance(id: "gate", subject: .node("N"), name: "not checked")])
        let before = w
        var n = w.nodes[0]; n.isRequired = false
        try w.updateNode(n, now: at(1), note: "explicitly remove deliverable from scope")
        #expect(!w.nodes[0].required)
        #expect(w.nodes[0].completedAt == nil)
        #expect(try item("work", in: w) == item("work", in: before))
        #expect(try gate("gate", in: w).state == .pending && gate("gate", in: w).acceptedAt == nil)
        #expect(!w.sourceSatisfied(.node("N")))
        #expect(w.history.starts(with: before.history))
        let event = try #require(w.history.last)
        #expect(event.kind == .scopeChanged && event.objectID == "N")
        let detail = try #require(event.detail?.data(using: .utf8))
        let change = try #require(try JSONSerialization.jsonObject(with: detail) as? [String: Any])
        let after = try #require(change["after"] as? [String: Any])
        #expect(after["isRequired"] as? Bool == false)
        #expect(!(w.acceptanceResults ?? []).contains { $0.state == .accepted })
        // Putting it back into required scope cannot manufacture a prior acceptance.
        n = w.nodes[0]; n.isRequired = true
        try w.updateNode(n, now: at(2), note: "restore requirement")
        #expect(w.nodes[0].required && !w.sourceSatisfied(.node("N")))
        #expect(throws: CoreError.self) { try w.completeNode(id: "N", now: at(3)) }
    }

    @Test func ac019SharedActualEffortCountsOnceAcrossThreeProjectsAndWorkLink() throws {
        var w = Workspace(projects: [project("A"), project("B"), project("C")],
                          items: [WorkItem(id: "shared", name: "one actual work", projectIDs: ["A", "B"], remainingMinutes: 90)],
                          workLinks: [WorkLink(id: "to-C", source: .item("shared"), projectID: "C")])
        try w.recordWork(itemID: "shared", start: at(0), end: at(30), actualMinutes: 30, remaining: .minutes(75))
        #expect(w.workSessions.count == 1 && w.effectiveWorkSessions.count == 1)
        #expect(w.effortSummary().confirmedMinutes == 30)
        #expect(w.effortSummary(itemIDs: ["shared"]).confirmedMinutes == 30)
        #expect(try item("shared", in: w).remainingMinutes == 75)
        let plan = try Engine.plan(workspace: w, input: PlanningInput(slots: [CapacitySlot(start: at(30), end: at(240))], now: at(30)))
        #expect(plan.knownDemandMinutes == 75 && plan.committedDemandMinutes == 75)
        #expect(Set(plan.projects.map(\.projectID)) == Set(["A", "B", "C"]))
        #expect(plan.projects.allSatisfy { $0.knownDemandMinutes == 75 })
        #expect(Int(plan.witness.allocations.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } / 60) == 75)
        let originalID = try #require(w.workSessions.first?.id)
        try w.removeWorkLink(id: "to-C", now: at(31), note: "remove one benefit, preserve fact")
        #expect(w.workSessions.first?.id == originalID && w.effortSummary().confirmedMinutes == 30)
        #expect(try item("shared", in: w).projectIDs == ["A", "B"])
        #expect(w.items.count == 1)
    }

    @Test func ac017OneBlockerReleaseReallyUnlocksThreeDifferentProjects() throws {
        var w = Workspace(projects: [project("A"), project("B"), project("C")],
                          items: [WorkItem(id: "a", name: "a", projectIDs: ["A"], remainingMinutes: 10),
                                  WorkItem(id: "b", name: "b", projectIDs: ["B"], remainingMinutes: 10),
                                  WorkItem(id: "c", name: "c", projectIDs: ["C"], remainingMinutes: 10)],
                          blockers: [Blocker(id: "quote", name: "one shared external condition")],
                          dependencies: [Dependency(id: "quote-a", source: .blocker("quote"), targetItemID: "a"),
                                         Dependency(id: "quote-b", source: .blocker("quote"), targetItemID: "b"),
                                         Dependency(id: "quote-c", source: .blocker("quote"), targetItemID: "c")])
        try w.triggerBlocker(id: "quote", now: at(0))
        let input = PlanningInput(slots: [CapacitySlot(start: at(1), end: at(240))], now: at(1))
        let waiting = try Engine.plan(workspace: w, input: input)
        #expect(waiting.summary.itemStates.allSatisfy { $0.isBlocked })
        #expect(waiting.summary.availableActions.isEmpty)
        try w.resolveBlocker(id: "quote", now: at(1))
        let ready = try Engine.plan(workspace: w, input: input)
        #expect(Set(ready.summary.availableActions.map(\.itemID)) == Set(["a", "b", "c"]))
        #expect(ready.summary.itemStates.allSatisfy { !$0.isBlocked })
        #expect(w.blockers.count == 1)
        #expect(w.history.filter { $0.kind == .blockerResolved && $0.objectID == "quote" }.count == 1)
        for id in ["a", "b", "c"] { try w.completeItem(id: id, now: at(2)) }
        try w.triggerBlocker(id: "quote", now: at(3))
        #expect(w.items.allSatisfy { $0.status == .completed && $0.needsReview })
        #expect(w.blockers[0].currentRound == 2)
        #expect(w.history.filter { $0.kind == .blockerResolved && $0.objectID == "quote" }.count == 1)
    }

    // Both US DST transitions and an ordinary Shanghai day; no process-global timezone changes.
    @Test(arguments: [
        ("2026-03-08T12:00:00-04:00", "America/New_York", "2026-03-08T00:00:00-05:00", "2026-03-09T00:00:00-04:00", 1380),
        ("2026-11-01T12:00:00-05:00", "America/New_York", "2026-11-01T00:00:00-04:00", "2026-11-02T00:00:00-05:00", 1500),
        ("2026-10-04T12:00:00+08:00", "Asia/Shanghai", "2026-10-04T00:00:00+08:00", "2026-10-05T00:00:00+08:00", 1440)
    ])
    func ac006ProjectDateOnlyDSTAndStoredZoneSurviveRoundTripAndUnrelatedEdit(_ input: (String, String, String, String, Int)) throws {
        let formatter = ISO8601DateFormatter()
        let day = try #require(formatter.date(from: input.0))
        let start = try #require(formatter.date(from: input.2))
        let nextMidnight = try #require(formatter.date(from: input.3))
        let expected = nextMidnight.addingTimeInterval(-0.001)
        var w = Workspace(projects: [project("P")], items: [WorkItem(id: "x", name: "x", projectIDs: ["P"], remainingMinutes: 10)])
        try w.setProjectDeadline(id: "P", deadline: day, timeZoneID: input.1, dateOnly: true, now: origin)
        #expect(abs(try #require(w.projects[0].deadline).timeIntervalSince(expected)) < 0.00001)
        #expect(w.projects[0].deadlineIsDateOnly == true && w.projects[0].deadlineTimeZoneID == input.1)
        #expect(w.history.last?.kind == .deadlineChanged && w.history.last?.objectID == "P")
        let capacity = try Engine.plan(workspace: w, input: PlanningInput(slots: [CapacitySlot(start: start, end: nextMidnight)], now: start))
        #expect(capacity.summary.capacityMinutes == input.4)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        var restored = try decoder.decode(Workspace.self, from: encoder.encode(w))
        let decodedDeadline = try #require(restored.projects[0].deadline)
        let originalDeadline = try #require(w.projects[0].deadline)
        // Foundation epoch conversion can shift a millisecond Date by one binary ULP.
        // Bound that shift to <1 microsecond; all other Workspace facts remain exact.
        #expect(abs(decodedDeadline.timeIntervalSince(originalDeadline)) < 0.000001)
        #expect(abs(decodedDeadline.timeIntervalSince(expected)) < 0.000001)
        var precisionAdjustedExpected = w
        precisionAdjustedExpected.projects[0].deadline = decodedDeadline
        #expect(restored == precisionAdjustedExpected)
        print("PRD DATE zone=\(input.1) capacity_minutes=\(input.4) roundtrip_delta_seconds=\(decodedDeadline.timeIntervalSince(originalDeadline))")
        var unrelatedEdit = restored.projects[0]
        unrelatedEdit.name = "renamed without changing the deadline"
        try restored.updateProject(unrelatedEdit, now: at(1))
        #expect(restored.projects[0].deadlineTimeZoneID == input.1)
        #expect(restored.projects[0].deadlineIsDateOnly == true)
        #expect(abs(try #require(restored.projects[0].deadline).timeIntervalSince(expected)) < 0.00001)
        #expect(restored.history.last?.kind == .edited)
        let beforeBadZone = w
        #expect(throws: CoreError.self) {
            try w.setProjectDeadline(id: "P", deadline: day, timeZoneID: "Not/A_TimeZone", dateOnly: true, now: at(1))
        }
        #expect(w == beforeBadZone)
        try w.setProjectDeadline(id: "P", deadline: nil, timeZoneID: input.1, now: at(2))
        #expect(w.projects[0].deadline == nil)
    }

    @Test func ac090ScopeReworkAndChoiceKeepDifferentEventSources() throws {
        var w = Workspace(projects: [project("P")], items: [WorkItem(id: "x", name: "x", projectIDs: ["P"], remainingMinutes: 20)])
        var p = w.projects[0]; p.planningCompleteness = .incomplete
        try w.updateProject(p, now: at(0), note: "new scope not fully modeled")
        let scope = try #require(w.history.last)
        #expect(scope.kind == .scopeChanged && scope.objectID == "P")
        try w.updateRemaining(itemID: "x", minutes: 40, now: at(1), reason: .scopeChange, note: "additional deliverable work")
        let scopeEstimate = try #require(w.estimateRevisions?.last)
        #expect(scopeEstimate.reason == .scopeChange && scopeEstimate.itemID == "x")
        try w.chooseNextAction(itemID: "x", now: at(2), displayedItemIDs: ["x"], impactWasVerified: false, note: "user chose this")
        let originalChoice = try #require(w.currentNextAction)
        let choiceEvent = try #require(w.history.last)
        #expect(choiceEvent.kind == .choiceRecorded && choiceEvent.objectID == originalChoice.id)
        #expect(originalChoice.trial == nil && !originalChoice.impactWasVerified)
        #expect(try item("x", in: w).status == .pending && item("x", in: w).started == nil)
        #expect(w.workSessions.isEmpty)
        try w.completeItem(id: "x", now: at(3))
        try w.reworkItem(id: "x", remainingMinutes: 15, now: at(4), note: "quality rework")
        let rework = try #require(w.history.last)
        #expect(rework.kind == .reworked && rework.objectID == "x" && rework.round == 2)
        #expect(w.estimateRevisions?.last?.reason == .rework)
        #expect(w.history.contains { $0.id == scope.id && $0.kind == .scopeChanged })
        #expect(w.history.contains { $0.id == choiceEvent.id && $0.date == at(2) })
        #expect(w.choices?.first { $0.id == originalChoice.id } == originalChoice)
        #expect(w.workSessions.isEmpty)
        #expect(w.history.filter { $0.kind == .choiceRecorded }.count == 1)
    }

    @Test func rootArchiveCurrentWorkspaceCancelsScopeRetainsSharedFactsAndExplicitRestore() throws {
        var w = Workspace(projects: [project("A"), project("B"), project("finished")],
                          nodes: [Node(id: "N", projectID: "B", name: "shared incomplete stage", planningCompleteness: .complete)],
                          items: [WorkItem(id: "shared", name: "shared", projectIDs: ["A", "B"], remainingMinutes: 60),
                                  WorkItem(id: "done", name: "done", projectIDs: ["finished"], remainingMinutes: 5)],
                          blockers: [Blocker(id: "future-wait", name: "not initiated")],
                          acceptances: [Acceptance(id: "gate", subject: .node("N"), name: "not checked")],
                          workLinks: [WorkLink(id: "shared-N", source: .item("shared"), projectID: "B", nodeID: "N")])
        try w.recordWork(itemID: "shared", start: at(0), end: at(10), actualMinutes: 10, remaining: .minutes(50))
        try w.completeItem(id: "done", now: at(11))
        try w.completeProject(id: "finished", now: at(12))
        try w.chooseNextAction(itemID: "shared", now: at(13), displayedItemIDs: ["shared"], impactWasVerified: false)
        let before = w
        try w.archiveCurrentWorkspace(now: at(14))
        #expect(w.projects.allSatisfy { $0.archived })
        #expect(w.projects.filter { $0.id != "finished" }.allSatisfy { $0.effectiveStatus == .cancelled })
        #expect(w.projects.first { $0.id == "finished" }?.effectiveStatus == .completed)
        #expect(w.nodes.allSatisfy { $0.archived })
        #expect(w.blockers.allSatisfy { $0.isArchived == true })
        #expect(try item("shared", in: w).status == .inProgress && item("shared", in: w).effectiveDisposition == .cancelled)
        #expect(try item("shared", in: w).remainingMinutes == 50)
        #expect(try item("done", in: w).status == .completed)
        #expect(w.currentChoiceID == nil && w.choices == before.choices)
        #expect(w.workLinks == before.workLinks && w.dependencies == before.dependencies)
        #expect(w.workRounds == before.workRounds && w.workSessions == before.workSessions)
        #expect(w.acceptances == before.acceptances)
        #expect(w.history.starts(with: before.history))
        #expect(w.effortSummary().confirmedMinutes == 10)
        let hidden = try Engine.plan(workspace: w, input: PlanningInput(slots: [CapacitySlot(start: at(14), end: at(240))], now: at(14)))
        #expect(hidden.committedDemandMinutes == 0)
        // Visibility restore alone must not silently renew cancelled commitments.
        for id in ["A", "B"] { try w.setProjectArchived(id: id, archived: false, now: at(15)) }
        try w.setArchived(.node("N"), archived: false, now: at(15))
        try w.setArchived(.item("shared"), archived: false, now: at(15))
        try w.setBlockerArchived(id: "future-wait", archived: false, now: at(15))
        #expect(w.projects.filter { $0.id != "finished" }.allSatisfy { $0.effectiveStatus == .cancelled })
        for id in ["A", "B"] { try w.reopenProject(id: id, now: at(16), note: "explicitly restore delivery commitment") }
        try w.setItemDisposition(id: "shared", disposition: .active, now: at(16))
        #expect(try item("shared", in: w).projectIDs == ["A", "B"])
        #expect(try item("shared", in: w).remainingMinutes == 50 && item("shared", in: w).status == .inProgress)
        #expect(w.workLinks == before.workLinks && w.workSessions == before.workSessions)
        #expect(w.effortSummary().confirmedMinutes == 10)
        #expect(try gate("gate", in: w).state == .pending)
        #expect(!w.sourceSatisfied(.node("N")))
        let restored = try Engine.plan(workspace: w, input: PlanningInput(slots: [CapacitySlot(start: at(16), end: at(240))], now: at(16)))
        #expect(restored.committedDemandMinutes == 50)
        #expect(w.history.contains { $0.kind == .restored && $0.objectID == "shared" })
    }

    // R5-F1: equal numeric estimates are not interchangeable event identities.
    @Test func r5f1CreatedInitial60OriginSurvives120Then60AndCorrectionChain() throws {
        var w = Workspace()
        try w.addItem(WorkItem(id: "created-estimate", name: "known on creation", remainingMinutes: 60), now: at(0))
        let created = try #require(w.history.last { $0.objectID == "created-estimate" && $0.kind == .created })
        #expect(try item("created-estimate", in: w).initialMinutes == 60)
        #expect(try item("created-estimate", in: w).initialEstimateEventID == created.id)
        try w.updateRemaining(itemID: "created-estimate", minutes: 120, now: at(1))
        try w.updateRemaining(itemID: "created-estimate", minutes: 60, now: at(2))
        let laterSame60 = try #require(w.history.last { $0.objectID == "created-estimate" && $0.kind == .remainingUpdated })
        #expect(laterSame60.minutes == 60 && laterSame60.id != created.id)
        let before = w
        try w.correctEstimateBaseline(itemID: "created-estimate", baseline: .initial, minutes: 50, now: at(3), note: "correct original creation estimate")
        let firstCorrection = try #require(w.history.last)
        #expect(firstCorrection.correctsEventID == created.id)
        #expect(firstCorrection.correctsEventID != laterSame60.id)
        #expect(firstCorrection.previousMinutes == 60 && firstCorrection.minutes == 50)
        #expect(firstCorrection.changeReason == .correction)
        #expect(try item("created-estimate", in: w) == item("created-estimate", in: before))
        #expect(w.estimateRevisions == before.estimateRevisions)
        #expect(w.history.starts(with: before.history))
        try w.correctEstimateBaseline(itemID: "created-estimate", baseline: .initial, minutes: 55, now: at(4), note: "second interpretation correction")
        #expect(w.history.last?.correctsEventID == firstCorrection.id)
        #expect(w.baselineCorrections(itemID: "created-estimate").map(\.originalMinutes) == [60, 60])
        #expect(try item("created-estimate", in: w).initialEstimateEventID == created.id)
        #expect(try item("created-estimate", in: w).remainingMinutes == 60)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let restored = try decoder.decode(Workspace.self, from: encoder.encode(w))
        #expect(restored == w)
        #expect(try item("created-estimate", in: restored).initialEstimateEventID == created.id)
    }

    @Test func r5f1LegacyMissingOriginCannotBeInferredFromLaterSame60() throws {
        // Literal old schema-1 data, not the current encoder with a key deleted.
        let legacy = """
        {"schemaVersion":1,"projects":[],"nodes":[],"items":[{"id":"legacy-estimate","name":"legacy","projectIDs":[],"remainingMinutes":60,"initialMinutes":60,"energy":"normal","requiresContinuous":false,"status":"pending","needsReview":false}],"blockers":[],"dependencies":[],"acceptances":[],"history":[{"id":"old-created","date":1791093600000,"kind":"created","objectID":"legacy-estimate","note":""},{"id":"later-120","date":1791093660000,"kind":"remainingUpdated","objectID":"legacy-estimate","note":"","minutes":120},{"id":"later-same-60","date":1791093720000,"kind":"remainingUpdated","objectID":"legacy-estimate","note":"","minutes":60}],"decisions":[],"workSessions":[]}
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        var w = try decoder.decode(Workspace.self, from: Data(legacy.utf8))
        try w.validate()
        #expect(try item("legacy-estimate", in: w).initialEstimateEventID == nil)
        let before = w
        try w.correctEstimateBaseline(itemID: "legacy-estimate", baseline: .initial, minutes: 50, now: at(3), note: "original source unknown")
        let firstCorrection = try #require(w.history.last)
        #expect(firstCorrection.correctsEventID == nil)
        #expect(firstCorrection.previousMinutes == 60 && firstCorrection.minutes == 50)
        #expect(try item("legacy-estimate", in: w) == item("legacy-estimate", in: before))
        #expect(w.history.starts(with: before.history))
        try w.correctEstimateBaseline(itemID: "legacy-estimate", baseline: .initial, minutes: 55, now: at(4), note: "known correction chain, unknown original origin")
        #expect(w.history.last?.correctsEventID == firstCorrection.id)
        #expect(w.history.last?.correctsEventID != "later-same-60")
        #expect(w.baselineCorrections(itemID: "legacy-estimate").map(\.originalMinutes) == [60, 60])
        #expect(try item("legacy-estimate", in: w).initialEstimateEventID == nil)
        #expect(try item("legacy-estimate", in: w).initialMinutes == 60 && item("legacy-estimate", in: w).remainingMinutes == 60)
    }

    @Test func r5f1InitiallyUnknownCapturesFirstRemainingEventAndKeepsItsIdentity() throws {
        var w = Workspace()
        try w.addItem(WorkItem(id: "unknown-estimate", name: "unknown at creation"), now: at(0))
        let created = try #require(w.history.last)
        #expect(try item("unknown-estimate", in: w).initialEstimateEventID == nil)
        let unknown = w
        #expect(throws: CoreError.self) {
            try w.correctEstimateBaseline(itemID: "unknown-estimate", baseline: .initial, minutes: 50, now: at(1))
        }
        #expect(w == unknown)
        try w.updateRemaining(itemID: "unknown-estimate", minutes: 60, now: at(2))
        let firstEstimate = try #require(w.history.last)
        #expect(firstEstimate.kind == .remainingUpdated && firstEstimate.minutes == 60)
        #expect(try item("unknown-estimate", in: w).initialEstimateEventID == firstEstimate.id)
        try w.updateRemaining(itemID: "unknown-estimate", minutes: 120, now: at(3))
        try w.updateRemaining(itemID: "unknown-estimate", minutes: 60, now: at(4))
        let laterSame60 = try #require(w.history.last)
        try w.correctEstimateBaseline(itemID: "unknown-estimate", baseline: .initial, minutes: 50, now: at(5))
        let correction = try #require(w.history.last)
        #expect(correction.correctsEventID == firstEstimate.id)
        #expect(correction.correctsEventID != created.id && correction.correctsEventID != laterSame60.id)
        try w.correctEstimateBaseline(itemID: "unknown-estimate", baseline: .initial, minutes: 55, now: at(6))
        #expect(w.history.last?.correctsEventID == correction.id)
        #expect(try item("unknown-estimate", in: w).initialMinutes == 60 && item("unknown-estimate", in: w).remainingMinutes == 60)
        #expect(try item("unknown-estimate", in: w).initialEstimateEventID == firstEstimate.id)
    }

    private func r7MembershipFixture(inProgress: Bool, sourceNodeID: String?, nodes: [Node], blockers: [Blocker], extraDependencies: [Dependency] = []) throws -> Workspace {
        var w = Workspace(projects: [project("P1"), project("P2"), project("unrelated")], nodes: nodes,
                          items: [WorkItem(id: "x", name: "existing result", nodeID: sourceNodeID,
                                           projectIDs: sourceNodeID == nil ? [] : ["P1"], remainingMinutes: 20),
                                  WorkItem(id: "y", name: "item-granularity consumer", projectIDs: ["P2"], remainingMinutes: 10),
                                  WorkItem(id: "z", name: "unrelated result", projectIDs: ["unrelated"], remainingMinutes: 10)],
                          blockers: blockers,
                          dependencies: [Dependency(id: "x-y", source: .item("x"), targetItemID: "y")] + extraDependencies,
                          acceptances: nodes.map { Acceptance(id: "gate-" + $0.id, subject: .node($0.id), name: "manual node check") })
        for b in blockers {
            try w.triggerBlocker(id: b.id, now: at(0))
            try w.resolveBlocker(id: b.id, now: at(1))
        }
        try w.recordWork(itemID: "x", start: at(2), end: at(7), actualMinutes: 5)
        try w.completeItem(id: "x", now: at(8))
        try w.recordWork(itemID: "y", start: at(9), end: at(14), actualMinutes: 5)
        try w.completeItem(id: "y", now: at(15))
        try w.completeProject(id: "P2", now: at(16))
        try w.completeItem(id: "z", now: at(17))
        try w.completeProject(id: "unrelated", now: at(18))
        if inProgress {
            // Establish a legal completed consumer of an old result while x works
            // round 2: explicit stillValid, never hand-set a completed flag.
            try w.reworkItem(id: "x", remainingMinutes: 20, now: at(19))
            try w.reviewItem(id: "y", outcome: .stillValid, now: at(20))
            try w.completeProject(id: "P2", now: at(21))
            try w.recordWork(itemID: "x", start: at(22), end: at(27), actualMinutes: 5)
        }
        return w
    }

    private func expectR7ResultFactsPreserved(_ w: Workspace, before: Workspace) throws {
        for id in ["x", "y"] {
            let actual = try item(id, in: w), old = try item(id, in: before)
            #expect(actual.status == old.status && actual.completedAt == old.completedAt)
            #expect(actual.started == old.started && actual.currentRound == old.currentRound)
            #expect(actual.initialMinutes == old.initialMinutes && actual.preStartMinutes == old.preStartMinutes)
            #expect(actual.remainingMinutes == old.remainingMinutes)
        }
        #expect(w.workRounds == before.workRounds)
        #expect(w.workSessions == before.workSessions)
        #expect(w.estimateRevisions == before.estimateRevisions)
        #expect(w.history.starts(with: before.history))
        #expect(w.effortSummary().confirmedMinutes == before.effortSummary().confirmedMinutes)
        #expect(try item("z", in: w) == item("z", in: before))
        #expect(w.projects.first { $0.id == "unrelated" } == before.projects.first { $0.id == "unrelated" })
    }

    @Test(arguments: [false, true])
    func r7IndependentCompletedOrInProgressMemberEnteringActiveScopeRequiresReview(_ inProgress: Bool) throws {
        let n = Node(id: "N", projectID: "P1", name: "blocked scope", planningCompleteness: .complete, blockerIDs: ["b"])
        var w = try r7MembershipFixture(inProgress: inProgress, sourceNodeID: nil, nodes: [n], blockers: [Blocker(id: "b", name: "whole-node condition")])
        try w.triggerBlocker(id: "b", now: at(29))
        let before = w
        #expect(w.projects.first { $0.id == "P2" }?.effectiveStatus == .completed)
        #expect(try !item("x", in: w).needsReview && !item("y", in: w).needsReview)
        var moved = try item("x", in: w); moved.nodeID = "N"; moved.projectIDs = ["P1"]
        try w.updateItem(moved, now: at(30), note: "membership adds a real input")
        #expect(try item("x", in: w).nodeID == "N" && item("x", in: w).needsReview)
        #expect(try item("y", in: w).needsReview)
        #expect(!w.sourceSatisfied(.item("x")) && !w.sourceSatisfied(.item("y")))
        #expect(w.projects.first { $0.id == "P2" }?.effectiveStatus == .active)
        #expect(w.projects.first { $0.id == "P2" }?.completedAt == nil)
        #expect(w.projects.first { $0.id == "P2" }?.hasDeliveryCommitment == true)
        try expectR7ResultFactsPreserved(w, before: before)
        try w.resolveBlocker(id: "b", now: at(35))
        #expect(w.sourceSatisfied(.blocker("b")))
        #expect(try item("x", in: w).needsReview && item("y", in: w).needsReview)
        #expect(!w.sourceSatisfied(.item("x")) && !w.sourceSatisfied(.item("y")))
        let unresolved = w
        #expect(throws: CoreError.self) { try w.completeProject(id: "P2", now: at(35)) }
        #expect(w == unresolved)
        if inProgress {
            #expect(throws: CoreError.self) { try w.recordWork(itemID: "x", start: at(35), end: at(36), actualMinutes: 1) }
            #expect(w == unresolved)
            #expect(throws: CoreError.self) {
                try w.recordApproximateWork(itemID: "x", occurredOn: at(35), recordedAt: at(35), actualMinutes: 1)
            }
            #expect(w == unresolved)
        }
        // Positive control: only explicit checks make old results reusable.
        try w.reviewItem(id: "x", outcome: .stillValid, now: at(36))
        let review = try #require(w.reviews?.last { $0.itemID == "x" })
        #expect(!review.sources.contains { $0.source == .blocker("b") })
        #expect(review.currentSources?.contains { $0.source == .blocker("b") && $0.sourceRound == 2 && $0.nodeID == "N" } == true)
        #expect(try item("y", in: w).needsReview)
        try w.reviewItem(id: "y", outcome: .stillValid, now: at(37))
        try w.completeProject(id: "P2", now: at(38))
        #expect(w.projects.first { $0.id == "P2" }?.effectiveStatus == .completed)
        if inProgress {
            try w.recordWork(itemID: "x", start: at(39), end: at(40), actualMinutes: 1)
            #expect(w.workSessions.count == before.workSessions.count + 1)
        } else {
            #expect(w.sourceSatisfied(.item("x")))
        }
    }

    @Test(arguments: [(false, false), (false, true), (true, false), (true, true)])
    func r7PureMembershipMoveWithSameEffectivePrerequisitesKeepsResults(_ input: (Bool, Bool)) throws {
        let inProgress = input.0, sharedWait = input.1
        let nodes = ["old", "new"].map { Node(id: $0, projectID: "P1", name: $0, planningCompleteness: .complete, blockerIDs: sharedWait ? ["same-b"] : []) }
        var w = try r7MembershipFixture(inProgress: inProgress, sourceNodeID: "old", nodes: nodes,
                                       blockers: sharedWait ? [Blocker(id: "same-b", name: "same actual prerequisite")] : [])
        let before = w
        var moved = try item("x", in: w); moved.nodeID = "new"
        try w.updateItem(moved, now: at(30), note: "location changes; actual prerequisite does not")
        #expect(try item("x", in: w).nodeID == "new" && !item("x", in: w).needsReview)
        #expect(try !item("y", in: w).needsReview)
        #expect(w.projects.first { $0.id == "P2" } == before.projects.first { $0.id == "P2" })
        #expect(w.sourceSatisfied(.item("y")))
        #expect(w.reviews == before.reviews)
        try expectR7ResultFactsPreserved(w, before: before)
        if sharedWait {
            let consumed = try #require(try round("x", inProgress ? 2 : 1, in: w).sources?.first { $0.source == .blocker("same-b") })
            #expect(consumed.nodeID == "old" && consumed.sourceRound == 1)
            #expect(w.blockers == before.blockers)
        }
        if inProgress {
            try w.recordWork(itemID: "x", start: at(31), end: at(32), actualMinutes: 1)
            #expect(w.workSessions.count == before.workSessions.count + 1)
        } else {
            #expect(w.sourceSatisfied(.item("x")))
        }
    }

    @Test(arguments: [(false, false), (false, true), (true, false), (true, true)])
    func r7DifferentResolvedBlockerIdentitiesRequireMemberAndConsumerReview(_ input: (Bool, Bool)) throws {
        let inProgress = input.0, moveMembership = input.1
        let oldNode = Node(id: "old", projectID: "P1", name: "old input", planningCompleteness: .complete, blockerIDs: ["old-b"])
        let newNode = Node(id: "new", projectID: "P1", name: "new input", planningCompleteness: .complete, blockerIDs: ["new-b"])
        var w = try r7MembershipFixture(inProgress: inProgress, sourceNodeID: "old", nodes: [oldNode, newNode],
                                       blockers: [Blocker(id: "old-b", name: "old condition"), Blocker(id: "new-b", name: "different condition")])
        let before = w
        #expect(w.blockers.allSatisfy { $0.state == .resolved && $0.currentRound == 1 })
        if moveMembership {
            var moved = try item("x", in: w); moved.nodeID = "new"
            try w.updateItem(moved, now: at(30), note: "different resolved input on new membership")
        } else {
            var changed = w.nodes[0]; changed.blockerIDs = ["new-b"]
            try w.updateNode(changed, now: at(30), note: "different resolved input for existing members")
        }
        let expectedNodeID = moveMembership ? "new" : "old"
        #expect(try item("x", in: w).needsReview && item("y", in: w).needsReview)
        #expect(!w.sourceSatisfied(.item("y")))
        #expect(w.projects.first { $0.id == "P2" }?.effectiveStatus == .active)
        #expect(w.projects.first { $0.id == "P2" }?.completedAt == nil)
        #expect(w.blockers == before.blockers)
        try expectR7ResultFactsPreserved(w, before: before)
        let pendingReview = w
        #expect(throws: CoreError.self) { try w.completeProject(id: "P2", now: at(31)) }
        #expect(w == pendingReview)
        if inProgress {
            #expect(throws: CoreError.self) { try w.recordWork(itemID: "x", start: at(31), end: at(32), actualMinutes: 1) }
            #expect(w == pendingReview)
        }
        try w.reviewItem(id: "x", outcome: .stillValid, now: at(33))
        let review = try #require(w.reviews?.last { $0.itemID == "x" })
        let consumed = try #require(review.sources.first { $0.source == .blocker("old-b") })
        let checked = try #require(review.currentSources?.first { $0.source == .blocker("new-b") })
        #expect(consumed.nodeID == "old" && consumed.sourceRound == 1)
        #expect(checked.nodeID == expectedNodeID && checked.sourceRound == 1)
        #expect(consumed.dependencyID != checked.dependencyID)
        #expect(review.currentSources?.contains { $0.source == .blocker("old-b") } == false)
        #expect(try item("y", in: w).needsReview)
        try w.reviewItem(id: "y", outcome: .stillValid, now: at(34))
        try w.completeProject(id: "P2", now: at(35))
        #expect(w.sourceSatisfied(.item("y")))
        if inProgress { try w.recordWork(itemID: "x", start: at(36), end: at(37), actualMinutes: 1) }
        else { #expect(w.sourceSatisfied(.item("x"))) }
    }

    @Test(arguments: [false, true])
    func r7StillValidActiveSameBlockerMovePreservesContextButNotNewRoundOrExplicitIdentity(_ inProgress: Bool) throws {
        let nodes = ["old", "new"].map { Node(id: $0, projectID: "P1", name: $0, planningCompleteness: .complete, blockerIDs: ["same-b"]) }
        var w = try r7MembershipFixture(inProgress: inProgress, sourceNodeID: "old", nodes: nodes,
                                       blockers: [Blocker(id: "same-b", name: "same active condition")],
                                       extraDependencies: [Dependency(id: "explicit-b-x", source: .blocker("same-b"), targetItemID: "x")])
        try w.triggerBlocker(id: "same-b", now: at(29))
        try w.reviewItem(id: "x", outcome: .stillValid, now: at(30))
        try w.reviewItem(id: "y", outcome: .stillValid, now: at(31))
        try w.completeProject(id: "P2", now: at(32))
        let oldReview = try #require(w.reviews?.last { $0.itemID == "x" })
        let consumed = try #require(oldReview.sources.first { $0.source == .blocker("same-b") && $0.nodeID == "old" })
        let checked = try #require(oldReview.currentSources?.first { $0.source == .blocker("same-b") && $0.nodeID == "old" })
        let explicit = try #require(oldReview.currentSources?.first { $0.dependencyID == "explicit-b-x" })
        #expect(consumed.sourceRound == 1 && checked.sourceRound == 2)
        #expect(explicit.sourceRound == 2 && explicit.dependencyRevision == 1 && explicit.nodeID == nil)
        let reviewed = w
        var moved = try item("x", in: w); moved.nodeID = "new"
        try w.updateItem(moved, now: at(33), note: "same active condition; old review scope provenance stays historical")
        #expect(try !item("x", in: w).needsReview && !item("y", in: w).needsReview)
        #expect(w.sourceSatisfied(.item("y")))
        if !inProgress { #expect(w.sourceSatisfied(.item("x"))) }
        #expect(!w.sourceSatisfied(.blocker("same-b")))
        #expect(w.projects.first { $0.id == "P2" } == reviewed.projects.first { $0.id == "P2" })
        #expect(w.reviews == reviewed.reviews)
        try expectR7ResultFactsPreserved(w, before: reviewed)
        #expect(!w.sourceSatisfied(.node("new")))
        let movedSnapshot = w
        if inProgress {
            #expect(throws: CoreError.self) { try w.recordWork(itemID: "x", start: at(34), end: at(35), actualMinutes: 1) }
            #expect(w == movedSnapshot)
            #expect(throws: CoreError.self) {
                try w.recordApproximateWork(itemID: "x", occurredOn: at(34), recordedAt: at(34), actualMinutes: 1)
            }
            #expect(w == movedSnapshot)
            #expect(throws: CoreError.self) { try w.completeItem(id: "x", now: at(34)) }
            #expect(w == movedSnapshot)
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let restored = try decoder.decode(Workspace.self, from: encoder.encode(w))
        try restored.validate()
        #expect(restored == w)
        #expect(restored.reviews?.first { $0.id == oldReview.id } == oldReview)
        #expect(restored.sourceSatisfied(.item("y")))
        if !inProgress { #expect(restored.sourceSatisfied(.item("x"))) }

        // Explicit identities remain distinct even when the actual blocker/round is unchanged.
        var revised = w
        let dependency = try #require(revised.dependencies.first { $0.id == "explicit-b-x" })
        try revised.updateDependency(dependency, now: at(34), note: "new explicit relation version")
        #expect(revised.dependencies.first { $0.id == "explicit-b-x" }?.currentRevision == 2)
        #expect(try item("x", in: revised).needsReview && item("y", in: revised).needsReview)
        #expect(!revised.sourceSatisfied(.item("y")))
        if !inProgress { #expect(!revised.sourceSatisfied(.item("x"))) }
        #expect(revised.projects.first { $0.id == "P2" }?.effectiveStatus == .active)
        #expect(revised.reviews?.first { $0.id == oldReview.id } == oldReview)
        try revised.reviewItem(id: "x", outcome: .stillValid, now: at(35))
        let revisedReview = try #require(revised.reviews?.last { $0.itemID == "x" })
        #expect(revisedReview.currentSources?.contains { $0.dependencyID == "explicit-b-x" && $0.dependencyRevision == 2 && $0.sourceRound == 2 } == true)
        try revised.reviewItem(id: "y", outcome: .stillValid, now: at(36))
        try revised.completeProject(id: "P2", now: at(37))

        var replaced = w
        try replaced.removeDependency(id: "explicit-b-x", now: at(34))
        try replaced.addDependency(Dependency(id: "replacement-b-x", source: .blocker("same-b"), targetItemID: "x"), now: at(35))
        #expect(try item("x", in: replaced).needsReview && item("y", in: replaced).needsReview)
        #expect(!replaced.sourceSatisfied(.item("y")))
        if !inProgress { #expect(!replaced.sourceSatisfied(.item("x"))) }
        #expect(replaced.projects.first { $0.id == "P2" }?.effectiveStatus == .active)
        #expect(replaced.reviews?.first { $0.id == oldReview.id } == oldReview)
        try replaced.reviewItem(id: "x", outcome: .stillValid, now: at(36))
        let replacementReview = try #require(replaced.reviews?.last { $0.itemID == "x" })
        #expect(replacementReview.currentSources?.contains { $0.dependencyID == "replacement-b-x" && $0.dependencyRevision == 1 && $0.sourceRound == 2 } == true)
        #expect(replacementReview.currentSources?.contains { $0.dependencyID == "explicit-b-x" } == false)
        try replaced.reviewItem(id: "y", outcome: .stillValid, now: at(37))
        try replaced.completeProject(id: "P2", now: at(38))

        try w.resolveBlocker(id: "same-b", now: at(40))
        #expect(w.sourceSatisfied(.item("y")))
        try w.triggerBlocker(id: "same-b", now: at(41))
        #expect(w.blockers[0].currentRound == 3)
        #expect(try item("x", in: w).needsReview && item("y", in: w).needsReview)
        #expect(!w.sourceSatisfied(.item("x")) && !w.sourceSatisfied(.item("y")))
        #expect(w.projects.first { $0.id == "P2" }?.effectiveStatus == .active)
        #expect(w.projects.first { $0.id == "P2" }?.completedAt == nil)
        #expect(w.reviews == reviewed.reviews)
        #expect(w.workRounds == reviewed.workRounds && w.workSessions == reviewed.workSessions)
        try w.resolveBlocker(id: "same-b", now: at(43))
        #expect(try item("x", in: w).needsReview && item("y", in: w).needsReview)
        let expired = w
        #expect(throws: CoreError.self) { try w.completeProject(id: "P2", now: at(43)) }
        #expect(w == expired)
        try w.reviewItem(id: "x", outcome: .stillValid, now: at(44))
        let newReview = try #require(w.reviews?.last { $0.itemID == "x" })
        #expect(newReview.currentSources?.contains { $0.source == .blocker("same-b") && $0.sourceRound == 3 && $0.nodeID == "new" } == true)
        #expect(w.reviews?.first { $0.id == oldReview.id } == oldReview)
        try w.reviewItem(id: "y", outcome: .stillValid, now: at(45))
        try w.completeProject(id: "P2", now: at(46))
        if inProgress { try w.recordWork(itemID: "x", start: at(47), end: at(48), actualMinutes: 1) }
        else { #expect(w.sourceSatisfied(.item("x"))) }
    }
}
