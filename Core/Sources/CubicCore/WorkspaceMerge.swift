/// Three-way merge of workspace facts and portable settings.
enum WorkspaceMerge {
    static func merge(base: JSONValue, local: JSONValue, remote: JSONValue, preferLocal: Bool) -> (value: JSONValue, conflicted: Bool) {
        var conflicted = false
        func mergeValue(_ base: JSONValue?, _ local: JSONValue?, _ remote: JSONValue?) -> JSONValue? {
            if local == base { return remote }
            if remote == base || local == remote { return local }
            if case .object(let b) = base, case .object(let l) = local, case .object(let r) = remote {
                var result: [String: JSONValue] = [:]
                for key in Set(b.keys).union(l.keys).union(r.keys) {
                    result[key] = mergeValue(b[key], l[key], r[key])
                }
                return .object(result)
            }
            if case .array(let b) = base ?? .array([]), case .array(let l) = local, case .array(let r) = remote,
               (b + l + r).allSatisfy({ $0.object?["id"]?.string != nil }) {
                let bases = Dictionary(b.map { ($0.object!["id"]!.string!, $0) }, uniquingKeysWith: { _, last in last })
                let locals = Dictionary(l.map { ($0.object!["id"]!.string!, $0) }, uniquingKeysWith: { _, last in last })
                let remotes = Dictionary(r.map { ($0.object!["id"]!.string!, $0) }, uniquingKeysWith: { _, last in last })
                var result: [JSONValue] = []
                var seen: Set<String> = []
                for element in l + r {
                    let id = element.object!["id"]!.string!
                    guard seen.insert(id).inserted else { continue }
                    let value: JSONValue?
                    if let original = bases[id], locals[id] == nil, let edited = remotes[id], edited != original {
                        value = edited
                    } else if let original = bases[id], remotes[id] == nil, let edited = locals[id], edited != original {
                        value = edited
                    } else { value = mergeValue(bases[id], locals[id], remotes[id]) }
                    if let value { result.append(value) }
                }
                return .array(result)
            }
            conflicted = true
            return preferLocal ? local : remote
        }
        let value = mergeValue(base, local, remote)!
        return (value, conflicted)
    }
}
