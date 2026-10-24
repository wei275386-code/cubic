import Foundation
import Testing
@testable import CubicCore

@Suite(.serialized) struct DomainRulesTests {
    private func nodeWorkspace() -> Workspace {
        Workspace(projects:[PRD.project()],nodes:[Node(id:"n",projectID:"p",name:"n",planningCompleteness:.complete)],
                  items:[WorkItem(id:"a",name:"a",nodeID:"n",projectIDs:["p"],remainingMinutes:20),WorkItem(id:"b",name:"b",nodeID:"n",projectIDs:["p"],remainingMinutes:20)],
                  acceptances:[Acceptance(id:"g1",subject:.node("n"),name:"first"),Acceptance(id:"g2",subject:.node("n"),name:"second")])
    }
    @Test func titleOnlyDirectCompletionAndEstimates() throws {
        var w = Workspace.empty
        try w.addItem(WorkItem(id:"inbox",name:"just a title"),now:PRD.t)
        #expect(w.items[0].remainingMinutes == nil); #expect(w.items[0].projectIDs.isEmpty)
        try w.updateRemaining(itemID:"inbox",minutes:60,now:PRD.at(1))
        try w.updateRemaining(itemID:"inbox",minutes:90,now:PRD.at(2),reason:.scopeChange)
        try w.startItem(id:"inbox",now:PRD.at(3))
        #expect(w.items[0].initialMinutes == 60); #expect(w.items[0].preStartMinutes == 90)
        try w.recordWork(itemID:"inbox",start:PRD.at(3),end:PRD.at(43),actualMinutes:40)
        #expect(w.items[0].remainingMinutes == 90)
        try w.updateRemaining(itemID:"inbox",minutes:0,now:PRD.at(44))
        #expect(w.items[0].status == .inProgress)
        let count = w.workSessions.count
        try w.updateRemaining(itemID:"inbox",minutes:nil,now:PRD.at(45))
        #expect(w.workSessions.count == count)
        try w.completeItem(id:"inbox",now:PRD.at(46))
        #expect(w.items[0].remainingMinutes == 0)
        #expect(w.effortSummary().recordingIsComplete)
        let oldHistory = w.history, oldSessions = w.workSessions
        try w.reworkItem(id:"inbox",remainingMinutes:nil,now:PRD.at(47))
        #expect(w.items[0].remainingMinutes == nil); #expect(w.items[0].currentRound == 2)
        #expect(w.items[0].status == .pending); #expect(w.items[0].preStartMinutes == 90)
        #expect(w.workRounds?.last?.startedAt == nil)
        #expect(w.history.starts(with:oldHistory)); #expect(w.workSessions == oldSessions)
        try w.addItem(WorkItem(id:"direct",name:"direct"),now:PRD.at(48))
        try w.completeItem(id:"direct",now:PRD.at(49))
        #expect(w.items[1].started == nil); #expect(w.items[1].preStartCapturedAt == nil)
        #expect(w.items[1].initialMinutes == nil)
    }

    @Test func approximatePastDayUnknownAndNoClockAccumulation() throws {
        var w = Workspace(items:[WorkItem(id:"x",name:"x",remainingMinutes:60)])
        try w.recordApproximateWork(itemID:"x",occurredOn:PRD.at(-1440),recordedAt:PRD.t,actualMinutes:40)
        let s = try #require(w.workSessions.first)
        #expect(s.occurredOn == PRD.at(-1440)); #expect(s.recordedAt == PRD.t)
        #expect(!s.hasExactInterval); #expect(s.start == s.end)
        #expect(w.items[0].remainingMinutes == 60)
        #expect(w.items[0].started == nil); #expect(w.items[0].preStartCapturedAt == nil)
        #expect(w.items[0].startTimeIsUnknown == true)
        let before = w.workSessions
        _ = try PRD.plan(w,[PRD.slot(1440,1560)])
        #expect(w.workSessions == before); #expect(w.effortSummary().confirmedMinutes == 40)
        try w.recordApproximateWork(itemID:"x",occurredOn:PRD.t,recordedAt:PRD.at(1),actualMinutes:1,remaining:.unknown)
        #expect(w.items[0].remainingMinutes == nil)
    }

    @Test func mandatoryPerCriterionGateAndItemVsNodeGranularity() throws {
        var w = nodeWorkspace()
        try w.addItem(WorkItem(id:"item-consumer",name:"item",remainingMinutes:5),now:PRD.t)
        try w.addItem(WorkItem(id:"node-consumer",name:"node",remainingMinutes:5),now:PRD.t)
        try w.addDependency(Dependency(id:"item-edge",source:.item("a"),targetItemID:"item-consumer"),now:PRD.t)
        try w.addDependency(Dependency(id:"node-edge",source:.node("n"),targetItemID:"node-consumer"),now:PRD.t)
        #expect(throws: CoreError.self) { try w.accept(id:"g1",now:PRD.t) }
        try w.completeItem(id:"a",now:PRD.at(1))
        #expect(w.sourceSatisfied(.item("a")))
        try w.startItem(id:"item-consumer",now:PRD.at(2))
        #expect(throws: CoreError.self) { try w.startItem(id:"node-consumer",now:PRD.at(2)) }
        try w.completeItem(id:"b",now:PRD.at(3))
        #expect(throws: CoreError.self) { try w.completeNode(id:"n",now:PRD.at(4)) }
        try w.accept(id:"g1",now:PRD.at(4))
        #expect(!w.sourceSatisfied(.node("n")))
        #expect(w.acceptances[1].state == .pending)
        try w.accept(id:"g2",now:PRD.at(5))
        #expect(w.sourceSatisfied(.node("n")))
        try w.completeNode(id:"n",now:PRD.at(6))
        try w.completeProject(id:"p",now:PRD.at(7))
        #expect(w.projects[0].effectiveStatus == .completed)
        try w.startItem(id:"node-consumer",now:PRD.at(8))
    }

    @Test func defaultAcceptanceWhenNoGateAndAddedGateIsAlwaysRequired() throws {
        var w = nodeWorkspace()
        try w.completeItem(id:"a",now:PRD.at(1)); try w.completeItem(id:"b",now:PRD.at(1))
        try w.removeAcceptance(id:"g1",now:PRD.at(2)); try w.removeAcceptance(id:"g2",now:PRD.at(2))
        #expect(w.acceptances.allSatisfy { $0.state == .pending && !$0.isActive })
        #expect(w.acceptanceMode(for:.node("n")) == .selfCompletion)
        #expect(w.history.contains { $0.kind == .acceptanceRemoved })
        var n = w.nodes[0]; n.planningCompleteness = .incomplete
        try w.updateNode(n,now:PRD.at(3))
        #expect(!w.nodeCompletionIssues(id:"n").contains { $0.contains("范围") })
        // 默认验收：没有显式条件时，验收等于“完成自身”
        #expect(w.nodeCompletionIssues(id:"n").isEmpty)
        #expect(w.sourceSatisfied(.node("n")))
        try w.completeNode(id:"n",now:PRD.at(4))
        // 一旦添加验收条件，必须逐条人工通过
        try w.addAcceptance(Acceptance(id:"g3",subject:.node("n"),name:"third"),now:PRD.at(5))
        #expect(w.nodes[0].completedAt == nil)
        #expect(w.acceptanceMode(for:.node("n")) == .explicit)
        #expect(!w.sourceSatisfied(.node("n")))
        #expect(w.nodeCompletionIssues(id:"n").contains { $0.contains("必需验收未通过") })
        #expect(throws: CoreError.self) { try w.completeNode(id:"n",now:PRD.at(6)) }
        try w.accept(id:"g3",now:PRD.at(7))
        #expect(w.acceptances.first { $0.id == "g3" }?.required == true)
        #expect(w.sourceSatisfied(.node("n")))
    }

    @Test func defaultAcceptanceRejectsEmptyNode() throws {
        var w = Workspace(projects:[PRD.project()],nodes:[Node(id:"empty",projectID:"p",name:"empty")])
        #expect(w.acceptanceMode(for:.node("empty")) == .selfCompletion)
        #expect(w.nodeCompletionIssues(id:"empty") == ["节点还没有工作"])
        #expect(throws: CoreError.self) { try w.completeNode(id:"empty",now:PRD.at(1)) }
        try w.addItem(WorkItem(id:"m",name:"m",nodeID:"empty",projectIDs:["p"],remainingMinutes:10),now:PRD.at(2))
        #expect(!w.nodeCompletionIssues(id:"empty").contains("节点还没有工作"))
        try w.completeItem(id:"m",now:PRD.at(3))
        #expect(w.nodeCompletionIssues(id:"empty").isEmpty)
        try w.completeNode(id:"empty",now:PRD.at(4))
        #expect(w.sourceSatisfied(.node("empty")))
    }

    @Test func localBranchANDAndCycleAtomicPath() throws {
        var w = nodeWorkspace()
        try w.addBlocker(Blocker(id:"quote",name:"quote"),now:PRD.t)
        try w.addDependency(Dependency(id:"q-b",source:.blocker("quote"),targetItemID:"b"),now:PRD.t)
        try w.addItem(WorkItem(id:"merge",name:"merge",nodeID:"n",projectIDs:["p"],remainingMinutes:10),now:PRD.t)
        try w.addDependency(Dependency(id:"a-m",source:.item("a"),targetItemID:"merge"),now:PRD.t)
        #expect(w.dependencies.contains { $0.isActive && $0.source == .item("b") && $0.targetItemID == "merge" })
        let p = try PRD.plan(w)
        #expect(p.summary.availableActions.contains { $0.itemID == "a" })
        #expect(!p.summary.availableActions.contains { $0.itemID == "b" || $0.itemID == "merge" })
        try w.completeItem(id:"a",now:PRD.at(1))
        #expect(throws: CoreError.self) { try w.startItem(id:"merge",now:PRD.at(2)) }
        let old = w
        do {
            try w.addDependency(Dependency(id:"cycle",source:.item("merge"),targetItemID:"a"),now:PRD.at(2))
            Issue.record("cycle must reject")
        } catch CoreError.cycle(let path) {
            #expect(path.count >= 3); #expect(path.first == path.last)
            #expect(path.contains { $0.contains("a") }); #expect(path.contains { $0.contains("merge") })
        }
        #expect(w == old)
    }

    @Test func wholeNodeBlockerAllRealLaborEntrypoints() throws {
        var w = nodeWorkspace()
        try w.startItem(id:"a",now:PRD.t)
        try w.addBlocker(Blocker(id:"global",name:"node entry"),now:PRD.at(1))
        var n = w.nodes[0]; n.blockerIDs = ["global"]
        try w.updateNode(n,now:PRD.at(1))
        let original = w
        #expect(throws: CoreError.self) { try w.startItem(id:"b",now:PRD.at(2)) }
        #expect(throws: CoreError.self) { try w.completeItem(id:"a",now:PRD.at(2)) }
        #expect(throws: CoreError.self) { try w.recordWork(itemID:"a",start:PRD.at(1),end:PRD.at(2),actualMinutes:1) }
        #expect(throws: CoreError.self) { try w.recordApproximateWork(itemID:"a",occurredOn:PRD.at(2),recordedAt:PRD.at(2),actualMinutes:1) }
        #expect(w == original)
    }

    @Test func wholeNodeBlockerPlanningActionAndTrialReadiness() throws {
        var w = nodeWorkspace(); w.blockers = [Blocker(id:"global",name:"entry",state:.active,expectedResolution:PRD.at(60),triggeredAt:PRD.t)]
        w.nodes[0].blockerIDs = ["global"]
        let p = try PRD.plan(w)
        #expect(p.summary.itemStates.allSatisfy { $0.isBlocked })
        #expect(p.summary.availableActions.isEmpty)
        #expect(p.witness.allocations.allSatisfy { $0.start >= PRD.at(60) })
        #expect(throws: CoreError.self) { try Engine.trial(workspace:w,request:PlanningTrialRequest(itemID:"a",minutes:20),input:PlanningInput(slots:[PRD.slot(0,120)],now:PRD.t)) }
        let cf = try Engine.trial(workspace:w,request:PlanningTrialRequest(itemID:"a",minutes:20,counterfactual:true),input:PlanningInput(slots:[PRD.slot(0,120)],now:PRD.t))
        #expect(cf.conditions.contains { $0.kind == .counterfactualReadiness })
    }

    @Test func waitingTriggerFollowupSharedResolutionAndReopen() throws {
        var w = Workspace(items:[WorkItem(id:"a",name:"a",remainingMinutes:10),WorkItem(id:"b",name:"b",remainingMinutes:10),WorkItem(id:"c",name:"c",remainingMinutes:10)],
            blockers:[Blocker(id:"q",name:"contact",expectedDurationMinutes:60),Blocker(id:"other",name:"contact",resolutionCondition:"stamped quote")],
            dependencies:[Dependency(id:"qa",source:.blocker("q"),targetItemID:"a"),Dependency(id:"qb",source:.blocker("q"),targetItemID:"b"),Dependency(id:"qc",source:.blocker("q"),targetItemID:"c")])
        #expect(w.blockers[0].estimatedResolution == nil)
        #expect(throws: CoreError.self) { try w.startItem(id:"a",now:PRD.t) }
        try w.triggerBlocker(id:"q",now:PRD.at(1440))
        #expect(w.blockers[0].estimatedResolution == PRD.at(1500))
        var q = w.blockers[0]; q.followUpAt = PRD.at(1470)
        try w.updateBlocker(q,now:PRD.at(1441))
        #expect(w.blockers[0].estimatedResolution == PRD.at(1500))
        #expect(!w.sourceSatisfied(.blocker("q")))
        #expect(throws: CoreError.self) { try w.completeItem(id:"a",now:PRD.at(1501)) }
        try w.resolveBlocker(id:"q",now:PRD.at(1502))
        for id in ["a","b","c"] { try w.completeItem(id:id,now:PRD.at(1503)) }
        #expect(w.blockers[1].state == .inactive)
        try w.triggerBlocker(id:"q",now:PRD.at(1504))
        #expect(w.blockers[0].currentRound == 2)
        #expect(w.blockerRounds?.contains { $0.round == 1 && $0.resolvedAt == PRD.at(1502) } == true)
        #expect(w.items.allSatisfy { $0.status == .completed && $0.needsReview })
    }

    @Test func acceptanceFailureSelectedReworkAndLocalStillValidReview() throws {
        var w = nodeWorkspace()
        try w.addItem(WorkItem(id:"down",name:"down",remainingMinutes:10),now:PRD.t)
        try w.addItem(WorkItem(id:"unrelated",name:"unrelated",remainingMinutes:10),now:PRD.t)
        try w.addDependency(Dependency(id:"n-down",source:.node("n"),targetItemID:"down"),now:PRD.t)
        var g = w.acceptances[0]; g.candidateItemIDs = ["a","b"]
        try w.updateAcceptance(g,now:PRD.t)
        try w.recordWork(itemID:"a",start:PRD.t,end:PRD.at(10),actualMinutes:10)
        try w.completeItem(id:"a",now:PRD.at(11)); try w.completeItem(id:"b",now:PRD.at(11))
        try w.accept(id:"g1",now:PRD.at(12)); try w.accept(id:"g2",now:PRD.at(13))
        try w.completeNode(id:"n",now:PRD.at(14))
        try w.completeItem(id:"down",now:PRD.at(15)); try w.startItem(id:"unrelated",now:PRD.at(15))
        let oldSessions = w.workSessions, oldHistory = w.history
        try w.failAcceptance(id:"g1",now:PRD.at(16),reason:"budget")
        #expect(w.items[0].status == .completed && w.items[1].status == .completed)
        #expect(w.acceptances[0].state == .failed && w.acceptances[0].reworkScopeConfirmed == false)
        #expect(try PRD.plan(w).unknowns.contains { $0.objectID == "n" })
        #expect(throws: CoreError.self) { try w.accept(id:"g1",now:PRD.at(17)) }
        let beforeInvalid = w
        #expect(throws: CoreError.self) { try w.confirmAcceptanceRework(id:"g1",itemIDs:["a","missing"],blockerIDs:[],now:PRD.at(17)) }
        #expect(w == beforeInvalid)
        try w.confirmAcceptanceRework(id:"g1",itemIDs:["a"],blockerIDs:[],now:PRD.at(18))
        #expect(w.items[0].status == .pending && w.items[0].remainingMinutes == nil && w.items[0].currentRound == 2)
        #expect(w.items[1].status == .completed && !w.items[1].needsReview)
        #expect(w.items[2].status == .completed && w.items[2].needsReview)
        #expect(w.items[3].status == .inProgress && !w.items[3].needsReview)
        #expect(w.workSessions == oldSessions); #expect(w.history.starts(with:oldHistory))
        #expect(w.acceptanceResults?.contains { $0.acceptanceID == "g1" && $0.state == .accepted } == true)
        try w.reviewItem(id:"down",outcome:.stillValid,now:PRD.at(19))
        #expect(w.sourceSatisfied(.item("down")))
        #expect(!w.sourceSatisfied(.node("n")))
        let reviewed = w
        try w.reworkItem(id:"down",remainingMinutes:5,now:PRD.at(20))
        let beforeWork = w
        #expect(throws: CoreError.self) { try w.startItem(id:"down",now:PRD.at(21)) }
        #expect(throws: CoreError.self) { try w.recordWork(itemID:"down",start:PRD.at(20),end:PRD.at(21),actualMinutes:1) }
        #expect(w == beforeWork)
        #expect(reviewed.reviews?.last?.currentSources?.first?.sourceRound == w.nodes[0].currentRound)
    }

    @Test func inProgressStillValidCannotBypassNewApproximateLaborDependency() throws {
        var w = Workspace(items:[WorkItem(id:"up",name:"up",remainingMinutes:10),WorkItem(id:"down",name:"down",remainingMinutes:20)],dependencies:[Dependency(id:"edge",source:.item("up"),targetItemID:"down")])
        try w.completeItem(id:"up",now:PRD.t); try w.startItem(id:"down",now:PRD.at(1))
        try w.reworkItem(id:"up",remainingMinutes:10,now:PRD.at(2))
        try w.reviewItem(id:"down",outcome:.stillValid,now:PRD.at(3))
        let before = w
        #expect(throws: CoreError.self) { try w.recordApproximateWork(itemID:"down",occurredOn:PRD.at(4),recordedAt:PRD.at(4),actualMinutes:1) }
        #expect(w == before)
    }

    @Test func legacyCompletedInvalidityReviewAndVersionInvalidation() throws {
        var w = Workspace(items:[WorkItem(id:"up",name:"up",remainingMinutes:10),WorkItem(id:"old",name:"old",remainingMinutes:0,status:.completed,completedAt:PRD.t),WorkItem(id:"new",name:"new",remainingMinutes:10)],
            dependencies:[Dependency(id:"u-o",source:.item("up"),targetItemID:"old"),Dependency(id:"o-n",source:.item("old"),targetItemID:"new")])
        try w.validate()
        #expect(!w.sourceSatisfied(.item("old")))
        #expect(try PRD.plan(w).summary.itemStates.first { $0.itemID == "new" }?.isBlocked == true)
        try w.reviewItem(id:"old",outcome:.stillValid,now:PRD.at(1))
        #expect(w.sourceSatisfied(.item("old"))); #expect(!w.sourceSatisfied(.item("up")))
        #expect(try PRD.plan(w).summary.itemStates.first { $0.itemID == "new" }?.isBlocked == false)
        try w.reworkItem(id:"up",remainingMinutes:15,now:PRD.at(2))
        #expect(!w.sourceSatisfied(.item("old")))
        #expect(w.items[1].status == .completed && w.items[1].needsReview)
    }

    @Test func deferCancelArchiveSharedReferenceAndExplicitCurrentChoice() throws {
        var w = Workspace(projects:[PRD.project("a",60),PRD.project("b",60)],items:[WorkItem(id:"shared",name:"shared",projectIDs:["a","b"],remainingMinutes:90),WorkItem(id:"later",name:"later",remainingMinutes:20)])
        let base = try PRD.plan(w,[PRD.slot(0,60)])
        #expect(base.knownDemandMinutes == 110); #expect(base.committedDemandMinutes == 90)
        var a = w.projects[0]; a.status = .deferred
        try w.updateProject(a,now:PRD.t); try w.setProjectArchived(id:"a",archived:true,now:PRD.t)
        #expect(try PRD.plan(w,[PRD.slot(0,60)]).committedDemandMinutes == 90)
        try w.setItemProjectReference(itemID:"shared",projectID:"a",included:false,now:PRD.at(1))
        #expect(w.items[0].projectIDs == ["b"]); #expect(w.items.count == 2)
        #expect(try PRD.plan(w,[PRD.slot(0,60)]).committedDemandMinutes == 90)
        try w.setArchived(.item("shared"),archived:true,now:PRD.at(2))
        #expect(try PRD.plan(w,[PRD.slot(0,60)]).committedDemandMinutes == 90)
        try w.setArchived(.item("shared"),archived:false,now:PRD.at(3))
        try w.setItemDisposition(id:"later",disposition:.deferred,now:PRD.at(4))
        #expect(try !Engine.availableActions(workspace:w,slots:[PRD.slot(0,60)],now:PRD.t).contains { $0.itemID == "later" })
        let itemsBefore = w.items, projectsBefore = w.projects
        try w.chooseNextAction(itemID:"shared",now:PRD.at(5),displayedItemIDs:["shared"],impactWasVerified:false,note:"self choice")
        #expect(w.items == itemsBefore); #expect(w.projects == projectsBefore); #expect(w.workSessions.isEmpty)
        #expect(w.currentNextAction?.impactWasVerified == false)
        try w.chooseNextAction(itemID:nil,now:PRD.at(6))
        #expect(w.choices?.count == 2); #expect(w.currentNextAction?.itemID == nil)
        try w.setItemDisposition(id:"shared",disposition:.cancelled,now:PRD.at(7))
        #expect(w.items[0].status == .pending); #expect(w.items[0].remainingMinutes == 90)
        #expect(!w.sourceSatisfied(.item("shared"))); #expect(!w.items[0].required)
        #expect(w.history.contains { $0.kind == .cancelled })
    }

    @Test func effortOverlapAllocationLocalWindowCorrectionAndVoid() throws {
        var w = Workspace(items:[WorkItem(id:"a",name:"a",remainingMinutes:120),WorkItem(id:"b",name:"b",remainingMinutes:120)])
        try w.recordWork(itemID:"a",start:PRD.t,end:PRD.at(60),actualMinutes:60)
        try w.recordWork(itemID:"b",start:PRD.at(30),end:PRD.at(90),actualMinutes:60)
        let ids = w.workSessions.map(\.id)
        #expect(w.effortSummary().confirmedMinutes == 120)
        #expect(w.effortSummary().unresolvedSessionIDs.count == 2)
        #expect(w.effortSummary(itemIDs:["a"]).unresolvedSessionIDs.count == 1)
        let old = w
        #expect(throws: CoreError.self) { try w.confirmEffortAllocation(sessionIDs:ids,allocatedMinutes:[60,60],now:PRD.at(91)) }
        #expect(w == old)
        try w.confirmEffortAllocation(sessionIDs:ids,allocatedMinutes:[45,45],now:PRD.at(92))
        #expect(w.workSessions.count == 4); #expect(w.effectiveWorkSessions.count == 2)
        #expect(w.effortSummary().confirmedMinutes == 90); #expect(w.effortSummary().unresolvedSessionIDs.isEmpty)
        #expect(w.effortSummary().recordingIsComplete)
        try w.setEffortRecordingComplete(itemID:"a",complete:true,now:PRD.at(93)); try w.setEffortRecordingComplete(itemID:"b",complete:true,now:PRD.at(93))
        #expect(w.effortSummary().recordingIsComplete)
        let effective = w.effectiveWorkSessions[0]
        try w.correctWorkSession(id:effective.id,replacement:nil,now:PRD.at(94))
        #expect(w.effortSummary().confirmedMinutes == 45); #expect(w.workSessions.count == 5)
        var replacement = w.effectiveWorkSessions[0]; replacement.id = "replacement"; replacement.actualMinutes = 30
        try w.correctWorkSession(id:w.effectiveWorkSessions[0].id,replacement:replacement,now:PRD.at(95))
        #expect(w.effortSummary().confirmedMinutes == 30)
        #expect(w.history.contains { $0.kind == .effortCorrected })
        var local = Workspace(items:[WorkItem(id:"a",name:"a",remainingMinutes:120),WorkItem(id:"b",name:"b",remainingMinutes:120),WorkItem(id:"c",name:"c",remainingMinutes:120)],
            workSessions:[WorkSession(id:"s1",itemID:"a",start:PRD.t,end:PRD.at(10),actualMinutes:10),WorkSession(id:"s2",itemID:"b",start:PRD.t,end:PRD.at(10),actualMinutes:10),WorkSession(id:"s3",itemID:"c",start:PRD.at(5),end:PRD.at(100),actualMinutes:10)])
        let before = local
        // Total 30 <= union 100, but 20 cannot fit the forced [0,10) interior window.
        #expect(throws: CoreError.self) { try local.confirmEffortAllocation(sessionIDs:["s1","s2","s3"],allocatedMinutes:[10,10,10],now:PRD.at(101)) }
        #expect(local == before)
        #expect(throws: CoreError.self) { try local.confirmEffortAllocation(sessionIDs:["s1","s2"],allocatedMinutes:[5,5],now:PRD.at(101)) }
    }

    @Test func historicalEstimateAndImmutableBaselineCorrections() throws {
        var w = Workspace.empty
        try w.addItem(WorkItem(id:"a",name:"a",remainingMinutes:60),now:PRD.t)
        let first = try #require(w.estimateRevisions?.first?.id)
        try w.updateRemaining(itemID:"a",minutes:90,now:PRD.at(1))
        try w.startItem(id:"a",now:PRD.at(2))
        try w.correctEstimate(revisionID:first,minutes:50,now:PRD.at(3))
        #expect(w.items[0].remainingMinutes == 90); #expect(w.items[0].initialMinutes == 60); #expect(w.items[0].preStartMinutes == 90)
        #expect(w.effectiveEstimateRevisions.map(\.minutes) == [50,90])
        let latest = try #require(w.effectiveEstimateRevisions.last?.id)
        try w.correctEstimate(revisionID:latest,minutes:80,now:PRD.at(4))
        #expect(w.items[0].remainingMinutes == 80)
        try w.correctEstimateBaseline(itemID:"a",baseline:.initial,minutes:55,now:PRD.at(5),note:"typo")
        try w.correctEstimateBaseline(itemID:"a",baseline:.preStart,minutes:85,now:PRD.at(6),note:"typo")
        #expect(w.items[0].initialMinutes == 60 && w.items[0].preStartMinutes == 90 && w.items[0].remainingMinutes == 80)
        #expect(w.baselineCorrections(itemID:"a").map(\.correctedMinutes) == [55,85])
        try w.addItem(WorkItem(id:"missing",name:"missing"),now:PRD.at(7)); try w.completeItem(id:"missing",now:PRD.at(8))
        let original = w
        #expect(throws: CoreError.self) { try w.correctEstimateBaseline(itemID:"missing",baseline:.preStart,minutes:10,now:PRD.at(9)) }
        #expect(throws: CoreError.self) { try w.correctEstimateBaseline(itemID:"missing",baseline:.initial,minutes:10,now:PRD.at(9)) }
        #expect(w == original)
    }

    @Test func nodeMovePreservesFactsLinksAndAtomicFailure() throws {
        var w = nodeWorkspace()
        try w.addProject(PRD.project("target"),now:PRD.t)
        try w.addItem(WorkItem(id:"shared",name:"shared",projectIDs:["target"],remainingMinutes:10),now:PRD.t)
        try w.addWorkLink(WorkLink(id:"link",source:.item("shared"),projectID:"p",nodeID:"n"),now:PRD.t)
        for id in ["a","b","shared"] { try w.completeItem(id:id,now:PRD.at(1)) }
        try w.accept(id:"g1",now:PRD.at(2)); try w.accept(id:"g2",now:PRD.at(3)); try w.completeNode(id:"n",now:PRD.at(4))
        let old = w
        #expect(throws: CoreError.self) { try w.moveNode(id:"n",projectID:"missing",now:PRD.at(5)) }
        #expect(w == old)
        try w.moveNode(id:"n",projectID:"target",now:PRD.at(6))
        #expect(w.nodes[0].projectID == "target" && w.nodes[0].completedAt == old.nodes[0].completedAt)
        #expect(w.acceptances == old.acceptances); #expect(w.workSessions == old.workSessions)
        #expect(w.items[0].projectIDs == ["target"] && w.items[0].status == .completed && !w.items[0].needsReview)
        #expect(w.workLinks?.first?.projectID == "target"); #expect(w.workLinks?.first?.id == "link")
        #expect(w.projects.map(\.planningCompleteness) == old.projects.map(\.planningCompleteness))
        #expect(w.projects.allSatisfy { w.projectCompletionIssues(id: $0.id).isEmpty })
        #expect(w.history.starts(with:old.history))
    }
}
