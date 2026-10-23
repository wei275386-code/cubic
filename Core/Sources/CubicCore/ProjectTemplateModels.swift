import Foundation

/// An independent content snapshot. Execution state and absolute scheduling dates have no representation here.
public struct ProjectTemplatePayload: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public let version: Int
    public let project: ProjectTemplateProject
    public let nodes: [ProjectTemplateNode]
    public let items: [ProjectTemplateWork]
    public let blockers: [ProjectTemplateBlocker]
    public let dependencies: [ProjectTemplateDependency]
    public let acceptances: [ProjectTemplateAcceptance]
    public let workLinks: [ProjectTemplateWorkLink]
    public init(version: Int = Self.currentVersion, project: ProjectTemplateProject,
                nodes: [ProjectTemplateNode] = [], items: [ProjectTemplateWork] = [],
                blockers: [ProjectTemplateBlocker] = [], dependencies: [ProjectTemplateDependency] = [],
                acceptances: [ProjectTemplateAcceptance] = [], workLinks: [ProjectTemplateWorkLink] = []) {
        self.version = version; self.project = project; self.nodes = nodes; self.items = items
        self.blockers = blockers; self.dependencies = dependencies; self.acceptances = acceptances; self.workLinks = workLinks
    }
    /// Indexed once for rendering. Alias positions refer to the same item/node IDs; never sum aliases as workload.
    public var structure: ProjectTemplateStructure { ProjectTemplateStructure(payload: self) }
}
public struct ProjectTemplateProject: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let description: String?
    public let importance: Int
    public let warningBufferMinutes: Int?
    public init(id: String = UUID().uuidString, name: String, description: String? = nil,
                importance: Int = 0, warningBufferMinutes: Int? = nil) {
        self.id = id; self.name = name; self.description = description
        self.importance = importance; self.warningBufferMinutes = warningBufferMinutes
    }
}
public struct ProjectTemplateNode: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let outcome: String?
    public let isRequired: Bool
    public let blockerIDs: [String]
    public var sequentialPredecessorNodeID: String?
    public let structureOrder: Int
    public init(id: String = UUID().uuidString, name: String, outcome: String? = nil,
                isRequired: Bool = true, blockerIDs: [String] = [], structureOrder: Int) {
        self.id = id; self.name = name; self.outcome = outcome; self.isRequired = isRequired
        self.blockerIDs = blockerIDs; self.structureOrder = structureOrder
    }
}
/// Date-only offsets use Calendar days in the declared source zone. Exact deadlines use seconds.
/// Instantiation maps both onto the supplied project deadline in the supplied destination zone.
public enum ProjectTemplateDeadlineRule: Codable, Sendable, Equatable {
    case calendarDays(Int)
    case seconds(TimeInterval)
}
public struct ProjectTemplateWork: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let description: String?
    public let nodeID: String?
    public let durationMinutes: Int
    public let energy: Energy
    public let requiresContinuous: Bool
    public let continuousMinutes: Int?
    public let contextTags: [String]
    public let isRequired: Bool
    public let deadlineRule: ProjectTemplateDeadlineRule?
    public let structureOrder: Int
    public init(id: String = UUID().uuidString, name: String, description: String? = nil, nodeID: String? = nil,
                durationMinutes: Int, energy: Energy = .normal, requiresContinuous: Bool = false,
                continuousMinutes: Int? = nil, contextTags: [String] = [], isRequired: Bool = true,
                deadlineRule: ProjectTemplateDeadlineRule? = nil, structureOrder: Int) {
        self.id = id; self.name = name; self.description = description; self.nodeID = nodeID
        self.durationMinutes = durationMinutes; self.energy = energy; self.requiresContinuous = requiresContinuous
        self.continuousMinutes = continuousMinutes; self.contextTags = contextTags; self.isRequired = isRequired
        self.deadlineRule = deadlineRule; self.structureOrder = structureOrder
    }
}
public struct ProjectTemplateBlocker: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let resolutionCondition: String?
    public let expectedDurationMinutes: Int?
    public let contactNote: String?
    public let followUpItemID: String?
    public init(id: String = UUID().uuidString, name: String, resolutionCondition: String? = nil,
                expectedDurationMinutes: Int? = nil, contactNote: String? = nil, followUpItemID: String? = nil) {
        self.id = id; self.name = name; self.resolutionCondition = resolutionCondition
        self.expectedDurationMinutes = expectedDurationMinutes; self.contactNote = contactNote; self.followUpItemID = followUpItemID
    }
}
public struct ProjectTemplateDependency: Codable, Sendable, Equatable {
    public let id: String
    public let source: DependencySource
    public let targetItemID: String
    public init(id: String = UUID().uuidString, source: DependencySource, targetItemID: String) {
        self.id = id; self.source = source; self.targetItemID = targetItemID
    }
}
public struct ProjectTemplateAcceptance: Codable, Sendable, Equatable {
    public let id: String
    public let subject: WorkReference
    public let name: String
    public let candidateItemIDs: [String]?
    public let candidateBlockerIDs: [String]?
    public init(id: String = UUID().uuidString, subject: WorkReference, name: String,
                candidateItemIDs: [String]? = nil, candidateBlockerIDs: [String]? = nil) {
        self.id = id; self.subject = subject; self.name = name
        self.candidateItemIDs = candidateItemIDs; self.candidateBlockerIDs = candidateBlockerIDs
    }
}
public struct ProjectTemplateWorkLink: Codable, Sendable, Equatable {
    public let id: String
    public let source: WorkReference
    public let nodeID: String?
    public let isRequired: Bool
    public let structureOrder: Int
    public init(id: String = UUID().uuidString, source: WorkReference, nodeID: String? = nil,
                isRequired: Bool = true, structureOrder: Int) {
        self.id = id; self.source = source; self.nodeID = nodeID; self.isRequired = isRequired; self.structureOrder = structureOrder
    }
}

/// Payload is immutable. nil means missing/unknown wire content, kept isolated from ordinary work.
/// Malformed wire content is preserved losslessly for backup and sync recovery.
public struct ProjectTemplate: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var title: String
    public let payload: ProjectTemplatePayload?
    public let createdAt: Date?
    public var renamedAt: Date?
    public var removedAt: Date?
    public var isArchived: Bool?
    public var archivedAt: Date?
    public let provenanceProjectName: String?
    /// Why this template cannot be used (for example an unrecognized payload).
    public internal(set) var availabilityIssue: String?
    private let unrecognizedPayload: JSONValue?
    public init(id: String = UUID().uuidString, title: String, payload: ProjectTemplatePayload,
                createdAt: Date? = nil, renamedAt: Date? = nil, removedAt: Date? = nil,
                isArchived: Bool? = nil, archivedAt: Date? = nil, provenanceProjectName: String? = nil) {
        self.id = id; self.title = title; self.payload = payload; self.createdAt = createdAt
        self.renamedAt = renamedAt; self.removedAt = removedAt; self.isArchived = isArchived
        self.archivedAt = archivedAt; self.provenanceProjectName = provenanceProjectName
        self.availabilityIssue = nil; self.unrecognizedPayload = nil
    }
    public var isRemoved: Bool { removedAt != nil }
    public var archived: Bool { isArchived == true }
    public var canInstantiate: Bool { validationIssues.isEmpty }
    public var validationIssues: [ProjectTemplateIssue] {
        var result: [ProjectTemplateIssue] = []
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(.init(code: .invalidPayload, message: "模板标题缺失", objectID: id))
        }
        if isRemoved { result.append(.init(code: .unavailableTemplate, message: "模板已删除", objectID: id)) }
        if archived { result.append(.init(code: .unavailableTemplate, message: "模板已归档", objectID: id)) }
        if let availabilityIssue { result.append(.init(code: .unavailableTemplate, message: availabilityIssue, objectID: id)) }
        guard let payload else {
            result.append(.init(code: .invalidPayload, message: "模板内容缺失或格式不受支持", objectID: id)); return result
        }
        do { try payload.validate() } catch {
            result.append(.init(code: .invalidPayload, message: String(describing: error), objectID: id))
        }
        return result
    }
    private enum CodingKeys: String, CodingKey {
        case id, title, payload, createdAt, renamedAt, removedAt, isArchived, archivedAt, provenanceProjectName, availabilityIssue
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        if let value = try? c.decode(ProjectTemplatePayload.self, forKey: .payload) {
            payload = value; unrecognizedPayload = nil
        } else {
            payload = nil; unrecognizedPayload = try c.decodeIfPresent(JSONValue.self, forKey: .payload)
        }
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        renamedAt = try c.decodeIfPresent(Date.self, forKey: .renamedAt)
        removedAt = try c.decodeIfPresent(Date.self, forKey: .removedAt)
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived)
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
        provenanceProjectName = try c.decodeIfPresent(String.self, forKey: .provenanceProjectName)
        availabilityIssue = try c.decodeIfPresent(String.self, forKey: .availabilityIssue)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(title, forKey: .title)
        if let payload { try c.encode(payload, forKey: .payload) }
        else { try c.encodeIfPresent(unrecognizedPayload, forKey: .payload) }
        try c.encodeIfPresent(createdAt, forKey: .createdAt); try c.encodeIfPresent(renamedAt, forKey: .renamedAt)
        try c.encodeIfPresent(removedAt, forKey: .removedAt); try c.encodeIfPresent(isArchived, forKey: .isArchived)
        try c.encodeIfPresent(archivedAt, forKey: .archivedAt); try c.encodeIfPresent(provenanceProjectName, forKey: .provenanceProjectName)
        try c.encodeIfPresent(availabilityIssue, forKey: .availabilityIssue)
    }
}
public enum ProjectTemplateIssueCode: String, Codable, Sendable, Equatable {
    case missingProject, excludedScope, externalWorkLink, externalDependency, missingBlocker
    case needsDeadlineAnchor, invalidDeadline, durationFallback, clearedBlockerDates, clearedExternalFollowUp
    case executionReset, invalidPayload, unavailableTemplate
}
public struct ProjectTemplateIssue: Codable, Sendable, Equatable {
    public let code: ProjectTemplateIssueCode
    public let message: String
    /// Source runtime ID in preview diagnostics only; never a payload reference.
    public let objectID: String?
    public init(code: ProjectTemplateIssueCode, message: String, objectID: String? = nil) {
        self.code = code; self.message = message; self.objectID = objectID
    }
}
public struct ProjectTemplatePreview: Codable, Sendable, Equatable {
    public let payload: ProjectTemplatePayload?
    public let errors: [ProjectTemplateIssue]
    public let warnings: [ProjectTemplateIssue]
    public let needsDeadlineAnchor: Bool
    public var canSave: Bool { payload != nil && errors.isEmpty && !needsDeadlineAnchor }
    public init(payload: ProjectTemplatePayload?, errors: [ProjectTemplateIssue] = [],
                warnings: [ProjectTemplateIssue] = [], needsDeadlineAnchor: Bool = false) {
        self.payload = payload; self.errors = errors; self.warnings = warnings; self.needsDeadlineAnchor = needsDeadlineAnchor
    }
}
public struct ProjectTemplateStructure: Sendable, Equatable {
    public let nodes: [ProjectTemplateNode]
    public let itemsByID: [String: ProjectTemplateWork]
    public let nodesByID: [String: ProjectTemplateNode]
    public let membersByNode: [String: [ProjectTemplateWork]]
    public let directItems: [ProjectTemplateWork]
    public let linksByNode: [String: [ProjectTemplateWorkLink]]
    public let directLinks: [ProjectTemplateWorkLink]
    public init(payload: ProjectTemplatePayload) {
        nodes = Workspace.inStructureOrder(payload.nodes, order: { $0.structureOrder })
        itemsByID = payload.items.reduce(into: [:]) { $0[$1.id] = $1 }
        nodesByID = payload.nodes.reduce(into: [:]) { $0[$1.id] = $1 }
        var members: [String: [ProjectTemplateWork]] = [:], direct: [ProjectTemplateWork] = []
        for item in Workspace.inStructureOrder(payload.items, order: { $0.structureOrder }) {
            if let node = item.nodeID { members[node, default: []].append(item) } else { direct.append(item) }
        }
        membersByNode = members; directItems = direct
        var links: [String: [ProjectTemplateWorkLink]] = [:], directAliases: [ProjectTemplateWorkLink] = []
        for link in Workspace.inStructureOrder(payload.workLinks, order: { $0.structureOrder }) {
            if let node = link.nodeID { links[node, default: []].append(link) } else { directAliases.append(link) }
        }
        linksByNode = links; directLinks = directAliases
    }
}
