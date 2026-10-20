import Foundation

public struct CapacitySlot: Codable, Sendable, Equatable {
    public var start: Date; public var end: Date; public var energy: Energy
    public init(start: Date, end: Date, energy: Energy = .normal) { self.start = start; self.end = end; self.energy = energy }
}
public struct BusyInterval: Codable, Sendable, Equatable {
    public var start: Date; public var end: Date
    public init(start: Date, end: Date) { self.start = start; self.end = end }
}
public enum BlockReason: Codable, Sendable, Equatable {
    case dependency(String), acceptance(String), needsReview
}
public struct ItemState: Codable, Sendable, Equatable {
    public var itemID: String; public var isBlocked: Bool; public var reasons: [BlockReason]
    public init(itemID: String, isBlocked: Bool, reasons: [BlockReason]) {
        self.itemID = itemID; self.isBlocked = isBlocked; self.reasons = reasons
    }
}
public struct AvailableAction: Codable, Sendable, Equatable {
    public var itemID: String; public var remainingMinutes: Int?; public var canFit: Bool?
    public var compatibleMinutes: Int; public var longestContinuousMinutes: Int
    public init(itemID: String, remainingMinutes: Int?, canFit: Bool?, compatibleMinutes: Int, longestContinuousMinutes: Int) {
        self.itemID = itemID; self.remainingMinutes = remainingMinutes; self.canFit = canFit
        self.compatibleMinutes = compatibleMinutes; self.longestContinuousMinutes = longestContinuousMinutes
    }
}
public enum RiskKind: String, Codable, Sendable, Equatable {
    case provenCapacityShortfall, conditionalUnlock, sharedResourceConflict
    case insufficientInformation, energyConstraint, continuousConstraint
}
public enum Feasibility: String, Codable, Sendable, Equatable { case feasible, infeasible, undetermined }
public struct Risk: Codable, Sendable, Equatable {
    public var kind: RiskKind; public var projectID: String?; public var itemIDs: [String]
    public var shortageMinutes: Int?; public var message: String
    public init(kind: RiskKind, projectID: String? = nil, itemIDs: [String] = [], shortageMinutes: Int? = nil, message: String) {
        self.kind = kind; self.projectID = projectID; self.itemIDs = itemIDs
        self.shortageMinutes = shortageMinutes; self.message = message
    }
}
public struct ProjectAssessment: Codable, Sendable, Equatable {
    public var projectID: String; public var demandMinutes: Int?; public var capacityMinutes: Int
    public var shortageMinutes: Int?; public var feasibility: Feasibility; public var conditionalItemIDs: [String]
    public init(projectID: String, demandMinutes: Int?, capacityMinutes: Int, shortageMinutes: Int?,
                feasibility: Feasibility, conditionalItemIDs: [String] = []) {
        self.projectID = projectID; self.demandMinutes = demandMinutes; self.capacityMinutes = capacityMinutes
        self.shortageMinutes = shortageMinutes; self.feasibility = feasibility; self.conditionalItemIDs = conditionalItemIDs
    }
}
public struct EngineSnapshot: Codable, Sendable, Equatable {
    public var availableActions: [AvailableAction]; public var itemStates: [ItemState]; public var risks: [Risk]
    public var projects: [ProjectAssessment]; public var capacityMinutes: Int; public var feasibility: Feasibility
    public init(availableActions: [AvailableAction], itemStates: [ItemState], risks: [Risk], projects: [ProjectAssessment],
                capacityMinutes: Int, feasibility: Feasibility) {
        self.availableActions = availableActions; self.itemStates = itemStates; self.risks = risks; self.projects = projects
        self.capacityMinutes = capacityMinutes; self.feasibility = feasibility
    }
}
public struct TrialSelection: Codable, Sendable, Equatable {
    public var itemID: String; public var minutes: Int
    public init(itemID: String, minutes: Int) { self.itemID = itemID; self.minutes = minutes }
}
public struct TrialAllocation: Codable, Sendable, Equatable {
    public var itemID: String; public var start: Date; public var end: Date
    public init(itemID: String, start: Date, end: Date) { self.itemID = itemID; self.start = start; self.end = end }
}
public struct TrialResult: Codable, Sendable, Equatable {
    public var selections: [TrialSelection]; public var allocations: [TrialAllocation]
    public var unallocatedMinutes: Int; public var snapshot: EngineSnapshot
    /// nil when decoding schema-1 legacy decisions. New single-item trials preserve exact inputs/impacts.
    public var planning: PlanningTrialResult?
    public init(selections: [TrialSelection], allocations: [TrialAllocation], unallocatedMinutes: Int, snapshot: EngineSnapshot,
                planning: PlanningTrialResult? = nil) {
        self.selections = selections; self.allocations = allocations
        self.unallocatedMinutes = unallocatedMinutes; self.snapshot = snapshot
        self.planning = planning
    }
}
