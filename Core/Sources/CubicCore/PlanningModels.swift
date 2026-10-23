import Foundation

public struct PlanningRevision: Codable, Sendable, Equatable {
    public var workspace: String
    public var capacity: String
    public var calendar: String
    public var time: String
    public init(workspace: String = "", capacity: String = "", calendar: String = "", time: String = "") {
        self.workspace = workspace; self.capacity = capacity; self.calendar = calendar; self.time = time
    }
}

/// Explicit scenario assumptions; never edits the underlying waiting round or dependency.
public struct PlanningWait: Codable, Sendable, Equatable {
    public var blockerID: String
    public var startAfterItemIDs: [String]
    public var assumedStart: Date?
    public var elapsedMinutes: Int?
    public var expectedResolution: Date?
    public init(blockerID: String, startAfterItemIDs: [String] = [], assumedStart: Date? = nil,
                elapsedMinutes: Int? = nil, expectedResolution: Date? = nil) {
        self.blockerID = blockerID; self.startAfterItemIDs = startAfterItemIDs
        self.assumedStart = assumedStart; self.elapsedMinutes = elapsedMinutes
        self.expectedResolution = expectedResolution
    }
}

public struct PlanningOptions: Codable, Sendable, Equatable {
    public var capacityVerified: Bool
    public var capacityNote: String?
    /// Legacy captured values retained for decoding older trials; current planning uses the as-is structure.
    public var projectScopeComplete: [String: Bool]
    public var nodeScopeComplete: [String: Bool]
    public var requiredItemIDs: [String: Bool]
    public var requiredNodeIDs: [String: Bool]
    public var committedProjectIDs: [String: Bool]
    public var itemDeadlines: [String: Date]
    public var warningMargins: [String: Int]
    public var manualGateDates: [String: Date]
    public var waits: [PlanningWait]
    /// Caps expensive interval proofs; skipped proofs are never treated as successful schedules.
    public var maximumIntervalChecks: Int
    public init(capacityVerified: Bool = true, capacityNote: String? = nil,
                projectScopeComplete: [String: Bool] = [:], nodeScopeComplete: [String: Bool] = [:],
                requiredItemIDs: [String: Bool] = [:], requiredNodeIDs: [String: Bool] = [:],
                committedProjectIDs: [String: Bool] = [:], itemDeadlines: [String: Date] = [:],
                warningMargins: [String: Int] = [:], manualGateDates: [String: Date] = [:],
                waits: [PlanningWait] = [], maximumIntervalChecks: Int = 100_000) {
        self.capacityVerified = capacityVerified; self.capacityNote = capacityNote
        self.projectScopeComplete = projectScopeComplete; self.nodeScopeComplete = nodeScopeComplete
        self.requiredItemIDs = requiredItemIDs; self.requiredNodeIDs = requiredNodeIDs
        self.committedProjectIDs = committedProjectIDs; self.itemDeadlines = itemDeadlines
        self.warningMargins = warningMargins; self.manualGateDates = manualGateDates
        self.waits = waits; self.maximumIntervalChecks = maximumIntervalChecks
    }
}

public struct PlanningInput: Codable, Sendable, Equatable {
    public var slots: [CapacitySlot]
    public var busy: [BusyInterval]
    public var now: Date
    public var horizonEnd: Date
    public var revision: PlanningRevision
    public var options: PlanningOptions
    public init(slots: [CapacitySlot], busy: [BusyInterval] = [], now: Date,
                horizonEnd: Date? = nil, revision: PlanningRevision = PlanningRevision(),
                options: PlanningOptions = PlanningOptions()) {
        self.slots = slots; self.busy = busy; self.now = now
        self.horizonEnd = horizonEnd ?? max(now, slots.map(\.end).max() ?? now)
        self.revision = revision; self.options = options
    }
}

public enum PlanningConditionKind: String, Codable, Sendable {
    case estimatedCompletion, manualAcceptance, externalResolution, assumedWaitStart
    case counterfactualReadiness, capacityUnverified, trialResourceUse
}
public struct PlanningCondition: Codable, Sendable, Equatable {
    public var id: String
    public var kind: PlanningConditionKind
    public var objectID: String
    public var dependencyIDs: [String]
    public var expectedAt: Date?
    public var message: String
    public init(id: String, kind: PlanningConditionKind, objectID: String,
                dependencyIDs: [String] = [], expectedAt: Date? = nil, message: String) {
        self.id = id; self.kind = kind; self.objectID = objectID
        self.dependencyIDs = dependencyIDs; self.expectedAt = expectedAt; self.message = message
    }
}
public struct PlanningUnknown: Codable, Sendable, Equatable {
    public var objectID: String
    public var message: String
    public init(objectID: String, message: String) { self.objectID = objectID; self.message = message }
}
public struct PlanningSource: Codable, Sendable, Equatable {
    public var input: PlanningInput
    public var projects: [Project]
    public var nodes: [Node]
    public var items: [WorkItem]
    public var blockers: [Blocker]
    public var dependencies: [Dependency]
    public var acceptances: [Acceptance]
    public var workLinks: [WorkLink]
    public var reviews: [ReviewRecord]
    public var workRounds: [WorkRound]
    public init(workspace: Workspace, input: PlanningInput) {
        self.input = input; projects = workspace.projects; nodes = workspace.nodes
        items = workspace.items; blockers = workspace.blockers
        dependencies = workspace.dependencies; acceptances = workspace.acceptances
        workLinks = workspace.workLinks ?? []
        reviews = workspace.reviews ?? []; workRounds = workspace.workRounds ?? []
    }
    public func matches(workspace: Workspace, input: PlanningInput) -> Bool {
        self == PlanningSource(workspace: workspace, input: input)
    }
}
public struct PlanningWitness: Codable, Sendable, Equatable {
    public var allocations: [TrialAllocation]
    public var eventTimes: [String: Date]
    public var conditionIDs: [String]
    public var isComplete: Bool
    public init(allocations: [TrialAllocation] = [], eventTimes: [String: Date] = [:],
                conditionIDs: [String] = [], isComplete: Bool = false) {
        self.allocations = allocations; self.eventTimes = eventTimes
        self.conditionIDs = conditionIDs; self.isComplete = isComplete
    }
}
public enum PlanningLayer: String, Codable, Sendable { case dependency, singleProject, global }
public enum PlanningPrecision: String, Codable, Sendable { case necessaryUpperBound, feasibleCandidate, unknown }
public struct PlanningBoundary: Codable, Sendable, Equatable {
    public var subject: WorkReference
    public var layer: PlanningLayer
    public var projectIDs: [String]
    public var latestStart: Date?
    public var latestFinish: Date?
    public var precision: PlanningPrecision
    public var conditionIDs: [String]
    public var chain: [String]
}
public enum PlanningWarningState: String, Codable, Sendable {
    case notConfigured, sufficient, insufficient, undetermined, boundaryReached, infeasible
}
public struct PlanningProjectAssessment: Codable, Sendable, Equatable {
    public var projectID: String
    public var knownDemandMinutes: Int
    public var totalDemandMinutes: Int?
    public var knownCapacityMinutes: Int
    public var feasibility: Feasibility
    public var scopeComplete: Bool
    public var warningMarginMinutes: Int?
    public var slackLowerBoundMinutes: Int?
    public var slackUpperBoundMinutes: Int?
    public var warningState: PlanningWarningState
    public var conditionIDs: [String]
    public var witness: PlanningWitness
}
public enum PlanningCertificateKind: String, Codable, Sendable {
    case capacityShortfall, energyShortfall, continuousShortfall, dependencyWindow
}
public struct PlanningCertificate: Codable, Sendable, Equatable {
    public var kind: PlanningCertificateKind
    public var projectIDs: [String]
    public var itemIDs: [String]
    public var windowStart: Date
    public var windowEnd: Date
    public var energy: Energy
    public var demandMinutes: Int
    public var capacityMinutes: Int
    public var shortageMinutes: Int
    public var demandSeconds: Double
    public var capacitySeconds: Double
    public var shortageSeconds: Double
    public var requiredReadyAt: Date?
    public var latestAllowedAt: Date?
    /// Date-path contradiction, separate from missing personal labor time.
    public var elapsedDelaySeconds: Double?
    public var conditionIDs: [String]
    public var message: String
}
public struct PlanningSnapshot: Codable, Sendable, Equatable {
    public var source: PlanningSource
    public var legacy: EngineSnapshot
    public var knownDemandMinutes: Int
    /// Only these demands are forced by real deadlines; undated known work stays visible above.
    public var committedDemandMinutes: Int
    public var unknowns: [PlanningUnknown]
    public var conditions: [PlanningCondition]
    public var witness: PlanningWitness
    public var boundaries: [PlanningBoundary]
    public var projects: [PlanningProjectAssessment]
    public var certificates: [PlanningCertificate]
    /// Candidate failure or unknown premises identify a decision set, without asserting an impossible schedule.
    public var unprovenCompetitions: [PlanningImpact]
    public var feasibility: Feasibility { legacy.feasibility }
}

public struct PlanningTrialRequest: Codable, Sendable, Equatable {
    public var itemID: String
    public var minutes: Int?
    public var start: Date?
    public var counterfactual: Bool
    public init(itemID: String, minutes: Int? = nil, start: Date? = nil, counterfactual: Bool = false) {
        self.itemID = itemID; self.minutes = minutes; self.start = start; self.counterfactual = counterfactual
    }
}
public enum PlanningImpactKind: String, Codable, Sendable {
    case sharedProgress, dependencyRelease, boundaryImprovement
    case compatibleCapacityLoss, slackLoss, shortageIncrease, unresolvedCompetition, unknown
}
public struct PlanningImpact: Codable, Sendable, Equatable {
    public var kind: PlanningImpactKind
    public var projectIDs: [String]
    public var itemIDs: [String]
    public var beforeMinutes: Int?
    public var afterMinutes: Int?
    public var beforeDate: Date?
    public var afterDate: Date?
    public var windowStart: Date?
    public var windowEnd: Date?
    public var energy: Energy?
    public var conditionIDs: [String]
    public var chain: [String]
    public var message: String
}
public struct PlanningTrialResult: Codable, Sendable, Equatable {
    public var request: PlanningTrialRequest
    public var source: PlanningSource
    public var baseline: PlanningSnapshot
    public var scenario: PlanningSnapshot?
    public var allocations: [TrialAllocation]
    public var startPosition: Date?
    public var assumedRemainingMinutes: Int?
    public var estimatedCompletion: Date?
    public var unallocatedMinutes: Int?
    public var excessMinutes: Int?
    public var impacts: [PlanningImpact]
    public var unresolvedConflicts: [PlanningCertificate]
    public var conditions: [PlanningCondition]
    public func isStale(comparedTo input: PlanningInput) -> Bool { source.input != input }
    public func isStale(workspace: Workspace, input: PlanningInput) -> Bool {
        !source.matches(workspace: workspace, input: input)
    }
}
