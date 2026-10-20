import Foundation

/// Decodes operation headers/deltas without decoding any legacy immutableWorkspace object.
/// Legacy files remain on disk; only their delta enters resident memory or transport.
struct SyncOperationEnvelope: Decodable {
    let formatVersion: Int
    let id: String
    let workspaceID: String
    let deviceID: String
    let parents: [String]
    let createdAt: Date
    let changes: [SyncChange]
    var revision: SyncRevision {
        SyncRevision(id: id, workspaceID: workspaceID, deviceID: deviceID,
            parents: parents, createdAt: createdAt, changes: changes)
    }
    static func decode(_ data: Data) throws -> SyncRevision {
        let value = try SyncCoding.decode(Self.self, from: data)
        guard [1, 2].contains(value.formatVersion) else { throw SyncError.invalidJournal("revision format") }
        return value.revision
    }
}

struct SyncCausalFrontier {
    let closedIDs: Set<String>
    let stagedIDs: Set<String>
    let missingParentIDs: Set<String>
    init(_ revisions: [String: SyncRevision], workspaceID: String) throws {
        var degrees: [String: Int] = [:], children: [String: [String]] = [:], missing = Set<String>()
        for revision in revisions.values {
            try Self.validate(revision, workspaceID: workspaceID)
            degrees[revision.id] = 0
            for parent in revision.parents {
                if revisions[parent] == nil { missing.insert(parent) }
                else { degrees[revision.id, default: 0] += 1; children[parent, default: []].append(revision.id) }
            }
        }
        var queue = degrees.keys.filter { degrees[$0] == 0 }.sorted(), position = 0, closed = Set<String>()
        while position < queue.count {
            let id = queue[position]; position += 1
            if revisions[id]!.parents.allSatisfy({ closed.contains($0) }) { closed.insert(id) }
            for child in children[id] ?? [] {
                degrees[child, default: 0] -= 1
                if degrees[child] == 0 { queue.append(child) }
            }
        }
        guard queue.count == revisions.count else { throw SyncError.invalidJournal("cyclic causal parents") }
        closedIDs = closed; stagedIDs = Set(revisions.keys).subtracting(closed); missingParentIDs = missing
    }
    static func validate(_ r: SyncRevision, workspaceID: String) throws {
        guard r.workspaceID == workspaceID else { throw SyncError.wrongWorkspace(r.workspaceID) }
        guard [1, 2].contains(r.formatVersion), !r.id.isEmpty, r.id.utf8.count <= 110, !r.deviceID.isEmpty,
              !r.parents.contains(r.id), Set(r.parents).count == r.parents.count,
              r.parents.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 110 }),
              r.createdAt.timeIntervalSince1970.isFinite,
              Set(r.changes.map(\.path)).count == r.changes.count else { throw SyncError.invalidJournal(r.id) }
    }
}
