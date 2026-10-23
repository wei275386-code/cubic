import Foundation
import Testing
@testable import CubicCore

@Suite(.serialized) struct PlanningDisplayTests {
    private let t = Date(timeIntervalSince1970: 1_800_000_000)
    private func proof() -> PlanningCertificate {
        PlanningCertificate(kind: .capacityShortfall, projectIDs: ["p"], itemIDs: ["a", "b"],
            windowStart: t, windowEnd: t.addingTimeInterval(3600), energy: .normal,
            demandMinutes: 120, capacityMinutes: 60, shortageMinutes: 60,
            demandSeconds: 7200, capacitySeconds: 3600, shortageSeconds: 3600,
            requiredReadyAt: nil, latestAllowedAt: nil, elapsedDelaySeconds: nil,
            conditionIDs: ["c"], message: "capacity cause")
    }
    @Test func equivalentEvidencePreservesEveryConstraintAndScope() {
        let a = proof()
        var b = a; b.kind = .energyShortfall; b.energy = .high; b.projectIDs = ["q"]
        var c = a; c.kind = .dependencyWindow; c.projectIDs = ["p", "q"]; c.itemIDs = ["b", "a", "a"]
        var d = a; d.kind = .continuousShortfall; d.conditionIDs = ["c", "c"]
        let groups = PlanningDisplay.certificates([a,b,c,d])
        #expect(groups.count == 1)
        #expect(groups[0].proofs == [a,b,c,d])
        #expect(groups[0].summary.projectIDs == ["p", "q"])
        #expect(groups[0].proofs[1].energy == .high)
        #expect(groups[0].proofs[3].kind == .continuousShortfall)
    }
    @Test func distinctPremisesSecondsWindowsAndDateContradictionsStaySeparate() {
        let a = proof()
        var variants = [a]
        func add(_ change: (inout PlanningCertificate) -> Void) { var p = a; change(&p); variants.append(p) }
        add { $0.itemIDs = ["a"] }; add { $0.conditionIDs = ["d"] }
        add { $0.demandSeconds += 0.25 }; add { $0.capacitySeconds += 0.25 }
        add { $0.shortageSeconds += 0.25 }; add { $0.windowStart = t.addingTimeInterval(1) }
        add { $0.windowEnd = t.addingTimeInterval(3601) }
        add { $0.requiredReadyAt = t }; add { $0.latestAllowedAt = t }
        add { $0.elapsedDelaySeconds = 0 }; add { $0.elapsedDelaySeconds = 1 }
        add { $0.demandMinutes += 1 }; add { $0.capacityMinutes += 1 }; add { $0.shortageMinutes += 1 }
        let groups = PlanningDisplay.certificates(variants)
        #expect(groups.count == variants.count)
        #expect(groups.allSatisfy { $0.proofs.count == 1 })
    }
    @Test func riskAggregationIsCauseSpecificMaximumLowerBound() {
        let a = Risk(kind: .provenCapacityShortfall, projectID: "p", itemIDs: ["b", "a", "a"], shortageMinutes: 30, message: "cause")
        var b = a; b.itemIDs = ["c"]; b.shortageMinutes = 60
        var c = a; c.shortageMinutes = nil
        var d = a; d.kind = .energyConstraint
        var e = a; e.projectID = "q"
        var f = a; f.message = "other cause"
        let rows = PlanningDisplay.risks([a,b,c,d,e,f])
        #expect(rows.count == 4)
        #expect(rows[0].shortageMinutes == 60)
        #expect(rows[0].itemIDs == ["a", "b", "c"])
        #expect(rows.dropFirst().map(PlanningDisplay.riskKey) == [d,e,f].map(PlanningDisplay.riskKey))
        #expect(rows.dropFirst().allSatisfy { $0.itemIDs == ["a", "b"] && $0.shortageMinutes == 30 })
    }
    @Test func riskIndexDoesNotLeakAcrossReasonProjectOrType() {
        let a = proof()
        var b = a; b.message = "other cause"
        var c = a; c.projectIDs = ["q"]
        var d = a; d.kind = .energyShortfall
        var e = a; e.kind = .continuousShortfall
        var f = a; f.projectIDs = ["p", "q"]
        var g = a; g.kind = .dependencyWindow
        let index = PlanningDisplay.certificatesByRisk([a,b,c,d,e,f,g])
        let risk = Risk(kind: .provenCapacityShortfall, projectID: "p", itemIDs: ["a", "b"], message: a.message)
        #expect(index[PlanningDisplay.riskKey(risk)]?.flatMap(\.proofs) == [a,g])
        #expect(index.count == 6)
        #expect(index[PlanningDisplay.riskKey(Risk(kind: .conditionalUnlock, projectID: "p", message: a.message))] == nil)
        for groups in index.values { #expect(groups.flatMap(\.proofs).allSatisfy { $0.message == groups[0].proofs[0].message }) }
    }
    @Test func boundaryGroupingPreservesLayerScopeAndSubjectType() {
        let a = PlanningBoundary(subject: .item("same"), layer: .dependency, projectIDs: ["p"], latestStart: t, latestFinish: t.addingTimeInterval(60), precision: .necessaryUpperBound, conditionIDs: ["c"], chain: ["a", "b"])
        var b = a; b.layer = .singleProject; b.projectIDs = ["q"]
        var c = a; c.layer = .global; c.projectIDs = ["p", "q"]
        var d = a; d.subject = .node("same")
        var e = a; e.chain = ["b", "a"]
        var f = a; f.conditionIDs = ["different"]
        var g = a; g.precision = .feasibleCandidate
        let groups = PlanningDisplay.boundaries([a,b,c,d,e,f,g])
        #expect(groups.count == 5)
        #expect(groups[0].boundaries == [a,b,c])
        #expect(groups[0].summary.projectIDs == ["p", "q"])
        #expect(groups[1].boundaries[0].subject == .node("same"))
    }
    @Test func realEngineExpiredExampleRetainsZeroWindowsAndRawEvidence() throws {
        let deadline = t.addingTimeInterval(-3600)
        let w = Workspace(projects: [Project(id: "p", name: "Expired", deadline: deadline, planningCompleteness: .complete)],
            items: [WorkItem(id: "a", name: "A", projectIDs: ["p"], remainingMinutes: 60, energy: .high, requiresContinuous: true)])
        let plan = try Engine.plan(workspace: w, input: PlanningInput(slots: [CapacitySlot(start: t, end: t.addingTimeInterval(7200))], now: t))
        let original = plan.certificates
        let groups = PlanningDisplay.certificates(original)
        #expect(!original.isEmpty)
        #expect(original.contains { $0.windowStart == deadline && $0.windowEnd == deadline && $0.capacitySeconds == 0 })
        #expect(groups.count < original.count)
        #expect(groups.flatMap(\.proofs).count == original.count)
        #expect(plan.certificates == original)
        let index = PlanningDisplay.certificatesByRisk(original)
        for risk in PlanningDisplay.risks(plan.summary.risks) where risk.shortageMinutes != nil {
            let linked = try #require(index[PlanningDisplay.riskKey(risk)])
            #expect(linked.flatMap(\.proofs).allSatisfy { $0.message == risk.message })
        }
        print("DISPLAY_EXPIRED raw=\(original.count) grouped=\(groups.count) risks=\(plan.summary.risks.count)/\(PlanningDisplay.risks(plan.summary.risks).count)")
    }
    @Test func realFutureTrialKeepsItsOwnPremisesAndDoesNotMutateWorkspace() throws {
        let w = Workspace(projects: [Project(id: "p", name: "Future", deadline: t.addingTimeInterval(3600), planningCompleteness: .complete),
            Project(id: "q", name: "Shared Future", deadline: t.addingTimeInterval(3600), planningCompleteness: .complete)],
            items: [WorkItem(id: "a", name: "A", projectIDs: ["p", "q"], remainingMinutes: 120)])
        let trial = try Engine.trial(workspace: w, request: PlanningTrialRequest(itemID: "a", minutes: 30), input: PlanningInput(slots: [CapacitySlot(start: t, end: t.addingTimeInterval(3600))], now: t))
        #expect(trial.source.items == w.items)
        #expect(trial.request.minutes == 30)
        #expect(!trial.conditions.isEmpty)
        #expect(w.items[0].remainingMinutes == 120)
        let groups = PlanningDisplay.certificates(trial.unresolvedConflicts)
        #expect(groups.flatMap(\.proofs).count == trial.unresolvedConflicts.count)
        #expect(!groups.isEmpty)
        #expect(groups.flatMap(\.proofs).allSatisfy { $0.conditionIDs.contains("trial-resource:a") })
        #expect(!trial.baseline.conditions.contains { $0.id == "trial-resource:a" })
        let requiredPremises = Set(trial.unresolvedConflicts.flatMap(\.conditionIDs))
        let scenarioPremises = Set(trial.scenario?.conditions.map(\.id) ?? [])
        #expect(requiredPremises.isSubset(of: scenarioPremises))
        let omittedByDeltaOnly = requiredPremises.subtracting(trial.conditions.map(\.id)).sorted()
        print("DISPLAY_TRIAL_CONTEXT required=\(requiredPremises.sorted()) trial_delta=\(trial.conditions.map(\.id).sorted()) missing_if_delta_only=\(omittedByDeltaOnly)")
        print("DISPLAY_TRIAL conditions=\(trial.conditions.count) unresolved=\(trial.unresolvedConflicts.count) grouped=\(groups.count)")
    }
    @Test func groupingAndRiskIndexPerformanceAt1200Through4800Records() {
        for n in [1200, 2400, 4800] {
            let records = (0..<n).map { i in
                var p = proof(); p.itemIDs = ["item-\(i / 4)"]; p.message = "cause-\(i / 4)"
                p.kind = [.capacityShortfall, .energyShortfall, .continuousShortfall, .dependencyWindow][i % 4]
                return p
            }
            var grouping: [Double] = [], indexing: [Double] = []
            for _ in 0..<10 {
                var start = Date(); let groups = PlanningDisplay.certificates(records); grouping.append(Date().timeIntervalSince(start))
                #expect(groups.count == n / 4); #expect(groups.flatMap(\.proofs).count == n)
                start = Date(); let index = PlanningDisplay.certificatesByRisk(records); indexing.append(Date().timeIntervalSince(start))
                #expect(index.count == 3 * n / 4)
                #expect(index.values.flatMap { $0 }.flatMap(\.proofs).count == n)
            }
            print("DISPLAY_PERF records=\(n) runs=10 grouping_mean_ms=\(grouping.reduce(0,+)/10*1000) grouping_max_ms=\(grouping.max()!*1000) index_mean_ms=\(indexing.reduce(0,+)/10*1000) index_max_ms=\(indexing.max()!*1000)")
        }
    }
    @Test func riskMergePerformanceWithDistinctItemsUnderOneCause() {
        for n in [1200, 2400, 4800] {
            let records = (0..<n).map { Risk(kind: .provenCapacityShortfall, projectID: "p", itemIDs: ["item-\($0)"], shortageMinutes: $0 + 1, message: "one cause") }
            let start = Date()
            let rows = PlanningDisplay.risks(records)
            let elapsed = Date().timeIntervalSince(start)
            #expect(rows.count == 1)
            #expect(rows[0].itemIDs.count == n)
            #expect(rows[0].shortageMinutes == n)
            print("DISPLAY_RISK_PERF records=\(n) runs=1 merge_ms=\(elapsed*1000)")
        }
    }
    @Test func latestStartSuggestionsKeepLeafWorkOnceAndPreferNecessaryBound() throws {
        let a = PlanningBoundary(subject: .item("work"), layer: .dependency, projectIDs: ["p"], latestStart: t, latestFinish: t.addingTimeInterval(60), precision: .necessaryUpperBound, conditionIDs: ["c"], chain: ["item:work"])
        var b = a; b.layer = .singleProject; b.projectIDs = ["q"]; b.latestStart = t.addingTimeInterval(120); b.latestFinish = t.addingTimeInterval(180)
        var c = a; c.layer = .global; c.conditionIDs = ["d"]
        var node = a; node.subject = .node("work")
        var other = a; other.subject = .item("other"); other.latestStart = t.addingTimeInterval(3600); other.latestFinish = t.addingTimeInterval(3660)
        let suggestions = PlanningDisplay.latestStartSuggestions(PlanningDisplay.boundaries([a, b, c, node, other]))
        #expect(suggestions.map(\.id) == ["work", "other"])
        let work = try #require(suggestions.first { $0.id == "work" })
        #expect(work.latestStart == t)
        #expect(work.latestFinish == t.addingTimeInterval(60))
        #expect(work.precision == .necessaryUpperBound)
        #expect(work.projectIDs == ["p", "q"])
        #expect(work.conditionIDs == ["c", "d"])
        #expect(work.layers == [.dependency, .singleProject, .global])
        #expect(work.boundaries.count == 3)
    }

    @Test func realEngineLatestStartSuggestionsCollapseLayersWithoutNodeRows() throws {
        let plan = try Engine.plan(workspace: PRD.abc, input: PRD.abcInput)
        #expect(!plan.boundaries.contains { if case .node = $0.subject { true } else { false } })
        let rawItemIDs = plan.boundaries.compactMap { boundary -> String? in if case .item(let id) = boundary.subject { id } else { nil } }
        #expect(rawItemIDs.count > Set(rawItemIDs).count, "engine 应为每项工作产生多层边界")
        let suggestions = PlanningDisplay.latestStartSuggestions(PlanningDisplay.boundaries(plan.boundaries))
        #expect(suggestions.map(\.id).sorted() == ["a", "b", "c"])
        let work = try #require(suggestions.first { $0.id == "a" })
        #expect(work.precision == .necessaryUpperBound)
        #expect(work.layers.contains(.dependency))
        #expect(work.boundaries.count >= 2)
    }

    @Test func realConditionalRiskNeverReceivesCapacityProofs() throws {
        let w = Workspace(projects: [Project(id: "p", name: "Conditional", deadline: t.addingTimeInterval(3600), planningCompleteness: .complete)],
            items: [WorkItem(id: "a", name: "A", projectIDs: ["p"], remainingMinutes: 120)],
            blockers: [Blocker(id: "wait", name: "External confirmation", state: .active, expectedResolution: t.addingTimeInterval(1800), triggeredAt: t)],
            dependencies: [Dependency(id: "wait-a", source: .blocker("wait"), targetItemID: "a")])
        let plan = try Engine.plan(workspace: w, input: PlanningInput(slots: [CapacitySlot(start: t, end: t.addingTimeInterval(3600))], now: t))
        let conditional = plan.summary.risks.filter { $0.kind == .conditionalUnlock }
        #expect(!conditional.isEmpty)
        #expect(!plan.certificates.isEmpty)
        let index = PlanningDisplay.certificatesByRisk(plan.certificates)
        for risk in conditional { #expect(index[PlanningDisplay.riskKey(risk)] == nil) }
    }
    @Test func matchesRejectsDifferentEnergyAndContinuousReasons() {
        for pair: (PlanningCertificateKind, RiskKind) in [(.energyShortfall, .energyConstraint), (.continuousShortfall, .continuousConstraint)] {
            var p = proof(); p.kind = pair.0
            let risk = Risk(kind: pair.1, projectID: "p", itemIDs: ["a", "b"], message: "different reason")
            #expect(!PlanningDisplay.matches(p, risk: risk))
        }
    }
    @Test func realUIFixtureTrialProofPremisesResolveInCapturedScenario() throws {
        let deadline = t.addingTimeInterval(3600)
        let w = Workspace(projects: ["a", "b", "c"].map { Project(id: $0, name: $0, deadline: deadline, planningCompleteness: .complete) },
            items: [WorkItem(id: "work-a", name: "Shared preparation", projectIDs: ["a", "b"], remainingMinutes: 60),
                    WorkItem(id: "work-b", name: "Submission", projectIDs: ["b"], remainingMinutes: 90, energy: .high, requiresContinuous: true),
                    WorkItem(id: "work-c", name: "Integration", projectIDs: ["c"], remainingMinutes: 30)],
            dependencies: [Dependency(id: "a-c", source: .item("work-a"), targetItemID: "work-c")])
        let trial = try Engine.trial(workspace: w, request: PlanningTrialRequest(itemID: "work-a", minutes: 30),
            input: PlanningInput(slots: [CapacitySlot(start: t, end: t.addingTimeInterval(7200))], now: t))
        let required = Set(trial.unresolvedConflicts.flatMap(\.conditionIDs))
        let captured = Set(trial.scenario?.conditions.map(\.id) ?? [])
        #expect(required.isSubset(of: captured))
        #expect(Set(["completion:work-a", "completion:work-b", "completion:work-c"]).isSubset(of: required))
        #expect(PlanningDisplay.certificates(trial.unresolvedConflicts).flatMap(\.proofs).count == trial.unresolvedConflicts.count)
        print("DISPLAY_UI_CONTEXT required=\(required.sorted()) captured_scenario=\(captured.sorted()) trial_delta=\(trial.conditions.map(\.id).sorted()) omitted_by_delta_only=\(required.subtracting(trial.conditions.map(\.id)).sorted())")
    }
    private func m3Trial(minutes: Int? = 30) throws -> PlanningTrialResult {
        let deadline = t.addingTimeInterval(3600)
        let w = Workspace(projects: ["a", "b", "c"].map { Project(id: $0, name: "Captured " + $0, deadline: deadline, planningCompleteness: .complete) },
            items: [WorkItem(id: "work-a", name: "Captured preparation", projectIDs: ["a", "b"], remainingMinutes: 60),
                    WorkItem(id: "work-b", name: "Captured submission", projectIDs: ["b"], remainingMinutes: 90, energy: .high, requiresContinuous: true),
                    WorkItem(id: "work-c", name: "Captured integration", projectIDs: ["c"], remainingMinutes: 30)],
            dependencies: [Dependency(id: "a-c", source: .item("work-a"), targetItemID: "work-c")])
        return try Engine.trial(workspace: w, request: PlanningTrialRequest(itemID: "work-a", minutes: minutes),
            input: PlanningInput(slots: [CapacitySlot(start: t, end: t.addingTimeInterval(7200))], now: t))
    }
    @Test func realTrialEquivalentEnergyEffectsGroupAndPreserveRaw() throws {
        let trial = try m3Trial(); let original = trial.impacts
        let context = PlanningDisplay.TrialContext(trial)
        for project in ["b", "c"] {
            let raw = original.filter { $0.kind == .compatibleCapacityLoss && $0.projectIDs == [project] }
            #expect(raw.count == 2)
            #expect(Set(raw.compactMap(\.energy)) == [.low, .normal])
            let groups = context.impactGroups.filter { $0.summary.kind == .compatibleCapacityLoss && $0.summary.projectIDs == [project] }
            #expect(groups.count == 1)
            #expect(groups[0].impacts == raw)
        }
        #expect(context.impactGroups.flatMap(\.impacts).count == original.count)
        #expect(trial.impacts == original)
        print("DISPLAY_M3_IMPACTS raw=\(original.count) grouped=\(context.impactGroups.count)")
    }
    @Test func impactFactsPremisesChainsAndResourceModelsRemainDistinct() throws {
        let trial = try m3Trial()
        let a = try #require(trial.impacts.first { $0.kind == .compatibleCapacityLoss && $0.energy == .low })
        var variants = [a]
        func add(_ change: (inout PlanningImpact) -> Void) { var v = a; change(&v); variants.append(v) }
        add { $0.kind = .slackLoss }; add { $0.projectIDs = ["different"] }; add { $0.itemIDs = ["different"] }
        add { $0.beforeMinutes = (a.beforeMinutes ?? 0) + 1 }; add { $0.afterMinutes = (a.afterMinutes ?? 0) + 1 }
        add { $0.beforeDate = t }; add { $0.afterDate = t }; add { $0.windowStart = t.addingTimeInterval(0.25) }
        add { $0.windowEnd = t.addingTimeInterval(3600.25) }; add { $0.conditionIDs = ["different"] }
        add { $0.chain = a.chain.reversed() }; add { $0.chain.append("dependency:other") }
        add { $0.chain = a.chain.map { $0 == "resource:low" ? "resource:shared" : $0 } }
        add { $0.chain = a.chain.map { $0 == "resource:low" ? "resource:custom-low" : $0 } }
        add { $0.message += " different" }; add { $0.beforeMinutes = nil }
        let groups = PlanningDisplay.impacts(variants)
        #expect(groups.count == variants.count)
        #expect(groups.allSatisfy { $0.impacts.count == 1 })
        var normalized = a; normalized.energy = .normal
        normalized.chain = a.chain.map { $0 == "resource:low" ? "resource:normal" : $0 }
        normalized.projectIDs += a.projectIDs; normalized.itemIDs += a.itemIDs; normalized.conditionIDs += a.conditionIDs
        #expect(PlanningDisplay.impacts([a, normalized]).count == 1)
    }
    @Test func actualUITrialContextResolvesAllProofAndImpactPremises() throws {
        for minutes in [30, 60] {
            let trial = try m3Trial(minutes: minutes); let context = PlanningDisplay.TrialContext(trial)
            let required = Set(trial.unresolvedConflicts.flatMap(\.conditionIDs) + trial.impacts.flatMap(\.conditionIDs))
            #expect(required.isSubset(of: Set(context.conditions.keys)))
            for id in ["completion:work-a", "completion:work-b", "completion:work-c", "trial-resource:work-a"] {
                #expect(context.conditions[id] != nil)
            }
            #expect(context.conflictGroups.flatMap(\.proofs).count == trial.unresolvedConflicts.count)
            print("DISPLAY_M3_CONTEXT minutes=\(minutes) required=\(required.sorted()) resolved=\(required.allSatisfy { context.conditions[$0] != nil })")
        }
    }
    @Test func directionOnlyContextFallsBackToCapturedBaseline() throws {
        let trial = try m3Trial(minutes: nil); #expect(trial.scenario == nil)
        let context = PlanningDisplay.TrialContext(trial)
        #expect(!trial.baseline.conditions.isEmpty)
        for condition in trial.baseline.conditions { #expect(context.conditions[condition.id] == condition) }
        #expect(context.names["work-a"] == "Captured preparation")
    }
    @Test func trialDeltaOverridesSameIDAndCapturedNamesRemainIsolated() throws {
        var trial = try m3Trial()
        let original = try #require(trial.scenario?.conditions.first)
        var latest = original; latest.message = "Delta replaces captured premise"; latest.expectedAt = t.addingTimeInterval(60)
        trial.conditions.append(latest)
        let context = PlanningDisplay.TrialContext(trial)
        #expect(context.conditions[latest.id] == latest)
        trial.source.items[0].name = "Later renamed live item"
        trial.source.projects[0].name = "Later renamed live project"
        trial.conditions[trial.conditions.count - 1].message = "Later mutation"
        #expect(context.names["work-a"] == "Captured preparation")
        #expect(context.names["a"] == "Captured a")
        #expect(context.conditions[latest.id]?.message == "Delta replaces captured premise")
    }
    @Test func capturedReferenceNamesRenderFriendlyResourceAndDependencyLabels() throws {
        let context = PlanningDisplay.TrialContext(try m3Trial())
        #expect(context.referenceName("item:work-a") == "Captured preparation")
        #expect(context.referenceName("project:b") == "Captured b")
        #expect(context.referenceName("dependency:a-c") == "前置关系：Captured preparation → Captured integration")
        #expect(context.referenceName("resource:low") == "任意精力容量")
        #expect(context.referenceName("resource:normal") == "普通及高专注容量")
        #expect(context.referenceName("resource:high") == "高专注容量")
        #expect(context.referenceName("resource:shared") == "共享容量")
        #expect(context.referenceName("resource:unknown") == "原记录对象")
        #expect(context.referenceName("item:missing") == "原记录对象")
    }
    @Test func sharedReferenceNamesResolveTypedBareColonIDsAndPreferKnownNames() {
        let names = ["work": "准备材料", "delivery:甲": "材料交付", "project:part:one": "完整引用优先",
                     "part:one": "项目后缀名称", "blocked:one": "外部回复", "dependency:dep:one": "前置关系：准备材料 → 提交申请",
                     "resource:low": "已知资源对象", "constraint:capacity": "已知约束对象"]
        let expected = ["work": "准备材料", "item:work": "准备材料", "delivery:甲": "材料交付",
                        "node:delivery:甲": "材料交付", "item:delivery:甲": "材料交付",
                        "project:part:one": "完整引用优先", "blocker:blocked:one": "外部回复",
                        "dependency:dep:one": "前置关系：准备材料 → 提交申请",
                        "resource:low": "已知资源对象", "constraint:capacity": "已知约束对象"]
        for (reference, name) in expected {
            #expect(PlanningDisplay.referenceName(reference, names: names) == name)
        }
        #expect(PlanningDisplay.referenceName("project:part:one", names: ["part:one": "项目后缀名称"]) == "项目后缀名称")
    }
    @Test func sharedReferenceResourceConstraintLabelsAndUnknownFallbackDoNotLeakIDs() {
        let expected = ["resource:low": "任意精力容量", "resource:normal": "普通及高专注容量",
                        "resource:high": "高专注容量", "resource:shared": "共享容量",
                        "resource:next-compatible-slot": "下一个匹配空档", "resource:split-slots": "分段空档",
                        "constraint:continuous": "连续时段约束", "constraint:capacity": "劳动容量约束"]
        for (reference, name) in expected {
            #expect(PlanningDisplay.referenceName(reference, names: [:]) == name)
        }
        for reference in ["missing", "missing:colon:id", "item:missing:colon", "node:missing", "project:missing",
                          "blocker:missing", "dependency:missing", "resource:unknown", "constraint:unknown", "item:", ""] {
            #expect(PlanningDisplay.referenceName(reference, names: [:]) == "原记录对象")
        }
    }
    @Test func capturedTrialContextDelegatesToSharedReferenceResolver() throws {
        var trial = try m3Trial()
        trial.source.items.append(WorkItem(id: "stage:with:colon", name: "Captured colon stage", projectIDs: ["a"], remainingMinutes: 1))
        let context = PlanningDisplay.TrialContext(trial)
        for reference in ["work-a", "item:work-a", "project:b", "dependency:a-c", "stage:with:colon", "item:stage:with:colon",
                          "resource:low", "resource:normal", "resource:high", "resource:shared", "resource:next-compatible-slot",
                          "resource:split-slots", "constraint:continuous", "constraint:capacity", "item:missing:colon"] {
            #expect(context.referenceName(reference) == PlanningDisplay.referenceName(reference, names: context.names))
        }
        #expect(context.referenceName("item:stage:with:colon") == "Captured colon stage")
        #expect(context.referenceName("dependency:a-c") == "前置关系：Captured preparation → Captured integration")
        #expect(context.referenceName("resource:next-compatible-slot") == "下一个匹配空档")
        #expect(context.referenceName("constraint:continuous") == "连续时段约束")
        #expect(context.referenceName("item:missing:colon") == "原记录对象")
    }
    @Test func impactGroupingAndCompleteContextPerformance4800Records() throws {
        var trial = try m3Trial()
        let original = try #require(trial.impacts.first { $0.kind == .compatibleCapacityLoss && $0.energy == .low })
        trial.impacts = (0..<4800).map { i in
            var v = original; v.itemIDs = ["item-\(i / 3)"]
            let e = ["low", "normal", "high"][i % 3]
            v.energy = [Energy.low, .normal, .high][i % 3]
            v.chain = ["item:item-\(i / 3)", "resource:" + e, "project:b"]
            return v
        }
        trial.unresolvedConflicts = (0..<4800).map { i in var p = proof(); p.itemIDs = ["item-\(i / 4)"]; return p }
        trial.source.items = (0..<1600).map { WorkItem(id: "item-\($0)", name: "Captured item \($0)", projectIDs: ["b"], remainingMinutes: 1) }
        var groupTimes:[Double] = [], contextTimes:[Double] = []
        for _ in 0..<10 {
            var start = Date(); let groups = PlanningDisplay.impacts(trial.impacts); groupTimes.append(Date().timeIntervalSince(start)*1000)
            #expect(groups.count == 1600); #expect(groups.flatMap(\.impacts).count == 4800)
            start = Date(); let context = PlanningDisplay.TrialContext(trial); contextTimes.append(Date().timeIntervalSince(start)*1000)
            #expect(context.impactGroups.count == 1600); #expect(context.conflictGroups.count == 1200)
            #expect(context.names["item-1599"] == "Captured item 1599")
        }
        print("DISPLAY_M3_PERF impacts=4800 proofs=4800 names=1600 runs=10 grouping_mean_ms=\(groupTimes.reduce(0,+)/10) grouping_max_ms=\(groupTimes.max()!) context_mean_ms=\(contextTimes.reduce(0,+)/10) context_max_ms=\(contextTimes.max()!)")
    }

}
