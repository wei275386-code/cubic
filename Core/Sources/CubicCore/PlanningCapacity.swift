import Foundation

struct PlanningWindow {
    var start: Date
    var end: Date
    var energy: Energy
    var seconds: Double { end.timeIntervalSince(start) }
}

/// Sweep boundaries once. Overlapping capacity is one resource; busy intervals are a union.
struct PlanningPool {
    var windows: [PlanningWindow]
    init(input: PlanningInput) throws {
        try checkDate(input.now, "planning.now"); try checkDate(input.horizonEnd, "planning.horizonEnd")
        guard input.now <= input.horizonEnd else { throw CoreError.invalid("规划窗口结束早于当前时间") }
        var events: [(Date, Int, Int)] = []
        for slot in input.slots {
            try checkInterval(slot.start, slot.end, "planning.slot")
            let start = max(input.now, slot.start), end = min(input.horizonEnd, slot.end)
            if start < end { events.append((start, slot.energy.rank, 1)); events.append((end, slot.energy.rank, -1)) }
        }
        for busy in input.busy {
            try checkInterval(busy.start, busy.end, "planning.busy")
            let start = max(input.now, busy.start), end = min(input.horizonEnd, busy.end)
            if start < end { events.append((start, 3, 1)); events.append((end, 3, -1)) }
        }
        events.sort { $0.0 < $1.0 }
        var counts = [0, 0, 0, 0], index = 0, result: [PlanningWindow] = []
        let energies: [Energy] = [.low, .normal, .high]
        while index < events.count {
            let point = events[index].0
            while index < events.count && events[index].0 == point {
                counts[events[index].1] += events[index].2; index += 1
            }
            guard index < events.count, point < events[index].0, counts[3] == 0,
                  let rank = (0...2).reversed().first(where: { counts[$0] > 0 }) else { continue }
            let end = events[index].0
            if let last = result.indices.last, result[last].end == point, result[last].energy == energies[rank] {
                result[last].end = end
            } else { result.append(PlanningWindow(start: point, end: end, energy: energies[rank])) }
        }
        windows = result
    }
    init(windows: [PlanningWindow]) { self.windows = windows }
    /// Subtract sorted disjoint reservations in one sweep.
    mutating func subtract(_ intervals: [WorkTimeBlock]) {
        let ordered = intervals.sorted { $0.start < $1.start }
        var result: [PlanningWindow] = [], cursor = 0
        for window in windows {
            var position = window.start
            while cursor < ordered.count && ordered[cursor].end <= window.start { cursor += 1 }
            var i = cursor
            while i < ordered.count && ordered[i].start < window.end {
                let block = ordered[i]
                if position < block.start { result.append(PlanningWindow(start: position, end: min(window.end, block.start), energy: window.energy)) }
                position = max(position, min(window.end, block.end)); i += 1
            }
            if position < window.end { result.append(PlanningWindow(start: position, end: window.end, energy: window.energy)) }
        }
        windows = result
    }
    func compatible(energy: Energy, start: Date, end: Date) -> [PlanningWindow] {
        var result: [PlanningWindow] = []
        for window in windows where window.energy.rank >= energy.rank && window.start < end && window.end > start {
            let lower = max(start, window.start), upper = min(end, window.end)
            if let last = result.indices.last, result[last].end == lower {
                result[last].end = upper
            } else { result.append(PlanningWindow(start: lower, end: upper, energy: energy)) }
        }
        return result
    }
    func seconds(energy: Energy = .low, start: Date, end: Date) -> Double {
        windows.reduce(0) { total, window in
            guard window.energy.rank >= energy.rank else { return total }
            return total + max(0, min(end, window.end).timeIntervalSince(max(start, window.start)))
        }
    }
    func longest(energy: Energy, start: Date, end: Date) -> Double {
        compatible(energy: energy, start: start, end: end).map(\.seconds).max() ?? 0
    }
    /// A failed complete allocation leaves the free pool unchanged.
    mutating func allocate(itemID: String, seconds: Double, energy: Energy, continuous: Bool,
                           start: Date, end: Date, backwards: Bool = false,
                           requireComplete: Bool = true) -> [TrialAllocation] {
        guard seconds > 0.0001, start < end else { return [] }
        let eligible = compatible(energy: energy, start: start, end: end)
        let ordered = backwards ? Array(eligible.reversed()) : eligible
        var remaining = seconds, allocations: [TrialAllocation] = []
        for window in ordered where remaining > 0.0001 {
            if continuous && window.seconds + 0.0001 < seconds { continue }
            let used = min(remaining, window.seconds)
            let lower = backwards ? window.end.addingTimeInterval(-used) : window.start
            let upper = backwards ? window.end : window.start.addingTimeInterval(used)
            let actual = upper.timeIntervalSince(lower)
            guard lower < upper, lower >= window.start, upper <= window.end,
                  actual <= remaining + 0.0001, abs(actual - used) < 0.0001 else { return [] }
            allocations.append(TrialAllocation(itemID: itemID, start: lower, end: upper))
            remaining -= actual
            if continuous { break }
        }
        guard !requireComplete || remaining <= 0.0001 else { return [] }
        // Both lists are disjoint and ordered. Subtract in one sweep, not once per segment.
        allocations.sort { $0.start < $1.start }
        var result: [PlanningWindow] = [], cursor = 0
        for window in windows {
            var position = window.start
            while cursor < allocations.count && allocations[cursor].end <= window.start { cursor += 1 }
            var index = cursor
            while index < allocations.count && allocations[index].start < window.end {
                let allocation = allocations[index]
                if position < allocation.start {
                    result.append(PlanningWindow(start: position, end: min(window.end, allocation.start), energy: window.energy))
                }
                position = max(position, min(window.end, allocation.end)); index += 1
            }
            if position < window.end { result.append(PlanningWindow(start: position, end: window.end, energy: window.energy)) }
        }
        windows = result
        return allocations
    }
}

struct PlanningCapacityIndex {
    let windows: [PlanningWindow]
    let cumulative: [[Double]]
    init(pool: PlanningPool) {
        windows = pool.windows
        var prefixes = Array(repeating: [0.0], count: 3)
        for window in windows {
            for rank in 0...2 {
                prefixes[rank].append((prefixes[rank].last ?? 0) + (window.energy.rank >= rank ? window.seconds : 0))
            }
        }
        cumulative = prefixes
    }
    func before(_ date: Date, energy: Energy) -> Double {
        var lower = 0, upper = windows.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if windows[middle].end <= date { lower = middle + 1 } else { upper = middle }
        }
        var result = cumulative[energy.rank][lower]
        if lower < windows.count, windows[lower].energy.rank >= energy.rank {
            result += max(0, min(date, windows[lower].end).timeIntervalSince(windows[lower].start))
        }
        return result
    }
    func seconds(start: Date, end: Date, energy: Energy) -> Double {
        max(0, before(end, energy: energy) - before(start, energy: energy))
    }
}

func planningMinutes(_ seconds: Double, up: Bool = false) -> Int {
    // Date math is finite after validation; small tolerance avoids 60.0000000001 -> 2.
    let minutes = max(0, seconds) / 60
    return Int(min(Double(Int.max / 2), up ? ceil(minutes - 0.00000001) : floor(minutes + 0.00000001)))
}
