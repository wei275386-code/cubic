import Foundation

/// A read-only projection. Raw proofs remain available for calculation and history.
public enum PlanningDisplay {
    /// Archive is visibility only. Keep shared work visible while any related project is visible.
    /// The caller supplies the full project scope, including nodes, links and prerequisites.
    public static func actionItems(workspace: Workspace, relatedProjectIDs: (WorkItem) -> Set<String>) -> [WorkItem] {
        let visibleProjectIDs = Set(workspace.projects.filter { !$0.archived }.map(\.id))
        return workspace.items.filter { item in
            guard !item.archived && item.effectiveDisposition == .active && item.status != .completed && !item.isPendingInboxOrganization else { return false }
            let projectIDs = relatedProjectIDs(item)
            return projectIDs.isEmpty || !projectIDs.isDisjoint(with: visibleProjectIDs)
        }
    }
    public enum SharedScheduleState: Equatable, Sendable {
        case shortfall(Int), dateConflict, missingInformation, unverified
    }
    /// A failed candidate is not proof of a shortage; absent minutes are not zero.
    public static func sharedScheduleState(_ risk: Risk, proofs: [PlanningCertificate], unknowns: [PlanningUnknown]) -> SharedScheduleState {
        if proofs.contains(where: { $0.elapsedDelaySeconds != nil }) { return .dateConflict }
        let shortages = proofs.filter { $0.elapsedDelaySeconds == nil }.map(\.shortageMinutes) + [risk.shortageMinutes ?? 0]
        if let shortage = shortages.max(), shortage > 0 { return .shortfall(shortage) }
        return unknowns.isEmpty ? .unverified : .missingInformation
    }
    public static func relatedUnknowns(_ unknowns: [PlanningUnknown], objectIDs: Set<String>, conditions: [PlanningCondition]) -> [PlanningUnknown] {
        let ids = objectIDs.union(conditions.map(\.objectID))
        var seen = Set<[String]>()
        return unknowns.filter {
            (ids.contains($0.objectID) || $0.objectID == "capacity") && seen.insert([$0.objectID, $0.message]).inserted
        }
    }
    public struct ImpactKey: Hashable, Sendable {
        let kind: String
        let projects: [String]
        let items: [String]
        let beforeMinutes: Int?
        let afterMinutes: Int?
        let beforeDate: Date?
        let afterDate: Date?
        let start: Date?
        let end: Date?
        let conditions: [String]
        let chain: [String]
        let message: String
    }
    public struct ImpactGroup: Identifiable, Sendable {
        public let id: ImpactKey
        public var impacts: [PlanningImpact]
        public var summary: PlanningImpact { impacts[0] }
    }
    /// Only equal effects can share a row; the contributing energy thresholds remain explicit.
    public static func impacts(_ impacts: [PlanningImpact]) -> [ImpactGroup] {
        var groups: [ImpactGroup] = [], indices: [ImpactKey: Int] = [:]
        for impact in impacts {
            let chain = impact.chain.map { reference in
                ["resource:low", "resource:normal", "resource:high"].contains(reference) ? "resource:energy" : reference
            }
            let key = ImpactKey(kind: impact.kind.rawValue, projects: Set(impact.projectIDs).sorted(),
                items: Set(impact.itemIDs).sorted(), beforeMinutes: impact.beforeMinutes, afterMinutes: impact.afterMinutes,
                beforeDate: impact.beforeDate, afterDate: impact.afterDate, start: impact.windowStart, end: impact.windowEnd,
                conditions: Set(impact.conditionIDs).sorted(), chain: chain, message: impact.message)
            if let index = indices[key] { groups[index].impacts.append(impact) }
            else { indices[key] = groups.count; groups.append(ImpactGroup(id: key, impacts: [impact])) }
        }
        return groups
    }

    /// Uses captured scenario premises, never the live workspace or only the trial delta.
    public struct TrialContext: Sendable {
        public let source: PlanningSource
        public let names: [String: String]
        public let conditions: [String: PlanningCondition]
        public let unknowns: [PlanningUnknown]
        public let impactGroups: [ImpactGroup]
        public let conflictGroups: [CertificateGroup]
        public init(_ trial: PlanningTrialResult) {
            let source = trial.source
            self.source = source
            var pairs = source.items.map { ($0.id, $0.name) }
            pairs += source.projects.map { ($0.id, $0.name) }
            pairs += source.nodes.map { ($0.id, $0.name) }
            pairs += source.blockers.map { ($0.id, $0.name) }
            pairs += source.acceptances.map { ($0.id, $0.name) }
            var names = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
            for dependency in source.dependencies {
                names["dependency:" + dependency.id] = "前置关系：" + (names[dependency.source.id] ?? "原记录") + " → " + (names[dependency.targetItemID] ?? "原记录")
            }
            self.names = names
            let captured = (trial.scenario ?? trial.baseline).conditions
            conditions = Dictionary((captured + trial.conditions).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            unknowns = (trial.scenario ?? trial.baseline).unknowns
            impactGroups = PlanningDisplay.impacts(trial.impacts)
            conflictGroups = PlanningDisplay.certificates(trial.unresolvedConflicts)
        }
        public func referenceName(_ reference: String) -> String {
            PlanningDisplay.referenceName(reference, names: names)
        }
    }

    /// Resolve graph references without exposing storage identifiers in user-facing paths.
    public static func referenceName(_ reference: String, names: [String: String]) -> String {
        if let name = names[reference] { return name }
        switch reference {
        case "resource:low": return "任意精力容量"
        case "resource:normal": return "普通及高专注容量"
        case "resource:high": return "高专注容量"
        case "resource:shared": return "共享容量"
        case "resource:next-compatible-slot": return "下一个匹配空档"
        case "resource:split-slots": return "分段空档"
        case "constraint:continuous": return "连续时段约束"
        case "constraint:capacity": return "劳动容量约束"
        default:
            let parts = reference.split(separator: ":", maxSplits: 1)
            if parts.count == 2, ["item", "node", "project", "blocker"].contains(String(parts[0])) {
                return names[String(parts[1])] ?? "原记录对象"
            }
            return "原记录对象"
        }
    }

    public struct CertificateKey: Hashable, Sendable {
        let items: [String]
        let conditions: [String]
        let start: Date
        let end: Date
        let demand: Double
        let capacity: Double
        let shortage: Double
        let demandMinutes: Int
        let capacityMinutes: Int
        let shortageMinutes: Int
        let ready: Date?
        let latest: Date?
        let delay: Double?
    }

    public struct CertificateGroup: Identifiable, Sendable {
        public let id: CertificateKey
        public var proofs: [PlanningCertificate]
        public var summary: PlanningCertificate {
            var result = proofs[0]
            result.projectIDs = Set(proofs.flatMap(\.projectIDs)).sorted()
            return result
        }
    }

    /// Equivalent numerical evidence shares one row, with every constraint/scope retained.
    /// Exact seconds and premises are deliberately not rounded away.
    public static func certificates(_ certificates: [PlanningCertificate]) -> [CertificateGroup] {
        var groups: [CertificateGroup] = [], indices: [CertificateKey: Int] = [:]
        for proof in certificates {
            let key = CertificateKey(items: Set(proof.itemIDs).sorted(), conditions: Set(proof.conditionIDs).sorted(),
                start: proof.windowStart, end: proof.windowEnd, demand: proof.demandSeconds,
                capacity: proof.capacitySeconds, shortage: proof.shortageSeconds,
                demandMinutes: proof.demandMinutes, capacityMinutes: proof.capacityMinutes,
                shortageMinutes: proof.shortageMinutes, ready: proof.requiredReadyAt,
                latest: proof.latestAllowedAt, delay: proof.elapsedDelaySeconds)
            if let index = indices[key] { groups[index].proofs.append(proof) }
            else { indices[key] = groups.count; groups.append(CertificateGroup(id: key, proofs: [proof])) }
        }
        return groups
    }

    public struct BoundaryKey: Hashable, Sendable {
        let subject: String
        let start: Date?
        let finish: Date?
        let precision: String
        let conditions: [String]
        let chain: [String]
    }
    public struct BoundaryGroup: Identifiable, Sendable {
        public let id: BoundaryKey
        public var boundaries: [PlanningBoundary]
        public var summary: PlanningBoundary {
            var result = boundaries[0]
            result.projectIDs = Set(boundaries.flatMap(\.projectIDs)).sorted()
            return result
        }
    }
    public static func boundaries(_ boundaries: [PlanningBoundary]) -> [BoundaryGroup] {
        var groups: [BoundaryGroup] = [], indices: [BoundaryKey: Int] = [:]
        for boundary in boundaries {
            let subject: String
            switch boundary.subject { case .item(let id): subject = "item:" + id; case .node(let id): subject = "node:" + id }
            let key = BoundaryKey(subject: subject, start: boundary.latestStart, finish: boundary.latestFinish,
                precision: boundary.precision.rawValue, conditions: Set(boundary.conditionIDs).sorted(), chain: boundary.chain)
            if let index = indices[key] { groups[index].boundaries.append(boundary) }
            else { indices[key] = groups.count; groups.append(BoundaryGroup(id: key, boundaries: [boundary])) }
        }
        return groups
    }

    /// A single actionable row per leaf work item. The engine emits newest-start
    /// boundaries once per analysis layer (`dependency`/`singleProject`/`global`)
    /// and also for node aggregates, so the raw list repeats the same work and
    /// shows non-actionable node rows. This folds every layer of one work item
    /// into one suggestion; the strongest (earliest necessary) bound wins, while
    /// all contributing layers remain available for the detail disclosure.
    public struct LatestStartSuggestion: Identifiable, Sendable, Equatable {
        public let id: String
        public var itemID: String { id }
        public var projectIDs: [String]
        public var latestStart: Date?
        public var latestFinish: Date?
        public var precision: PlanningPrecision
        public var conditionIDs: [String]
        public var chain: [String]
        public var layers: [PlanningLayer]
        public var boundaries: [PlanningBoundary]
    }

    public static func latestStartSuggestions(_ groups: [BoundaryGroup]) -> [LatestStartSuggestion] {
        var order: [String] = [], buckets: [String: [PlanningBoundary]] = [:]
        for group in groups {
            for boundary in group.boundaries {
                guard case .item(let id) = boundary.subject else { continue }
                if buckets[id] == nil { order.append(id) }
                buckets[id, default: []].append(boundary)
            }
        }
        return order.compactMap { id in
            guard let boundaries = buckets[id], let representative = boundaries.min(by: { boundaryRank($0) < boundaryRank($1) }) else { return nil }
            return LatestStartSuggestion(id: id,
                projectIDs: Set(boundaries.flatMap(\.projectIDs)).sorted(),
                latestStart: representative.latestStart, latestFinish: representative.latestFinish,
                precision: representative.precision,
                conditionIDs: Set(boundaries.flatMap(\.conditionIDs)).sorted(),
                chain: representative.chain,
                layers: Set(boundaries.map(\.layer)).sorted { layerRank($0) < layerRank($1) },
                boundaries: boundaries)
        }
    }

    /// Necessary upper bounds outrank candidate schedules; within a kind the
    /// earliest (most binding) start wins, then the earliest finish.
    static func boundaryRank(_ boundary: PlanningBoundary) -> (Int, Date, Date) {
        let precision: Int
        switch boundary.precision { case .necessaryUpperBound: precision = 0; case .feasibleCandidate: precision = 1; case .unknown: precision = 2 }
        return (precision, boundary.latestStart ?? .distantFuture, boundary.latestFinish ?? .distantFuture)
    }

    static func layerRank(_ layer: PlanningLayer) -> Int {
        switch layer { case .dependency: 0; case .singleProject: 1; case .global: 2 }
    }

    public struct RiskKey: Hashable, Sendable {
        let kind: String
        let project: String?
        let message: String
    }

    public static func riskKey(_ risk: Risk) -> RiskKey {
        RiskKey(kind: risk.kind.rawValue, project: risk.projectID, message: risk.message)
    }

    /// Build the lookup once per snapshot, instead of scanning every proof for every row.
    public static func certificatesByRisk(_ certificates: [PlanningCertificate]) -> [RiskKey: [CertificateGroup]] {
        let byCause = Dictionary(grouping: certificates, by: certificateRiskKey)
        return byCause.mapValues(Self.certificates)
    }

    private static func certificateRiskKey(_ proof: PlanningCertificate) -> RiskKey {
        let kind: RiskKind
        switch proof.kind {
        case .continuousShortfall: kind = .continuousConstraint
        case .energyShortfall: kind = .energyConstraint
        case .capacityShortfall, .dependencyWindow:
            kind = proof.projectIDs.count == 1 ? .provenCapacityShortfall : .sharedResourceConflict
        }
        return RiskKey(kind: kind.rawValue, project: proof.projectIDs.count == 1 ? proof.projectIDs[0] : nil, message: proof.message)
    }

    /// One cause per project; show the strongest lower bound, never sum overlapping proofs.
    public static func risks(_ risks: [Risk]) -> [Risk] {
        var rows: [Risk] = [], indices: [RiskKey: Int] = [:]
        var itemSets: [Set<String>] = []
        for risk in risks {
            let key = RiskKey(kind: risk.kind.rawValue, project: risk.projectID, message: risk.message)
            if let index = indices[key] {
                itemSets[index].formUnion(risk.itemIDs)
                if let shortage = risk.shortageMinutes {
                    rows[index].shortageMinutes = max(rows[index].shortageMinutes ?? 0, shortage)
                }
            } else {
                indices[key] = rows.count
                rows.append(risk)
                itemSets.append(Set(risk.itemIDs))
            }
        }
        for index in rows.indices { rows[index].itemIDs = itemSets[index].sorted() }
        return rows
    }

    public static func matches(_ proof: PlanningCertificate, risk: Risk) -> Bool {
        guard certificateRiskKey(proof) == riskKey(risk) else { return false }
        let items = Set(risk.itemIDs)
        return proof.itemIDs.isEmpty ? risk.projectID != nil || proof.projectIDs.count > 1 :
            !items.isDisjoint(with: proof.itemIDs) && Set(proof.itemIDs).isSubset(of: items)
    }
}
