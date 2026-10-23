import Foundation
import Testing
@testable import CubicCore

// PRD §20.1: real 240 minute two-day fixture; never the legacy 90 minute demo.
enum PRD {
    static let t = ISO8601DateFormatter().date(from: "2026-10-04T14:00:00+08:00")!
    static func at(_ m: Int) -> Date { t.addingTimeInterval(Double(m) * 60) }
    static func slot(_ start: Int, _ end: Int, _ energy: Energy = .normal) -> CapacitySlot {
        CapacitySlot(start: at(start), end: at(end), energy: energy)
    }
    static func project(_ id: String = "p", _ end: Int = 120) -> Project {
        Project(id: id, name: id, deadline: at(end), planningCompleteness: .complete)
    }
    static var abc: Workspace {
        Workspace(projects: [project("A", 1320), project("B", 120), project("C", 1320)],
                  items: [WorkItem(id: "a", name: "报价表", projectIDs: ["A"], remainingMinutes: 60),
                          WorkItem(id: "b", name: "申请", projectIDs: ["B"], remainingMinutes: 90),
                          WorkItem(id: "c", name: "合同", projectIDs: ["C"], remainingMinutes: 60)],
                  dependencies: [Dependency(id: "a-c", source: .item("a"), targetItemID: "c")])
    }
    static var abcInput: PlanningInput { PlanningInput(slots: [slot(0,120),slot(1200,1320)], now: t) }
    static func plan(_ w: Workspace, _ slots: [CapacitySlot] = [slot(0,120)], options: PlanningOptions = PlanningOptions()) throws -> PlanningSnapshot {
        try Engine.plan(workspace: w, input: PlanningInput(slots: slots, now: t, options: options))
    }
    static func minutes(_ allocations: [TrialAllocation]) -> Int {
        Int(allocations.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } / 60)
    }
    // Independent resource oracle: no overlapping labor, correct amounts, and all used
    // instants inside a compatible source slot and outside every supplied busy interval.
    static func verify(_ witness: PlanningWitness, workspace: Workspace, input: PlanningInput) {
        let a = witness.allocations.sorted { $0.start < $1.start }
        for i in a.indices {
            #expect(a[i].end > a[i].start)
            #expect(a[i].start >= input.now)
            if i > 0 { #expect(a[i-1].end <= a[i].start) }
            let item = workspace.items.first { $0.id == a[i].itemID }!
            #expect(input.slots.contains { $0.start <= a[i].start && $0.end >= a[i].end && $0.energy.rank >= item.energy.rank })
            #expect(!input.busy.contains { $0.start < a[i].end && a[i].start < $0.end })
            if let d = item.deadline { #expect(a[i].end <= d) }
            for p in workspace.projects where item.projectIDs.contains(p.id) {
                if let d = p.deadline { #expect(a[i].end <= d) }
            }
        }
        if witness.isComplete {
            for item in workspace.items where item.status != .completed && item.required && !a.filter({$0.itemID == item.id}).isEmpty {
                #expect(minutes(a.filter { $0.itemID == item.id }) == item.remainingMinutes)
            }
        }
    }
}

@Suite(.serialized) struct PlanningTests {
    @Test func abc240GoldenBaselineTrialActual() throws {
        var w = PRD.abc
        let original = w, input = PRD.abcInput
        let baseline = try Engine.plan(workspace: w, input: input)
        #expect(baseline.knownDemandMinutes == 210)
        #expect(baseline.summary.capacityMinutes == 240)
        #expect(baseline.feasibility == .feasible)
        #expect(baseline.witness.isComplete)
        #expect(baseline.certificates.isEmpty)
        #expect(baseline.summary.itemStates.first { $0.itemID == "c" }?.isBlocked == true)
        PRD.verify(baseline.witness, workspace: w, input: input)
        let expected = [("b",0,90),("a",90,120),("a",1200,1230),("c",1230,1290)]
        #expect(baseline.witness.allocations.count == expected.count)
        for (allocation,e) in zip(baseline.witness.allocations,expected) {
            #expect(allocation.itemID == e.0); #expect(allocation.start == PRD.at(e.1)); #expect(allocation.end == PRD.at(e.2))
        }
        let trial = try Engine.trial(workspace: w, request: PlanningTrialRequest(itemID: "a", minutes: 60), input: input)
        #expect(w == original)
        #expect(trial.estimatedCompletion == PRD.at(60))
        #expect(trial.assumedRemainingMinutes == 0)
        #expect(trial.allocations.count == 1)
        #expect(trial.allocations.first?.start == PRD.t)
        #expect(trial.allocations.first?.end == PRD.at(60))
        let scenario = try #require(trial.scenario)
        #expect(scenario.summary.capacityMinutes == 180)
        #expect(scenario.certificates.contains { $0.projectIDs == ["B"] && $0.shortageMinutes == 30 && $0.windowEnd == PRD.at(120) })
        #expect(trial.impacts.contains { $0.kind == .dependencyRelease && $0.itemIDs.contains("c") && $0.afterDate == PRD.at(60) && !$0.conditionIDs.isEmpty && $0.chain.contains("dependency:a-c") })
        #expect(trial.impacts.contains { $0.kind == .shortageIncrease && $0.projectIDs == ["B"] && $0.beforeMinutes == 0 && $0.afterMinutes == 30 })
        let legacy = TrialResult(selections: [TrialSelection(itemID: "a", minutes: 60)], allocations: trial.allocations,
                                 unallocatedMinutes: 0, snapshot: scenario.summary, planning: trial)
        try w.chooseNextAction(itemID: "a", now: PRD.t, trial: legacy, displayedItemIDs: ["a","b"], dataVersion: "golden-v1", impactWasVerified: true)
        #expect(w.items == original.items); #expect(w.workSessions.isEmpty)
        #expect(try Engine.plan(workspace: w, input: input).summary.capacityMinutes == 240)
        try w.startItem(id: "a", now: PRD.t)
        var laterInput = input; laterInput.now = PRD.at(40)
        let elapsedOnly = try Engine.plan(workspace: w, input: laterInput)
        #expect(elapsedOnly.summary.capacityMinutes == 200)
        try w.recordWork(itemID: "a", start: PRD.t, end: PRD.at(40), actualMinutes: 40, remaining: .minutes(40))
        let actual = try Engine.plan(workspace: w, input: laterInput)
        #expect(actual.knownDemandMinutes == 190)
        #expect(actual.summary.capacityMinutes == 200)
        #expect(actual.certificates.contains { $0.projectIDs == ["B"] && $0.shortageMinutes == 10 })
        #expect(actual.summary.itemStates.first { $0.itemID == "c" }?.isBlocked == true)
        #expect(w.items[0].preStartMinutes == 60)
        #expect(w.items[0].status == .inProgress)
        #expect(w.effortSummary().confirmedMinutes == 40)
        #expect(w.currentNextAction?.trial?.planning == trial)
        print("PRD ABC baseline=210/240 feasible trial_B_shortage=30 actual=190/200 B_shortage=10 C_real_blocked=true")
    }

    @Test func trialExcessNilBusyCounterfactualAndStaleness() throws {
        let w = PRD.abc, input = PRD.abcInput
        let excess = try Engine.trial(workspace: w, request: PlanningTrialRequest(itemID: "a", minutes: 90), input: input)
        #expect(PRD.minutes(excess.allocations) == 60); #expect(excess.excessMinutes == 30); #expect(excess.unallocatedMinutes == 30)
        #expect(excess.scenario?.summary.capacityMinutes == 180)
        let direction = try Engine.trial(workspace: w, request: PlanningTrialRequest(itemID: "a"), input: input)
        #expect(direction.scenario == nil); #expect(direction.assumedRemainingMinutes == nil); #expect(direction.unallocatedMinutes == nil)
        #expect(direction.impacts.allSatisfy { $0.beforeMinutes == nil && $0.afterMinutes == nil && $0.beforeDate == nil && $0.afterDate == nil })
        #expect(throws: CoreError.self) { try Engine.trial(workspace: w, request: PlanningTrialRequest(itemID: "c", minutes: 30), input: input) }
        let cf = try Engine.trial(workspace: w, request: PlanningTrialRequest(itemID: "c", minutes: 30, counterfactual: true), input: input)
        #expect(cf.conditions.contains { $0.kind == .counterfactualReadiness && $0.dependencyIDs.contains("a-c") })
        #expect(cf.source.items == w.items)
        var busyInput = input; busyInput.busy = [BusyInterval(start: PRD.t,end: PRD.at(30))]
        let next = try Engine.trial(workspace: w, request: PlanningTrialRequest(itemID: "a", minutes: 30), input: busyInput)
        #expect(next.startPosition == PRD.at(30))
        #expect(!excess.isStale(workspace: w,input: input))
        #expect(excess.isStale(comparedTo: busyInput))
        for dimension in 0..<4 {
            var changed = input
            switch dimension { case 0: changed.revision.workspace = "new"; case 1: changed.revision.capacity = "new"; case 2: changed.revision.calendar = "new"; default: changed.revision.time = "new" }
            #expect(excess.isStale(comparedTo: changed))
        }
        var changed = w; changed.items[0].remainingMinutes = 70
        #expect(excess.isStale(workspace: changed,input: input))
        #expect(w == PRD.abc)
    }

    @Test func energyShortfallAndNoAutomaticFatigue() throws {
        let w = Workspace(projects: [PRD.project("a",180), PRD.project("b",180)],
            items: [WorkItem(id: "a",name:"a",projectIDs:["a"],remainingMinutes:60,energy:.high), WorkItem(id:"b",name:"b",projectIDs:["b"],remainingMinutes:60,energy:.high)])
        let input = PlanningInput(slots:[PRD.slot(0,60,.high),PRD.slot(60,180)],now:PRD.t)
        let p = try Engine.plan(workspace:w,input:input)
        #expect(p.summary.capacityMinutes == 180)
        #expect(p.certificates.contains { $0.energy == .high && $0.shortageMinutes == 60 && Set($0.projectIDs) == Set(["a","b"]) })
        #expect(p.projects.allSatisfy { $0.feasibility == .feasible })
        #expect(p.feasibility == .infeasible)
        var done = w; try done.completeItem(id:"a",now:PRD.t)
        let after = try Engine.plan(workspace:done,input:input)
        #expect(after.feasibility == .feasible)
        #expect(after.summary.availableActions.first { $0.itemID == "b" }?.compatibleMinutes == 60)
        #expect(input.slots[0].energy == .high)
    }

    @Test func fragmentedContinuousAndBusyUnion() throws {
        var w = Workspace(projects:[PRD.project("p",90)],items:[WorkItem(id:"x",name:"x",projectIDs:["p"],remainingMinutes:60)])
        let slots = [PRD.slot(0,30),PRD.slot(60,90)]
        #expect(try PRD.plan(w,slots).feasibility == .feasible)
        w.items[0].requiresContinuous = true; w.items[0].continuousMinutes = 60
        let continuous = try PRD.plan(w,slots)
        #expect(continuous.feasibility == .infeasible)
        #expect(continuous.certificates.contains { $0.kind == .continuousShortfall })
        let tr = try Engine.trial(workspace:w,request:PlanningTrialRequest(itemID:"x",minutes:60),input:PlanningInput(slots:slots,now:PRD.t))
        #expect(tr.allocations.isEmpty); #expect(tr.unallocatedMinutes == 60)
        let busy = [BusyInterval(start:PRD.at(30),end:PRD.at(50)),BusyInterval(start:PRD.at(40),end:PRD.at(60))]
        let union = try Engine.plan(workspace:.empty,input:PlanningInput(slots:[PRD.slot(0,90),PRD.slot(20,70,.high)],busy:busy,now:PRD.at(10)))
        #expect(union.summary.capacityMinutes == 50)
        #expect(WorkItem(name:"default").energy == .normal); #expect(PRD.slot(0,10).energy == .normal)
    }

    @Test func interiorReleaseWindowAndSymmetricGlobalCapacity() throws {
        let w = Workspace(projects:[PRD.project("a",100),PRD.project("b",100)],
            items:[WorkItem(id:"a",name:"a",projectIDs:["a"],remainingMinutes:30),WorkItem(id:"b",name:"b",projectIDs:["b"],remainingMinutes:30)],
            blockers:[Blocker(id:"wait",name:"wait",state:.active,expectedResolution:PRD.at(60),triggeredAt:PRD.t)],
            dependencies:[Dependency(id:"wa",source:.blocker("wait"),targetItemID:"a"),Dependency(id:"wb",source:.blocker("wait"),targetItemID:"b")])
        let p = try PRD.plan(w,[PRD.slot(0,100)])
        #expect(p.knownDemandMinutes == 60); #expect(p.summary.capacityMinutes == 100)
        #expect(p.projects.allSatisfy { $0.feasibility == .feasible })
        #expect(p.certificates.contains { $0.windowStart == PRD.at(60) && $0.windowEnd == PRD.at(100) && $0.shortageMinutes == 20 && Set($0.itemIDs) == Set(["a","b"]) })
        #expect(p.feasibility == .infeasible)
        #expect(w.projects.allSatisfy { $0.deadline == PRD.at(100) })
        let reverseOrder = Workspace(projects:w.projects.reversed(),items:w.items.reversed(),blockers:w.blockers,dependencies:w.dependencies)
        let q = try PRD.plan(reverseOrder,[PRD.slot(0,100)])
        #expect(q.certificates.map(\.shortageMinutes).max() == p.certificates.map(\.shortageMinutes).max())
    }

    @Test func waitThreeNaturalDaysReverseAndManualGate() throws {
        let w = Workspace(projects:[PRD.project("p",4440)],
            items:[WorkItem(id:"draft",name:"draft",projectIDs:["p"],remainingMinutes:60),WorkItem(id:"publish",name:"publish",projectIDs:["p"],remainingMinutes:60)],
            blockers:[Blocker(id:"review",name:"review",expectedDurationMinutes:4320)],
            dependencies:[Dependency(id:"review-publish",source:.blocker("review"),targetItemID:"publish")])
        let slots = [PRD.slot(0,120),PRD.slot(1440,1560),PRD.slot(2880,3000),PRD.slot(4320,4440)]
        let options = PlanningOptions(waits:[PlanningWait(blockerID:"review",startAfterItemIDs:["draft"],elapsedMinutes:4320)])
        let p = try PRD.plan(w,slots,options:options)
        #expect(p.feasibility == .feasible)
        #expect(p.knownDemandMinutes == 120); #expect(p.summary.capacityMinutes == 480)
        #expect(p.witness.eventTimes["blocker:review"] == PRD.at(4380))
        let bound = try #require(p.boundaries.first { $0.subject == .item("draft") && $0.layer == .dependency })
        #expect(bound.latestFinish == PRD.at(60)); #expect(bound.latestStart == PRD.t)
        #expect(bound.chain.contains("blocker:review"))
        #expect(!w.sourceSatisfied(.blocker("review")))
        #expect(p.conditions.contains { $0.kind == .assumedWaitStart })
        var gated = Workspace(projects:[PRD.project("p",120)],nodes:[Node(id:"n",projectID:"p",name:"n",planningCompleteness:.complete)],
            items:[WorkItem(id:"source",name:"source",nodeID:"n",projectIDs:["p"],remainingMinutes:30),WorkItem(id:"down",name:"down",projectIDs:["p"],remainingMinutes:30)],
            dependencies:[Dependency(id:"n-down",source:.node("n"),targetItemID:"down")],acceptances:[Acceptance(id:"g",subject:.node("n"),name:"g")])
        let g = try PRD.plan(gated,options:PlanningOptions(manualGateDates:["g":PRD.at(90)]))
        #expect(g.feasibility == .feasible)
        #expect(g.witness.allocations.first { $0.itemID == "down" }?.start == PRD.at(90))
        #expect(g.conditions.contains { $0.objectID == "g" && $0.kind == .manualAcceptance })
        #expect(gated.acceptances[0].state == .pending)
        let impossible = try PRD.plan(gated,options:PlanningOptions(manualGateDates:["g":PRD.at(150)]))
        #expect(impossible.feasibility == .infeasible)
        #expect(impossible.certificates.contains { $0.elapsedDelaySeconds == 1800 && $0.shortageMinutes == 0 })
        try gated.completeItem(id:"source",now:PRD.at(30))
        #expect(throws: CoreError.self) { try gated.startItem(id:"down",now:PRD.at(31)) }
    }

    @Test func unknownScopeWarningUnsetThresholdAndHorizon() throws {
        var w = Workspace(projects:[Project(id:"p",name:"partial",deadline:PRD.at(120))],
            items:[WorkItem(id:"x",name:"known",projectIDs:["p"],remainingMinutes:30),WorkItem(id:"u",name:"unknown",projectIDs:["p"])])
        let p = try PRD.plan(w)
        #expect(p.knownDemandMinutes == 30); #expect(p.projects[0].totalDemandMinutes == nil)
        #expect(p.feasibility == .undetermined); #expect(p.projects[0].warningState == .notConfigured)
        #expect(!p.unknowns.isEmpty); #expect(p.summary.availableActions.contains { $0.itemID == "x" })
        w.items[0].remainingMinutes = 150
        let bad = try PRD.plan(w)
        #expect(bad.feasibility == .infeasible); #expect(!bad.unknowns.isEmpty)
        #expect(bad.certificates.contains { $0.shortageMinutes == 30 })
        let complete = Workspace(projects:[PRD.project()],items:[WorkItem(id:"x",name:"x",projectIDs:["p"],remainingMinutes:30)])
        let noMargin = try PRD.plan(complete)
        let margin = try PRD.plan(complete,options:PlanningOptions(warningMargins:["p":100]))
        #expect(noMargin.projects[0].warningState == .notConfigured)
        #expect(margin.projects[0].warningState == .insufficient)
        #expect(noMargin.knownDemandMinutes == margin.knownDemandMinutes)
        #expect(noMargin.witness.allocations == margin.witness.allocations)
        let unverified = try PRD.plan(complete,options:PlanningOptions(capacityVerified:false,capacityNote:"permission denied"))
        #expect(unverified.feasibility == .undetermined)
        #expect(unverified.conditions.contains { $0.kind == .capacityUnverified })
        var outside = complete; outside.projects[0].deadline = PRD.at(500)
        let finite = try PRD.plan(outside,[])
        #expect(finite.feasibility == .undetermined); #expect(finite.certificates.isEmpty)
    }

    @Test func independentUndatedTodoAndDateOnlyDST() throws {
        let w = Workspace(items:[WorkItem(id:"dated",name:"dated",remainingMinutes:30,deadline:PRD.at(30)),WorkItem(id:"free",name:"free",remainingMinutes:200)])
        let p = try PRD.plan(w,[PRD.slot(0,30)])
        #expect(p.knownDemandMinutes == 230); #expect(p.committedDemandMinutes == 30)
        #expect(p.feasibility == .feasible); #expect(p.summary.availableActions.count == 2)
        #expect(!p.boundaries.contains { $0.subject == .item("free") && $0.latestFinish != nil })
        let d = ISO8601DateFormatter().date(from:"2026-03-08T12:00:00-04:00")!
        let end = try Workspace.dateOnlyDeadline(on:d,timeZoneID:"America/New_York")
        let expected = ISO8601DateFormatter().date(from:"2026-03-09T00:00:00-04:00")!.addingTimeInterval(-0.001)
        #expect(abs(end.timeIntervalSince(expected)) < 0.00001)
        var edited = w
        try edited.setItemDeadline(id:"free",deadline:d,timeZoneID:"America/New_York",dateOnly:true,now:PRD.t)
        #expect(edited.items[1].deadline == end); #expect(edited.items[1].deadlineTimeZoneID == "America/New_York")
        #expect(edited.history.last?.kind == .deadlineChanged)
    }
}
