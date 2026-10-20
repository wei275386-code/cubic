import Foundation

public enum ProjectStatus: String, Codable, Sendable, Equatable { case planning, active, deferred, completed, cancelled }
public enum WorkDisposition: String, Codable, Sendable, Equatable { case active, deferred, cancelled }
public enum PlanningCompleteness: String, Codable, Sendable, Equatable { case incomplete, complete }
public enum EstimateReason: String, Codable, Sendable, Equatable { case revision, scopeChange, rework, correction, other }
public enum RemainingUpdate: Codable, Sendable, Equatable { case unchanged, unknown, minutes(Int) }
public enum ReviewOutcome: String, Codable, Sendable, Equatable { case stillValid, waitForUpstream }

extension Project {
    public var effectiveStatus: ProjectStatus { status ?? .planning }
    /// Historical scope declaration only; current delivery and planning use the as-is structure.
    public var isPlanningComplete: Bool { planningCompleteness == .complete }
    public var archived: Bool { isArchived == true }
    public var hasDeliveryCommitment: Bool { effectiveStatus != .cancelled && effectiveStatus != .completed }
}
extension Node {
    public var required: Bool { isRequired != false }
    /// Historical scope declaration only; current delivery and planning use the as-is structure.
    public var isPlanningComplete: Bool { planningCompleteness == .complete }
    public var archived: Bool { isArchived == true }
    public var currentRound: Int { round ?? 1 }
}
extension WorkItem {
    public var required: Bool { isRequired != false }
    public var effectiveDisposition: WorkDisposition { disposition ?? .active }
    public var archived: Bool { isArchived == true }
    public var currentRound: Int { round ?? 1 }
}
extension Blocker {
    public var currentRound: Int { round ?? 1 }
    public var estimatedResolution: Date? {
        if let expectedResolution { return expectedResolution }
        guard let triggeredAt, let expectedDurationMinutes else { return nil }
        return triggeredAt.addingTimeInterval(Double(expectedDurationMinutes) * 60)
    }
}
extension Dependency { public var isActive: Bool { removedAt == nil }; public var currentRevision: Int { revision ?? 1 } }
extension Acceptance {
    /// 验收条件没有“可选”语义：一旦添加即为必需（2026-10-06 决策）。
    /// isRequired 字段为旧数据兼容保留，判定一律视为必需。
    public var required: Bool { true }
    public var currentRound: Int { round ?? 1 }
    public var isActive: Bool { removedAt == nil }
}

public struct WorkLink: Codable, Sendable, Equatable {
    public var id: String; public var source: WorkReference; public var projectID: String
    public var nodeID: String?; public var isRequired: Bool; public var removedAt: Date?
    /// Stable alias position for independently copied templates; nil preserves legacy order.
    public var structureOrder: Int?
    public init(id: String = UUID().uuidString, source: WorkReference, projectID: String,
                nodeID: String? = nil, isRequired: Bool = true, removedAt: Date? = nil, structureOrder: Int? = nil) {
        self.id = id; self.source = source; self.projectID = projectID; self.nodeID = nodeID
        self.isRequired = isRequired; self.removedAt = removedAt; self.structureOrder = structureOrder
    }
}
public struct EstimateRevision: Codable, Sendable, Equatable {
    public var id: String; public var itemID: String; public var date: Date; public var minutes: Int?
    public var previousMinutes: Int?; public var reason: EstimateReason?; public var note: String
    public var round: Int; public var correctsRevisionID: String?
    public init(id: String = UUID().uuidString, itemID: String, date: Date, minutes: Int?,
                previousMinutes: Int? = nil, reason: EstimateReason? = nil, note: String = "",
                round: Int = 1, correctsRevisionID: String? = nil) {
        self.id = id; self.itemID = itemID; self.date = date; self.minutes = minutes
        self.previousMinutes = previousMinutes; self.reason = reason; self.note = note
        self.round = round; self.correctsRevisionID = correctsRevisionID
    }
}
public struct WorkRound: Codable, Sendable, Equatable {
    public var id: String; public var itemID: String; public var round: Int; public var openedAt: Date
    public var initialMinutes: Int?; public var preStartMinutes: Int?; public var startedAt: Date?
    public var completedAt: Date?; public var sources: [SourceUse]?
    public init(id: String = UUID().uuidString, itemID: String, round: Int, openedAt: Date,
                initialMinutes: Int?, preStartMinutes: Int? = nil, startedAt: Date? = nil,
                completedAt: Date? = nil, sources: [SourceUse]? = nil) {
        self.id = id; self.itemID = itemID; self.round = round; self.openedAt = openedAt
        self.initialMinutes = initialMinutes; self.preStartMinutes = preStartMinutes
        self.startedAt = startedAt; self.completedAt = completedAt; self.sources = sources
    }
}
public struct BlockerRound: Codable, Sendable, Equatable {
    public var id: String; public var blockerID: String; public var round: Int; public var triggeredAt: Date?
    public var expectedResolution: Date?; public var expectedDurationMinutes: Int?
    public var followUpAt: Date?; public var resolvedAt: Date?
    public init(id: String = UUID().uuidString, blockerID: String, round: Int, triggeredAt: Date?,
                expectedResolution: Date? = nil, expectedDurationMinutes: Int? = nil,
                followUpAt: Date? = nil, resolvedAt: Date? = nil) {
        self.id = id; self.blockerID = blockerID; self.round = round; self.triggeredAt = triggeredAt
        self.expectedResolution = expectedResolution; self.expectedDurationMinutes = expectedDurationMinutes
        self.followUpAt = followUpAt; self.resolvedAt = resolvedAt
    }
}
public struct AcceptanceResult: Codable, Sendable, Equatable {
    public var id: String; public var acceptanceID: String; public var round: Int
    public var state: AcceptanceState; public var date: Date; public var reason: String; public var reusedResultID: String?
    public init(id: String = UUID().uuidString, acceptanceID: String, round: Int, state: AcceptanceState,
                date: Date, reason: String = "", reusedResultID: String? = nil) {
        self.id = id; self.acceptanceID = acceptanceID; self.round = round; self.state = state
        self.date = date; self.reason = reason; self.reusedResultID = reusedResultID
    }
}
public struct SourceUse: Codable, Sendable, Equatable {
    public var dependencyID: String; public var source: DependencySource
    /// Historical inherited scope provenance; moving the same blocker/round does not change the condition itself.
    public var nodeID: String?
    public var sourceRound: Int; public var dependencyRevision: Int
    public init(dependencyID: String, source: DependencySource, sourceRound: Int, dependencyRevision: Int = 1, nodeID: String? = nil) {
        self.dependencyID = dependencyID; self.source = source; self.sourceRound = sourceRound
        self.dependencyRevision = dependencyRevision; self.nodeID = nodeID
    }
}
public struct ReviewRecord: Codable, Sendable, Equatable {
    public var id: String; public var itemID: String; public var date: Date; public var outcome: ReviewOutcome
    public var sources: [SourceUse]; public var note: String; public var currentSources: [SourceUse]?; public var round: Int?
    public init(id: String = UUID().uuidString, itemID: String, date: Date, outcome: ReviewOutcome,
                sources: [SourceUse] = [], note: String = "", currentSources: [SourceUse]? = nil, round: Int? = nil) {
        self.id = id; self.itemID = itemID; self.date = date; self.outcome = outcome
        self.sources = sources; self.note = note; self.currentSources = currentSources; self.round = round
    }
}
public struct NextActionChoice: Codable, Sendable, Equatable {
    public var id: String; public var itemID: String?; public var date: Date; public var note: String
    public var trial: TrialResult?; public var displayedItemIDs: [String]
    public var dataVersion: String?; public var impactWasVerified: Bool
    public init(id: String = UUID().uuidString, itemID: String?, date: Date, note: String = "",
                trial: TrialResult? = nil, displayedItemIDs: [String] = [],
                dataVersion: String? = nil, impactWasVerified: Bool = false) {
        self.id = id; self.itemID = itemID; self.date = date; self.note = note; self.trial = trial
        self.displayedItemIDs = displayedItemIDs; self.dataVersion = dataVersion; self.impactWasVerified = impactWasVerified
    }
}
public struct EffortSummary: Codable, Sendable, Equatable {
    public var confirmedMinutes: Int; public var unresolvedSessionIDs: [String]
    public var effectiveSessionIDs: [String]; public var recordingIsComplete: Bool
    public init(confirmedMinutes: Int, unresolvedSessionIDs: [String], effectiveSessionIDs: [String], recordingIsComplete: Bool) {
        self.confirmedMinutes = confirmedMinutes; self.unresolvedSessionIDs = unresolvedSessionIDs
        self.effectiveSessionIDs = effectiveSessionIDs; self.recordingIsComplete = recordingIsComplete
    }
}

/// A deduplicated factual invalidation scope; computing it has no side effects.
public struct DomainInvalidation: Codable, Sendable, Equatable {
    public var itemIDs: Set<String>
    public var nodeIDs: Set<String>
    public var projectIDs: Set<String>
    public init(itemIDs: Set<String> = [], nodeIDs: Set<String> = [], projectIDs: Set<String> = []) {
        self.itemIDs = itemIDs; self.nodeIDs = nodeIDs; self.projectIDs = projectIDs
    }
}
