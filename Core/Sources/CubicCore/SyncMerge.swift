import Foundation

struct SyncDocument {
    static func preference(_ field: String) -> SyncPath { SyncPath(collection: "@preferences", entityID: "user", field: field) }
    static let existence = "@exists"
    static let execution = "@execution"
    static let deadline = "@deadline"
    static let nodeSequence = "@nodeSequence"
    static let templateContent = "@templateContent"
    static let templateMetadata: Set<String> = ["title", "createdAt", "renamedAt", "removedAt", "isArchived", "archivedAt", "provenanceProjectName"]
    static let deadlineFields: Set<String> = ["deadline", "deadlineTimeZoneIdentifier", "deadlineTimeZoneID", "deadlineIsDateOnly"]
    static let choice = SyncPath(collection: "@sync", entityID: "workspace", field: "currentChoiceID")
    static let facts: Set<String> = ["history", "workSessions", "decisions", "estimateRevisions", "acceptanceResults", "reviews", "choices", "deletedItems"]
    // Everything else in a stateful entity is grouped, including future Domain round fields.
    static let independent: Set<String> = ["name", "title", "description", "detail", "notes", "note", "importance",
        "warningMarginMinutes", "warningBufferMinutes", "energy",
        "requiresContinuous", "continuousMinutes", "contextTags", "isFocused", "isArchived", "structureOrder", "sequentialDependenciesInitialized",
        "followUpDate", "contactNote", "expectedWaitMinutes"]
    var values: [SyncPath: SyncValue]
    init(_ workspace: Workspace, choice: String?) throws {
        guard let root = try SyncCoding.decode(SyncValue.self, from: SyncCoding.encode(workspace)).object else {
            throw SyncError.invalidJournal("Workspace is not an object")
        }
        values = [:]
        let projectNodes = Dictionary(grouping: workspace.nodes, by: \.projectID)
        for (collection, value) in root {
            if collection == "currentChoiceID" { continue }
            if case .array(let entities) = value,
               !entities.isEmpty && entities.allSatisfy({ $0.object?["id"]?.string != nil }) {
                for entity in entities {
                    let object = entity.object!, id = object["id"]!.string!
                    guard !id.isEmpty, values[SyncPath(collection: collection, entityID: id, field: Self.existence)] == nil else {
                        throw SyncError.identityCollision("\(collection)/\(id)")
                    }
                    values[SyncPath(collection: collection, entityID: id, field: Self.existence)] = .bool(true)
                    if collection == "projects" {
                        let sequence = (projectNodes[id] ?? []).sorted { ($0.structureOrder ?? Int.max, $0.id) < ($1.structureOrder ?? Int.max, $1.id) }.map(NodeSequenceEntry.init)
                        values[SyncPath(collection: collection, entityID: id, field: Self.nodeSequence)] = try SyncCoding.decode(SyncValue.self, from: SyncCoding.encode(sequence))
                    }
                    if collection == "projectTemplates" {
                        // Immutable snapshot is one register. Metadata can be edited without rewriting graph content.
                        values[SyncPath(collection: collection, entityID: id, field: Self.templateContent)] =
                            .object(["payload": object["payload"] ?? .null])
                        for field in Self.templateMetadata {
                            if let value = object[field] { values[SyncPath(collection: collection, entityID: id, field: field)] = value }
                        }
                    } else if Self.facts.contains(collection) {
                        values[SyncPath(collection: collection, entityID: id, field: "@fact")] = entity
                    } else {
                        var group: [String: SyncValue] = [:], deadlineGroup: [String: SyncValue] = [:]
                        for (field, fieldValue) in object where field != "id" {
                            // The complete project permutation is one causal register. Legacy per-node fields remain readable.
                            if collection == "nodes", ["structureOrder", "sequentialPredecessorNodeID"].contains(field) { continue }
                            if Self.deadlineFields.contains(field) { deadlineGroup[field] = fieldValue }
                            else if Self.independent.contains(field) {
                                values[SyncPath(collection: collection, entityID: id, field: field)] = fieldValue
                            } else { group[field] = fieldValue }
                        }
                        values[SyncPath(collection: collection, entityID: id, field: Self.execution)] = .object(group)
                        values[SyncPath(collection: collection, entityID: id, field: Self.deadline)] = .object(deadlineGroup)
                    }
                }
            } else if case .array(let entities) = value, entities.isEmpty {
                // Empty collections have no operation. Decoding uses Workspace.empty defaults.
            } else { values[SyncPath(collection: "@workspace", entityID: "workspace", field: collection)] = value }
        }
        values[Self.choice] = (choice ?? workspace.currentChoiceID).map(SyncValue.string) ?? .null
    }
    static func changes(from old: SyncDocument?, to new: SyncDocument) -> [SyncChange] {
        let before = old?.values ?? [:]
        return Set(before.keys).union(new.values.keys).sorted().compactMap { path in
            // Missing additive collection (legacy-shaped writeback) never implies deletion.
            // Template deletion is an explicit removedAt metadata operation.
            if path.collection == "projectTemplates", new.values[SyncPath(collection: path.collection, entityID: path.entityID, field: existence)] == nil { return nil }
            let value = new.values[path] ?? (path.field == existence ? .bool(false) : .null)
            if facts.contains(path.collection), new.values[path] == nil { return nil }
            // Deletion writes a tombstone only; keep last entity fields for recovery.
            if path.field != existence, !path.collection.hasPrefix("@"),
               new.values[SyncPath(collection: path.collection, entityID: path.entityID, field: existence)] == nil { return nil }
            return before[path] == value ? nil : SyncChange(path: path, value: value)
        }
    }
    static func workspace(_ values: [SyncPath: SyncValue]) throws -> Workspace {
        var root = try SyncCoding.decode(SyncValue.self, from: SyncCoding.encode(Workspace.empty)).object!
        var objects: [String: [String: [String: SyncValue]]] = [:]
        for (path, value) in values.sorted(by: { $0.key < $1.key }) {
            if path.collection == "@workspace" { root[path.field] = value; continue }
            guard !path.collection.hasPrefix("@"), path.field != existence,
                  values[SyncPath(collection: path.collection, entityID: path.entityID, field: existence)] != .bool(false) else { continue }
            if path.field == "@fact", let object = value.object { objects[path.collection, default: [:]][path.entityID] = object }
            else if [execution, deadline, templateContent].contains(path.field), let group = value.object {
                for (field, v) in group { objects[path.collection, default: [:]][path.entityID, default: ["id": .string(path.entityID)]][field] = v }
            } else if !path.field.hasPrefix("@"), value != .null {
                objects[path.collection, default: [:]][path.entityID, default: ["id": .string(path.entityID)]][path.field] = value
            }
        }
        // Partial template registers remain visible as unavailable identities instead of breaking Workspace decoding.
        for (path, value) in values where path.collection == "projectTemplates" && path.field == existence && value == .bool(true) {
            if objects[path.collection]?[path.entityID] == nil {
                objects[path.collection, default: [:]][path.entityID] = ["id": .string(path.entityID)]
            }
        }
        for (collection, entities) in objects {
            root[collection] = .array(entities.keys.sorted().map { .object(entities[$0]!) })
        }
        root["currentChoiceID"] = values[choice] ?? .null
        var workspace = try SyncCoding.decode(Workspace.self, from: SyncCoding.encode(SyncValue.object(root)))
        try applyNodeSequences(values, to: &workspace)
        // Imported structures retain Markdown order after every local save, sync and restore.
        // Legacy entities keep the existing deterministic ID order.
        workspace.nodes.sort { ($0.structureOrder ?? Int.max, $0.id) < ($1.structureOrder ?? Int.max, $1.id) }
        workspace.items.sort { ($0.structureOrder ?? Int.max, $0.id) < ($1.structureOrder ?? Int.max, $1.id) }
        workspace.workLinks?.sort { ($0.structureOrder ?? Int.max, $0.id) < ($1.structureOrder ?? Int.max, $1.id) }
        // Explicit deletion wins for interactive identity, including offline concurrent edits.
        // Original edits remain in causal registers for audit/conflict comparison.
        let deletedIDs = Set((workspace.deletedItems ?? []).map(\.id))
        workspace.items.removeAll { deletedIDs.contains($0.id) }
        if !deletedIDs.isEmpty {
            // Tombstones also defeat concurrently CREATED interactive references.
            // This is a deterministic projection only; registers/rawValues keep the delta.
            let dates = Dictionary(grouping: workspace.history.filter { $0.kind == .deleted }, by: \.objectID)
                .mapValues { $0.map(\.date).max() ?? Date(timeIntervalSince1970: 0) }
            let deletionTime = dates.values.max() ?? Date(timeIntervalSince1970: 0)
            var before = workspace
            before.items += workspace.deletedItems ?? []
            var roots: [DependencySource] = [], projects = Set<String>()
            for i in workspace.dependencies.indices where workspace.dependencies[i].isActive {
                let dependency = workspace.dependencies[i]
                let sourceDeleted: Bool
                if case .item(let id) = dependency.source { sourceDeleted = deletedIDs.contains(id) } else { sourceDeleted = false }
                if sourceDeleted || deletedIDs.contains(dependency.targetItemID) {
                    workspace.dependencies[i].removedAt = max(deletionTime, dependency.effectiveAt ?? deletionTime)
                    if !deletedIDs.contains(dependency.targetItemID) { roots.append(.item(dependency.targetItemID)) }
                }
            }
            if var links = workspace.workLinks {
                for i in links.indices where links[i].removedAt == nil {
                    if case .item(let id) = links[i].source, deletedIDs.contains(id) {
                        links[i].removedAt = dates[id] ?? deletionTime
                        projects.insert(links[i].projectID)
                        if let nodeID = links[i].nodeID { roots.append(.node(nodeID)) }
                    }
                }
                workspace.workLinks = links
            }
            for i in workspace.acceptances.indices {
                if case .item(let id) = workspace.acceptances[i].subject, deletedIDs.contains(id) {
                    workspace.acceptances[i].removedAt = workspace.acceptances[i].removedAt ?? dates[id] ?? deletionTime
                }
                workspace.acceptances[i].candidateItemIDs?.removeAll { deletedIDs.contains($0) }
            }
            for i in workspace.blockers.indices where workspace.blockers[i].followUpItemID.map(deletedIDs.contains) == true {
                workspace.blockers[i].followUpItemID = nil
            }
            workspace.timeBlocks?.removeAll { deletedIDs.contains($0.itemID) }
            if workspace.currentNextAction?.itemID.map(deletedIDs.contains) == true { workspace.currentChoiceID = nil }
            if !roots.isEmpty {
                let impact = DomainIndex(before).invalidationClosure(of: roots, includeSources: true)
                let current = DomainIndex(workspace)
                for i in workspace.items.indices where impact.itemIDs.contains(workspace.items[i].id) && workspace.items[i].status != .pending {
                    let item = workspace.items[i]
                    let reviewed = (workspace.reviews ?? []).contains { review in
                        review.itemID == item.id && review.round == item.currentRound && review.outcome == .stillValid && review.date >= deletionTime &&
                        review.currentSources.map { effectiveSourceConditionsMatch($0, current.sourcesUsed(for: item.id)) } == true
                    }
                    if !reviewed { workspace.items[i].needsReview = true }
                }
                for i in workspace.nodes.indices where impact.nodeIDs.contains(workspace.nodes[i].id) {
                    if workspace.nodes[i].completedAt != nil { workspace.nodes[i].needsReview = true; workspace.nodes[i].completedAt = nil }
                }
                projects.formUnion(impact.projectIDs)
            }
            for i in workspace.projects.indices where projects.contains(workspace.projects[i].id) && workspace.projects[i].effectiveStatus == .completed {
                workspace.projects[i].status = .active; workspace.projects[i].completedAt = nil
            }
        }
        return workspace
    }
}

public enum SyncMerge {
    /// Causal register merge. Dates and arrival order never choose authoritative winners.
    public static func merge(revisions: [SyncRevision], workspaceID: String) throws -> SyncMergeResult {
        try merge(revisions: revisions, workspaceID: workspaceID, preparedRegisters: nil)
    }
    static func merge(revisions: [SyncRevision], workspaceID: String,
                      preparedRegisters: [SyncPath: [SyncCandidate]]?) throws -> SyncMergeResult {
        var byID: [String: SyncRevision] = [:]
        for r in revisions {
            guard r.workspaceID == workspaceID else { throw SyncError.wrongWorkspace(r.workspaceID) }
            try SyncCausalFrontier.validate(r, workspaceID: workspaceID)
            if let old = byID[r.id], !old.hasSameOperation(as: r) { throw SyncError.identityCollision(r.id) }
            byID[r.id] = r
        }
        var children: [String: [String]] = [:], degrees: [String: Int] = [:]
        for r in byID.values {
            degrees[r.id] = r.parents.count
            for p in r.parents {
                guard byID[p] != nil else { throw SyncError.missingParent(p) }
                children[p, default: []].append(r.id)
            }
        }
        var queue = degrees.keys.filter { degrees[$0] == 0 }.sorted(), cursor = 0
        while cursor < queue.count {
            let id = queue[cursor]; cursor += 1
            for child in (children[id] ?? []).sorted() {
                degrees[child, default: 0] -= 1
                if degrees[child] == 0 { queue.append(child) }
            }
        }
        guard queue.count == byID.count else { throw SyncError.invalidJournal("cyclic causal parents") }
        var ancestryMemo: [String: [String: Bool]] = [:]
        func isAncestor(_ ancestor: String, of id: String) -> Bool {
            if let cached = ancestryMemo[id]?[ancestor] { return cached }
            var seen = Set<String>(), pending = byID[id]?.parents ?? [], position = 0
            while position < pending.count {
                let parent = pending[position]; position += 1
                if parent == ancestor { ancestryMemo[id, default: [:]][ancestor] = true; return true }
                if seen.insert(parent).inserted { pending.append(contentsOf: byID[parent]?.parents ?? []) }
            }
            ancestryMemo[id, default: [:]][ancestor] = false; return false
        }
        var registers: [SyncPath: [SyncCandidate]] = preparedRegisters ?? [:]
        for id in preparedRegisters == nil ? queue : [] {
            let r = byID[id]!
            for change in r.changes {
                let path = change.path
                var candidates = registers[path] ?? []
                candidates.removeAll { isAncestor($0.revisionID, of: id) }
                candidates.append(SyncCandidate(revisionID: id, value: change.value))
                registers[path] = candidates
            }
        }
        var values: [SyncPath: SyncValue] = [:], conflicts: [SyncConflict] = []
        for path in registers.keys.sorted() {
            let candidates = registers[path]!.sorted { $0.revisionID < $1.revisionID }
            values[path] = candidates.first!.value // stable tentative rendering ONLY; conflict never resolved by this.
            if candidates.contains(where: { $0.value != candidates.first!.value }) {
                conflicts.append(SyncConflict(kind: .concurrentValue, paths: [path], candidates: candidates,
                    message: "并发修改，当前值未确认；请比较各设备上下文后选择。"))
            }
        }
        // A tombstone cannot destroy retained edits or facts that still refer to an entity.
        var workspace = try SyncDocument.workspace(values)
        let deleted = values.keys.filter { $0.field == SyncDocument.existence && values[$0] == .bool(false) }
        for path in deleted.sorted() {
            let tombstones = registers[path] ?? []
            let concurrentEdit = registers.contains { entry in
                entry.key.collection == path.collection && entry.key.entityID == path.entityID && entry.key.field != SyncDocument.existence &&
                entry.value.contains { edit in tombstones.contains { tomb in
                    !isAncestor(edit.revisionID, of: tomb.revisionID) && !isAncestor(tomb.revisionID, of: edit.revisionID) && tomb.revisionID != edit.revisionID
                } }
            }
            let referenced = references(workspace, collection: path.collection, id: path.entityID)
            if concurrentEdit || referenced {
                if path.collection == "items", workspace.deletedItems?.contains(where: { $0.id == path.entityID }) == true {
                    if concurrentEdit {
                        conflicts.append(SyncConflict(kind: .deletionReference, paths: [path], candidates: tombstones,
                            message: "工作已删除；并发修改保留在审计中，不重新进入工作列表。"))
                    }
                    continue
                }
                values[path] = .bool(true)
                workspace = try SyncDocument.workspace(values)
                conflicts.append(SyncConflict(kind: .deletionReference, paths: [path], candidates: tombstones,
                    message: "删除与修改、引用或保留历史冲突；对象保留可恢复，需明确整理引用后再删除。"))
            }
        }
        workspace = try SyncDocument.workspace(values)
        // Template conflicts and invalid snapshots affect only template availability.
        // Raw content remains in registers/backups; ordinary Domain planning remains usable.
        if var templates = workspace.projectTemplates {
            let disputedTemplateIDs = Set(conflicts.flatMap(\.paths).filter { $0.collection == "projectTemplates" }.map(\.entityID))
            for index in templates.indices {
                let id = templates[index].id
                let disputed = disputedTemplateIDs.contains(id)
                if disputed { templates[index].availabilityIssue = "模板存在未处理的同步冲突，请到设置处理后再使用。" }
                let contentPath = SyncPath(collection: "projectTemplates", entityID: id, field: SyncDocument.templateContent)
                do {
                    guard let payload = templates[index].payload else { throw CoreError.invalid("模板内容缺失或格式不受支持") }
                    try payload.validate()
                } catch {
                    templates[index].availabilityIssue = String(describing: error)
                    conflicts.append(SyncConflict(kind: .invariant, paths: [contentPath], candidates: registers[contentPath] ?? [],
                        message: "模板内容已隔离：\(error)。现有项目继续使用。"))
                }
            }
            workspace.projectTemplates = templates
        }
        let graph = expandedGraph(workspace)
        let components = stronglyConnected(graph.edges)
        var quarantine = Set<String>(), quarantineLinks = Set<String>()
        for component in components where component.count > 1 || component.contains(where: { graph.edges[$0]?.contains($0) == true }) {
            let paths = graph.relationEdges.filter { entry in entry.value.contains { component.contains($0.0) && component.contains($0.1) } }.map(\.key).sorted()
            quarantine.formUnion(paths.filter { $0.collection == "dependencies" }.map(\.entityID))
            quarantineLinks.formUnion(paths.filter { $0.collection == "workLinks" }.map(\.entityID))
            let candidates = paths.flatMap { registers[$0] ?? [] }
            let cycleItems = Set(component.filter { $0.hasPrefix("i:") }.map { String($0.dropFirst(2)) })
                .union(component.filter { $0.hasPrefix("n:") }.flatMap { vertex in workspace.items.filter { $0.nodeID == String(vertex.dropFirst(2)) }.map(\.id) })
            conflicts.append(SyncConflict(kind: .dependencyCycle, paths: paths, candidates: candidates,
                affectedItemIDs: cycleItems.sorted(), message: "合并关系形成循环：\(cycleWitness(component, edges: graph.edges).joined(separator: " → "))。关系隔离，相关精确推算暂停。"))
        }
        // A projection disables quarantined edges, while journal keeps every original relationship.
        var planning = workspace, relationKeys = Set<String>()
        for index in planning.dependencies.indices {
            let d = planning.dependencies[index]
            guard d.isActive else { continue }
            let key = (try? SyncCoding.encode(d.source).base64EncodedString()) ?? ""
            if quarantine.contains(d.id) || !relationKeys.insert(key + ":" + d.targetItemID).inserted {
                planning.dependencies[index].removedAt = Date(timeIntervalSince1970: 0) // computation-only sentinel, never a factual edit
                quarantine.insert(d.id)
            }
        }
        if var links = planning.workLinks {
            for index in links.indices where quarantineLinks.contains(links[index].id) { links[index].removedAt = Date(timeIntervalSince1970: 0) }
            planning.workLinks = links
        }
        // Same business round/correction can be created with distinct UUIDs on offline devices.
        // Retain both raw records; choose a tentative effective projection and pause only their subject.
        var quarantinedRecords = Set<SyncPath>()
        func semanticGroups<T: Encodable>(_ records: [T], collection: String, correctionField: String? = nil,
                                             key: (T) -> String?) throws -> Set<String> {
            let encoded = try records.map { try SyncCoding.decode(SyncValue.self, from: SyncCoding.encode($0)) }
            let byEntity = Dictionary(uniqueKeysWithValues: encoded.compactMap { value -> (String, SyncValue)? in
                value.object?["id"]?.string.map { ($0, value) }
            })
            var descendants: [String: [String]] = [:]
            if let correctionField {
                for (id, value) in byEntity {
                    if let parent = value.object?[correctionField]?.string { descendants[parent, default: []].append(id) }
                }
            }
            func branch(_ root: String) -> Set<String> {
                var visited: Set<String> = [root], queue = [root], position = 0
                while position < queue.count {
                    let id = queue[position]; position += 1
                    for child in descendants[id] ?? [] where visited.insert(child).inserted { queue.append(child) }
                }
                return visited
            }
            var excluded = Set<String>()
            for id in byEntity.keys where values[SyncPath(collection: collection, entityID: id, field: "@effective")] == .bool(false) {
                excluded.formUnion(branch(id))
            }
            let groups = Dictionary(grouping: records.compactMap { record -> (String, SyncValue)? in
                guard let k = key(record), let value = try? SyncCoding.decode(SyncValue.self, from: SyncCoding.encode(record)) else { return nil }
                return (k, value)
            }, by: { $0.0 })
            // Visit correction groups from ancestors to descendants. Never emit conflicts inside an
            // already quarantined branch; choosing the branch later exposes its own internal choices.
            func depth(_ id: String) -> Int {
                guard let correctionField else { return 0 }
                var cursor = id, seen = Set<String>(), count = 0
                while seen.insert(cursor).inserted, let parent = byEntity[cursor]?.object?[correctionField]?.string {
                    count += 1; cursor = parent
                }
                return count
            }
            let ordered = groups.keys.sorted {
                let left = depth($0), right = depth($1); return left == right ? $0 < $1 : left < right
            }
            for groupKey in ordered {
                let entities = groups[groupKey]!.map { $0.1 }.filter { value in
                    guard let id = value.object?["id"]?.string else { return false }
                    return !excluded.contains(id)
                }.sorted { ($0.object?["id"]?.string ?? "") < ($1.object?["id"]?.string ?? "") }
                guard entities.count > 1 else { continue }
                let paths = entities.compactMap { $0.object?["id"]?.string }.map {
                    SyncPath(collection: collection, entityID: $0, field: "@effective")
                }
                for path in paths.dropFirst() { excluded.formUnion(branch(path.entityID)) }
                let candidates = entities.flatMap { entity -> [SyncCandidate] in
                    guard let id = entity.object?["id"]?.string else { return [] }
                    return (registers[SyncPath(collection: collection, entityID: id, field: SyncDocument.existence)] ?? []).map {
                        SyncCandidate(revisionID: $0.revisionID, value: entity)
                    }
                }
                let itemIDs = entities.compactMap { $0.object?["itemID"]?.string }
                let blockerIDs = entities.compactMap { $0.object?["blockerID"]?.string }
                var affectedItems = Set(itemIDs).union(workspace.dependencies.filter { blockerIDs.contains($0.source.id) }.map(\.targetItemID))
                if collection == "history" || collection == "blockerRounds" {
                    var subjectVertices = Set(paths.flatMap { subjectSeeds(workspace, path: $0) })
                    subjectVertices.formUnion(affectedItems.map { "i:" + $0 })
                    let reached = graphClosure(seeds: subjectVertices, edges: graph.edges)
                    affectedItems.formUnion(reached.filter { $0.hasPrefix("i:") }.map { String($0.dropFirst(2)) })
                }
                conflicts.append(SyncConflict(kind: .semanticRecord, paths: paths, candidates: candidates,
                    affectedItemIDs: affectedItems.sorted(), message: "同一轮次或更正分支出现并发版本；原始事实与全部后续更正保留，选择完整分支后计入统计。"))
            }
            for id in excluded {
                quarantinedRecords.insert(SyncPath(collection: collection, entityID: id, field: SyncDocument.existence))
            }
            return excluded
        }
        let excludedWorkRounds = try semanticGroups(workspace.workRounds ?? [], collection: "workRounds") { "\($0.itemID):\($0.round)" }
        let excludedBlockerRounds = try semanticGroups(workspace.blockerRounds ?? [], collection: "blockerRounds") { "\($0.blockerID):\($0.round)" }
        let excludedSessions = try semanticGroups(workspace.workSessions, collection: "workSessions", correctionField: "correctsSessionID") { $0.correctsSessionID }
        let excludedEstimates = try semanticGroups(workspace.estimateRevisions ?? [], collection: "estimateRevisions", correctionField: "correctsRevisionID") { $0.correctsRevisionID }
        let excludedHistory = try semanticGroups(workspace.history, collection: "history", correctionField: "correctsEventID") { $0.correctsEventID }
        planning.workRounds = planning.workRounds?.filter { !excludedWorkRounds.contains($0.id) }
        planning.blockerRounds = planning.blockerRounds?.filter { !excludedBlockerRounds.contains($0.id) }
        planning.workSessions.removeAll { excludedSessions.contains($0.id) }
        planning.estimateRevisions = planning.estimateRevisions?.filter { !excludedEstimates.contains($0.id) }
        // Raw history/audit stays complete; only disputed correction branches are excluded from
        // effective interpretation. Closure keeps later corrections from referencing an absent source.
        planning.history.removeAll { excludedHistory.contains($0.id) }
        var linkKeys = Set<String>()
        if var links = planning.workLinks {
            for index in links.indices where links[index].removedAt == nil {
                let link = links[index]
                let key = try SyncCoding.encode(link.source).base64EncodedString() + ":" + link.projectID + ":" + (link.nodeID ?? "")
                if !linkKeys.insert(key).inserted { links[index].removedAt = Date(timeIntervalSince1970: 0); quarantineLinks.insert(link.id) }
            }
            planning.workLinks = links
        }
        // Detect a downstream completion/start racing an upstream rework, even when neither
        // device changed the same register. Compare consumed rounds AND causal source context.
        let domain = DomainIndex(planning)
        var projectionReviews = Set<String>()
        for itemIndex in planning.items.indices {
            let item = planning.items[itemIndex]
            guard !item.needsReview, item.status == .completed || item.status == .inProgress else { continue }
            let itemPath = SyncPath(collection: "items", entityID: item.id, field: SyncDocument.execution)
            let itemVersions = registers[itemPath] ?? []
            let consumed = (planning.workRounds ?? []).first { $0.itemID == item.id && $0.round == item.currentRound }?.sources ?? []
            let current = domain.sourcesUsed(for: item.id)
            var changedPaths: [SyncPath] = []
            for use in (consumed.isEmpty ? current : consumed) {
                let sourcePath: SyncPath
                switch use.source {
                case .item(let id): sourcePath = SyncPath(collection: "items", entityID: id, field: SyncDocument.execution)
                case .node(let id): sourcePath = SyncPath(collection: "nodes", entityID: id, field: SyncDocument.execution)
                case .blocker(let id): sourcePath = SyncPath(collection: "blockers", entityID: id, field: SyncDocument.execution)
                }
                let sequencePath = nodeSequenceDependencyParts(use.dependencyID).flatMap { parts in
                    domain.nodes[parts.nodeID].map { SyncPath(collection: "projects", entityID: $0.projectID, field: SyncDocument.nodeSequence) }
                }
                let sourceVersions = (registers[sourcePath] ?? []) + (registers[SyncPath(collection: "dependencies", entityID: use.dependencyID, field: SyncDocument.execution)] ?? []) + (sequencePath.flatMap { registers[$0] } ?? [])
                let sourceWasNotObserved = sourceVersions.contains { source in itemVersions.contains { item in
                    source.revisionID != item.revisionID && !isAncestor(source.revisionID, of: item.revisionID)
                } }
                let nowUse = current.first { $0.dependencyID == use.dependencyID }
                let stale = nowUse != use || !domain.sourceSatisfied(use.source)
                guard stale && sourceWasNotObserved else { continue }
                let reviewed = (planning.reviews ?? []).contains { review in
                    guard review.itemID == item.id, review.outcome == .stillValid,
                          (review.currentSources ?? review.sources).sorted(by: { $0.dependencyID < $1.dependencyID }) == current.sorted(by: { $0.dependencyID < $1.dependencyID }) else { return false }
                    let versions = registers[SyncPath(collection: "reviews", entityID: review.id, field: "@fact")] ?? []
                    return versions.contains { owner in sourceVersions.allSatisfy {
                        $0.revisionID == owner.revisionID || isAncestor($0.revisionID, of: owner.revisionID)
                    } }
                }
                if !reviewed {
                    changedPaths.append(sourcePath)
                    if let sequencePath { changedPaths.append(sequencePath) }
                    changedPaths.append(SyncPath(collection: "dependencies", entityID: use.dependencyID, field: SyncDocument.execution))
                }
            }
            if !changedPaths.isEmpty {
                planning.items[itemIndex].needsReview = true; projectionReviews.insert(item.id)
                conflicts.append(SyncConflict(kind: .invariant, paths: [itemPath],
                    candidates: itemVersions + changedPaths.flatMap { registers[$0] ?? [] }, affectedItemIDs: [item.id],
                    message: "该成果/开工与前置变更并发，使用过的来源轮次或上下文已变化；事实保留，请确认仍适用或局部返工。"))
            }
        }
        var paused = Set<String>(), seeds = Set<String>()
        for conflict in conflicts {
            paused.formUnion(conflict.affectedItemIDs)
            for path in conflict.paths {
                paused.formUnion(affected(workspace, path: path))
                seeds.formUnion(subjectSeeds(workspace, path: path))
            }
        }
        // Downstream closure only, including node gates and shared-reference paths.
        seeds.formUnion(paused.map { "i:" + $0 })
        let visited = graphClosure(seeds: seeds, edges: graph.edges)
        paused.formUnion(visited.filter { $0.hasPrefix("i:") }.map { String($0.dropFirst(2)) })
        // Raw history is retained; only ambiguous effective round/correction views are isolated.
        var valid = true
        do { try planning.validate() } catch {
            valid = false
            // A cross-register domain invariant must be explicit; never silently assert merge succeeded.
            let message = String(describing: error)
            let involved = registers.keys.filter { path in !path.entityID.isEmpty && message.contains(path.entityID) }.sorted()
            let affectedItems = Set(involved.flatMap { affected(workspace, path: $0) })
            paused.formUnion(affectedItems)
            conflicts.append(SyncConflict(kind: .invariant, paths: involved,
                candidates: involved.flatMap { registers[$0] ?? [] }, affectedItemIDs: affectedItems.sorted(),
                message: "Domain 投影校验尚未成立：\(error)。事实已保留；请复核对应状态。"))
        }
        let heads = byID.keys.filter { children[$0]?.isEmpty != false }.sorted()
        let selected = workspace.currentChoiceID
        let choiceConflict = conflicts.contains { $0.paths.contains(SyncDocument.choice) }
        planning.currentChoiceID = choiceConflict ? nil : selected
        return SyncMergeResult(preferences: Dictionary(uniqueKeysWithValues: values.compactMap { path, value in
                guard path.collection == "@preferences", path.entityID == "user",
                      !conflicts.contains(where: { $0.paths.contains(path) }) else { return nil }
                return (path.field, value)
            }),
            workspace: workspace, planningWorkspace: planning,
            currentChoiceID: choiceConflict ? nil : selected, conflicts: conflicts.sorted { $0.id < $1.id },
            pausedItemIDs: paused, quarantinedDependencyIDs: quarantine, quarantinedWorkLinkIDs: quarantineLinks, quarantinedRecordPaths: quarantinedRecords, projectionReviewItemIDs: projectionReviews, heads: heads, planningIsValid: valid, registers: registers, rawValues: values)
    }

    private static func references(_ w: Workspace, collection: String, id: String) -> Bool {
        if collection == "items", w.deletedItems?.contains(where: { $0.id == id }) == true { return false }
        if w.history.contains(where: { $0.objectID == id || ($0.relatedIDs ?? []).contains(id) }) { return true }
        let links = w.workLinks ?? []
        if collection == "items", links.contains(where: { $0.source == .item(id) }) { return true }
        if collection == "nodes", links.contains(where: { $0.nodeID == id || $0.source == .node(id) }) { return true }
        if collection == "projects", links.contains(where: { $0.projectID == id }) { return true }
        if collection == "items" {
            if (w.estimateRevisions ?? []).contains(where: { $0.itemID == id }) || (w.workRounds ?? []).contains(where: { $0.itemID == id }) ||
               (w.reviews ?? []).contains(where: { $0.itemID == id }) || (w.choices ?? []).contains(where: { $0.itemID == id || $0.displayedItemIDs.contains(id) }) ||
               w.blockers.contains(where: { $0.followUpItemID == id }) || w.acceptances.contains(where: { ($0.candidateItemIDs ?? []).contains(id) }) { return true }
        }
        if collection == "blockers", (w.blockerRounds ?? []).contains(where: { $0.blockerID == id }) ||
           w.nodes.contains(where: { ($0.blockerIDs ?? []).contains(id) }) || w.acceptances.contains(where: { ($0.candidateBlockerIDs ?? []).contains(id) }) { return true }
        if collection == "acceptances", (w.acceptanceResults ?? []).contains(where: { $0.acceptanceID == id }) { return true }
        if collection == "dependencies", (w.workRounds ?? []).contains(where: { ($0.sources ?? []).contains { $0.dependencyID == id } }) ||
           (w.reviews ?? []).contains(where: { $0.sources.contains { $0.dependencyID == id } }) { return true }
        switch collection {
        case "projects": return w.nodes.contains { $0.projectID == id } || w.items.contains { $0.projectIDs.contains(id) }
        case "nodes": return w.nodes.contains { $0.sequentialPredecessorNodeID == id } || w.items.contains { $0.nodeID == id } || w.dependencies.contains { $0.isActive && $0.source == .node(id) } || w.acceptances.contains { $0.subject == .node(id) }
        case "items": return w.workSessions.contains { $0.itemID == id } || w.dependencies.contains { $0.isActive && ($0.targetItemID == id || $0.source == .item(id)) } || w.acceptances.contains { $0.subject == .item(id) } || w.decisions.contains { $0.trial.selections.contains { $0.itemID == id } }
        case "blockers": return w.dependencies.contains { $0.isActive && $0.source == .blocker(id) }
        default: return false
        }
    }
    private static func affected(_ w: Workspace, path: SyncPath) -> Set<String> {
        if ["name", "title", "description", "detail", "notes", "note", "isArchived", "isFocused", "contextTags"].contains(path.field) { return [] }
        switch path.collection {
        case "items": return [path.entityID]
        case "nodes": return Set(w.items.filter { $0.nodeID == path.entityID }.map(\.id)).union(w.dependencies.filter { $0.source == .node(path.entityID) }.map(\.targetItemID))
        case "projects": return Set(w.items.filter { $0.projectIDs.contains(path.entityID) }.map(\.id))
        case "blockers": return Set(w.dependencies.filter { $0.source == .blocker(path.entityID) }.map(\.targetItemID))
        case "dependencies": return Set(w.dependencies.filter { $0.id == path.entityID }.map(\.targetItemID))
        case "acceptances":
            return Set(w.acceptances.filter { $0.id == path.entityID }.flatMap { a in
                switch a.subject { case .item(let id): return [id]; case .node(let id): return w.items.filter { $0.nodeID == id }.map(\.id) }
            })
        case "history":
            // History identities are separate from their subjects. Pause the corrected subject and
            // its downstream work, never every item merely because history is a shared collection.
            return w.history.filter { $0.id == path.entityID }.reduce(into: Set<String>()) { result, event in
                let subject = event.objectID
                let collection: String?
                if w.items.contains(where: { $0.id == subject }) { collection = "items" }
                else if w.nodes.contains(where: { $0.id == subject }) { collection = "nodes" }
                else if w.projects.contains(where: { $0.id == subject }) { collection = "projects" }
                else if w.blockers.contains(where: { $0.id == subject }) { collection = "blockers" }
                else { collection = nil }
                if let collection {
                    result.formUnion(affected(w, path: SyncPath(collection: collection, entityID: subject, field: SyncDocument.execution)))
                }
            }
        case "workSessions": return Set(w.workSessions.filter { $0.id == path.entityID }.map(\.itemID))
        case "workRounds": return Set((w.workRounds ?? []).filter { $0.id == path.entityID }.map(\.itemID))
        case "blockerRounds": return Set(w.dependencies.filter { d in (w.blockerRounds ?? []).contains { $0.id == path.entityID && $0.blockerID == d.source.id } }.map(\.targetItemID))
        case "estimateRevisions": return Set((w.estimateRevisions ?? []).filter { $0.id == path.entityID }.map(\.itemID))
        case "workLinks": return Set((w.workLinks ?? []).filter { $0.id == path.entityID }.flatMap { link in
            w.items.filter { $0.nodeID == link.nodeID || $0.projectIDs.contains(link.projectID) }.map(\.id)
        })
        default: return []
        }
    }
    /// Preserve the actual subject vertex until AFTER graph traversal. In particular a blocker
    /// can gate only a node, with no direct item dependency at all.
    private static func subjectSeeds(_ w: Workspace, path: SyncPath) -> Set<String> {
        if ["name", "title", "description", "detail", "notes", "note", "isArchived", "isFocused", "contextTags"].contains(path.field) { return [] }
        switch path.collection {
        case "projects":
            guard path.field == SyncDocument.nodeSequence else { return [] }
            return Set(w.nodes.filter { $0.projectID == path.entityID }.map { "n:" + $0.id })
        case "nodes": return ["n:" + path.entityID]
        case "blockers": return ["b:" + path.entityID]
        case "blockerRounds": return Set((w.blockerRounds ?? []).filter { $0.id == path.entityID }.map { "b:" + $0.blockerID })
        case "history":
            return w.history.filter { $0.id == path.entityID }.reduce(into: Set<String>()) { seeds, event in
                let id = event.objectID
                if w.items.contains(where: { $0.id == id }) { seeds.insert("i:" + id) }
                if w.nodes.contains(where: { $0.id == id }) { seeds.insert("n:" + id) }
                if w.blockers.contains(where: { $0.id == id }) { seeds.insert("b:" + id) }
                if w.projects.contains(where: { $0.id == id }) {
                    seeds.formUnion(w.items.filter { $0.projectIDs.contains(id) }.map { "i:" + $0.id })
                    seeds.formUnion(w.nodes.filter { $0.projectID == id }.map { "n:" + $0.id })
                }
            }
        default: return []
        }
    }
    private static func graphClosure(seeds: Set<String>, edges: [String: Set<String>]) -> Set<String> {
        var visited = seeds, pending = seeds.sorted(), position = 0
        while position < pending.count {
            let id = pending[position]; position += 1
            for target in edges[id] ?? [] where visited.insert(target).inserted { pending.append(target) }
        }
        return visited
    }
    private static func expandedGraph(_ w: Workspace) -> (edges: [String: Set<String>], relationEdges: [SyncPath: [(String, String)]]) {
        var edges: [String: Set<String>] = [:], relationEdges: [SyncPath: [(String, String)]] = [:]
        for item in w.items {
            edges["i:" + item.id, default: []] = []
            if let node = item.nodeID { edges["i:" + item.id, default: []].insert("n:" + node) }
        }
        let members = Dictionary(grouping: w.items, by: { $0.nodeID ?? "" })
        for node in w.nodes {
            if edges["n:" + node.id] == nil { edges["n:" + node.id] = [] }
            if let predecessor = node.sequentialPredecessorNodeID {
                let source = "n:" + predecessor
                let targets = ["n:" + node.id] + (members[node.id] ?? []).map { "i:" + $0.id }
                for target in targets { edges[source, default: []].insert(target) }
                relationEdges[SyncPath(collection: "projects", entityID: node.projectID, field: SyncDocument.nodeSequence), default: []].append(contentsOf: targets.map { (source, $0) })
            }
            for blocker in node.blockerIDs ?? [] { edges["b:" + blocker, default: []].insert("n:" + node.id) }
        }
        for d in w.dependencies where d.isActive {
            let source: String
            switch d.source { case .item(let id): source = "i:" + id; case .node(let id): source = "n:" + id; case .blocker(let id): source = "b:" + id }
            let target = "i:" + d.targetItemID
            edges[source, default: []].insert(target)
            relationEdges[SyncPath(collection: "dependencies", entityID: d.id, field: SyncDocument.execution), default: []].append((source, target))
        }
        for link in w.workLinks ?? [] where link.removedAt == nil && link.isRequired {
            guard let node = link.nodeID else { continue }
            let source: String
            switch link.source { case .item(let id): source = "i:" + id; case .node(let id): source = "n:" + id }
            let target = "n:" + node
            edges[source, default: []].insert(target)
            relationEdges[SyncPath(collection: "workLinks", entityID: link.id, field: SyncDocument.execution), default: []].append((source, target))
        }
        return (edges, relationEdges)
    }
    private static func cycleWitness(_ component: Set<String>, edges: [String: Set<String>]) -> [String] {
        guard let start = component.sorted().first else { return [] }
        for next in (edges[start] ?? []).intersection(component).sorted() {
            if next == start { return [start, start] }
            var queue = [next], position = 0, predecessor: [String: String] = [:], seen: Set<String> = [next]
            while position < queue.count {
                let id = queue[position]; position += 1
                for target in (edges[id] ?? []).intersection(component).sorted() {
                    if target == start {
                        var path = [id], cursor = id
                        while let prior = predecessor[cursor] { path.append(prior); cursor = prior }
                        return [start] + path.reversed() + [start]
                    }
                    if seen.insert(target).inserted { predecessor[target] = id; queue.append(target) }
                }
            }
        }
        return component.sorted()
    }
    /// Iterative Kosaraju avoids recursion overflow for long user-created dependency chains.
    private static func stronglyConnected(_ edges: [String: Set<String>]) -> [Set<String>] {
        var seen = Set<String>(), order: [String] = []
        for root in edges.keys.sorted() where !seen.contains(root) {
            var stack: [(String, Bool)] = [(root, false)]
            while let (id, exiting) = stack.popLast() {
                if exiting { order.append(id); continue }
                guard seen.insert(id).inserted else { continue }
                stack.append((id, true))
                for target in (edges[id] ?? []).sorted().reversed() where !seen.contains(target) { stack.append((target, false)) }
            }
        }
        var reverse: [String: Set<String>] = [:]
        for (source, targets) in edges { for target in targets { reverse[target, default: []].insert(source) } }
        seen = []; var result: [Set<String>] = []
        for root in order.reversed() where !seen.contains(root) {
            var component = Set<String>(), pending = [root]
            while let id = pending.popLast() {
                guard seen.insert(id).inserted else { continue }
                component.insert(id); pending.append(contentsOf: reverse[id] ?? [])
            }
            result.append(component)
        }
        return result
    }
}

extension SyncRevision {
    /// Pure capture helper for QA/device simulation; no clock/store/network side effects when createdAt/id are supplied.
    public static func recording(workspace: Workspace, comparedTo previous: Workspace? = nil,
                                 previousChoiceID: String? = nil, currentChoiceID: String? = nil,
                                 id: String = UUID().uuidString, workspaceID: String, deviceID: String,
                                 parents: [String], createdAt: Date = Date()) throws -> SyncRevision {
        try workspace.validate()
        let old = try previous.map { try SyncDocument($0, choice: previousChoiceID) }
        let new = try SyncDocument(workspace, choice: currentChoiceID)
        return SyncRevision(id: id, workspaceID: workspaceID, deviceID: deviceID, parents: parents, createdAt: createdAt,
            changes: SyncDocument.changes(from: old, to: new))
    }
}
extension SyncMergeResult {
    /// Use with Engine.plan(workspace: planningWorkspace, input: planningInput(input)).
    /// A disputed branch remains unknown; unrelated branches still participate in planning.
    public func planningInput(_ input: PlanningInput) -> PlanningInput {
        var value = input
        let liveIDs = Set(planningWorkspace.items.map(\.id))
        value.options.disputedItemIDs = Set(input.options.disputedItemIDs).union(pausedItemIDs.intersection(liveIDs)).sorted()
        value.revision.workspace = (try? SyncCoding.encode(heads).base64EncodedString()) ?? heads.joined(separator: ",")
        return value
    }
}
