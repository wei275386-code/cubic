import Foundation
import Testing
@testable import CubicCore

@Suite(.serialized) struct PRDStoragePerformanceTests {
    private let legacy = """
    {"schemaVersion":1,"projects":[{"id":"p","name":"legacy","importance":3}],"nodes":[{"id":"n","projectID":"p","name":"legacy node"}],"items":[{"id":"old","name":"old","nodeID":"n","projectIDs":["p"],"remainingMinutes":0,"initialMinutes":60,"energy":"normal","requiresContinuous":false,"status":"completed","started":1799996400000,"completedAt":1800000000000,"needsReview":false},{"id":"waiting","name":"waiting","projectIDs":["p"],"remainingMinutes":0,"energy":"normal","requiresContinuous":false,"status":"completed","completedAt":1800000000000,"needsReview":false}],"blockers":[{"id":"b","name":"inactive","state":"inactive"}],"dependencies":[{"id":"b-w","source":{"blocker":{"_0":"b"}},"targetItemID":"waiting"}],"acceptances":[{"id":"g","subject":{"node":{"_0":"n"}},"name":"old gate","state":"accepted","acceptedAt":1800000000000}],"history":[],"decisions":[],"workSessions":[]}
    """
    @Test func schema1WorkspaceNoFabricatedBaselineOrGate() throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let bare = Data(legacy.utf8)
        let old = try decoder.decode(Workspace.self,from:bare)
        try old.validate()
        #expect(old.items[0].preStartMinutes == nil && old.items[0].preStartCapturedAt == nil)
        #expect(old.items[0].initialMinutes == 60 && old.items[0].started != nil)
        #expect(old.nodes[0].planningCompleteness == nil)
        #expect(old.acceptances[0].state == .accepted)
        // Legacy missing completeness flags do not invalidate completed work and a real accepted gate.
        #expect(old.sourceSatisfied(.node("n")))
        #expect(old.items[1].status == .completed && !old.sourceSatisfied(.item("waiting")))
        #expect(try persistedCopy(old) == old)
    }

    @Test func newFactsCorrectionsChoiceRoundTrip() throws {
        var w = PRD.abc
        try w.startItem(id:"a",now:PRD.t)
        try w.recordApproximateWork(itemID:"a",occurredOn:PRD.t,recordedAt:PRD.at(30),actualMinutes:30,remaining:.minutes(50))
        let session = try #require(w.workSessions.first)
        var corrected = session; corrected.id = "corrected"; corrected.actualMinutes = 20
        try w.correctWorkSession(id:session.id,replacement:corrected,now:PRD.at(31))
        try w.correctEstimateBaseline(itemID:"a",baseline:.preStart,minutes:55,now:PRD.at(32),note:"typo")
        let trial = try Engine.trial(workspace:w,request:PlanningTrialRequest(itemID:"b",minutes:30),input:PRD.abcInput)
        let stored = TrialResult(selections:[TrialSelection(itemID:"b",minutes:30)],allocations:trial.allocations,unallocatedMinutes:0,snapshot:try #require(trial.scenario).summary,planning:trial)
        try w.chooseNextAction(itemID:"b",now:PRD.at(33),trial:stored,displayedItemIDs:["a","b"],dataVersion:"v2",impactWasVerified:true)
        let loaded = try persistedCopy(w)
        #expect(loaded == w); #expect(loaded.effortSummary().confirmedMinutes == 20)
        #expect(loaded.baselineCorrections(itemID:"a").first?.correctedMinutes == 55)
        #expect(loaded.currentNextAction?.trial?.planning == trial)
    }

    @Test func scale1000BranchSharedHistoryAndPersistence() throws {
        let projects = (0..<10).map { PRD.project("p\($0)",2000) }
        let items = (0..<1000).map { i in
            WorkItem(id:String(format:"i%04d",i),name:"Task \(i)",projectIDs:i % 50 == 0 ? ["p\(i % 10)","p\((i+1) % 10)"] : ["p\(i % 10)"],remainingMinutes:1)
        }
        // 200 five-task forks: two sources -> join -> two independent consumers.
        var edges:[Dependency] = []
        for start in stride(from:0,to:1000,by:5) {
            for (a,b) in [(start,start+2),(start+1,start+2),(start+2,start+3),(start+2,start+4)] {
                edges.append(Dependency(id:"e\(a)-\(b)",source:.item(String(format:"i%04d",a)),targetItemID:String(format:"i%04d",b)))
            }
        }
        let history = (0..<10000).map { HistoryEvent(id:"h\($0)",date:PRD.at(-10000+$0),kind:.remainingUpdated,objectID:items[$0 % 1000].id,minutes:1) }
        let w = Workspace(projects:projects,items:items,dependencies:edges,history:history)
        let input = PlanningInput(slots:stride(from:0,to:2000,by:100).map { PRD.slot($0,$0+100) },now:PRD.t)
        let start = Date(); let p = try Engine.plan(workspace:w,input:input); let planSeconds = Date().timeIntervalSince(start)
        #expect(p.feasibility == .feasible && p.witness.isComplete)
        #expect(p.knownDemandMinutes == 1000 && p.committedDemandMinutes == 1000)
        #expect(PRD.minutes(p.witness.allocations) == 1000)
        PRD.verify(p.witness,workspace:w,input:input)
        let times = p.witness.eventTimes
        for edge in edges {
            let firstStart = try #require(p.witness.allocations.first { $0.itemID == edge.targetItemID }?.start)
            #expect(try #require(times["item:\(edge.source.id)"]) <= firstStart)
        }
        let trialStart = Date()
        let trial = try Engine.trial(workspace:w,request:PlanningTrialRequest(itemID:"i0000",minutes:1),input:input)
        let trialSeconds = Date().timeIntervalSince(trialStart)
        #expect(trial.assumedRemainingMinutes == 0)
        let persistenceStart = Date(); let loaded = try persistedCopy(w)
        let persistenceSeconds = Date().timeIntervalSince(persistenceStart)
        #expect(loaded == w)
        print("PRD PERF mode=debug/macOS items=1000 projects=10 dependencies=800 shared=20 history=10000 slots=20 plan_seconds=\(planSeconds) trial_seconds=\(trialSeconds) save_load_seconds=\(persistenceSeconds) allocations=\(p.witness.allocations.count)")
    }

    /// “修改详情”层级投影的规模基准：一次线性扫描，不按节点重复扫描全部工作。
    @Test func structureProjectionScales() {
        let nodeCount = 300, itemCount = 3000
        var nodes: [Node] = [], items: [WorkItem] = []
        for index in 0..<nodeCount { nodes.append(Node(id: "n\(index)", projectID: "p", name: "N\(index)")) }
        for index in 0..<itemCount { items.append(WorkItem(id: "i\(index)", name: "I\(index)", nodeID: "n\(index % nodeCount)", projectIDs: ["p"], remainingMinutes: 30)) }
        let workspace = Workspace(projects: [Project(id: "p", name: "P")], nodes: nodes, items: items)
        let start = Date(); var total = 0
        for _ in 0..<50 {
            let structure = workspace.projectStructure(projectID: "p")
            total += structure.nodes.count + structure.membersByNode.count + structure.directItems.count
        }
        let seconds = Date().timeIntervalSince(start)
        #expect(total > 0)
        #expect(seconds < 1.0)
        print("STRUCTURE PERF nodes=\(nodeCount) items=\(itemCount) runs=50 seconds=\(seconds)")
    }
}
