import Foundation

public enum CoreError: Error, Codable, Sendable, Equatable {
    case invalid(String), missing(String), blocked(String), cycle([String])
    case unsupportedSchema(Int), corruptData(String), storage(String)
}

public enum Energy: String, Codable, Sendable, Equatable {
    case low, normal, high
    public var rank: Int { switch self { case .low: 0; case .normal: 1; case .high: 2 } }
}
public enum WorkStatus: String, Codable, Sendable, Equatable { case pending, inProgress, completed }
public enum BlockerState: String, Codable, Sendable, Equatable { case inactive, active, resolved }
public enum AcceptanceState: String, Codable, Sendable, Equatable { case pending, accepted, failed }
public enum WorkReference: Codable, Sendable, Equatable {
    case item(String), node(String)
    public var id: String { switch self { case .item(let id), .node(let id): id } }
}
public enum DependencySource: Codable, Sendable, Equatable {
    case item(String), node(String), blocker(String)
    public var id: String { switch self { case .item(let id), .node(let id), .blocker(let id): id } }
}
public enum HistoryKind: String, Codable, Sendable, Equatable {
    case created, dependencyAdded, acceptanceAdded, started, effortRecorded
    case remainingUpdated, completed, reworked, reviewed, blockerTriggered
    case blockerResolved, accepted, decisionRecorded
    case edited, deadlineChanged, scopeChanged, dependencyChanged, dependencyRemoved
    case acceptanceChanged, acceptanceRemoved, acceptanceFailed, blockerUpdated
    case archived, restored, cancelled, deferred, estimateCorrected, effortCorrected
    case choiceRecorded, projectCompleted, nodeCompleted, baselineCaptured
    case deleted, timeBlockChanged
}
public struct Project: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var deadline: Date?
    public var importance: Int
    public var description: String?
    public var status: ProjectStatus?
    public var isArchived: Bool?
    public var planningCompleteness: PlanningCompleteness?
    public var warningBufferMinutes: Int?
    public var deadlineTimeZoneID: String?
    public var deadlineIsDateOnly: Bool?
    public var completedAt: Date?
    public var calendarIdentifier: String?
    public init(id: String = UUID().uuidString, name: String, deadline: Date? = nil, importance: Int = 0,
                description: String? = nil, status: ProjectStatus? = nil, isArchived: Bool? = nil, planningCompleteness: PlanningCompleteness? = nil, warningBufferMinutes: Int? = nil, deadlineTimeZoneID: String? = nil, deadlineIsDateOnly: Bool? = nil, completedAt: Date? = nil, calendarIdentifier: String? = nil) {
        self.id = id; self.name = name; self.deadline = deadline; self.importance = importance
        self.description = description
        self.status = status
        self.isArchived = isArchived
        self.planningCompleteness = planningCompleteness
        self.warningBufferMinutes = warningBufferMinutes
        self.deadlineTimeZoneID = deadlineTimeZoneID
        self.deadlineIsDateOnly = deadlineIsDateOnly
        self.completedAt = completedAt
        self.calendarIdentifier = calendarIdentifier
    }
}
public struct Node: Codable, Sendable, Equatable {
    public var id: String
    public var projectID: String
    public var name: String
    public var outcome: String?
    public var isRequired: Bool?
    public var planningCompleteness: PlanningCompleteness?
    public var isArchived: Bool?
    public var blockerIDs: [String]?
    public var completedAt: Date?
    public var needsReview: Bool?
    public var round: Int?
    /// Managed default prerequisite. Explicit item dependencies remain separate.
    public var sequentialPredecessorNodeID: String?
    /// Source order for structures created from Markdown; absent on legacy records.
    public var structureOrder: Int?
    /// One-time adoption of sequential work defaults; manual dependency edits remain authoritative.
    public var sequentialDependenciesInitialized: Bool?
    public init(id: String = UUID().uuidString, projectID: String, name: String,
                outcome: String? = nil, isRequired: Bool? = nil, planningCompleteness: PlanningCompleteness? = nil, isArchived: Bool? = nil, blockerIDs: [String]? = nil, completedAt: Date? = nil, needsReview: Bool? = nil, round: Int? = nil, structureOrder: Int? = nil) {
        self.id = id; self.projectID = projectID; self.name = name
        self.outcome = outcome
        self.isRequired = isRequired
        self.planningCompleteness = planningCompleteness
        self.isArchived = isArchived
        self.blockerIDs = blockerIDs
        self.completedAt = completedAt
        self.needsReview = needsReview
        self.round = round
        self.structureOrder = structureOrder
    }
}
public struct WorkItem: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var nodeID: String?
    public var projectIDs: [String]
    public var remainingMinutes: Int?
    public var initialMinutes: Int?
    public var energy: Energy
    public var requiresContinuous: Bool
    public var status: WorkStatus
    public var started: Date?
    public var completedAt: Date?
    public var needsReview: Bool
    public var description: String?
    public var deadline: Date?
    public var deadlineTimeZoneID: String?
    public var deadlineIsDateOnly: Bool?
    public var contextTags: [String]?
    public var isFocused: Bool?
    public var isRequired: Bool?
    public var disposition: WorkDisposition?
    public var isArchived: Bool?
    public var preStartMinutes: Int?
    public var preStartCapturedAt: Date?
    public var round: Int?
    public var effortRecordingComplete: Bool?
    public var continuousMinutes: Int?
    public var startTimeIsUnknown: Bool?
    /// Exact event that first captured initialMinutes; absent for legacy estimates with unknown origin.
    public var initialEstimateEventID: String?
    public var structureOrder: Int?
    public init(id: String = UUID().uuidString, name: String, nodeID: String? = nil,
                projectIDs: [String] = [], remainingMinutes: Int? = nil, initialMinutes: Int? = nil,
                energy: Energy = .normal, requiresContinuous: Bool = false, status: WorkStatus = .pending,
                started: Date? = nil, completedAt: Date? = nil, needsReview: Bool = false,
                description: String? = nil, deadline: Date? = nil, deadlineTimeZoneID: String? = nil, deadlineIsDateOnly: Bool? = nil, contextTags: [String]? = nil, isFocused: Bool? = nil, isRequired: Bool? = nil, disposition: WorkDisposition? = nil, isArchived: Bool? = nil, preStartMinutes: Int? = nil, preStartCapturedAt: Date? = nil, round: Int? = nil, effortRecordingComplete: Bool? = nil, continuousMinutes: Int? = nil, startTimeIsUnknown: Bool? = nil, initialEstimateEventID: String? = nil, structureOrder: Int? = nil) {
        self.id = id; self.name = name; self.nodeID = nodeID; self.projectIDs = projectIDs
        self.remainingMinutes = remainingMinutes; self.initialMinutes = initialMinutes; self.energy = energy
        self.requiresContinuous = requiresContinuous; self.status = status; self.started = started
        self.completedAt = completedAt; self.needsReview = needsReview
        self.description = description
        self.deadline = deadline
        self.deadlineTimeZoneID = deadlineTimeZoneID
        self.deadlineIsDateOnly = deadlineIsDateOnly
        self.contextTags = contextTags
        self.isFocused = isFocused
        self.isRequired = isRequired
        self.disposition = disposition
        self.isArchived = isArchived
        self.preStartMinutes = preStartMinutes
        self.preStartCapturedAt = preStartCapturedAt
        self.round = round
        self.effortRecordingComplete = effortRecordingComplete
        self.continuousMinutes = continuousMinutes
        self.startTimeIsUnknown = startTimeIsUnknown
        self.initialEstimateEventID = initialEstimateEventID
        self.structureOrder = structureOrder
    }
}
public struct Blocker: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var state: BlockerState
    public var expectedResolution: Date?
    public var triggeredAt: Date?
    public var resolvedAt: Date?
    public var resolutionCondition: String?
    public var expectedDurationMinutes: Int?
    public var followUpAt: Date?
    public var contactNote: String?
    public var followUpItemID: String?
    public var round: Int?
    public var isArchived: Bool?
    public init(id: String = UUID().uuidString, name: String, state: BlockerState = .inactive,
                expectedResolution: Date? = nil, triggeredAt: Date? = nil, resolvedAt: Date? = nil,
                resolutionCondition: String? = nil, expectedDurationMinutes: Int? = nil, followUpAt: Date? = nil, contactNote: String? = nil, followUpItemID: String? = nil, round: Int? = nil, isArchived: Bool? = nil) {
        self.id = id; self.name = name; self.state = state; self.expectedResolution = expectedResolution
        self.triggeredAt = triggeredAt; self.resolvedAt = resolvedAt
        self.resolutionCondition = resolutionCondition
        self.expectedDurationMinutes = expectedDurationMinutes
        self.followUpAt = followUpAt
        self.contactNote = contactNote
        self.followUpItemID = followUpItemID
        self.round = round
        self.isArchived = isArchived
    }
}
public struct Dependency: Codable, Sendable, Equatable {
    public var id: String
    public var source: DependencySource
    public var targetItemID: String
    public var createdAt: Date?
    public var effectiveAt: Date?
    public var removedAt: Date?
    public var revision: Int?
    public init(id: String = UUID().uuidString, source: DependencySource, targetItemID: String,
                createdAt: Date? = nil, effectiveAt: Date? = nil, removedAt: Date? = nil, revision: Int? = nil) {
        self.id = id; self.source = source; self.targetItemID = targetItemID
        self.createdAt = createdAt
        self.effectiveAt = effectiveAt
        self.removedAt = removedAt
        self.revision = revision
    }
}
public struct Acceptance: Codable, Sendable, Equatable {
    public var id: String
    public var subject: WorkReference
    public var name: String
    public var state: AcceptanceState
    public var acceptedAt: Date?
    public var isRequired: Bool?
    public var failedAt: Date?
    public var reason: String?
    public var candidateItemIDs: [String]?
    public var candidateBlockerIDs: [String]?
    public var round: Int?
    public var reworkScopeConfirmed: Bool?
    public var removedAt: Date?
    public init(id: String = UUID().uuidString, subject: WorkReference, name: String,
                state: AcceptanceState = .pending, acceptedAt: Date? = nil,
                isRequired: Bool? = nil, failedAt: Date? = nil, reason: String? = nil, candidateItemIDs: [String]? = nil, candidateBlockerIDs: [String]? = nil, round: Int? = nil, reworkScopeConfirmed: Bool? = nil, removedAt: Date? = nil) {
        self.id = id; self.subject = subject; self.name = name; self.state = state; self.acceptedAt = acceptedAt
        self.isRequired = isRequired
        self.failedAt = failedAt
        self.reason = reason
        self.candidateItemIDs = candidateItemIDs
        self.candidateBlockerIDs = candidateBlockerIDs
        self.round = round
        self.reworkScopeConfirmed = reworkScopeConfirmed
        self.removedAt = removedAt
    }
}
public struct HistoryEvent: Codable, Sendable, Equatable {
    public var id: String
    public var date: Date
    public var kind: HistoryKind
    public var objectID: String
    public var note: String
    public var minutes: Int?
    public var previousMinutes: Int?
    public var relatedIDs: [String]?
    public var round: Int?
    public var correctsEventID: String?
    public var changeReason: EstimateReason?
    public var detail: String?
    public init(id: String = UUID().uuidString, date: Date, kind: HistoryKind,
                objectID: String, note: String = "", minutes: Int? = nil,
                previousMinutes: Int? = nil, relatedIDs: [String]? = nil, round: Int? = nil, correctsEventID: String? = nil, changeReason: EstimateReason? = nil, detail: String? = nil) {
        self.id = id; self.date = date; self.kind = kind; self.objectID = objectID
        self.note = note; self.minutes = minutes
        self.previousMinutes = previousMinutes
        self.relatedIDs = relatedIDs
        self.round = round
        self.correctsEventID = correctsEventID
        self.changeReason = changeReason
        self.detail = detail
    }
}
public struct WorkSession: Codable, Sendable, Equatable {
    public var id: String
    public var itemID: String
    public var start: Date
    public var end: Date
    public var actualMinutes: Int
    public var remainingMinutesAfter: Int?
    /// nil preserves legacy exact records; false means start/end are the recording instant only.
    public var intervalIsExact: Bool?
    public var hasExactInterval: Bool { intervalIsExact != false }
    public var occurredOn: Date?
    public var recordedAt: Date?
    public var round: Int?
    public var correctsSessionID: String?
    public var isVoided: Bool?
    public var allocationGroupID: String?
    public init(id: String = UUID().uuidString, itemID: String, start: Date, end: Date,
                actualMinutes: Int, remainingMinutesAfter: Int? = nil, intervalIsExact: Bool? = nil,
                occurredOn: Date? = nil, recordedAt: Date? = nil, round: Int? = nil, correctsSessionID: String? = nil, isVoided: Bool? = nil, allocationGroupID: String? = nil) {
        self.id = id; self.itemID = itemID; self.start = start; self.end = end
        self.actualMinutes = actualMinutes; self.remainingMinutesAfter = remainingMinutesAfter
        self.intervalIsExact = intervalIsExact
        self.occurredOn = occurredOn
        self.recordedAt = recordedAt
        self.round = round
        self.correctsSessionID = correctsSessionID
        self.isVoided = isVoided
        self.allocationGroupID = allocationGroupID
    }
}
public struct Decision: Codable, Sendable, Equatable {
    public var id: String
    public var date: Date
    public var note: String
    public var trial: TrialResult
    public init(id: String = UUID().uuidString, date: Date, note: String = "", trial: TrialResult) {
        self.id = id; self.date = date; self.note = note; self.trial = trial
    }
}
public struct Workspace: Codable, Sendable, Equatable {
    public static let schemaVersion = 1
    public var schemaVersion: Int
    public var projects: [Project]
    public var nodes: [Node]
    public var items: [WorkItem]
    public var blockers: [Blocker]
    public var dependencies: [Dependency]
    public var acceptances: [Acceptance]
    public var history: [HistoryEvent]
    public var decisions: [Decision]
    public var workSessions: [WorkSession]
    public var workLinks: [WorkLink]?
    public var estimateRevisions: [EstimateRevision]?
    public var workRounds: [WorkRound]?
    public var blockerRounds: [BlockerRound]?
    public var acceptanceResults: [AcceptanceResult]?
    public var reviews: [ReviewRecord]?
    public var choices: [NextActionChoice]?
    public var currentChoiceID: String?
    /// Historical identities only. Never used as selectable work or planning demand.
    public var deletedItems: [WorkItem]?
    public var timeBlocks: [WorkTimeBlock]?
    /// Independent reusable content; never part of runtime planning demand. Absent on schema-1 legacy data.
    public var projectTemplates: [ProjectTemplate]?
    public init(schemaVersion: Int = Workspace.schemaVersion, projects: [Project] = [], nodes: [Node] = [],
                items: [WorkItem] = [], blockers: [Blocker] = [], dependencies: [Dependency] = [],
                acceptances: [Acceptance] = [], history: [HistoryEvent] = [], decisions: [Decision] = [],
                workSessions: [WorkSession] = [],
                workLinks: [WorkLink]? = nil, estimateRevisions: [EstimateRevision]? = nil, workRounds: [WorkRound]? = nil, blockerRounds: [BlockerRound]? = nil, acceptanceResults: [AcceptanceResult]? = nil, reviews: [ReviewRecord]? = nil, choices: [NextActionChoice]? = nil, currentChoiceID: String? = nil, deletedItems: [WorkItem]? = nil, timeBlocks: [WorkTimeBlock]? = nil, projectTemplates: [ProjectTemplate]? = nil) {
        self.schemaVersion = schemaVersion; self.projects = projects; self.nodes = nodes; self.items = items
        self.blockers = blockers; self.dependencies = dependencies; self.acceptances = acceptances
        self.history = history; self.decisions = decisions; self.workSessions = workSessions
        self.workLinks = workLinks
        self.estimateRevisions = estimateRevisions
        self.workRounds = workRounds
        self.blockerRounds = blockerRounds
        self.acceptanceResults = acceptanceResults
        self.reviews = reviews
        self.choices = choices
        self.currentChoiceID = currentChoiceID
        self.deletedItems = deletedItems; self.timeBlocks = timeBlocks
        self.projectTemplates = projectTemplates
    }
    public static var empty: Workspace { Workspace() }
    public static func demo(now: Date) -> Workspace {
        let deadline = now.addingTimeInterval(90 * 60)
        return Workspace(
            projects: [Project(id: "project-a", name: "A · 核心交付", deadline: deadline, importance: 5),
                       Project(id: "project-b", name: "B · 并行交付", deadline: deadline, importance: 4),
                       Project(id: "project-c", name: "C · 后续整合", deadline: deadline, importance: 3)],
            nodes: [Node(id: "node-a", projectID: "project-a", name: "核心实现"),
                    Node(id: "node-b", projectID: "project-b", name: "并行准备"),
                    Node(id: "node-c", projectID: "project-c", name: "整合发布")],
            items: [WorkItem(id: "item-a", name: "A：完成核心实现", nodeID: "node-a", projectIDs: ["project-a"], remainingMinutes: 60, initialMinutes: 60),
                    WorkItem(id: "item-b", name: "B：完成并行准备", nodeID: "node-b", projectIDs: ["project-b"], remainingMinutes: 60, initialMinutes: 60),
                    WorkItem(id: "item-c", name: "C：整合 A 的成果", nodeID: "node-c", projectIDs: ["project-c"], remainingMinutes: 30, initialMinutes: 30)],
            dependencies: [Dependency(id: "dependency-a-c", source: .item("item-a"), targetItemID: "item-c")]
        )
    }
}
