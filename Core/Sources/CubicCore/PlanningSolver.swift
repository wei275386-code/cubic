import Foundation

private struct PlanningHeap {
    var values: [String] = []
    let precedes: (String, String) -> Bool
    mutating func insert(_ value: String) {
        values.append(value); var index = values.count - 1
        while index > 0 {
            let parent = (index - 1) / 2
            guard precedes(values[index], values[parent]) else { break }
            values.swapAt(index, parent); index = parent
        }
    }
    mutating func pop() -> String? {
        guard !values.isEmpty else { return nil }
        if values.count == 1 { return values.removeLast() }
        let result = values[0]; values[0] = values.removeLast(); var index = 0
        while index * 2 + 1 < values.count {
            var child = index * 2 + 1
            if child + 1 < values.count && precedes(values[child + 1], values[child]) { child += 1 }
            guard precedes(values[child], values[index]) else { break }
            values.swapAt(child, index); index = child
        }
        return result
    }
}

struct PlanningSolution {
    var graph: PlanningGraph
    var pool: PlanningPool
    var input: PlanningInput
    var earliestStarts: [String: Date] = [:]
    var earliestFinishes: [String: Date] = [:]
    var latestStarts: [String: Date] = [:]
    var latestFinishes: [String: Date] = [:]
    var uncertainPath: Set<String> = []
    var uncertainBoundary: Set<String> = []

    init(graph: PlanningGraph, pool: PlanningPool, input: PlanningInput) {
        self.graph = graph; self.pool = pool; self.input = input
        // Optimistic logical pass: each labor vertex gets its own copy of the capacity.
        // This is a release LOWER bound, never a simultaneous schedule proof.
        for key in graph.order {
            guard let vertex = graph.vertices[key] else { continue }
            if vertex.unknown || vertex.predecessors.contains(where: { uncertainPath.contains($0) }) { uncertainPath.insert(key) }
            let release = max(input.now, vertex.notBefore ?? input.now,
                              vertex.predecessors.compactMap { earliestFinishes[$0] }.max() ?? input.now)
            earliestStarts[key] = release
            if vertex.kind == .item && vertex.knownSeconds > 0 {
                var individual = pool
                let allocation = individual.allocate(itemID: vertex.objectID, seconds: vertex.knownSeconds,
                    energy: vertex.energy, continuous: vertex.continuous, start: release, end: input.horizonEnd)
                if let finish = allocation.last?.end { earliestFinishes[key] = finish }
                else { uncertainPath.insert(key) }
            } else { earliestFinishes[key] = max(release.addingTimeInterval(vertex.lag), vertex.minimumFinish ?? release) }
        }
        // Reverse dependency bounds use successor start, not just deadline minus own labor.
        for key in graph.order.reversed() {
            guard let vertex = graph.vertices[key], let deadline = graph.deadlines[key], deadline <= input.horizonEnd else { continue }
            if vertex.unknown || vertex.successors.contains(where: { uncertainBoundary.contains($0) }) { uncertainBoundary.insert(key) }
            if let fixed = vertex.fixedEventAt { latestStarts[key] = fixed; latestFinishes[key] = fixed; continue }
            let constrained = vertex.successors.compactMap { latestStarts[$0] }.min() ?? deadline
            let end = min(deadline, constrained)
            if vertex.successors.contains(where: { graph.deadlines[$0] != nil && latestStarts[$0] == nil }) { continue }
            if vertex.kind == .item && vertex.knownSeconds > 0 {
                var individual = pool
                let allocation = individual.allocate(itemID: vertex.objectID, seconds: vertex.knownSeconds,
                    energy: vertex.energy, continuous: vertex.continuous, start: input.now,
                    end: end, backwards: true)
                if let start = allocation.first?.start, let finish = allocation.last?.end {
                    latestStarts[key] = start; latestFinishes[key] = finish
                }
            } else {
                latestStarts[key] = end.addingTimeInterval(-vertex.lag); latestFinishes[key] = end
            }
        }
    }

    /// A deterministic candidate is an explanation, not a priority/commitment or a proof of failure.
    func witness(keys: Set<String>, backwards: Bool = false) -> PlanningWitness {
        var free = pool, eventTimes: [String: Date] = [:], starts: [String: Date] = [:]
        var allocations: [TrialAllocation] = [], complete = true
        var degrees: [String: Int] = [:]
        for key in keys {
            let vertex = graph.vertices[key]
            degrees[key] = (backwards ? vertex?.successors : vertex?.predecessors)?.intersection(keys).count ?? 0
        }
        var heap = PlanningHeap(precedes: { lhs, rhs in
            let left = graph.deadlines[lhs] ?? input.horizonEnd, right = graph.deadlines[rhs] ?? input.horizonEnd
            if left != right { return backwards ? left > right : left < right }
            let a = graph.vertices[lhs], b = graph.vertices[rhs]
            if a?.continuous != b?.continuous { return a?.continuous == true }
            if a?.energy.rank != b?.energy.rank { return (a?.energy.rank ?? 0) > (b?.energy.rank ?? 0) }
            return lhs < rhs
        })
        for key in keys.sorted() where degrees[key] == 0 { heap.insert(key) }
        var visited = 0
        while let key = heap.pop(), let vertex = graph.vertices[key] {
            visited += 1
            let related = (backwards ? vertex.successors : vertex.predecessors).intersection(keys)
            let limit = min(graph.deadlines[key] ?? input.horizonEnd, input.horizonEnd)
            if vertex.unknown { complete = false }
            if graph.deadlines[key].map({ $0 > input.horizonEnd }) == true { complete = false }
            if backwards {
                let end = min(limit, related.compactMap { starts[$0] }.min() ?? limit)
                if related.contains(where: { starts[$0] == nil }) { complete = false }
                if let fixed = vertex.fixedEventAt {
                    starts[key] = fixed; eventTimes[key] = fixed
                    if fixed > end { complete = false }
                } else if vertex.actual {
                    starts[key] = input.now; eventTimes[key] = input.now
                } else if vertex.kind == .item && vertex.knownSeconds > 0 {
                    let release = max(input.now, vertex.notBefore ?? input.now, earliestStarts[key] ?? input.now)
                    let allocated = free.allocate(itemID: vertex.objectID, seconds: vertex.knownSeconds,
                        energy: vertex.energy, continuous: vertex.continuous, start: release, end: end, backwards: true)
                    if let start = allocated.first?.start, let finish = allocated.last?.end {
                        starts[key] = start; eventTimes[key] = finish; allocations.append(contentsOf: allocated)
                    } else { complete = false }
                } else {
                    let start = end.addingTimeInterval(-vertex.lag)
                    if start < max(input.now, vertex.notBefore ?? input.now) || end < (vertex.minimumFinish ?? input.now) { complete = false }
                    starts[key] = start; eventTimes[key] = end
                }
            } else {
                let start = max(input.now, vertex.notBefore ?? input.now, related.compactMap { eventTimes[$0] }.max() ?? input.now)
                if related.contains(where: { eventTimes[$0] == nil }) { complete = false }
                if let fixed = vertex.fixedEventAt {
                    starts[key] = fixed; eventTimes[key] = fixed
                    if start > fixed || fixed > limit { complete = false }
                } else if vertex.actual {
                    starts[key] = input.now; eventTimes[key] = input.now
                } else if vertex.kind == .item && vertex.knownSeconds > 0 {
                    let allocated = free.allocate(itemID: vertex.objectID, seconds: vertex.knownSeconds,
                        energy: vertex.energy, continuous: vertex.continuous, start: start, end: limit)
                    if let first = allocated.first?.start, let last = allocated.last?.end {
                        starts[key] = first; eventTimes[key] = last; allocations.append(contentsOf: allocated)
                    } else { complete = false }
                } else {
                    let end = max(start.addingTimeInterval(vertex.lag), vertex.minimumFinish ?? start)
                    if end > limit { complete = false }
                    starts[key] = start; eventTimes[key] = end
                }
            }
            for next in (backwards ? vertex.predecessors : vertex.successors).intersection(keys) {
                degrees[next, default: 0] -= 1
                if degrees[next] == 0 { heap.insert(next) }
            }
        }
        // Validate a reverse candidate against precedence after all predecessor times exist.
        for key in keys {
            guard let vertex = graph.vertices[key], !vertex.actual else { continue }
            if let start = starts[key] {
                for predecessor in vertex.predecessors.intersection(keys) {
                    if let finish = eventTimes[predecessor], finish > start { complete = false }
                }
            }
        }
        allocations.sort { $0.start == $1.start ? $0.itemID < $1.itemID : $0.start < $1.start }
        return PlanningWitness(allocations: allocations, eventTimes: eventTimes,
            conditionIDs: graph.conditionIDs(for: keys), isComplete: complete && visited == keys.count)
    }

    func certificates(keys: Set<String>, projectID: String? = nil) -> [PlanningCertificate] {
        let capacity = PlanningCapacityIndex(pool: pool)
        let labor = keys.compactMap { graph.vertices[$0] }.filter {
            $0.kind == .item && $0.knownSeconds > 0 && graph.deadlines[$0.key].map { $0 <= input.horizonEnd } == true
        }.sorted { graph.deadlines[$0.key, default: input.horizonEnd] < graph.deadlines[$1.key, default: input.horizonEnd] }
        var result: [PlanningCertificate] = []
        var owners: [String: [String]] = [:]
        for project in graph.projectRequirements.keys.sorted() {
            for key in graph.projectRequirements[project] ?? [] { owners[key, default: []].append(project) }
        }
        func certificate(_ constrained: [PlanningVertex], start: Date, end: Date, energy: Energy,
                         available: Double, kind: PlanningCertificateKind) -> PlanningCertificate? {
            let demand = constrained.reduce(0) { $0 + $1.knownSeconds }
            guard demand > available + 0.0001 else { return nil }
            let projects = projectID.map { [$0] } ?? Set(constrained.flatMap { owners[$0.key] ?? [] }).sorted()
            return PlanningCertificate(kind: kind, projectIDs: projects,
                itemIDs: constrained.map(\.objectID).sorted(), windowStart: min(start, end), windowEnd: end, energy: energy,
                demandMinutes: planningMinutes(demand, up: true), capacityMinutes: planningMinutes(available),
                shortageMinutes: planningMinutes(demand - available, up: true),
                demandSeconds: demand, capacitySeconds: available, shortageSeconds: demand - available,
                requiredReadyAt: nil, latestAllowedAt: nil, elapsedDelaySeconds: nil,
                conditionIDs: graph.conditionIDs(for: graph.ancestors(of: Set(constrained.map(\.key)))),
                message: "此窗口内去重的已知必需劳动下界超过匹配资源上界；缺口是劳动分钟，不是确定延期时长。")
        }
        // Prefix checks are incremental O(n log n), independent of interval-check budget.
        for energy in [Energy.low, .normal, .high] {
            var prefix: [PlanningVertex] = [], cursor = 0, demand = 0.0
            var best: (count: Int, end: Date, available: Double, deficit: Double)?
            while cursor < labor.count {
                let end = graph.deadlines[labor[cursor].key] ?? input.horizonEnd
                while cursor < labor.count && graph.deadlines[labor[cursor].key] == end {
                    if labor[cursor].energy.rank >= energy.rank { prefix.append(labor[cursor]); demand += labor[cursor].knownSeconds }
                    cursor += 1
                }
                let available = capacity.seconds(start: input.now, end: end, energy: energy)
                let deficit = demand - available
                if deficit > 0.0001 && deficit > (best?.deficit ?? 0) { best = (prefix.count, end, available, deficit) }
            }
            if let best, let proof = certificate(Array(prefix.prefix(best.count)), start: input.now,
                end: best.end, energy: energy, available: best.available,
                kind: energy == .low ? .capacityShortfall : .energyShortfall) { result.append(proof) }
        }
        for vertex in labor {
            let end = graph.deadlines[vertex.key] ?? input.horizonEnd
            let start = earliestStarts[vertex.key] ?? input.now
            let available = vertex.continuous ? pool.longest(energy: vertex.energy, start: start, end: end) :
                capacity.seconds(start: start, end: end, energy: vertex.energy)
            if let proof = certificate([vertex], start: min(start, end), end: end, energy: vertex.energy, available: available,
                kind: vertex.continuous ? .continuousShortfall : .dependencyWindow) { result.append(proof) }
        }
        for key in keys.sorted() {
            guard let vertex = graph.vertices[key], (vertex.kind != .item || vertex.fixedEventAt != nil), !vertex.actual,
                  let deadline = graph.deadlines[key], deadline <= input.horizonEnd,
                  let ready = earliestFinishes[key], ready > deadline else { continue }
            let projects = projectID.map { [$0] } ?? graph.projectRequirements.filter { $0.value.contains(key) }.map(\.key).sorted()
            result.append(PlanningCertificate(kind: .dependencyWindow, projectIDs: projects,
                itemIDs: [], windowStart: min(input.now, deadline), windowEnd: deadline, energy: .low,
                demandMinutes: 0, capacityMinutes: 0, shortageMinutes: 0,
                demandSeconds: 0, capacitySeconds: 0, shortageSeconds: 0,
                requiredReadyAt: ready, latestAllowedAt: deadline, elapsedDelaySeconds: ready.timeIntervalSince(deadline),
                conditionIDs: graph.conditionIDs(for: graph.ancestors(of: [key])),
                message: "在列明的等待/人工确认日期与进展假设下，结果最早就绪已晚于所需边界；这是依赖日期矛盾，不是劳动分钟缺口。"))
        }
        // Interior release/deadline windows catch waiting-induced competition missed by prefixes.
        // Bounded work: budget exhaustion merely omits extra proofs; a witness remains independently checked.
        let releases = Set(labor.compactMap { earliestStarts[$0.key] }.filter { $0 > input.now && $0 < input.horizonEnd }).sorted()
        let ends = Set(labor.compactMap { graph.deadlines[$0.key] }).sorted()
        var checks = 0
        outer: for start in releases {
            for end in ends where end > start {
                for energy in [Energy.low, .normal, .high] {
                    if checks + labor.count > input.options.maximumIntervalChecks { break outer }
                    checks += labor.count
                    let constrained = labor.filter {
                        (earliestStarts[$0.key] ?? input.now) >= start &&
                        (graph.deadlines[$0.key] ?? input.horizonEnd) <= end && $0.energy.rank >= energy.rank
                    }
                    let available = capacity.seconds(start: start, end: end, energy: energy)
                    if let proof = certificate(constrained, start: start, end: end, energy: energy, available: available,
                        kind: energy == .low ? .capacityShortfall : .energyShortfall) { result.append(proof) }
                }
            }
        }
        return result
    }

    func boundaries(keys: Set<String>, layer: PlanningLayer, projectIDs: [String],
                    candidate: PlanningWitness? = nil) -> [PlanningBoundary] {
        let grouped = Dictionary(grouping: candidate?.allocations ?? [], by: \.itemID)
        return keys.sorted().compactMap { key in
            guard let vertex = graph.vertices[key], (vertex.kind == .item || vertex.kind == .node), !vertex.actual else { return nil }
            let subject: WorkReference = vertex.kind == .item ? .item(vertex.objectID) : .node(vertex.objectID)
            let known = !uncertainPath.contains(key) && !uncertainBoundary.contains(key) && !vertex.unknown
            var start: Date?, finish: Date?, precision = PlanningPrecision.unknown
            if let candidate, candidate.isComplete, known {
                if vertex.kind == .item, let allocations = grouped[vertex.objectID], !allocations.isEmpty {
                    start = allocations.map(\.start).min(); finish = allocations.map(\.end).max()
                } else { finish = candidate.eventTimes[key]; start = finish }
                precision = .feasibleCandidate
            } else if layer == .dependency, known, let lower = latestStarts[key], let upper = latestFinishes[key] {
                start = lower; finish = upper; precision = .necessaryUpperBound
            }
            return PlanningBoundary(subject: subject, layer: layer, projectIDs: projectIDs,
                latestStart: start, latestFinish: finish, precision: precision,
                conditionIDs: graph.conditionIDs(for: graph.ancestors(of: [key])), chain: impactChain(from: key, keys: keys))
        }
    }
    func impactChain(from key: String, keys: Set<String>) -> [String] {
        // Longest constrained successor chain, using reverse bounds as the bottleneck witness.
        var chain: [String] = [], cursor: String? = key, seen = Set<String>()
        while let current = cursor, seen.insert(current).inserted, chain.count < 128 {
            chain.append(current)
            cursor = graph.vertices[current]?.successors.intersection(keys).min {
                let a = latestStarts[$0] ?? input.horizonEnd, b = latestStarts[$1] ?? input.horizonEnd
                return a == b ? $0 < $1 : a < b
            }
        }
        return chain
    }
}
