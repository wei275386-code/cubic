import Foundation
import Testing
@testable import CubicCore

@Suite struct WorkspaceMergeTests {
    private func item(_ id: String, _ name: String, minutes: Double = 30) -> JSONValue {
        .object(["id": .string(id), "name": .string(name), "minutes": .number(minutes)])
    }
    private func merge(_ base: [JSONValue], _ local: [JSONValue], _ remote: [JSONValue], preferLocal: Bool = true) -> (value: JSONValue, conflicted: Bool) {
        WorkspaceMerge.merge(base: .array(base), local: .array(local), remote: .array(remote), preferLocal: preferLocal)
    }

    @Test func differentItemsKeepBothEdits() {
        let a = item("a", "A"), b = item("b", "B")
        let result = merge([a, b], [item("a", "Local"), b], [a, item("b", "Remote")])
        #expect(result.value == .array([item("a", "Local"), item("b", "Remote")]))
        #expect(!result.conflicted)
    }

    @Test func differentFieldsKeepBothEdits() {
        let result = merge([item("a", "A")], [item("a", "Local")], [item("a", "A", minutes: 60)])
        #expect(result.value == .array([item("a", "Local", minutes: 60)]))
        #expect(!result.conflicted)
    }

    @Test func deletionAgainstUntouchedIsDeleted() {
        let a = item("a", "A"), b = item("b", "B")
        let result = merge([a, b], [b], [a, item("b", "Remote")])
        #expect(result.value == .array([item("b", "Remote")]))
        #expect(!result.conflicted)
    }

    @Test func deletionAgainstEditKeepsEditedItem() {
        for preferLocal in [true, false] {
            let edited = item("a", "Edited")
            let result = merge([item("a", "A")], [], [edited], preferLocal: preferLocal)
            let reverse = merge([item("a", "A")], [edited], [], preferLocal: preferLocal)
            #expect(result.value == .array([edited]) && reverse.value == result.value)
            #expect(!result.conflicted && !reverse.conflicted)
        }
    }

    @Test func sameFieldUsesPreferredSideAndReportsConflict() {
        for preferLocal in [true, false] {
            let local = item("a", "Local"), remote = item("a", "Remote")
            let result = merge([item("a", "A")], [local], [remote], preferLocal: preferLocal)
            #expect(result.value == .array([preferLocal ? local : remote]))
            #expect(result.conflicted)
        }
    }

    @Test func newItemsFollowLocalThenRemoteOrder() {
        let a = item("a", "A"), b = item("b", "B"), c = item("c", "C"), d = item("d", "D")
        let result = merge([a], [b, a], [c, a, d])
        #expect(result.value == .array([b, a, c, d]))
        #expect(!result.conflicted)
    }

    @Test func absentCollectionKeepsFirstAdditionsFromBothSides() {
        let local = item("local", "Local"), remote = item("remote", "Remote")
        let result = WorkspaceMerge.merge(base: .object([:]),
                                          local: .object(["timeBlocks": .array([local])]),
                                          remote: .object(["timeBlocks": .array([remote])]), preferLocal: true)
        #expect(result.value == .object(["timeBlocks": .array([local, remote])]))
        #expect(!result.conflicted)
    }

    @Test func missingObjectKeysAreDistinctFromNull() {
        let result = WorkspaceMerge.merge(base: .object(["removed": .null, "kept": .number(1)]),
                                          local: .object(["kept": .number(1)]),
                                          remote: .object(["removed": .null, "kept": .number(2)]), preferLocal: true)
        #expect(result.value == .object(["kept": .number(2)]))
        #expect(!result.conflicted)
    }

    @Test func otherArraysAndTypeChangesUsePreferredSide() {
        for remote in [JSONValue.array([.number(3)]), .string("changed")] {
            let result = WorkspaceMerge.merge(base: .array([.number(1)]), local: .array([.number(2)]), remote: remote, preferLocal: false)
            #expect(result.value == remote && result.conflicted)
        }
    }

    @Test func seededRandomWorkspaceProperties() throws {
        var seed: UInt64 = 0xC0B1C
        func random(_ upper: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 32) % UInt64(upper))
        }
        func json(_ workspace: Workspace) throws -> JSONValue {
            try JSONCoding.decode(JSONValue.self, from: JSONCoding.encode(workspace))
        }
        // Array order intentionally follows the local side; compare facts in id order.
        func ordered(_ value: JSONValue) throws -> Workspace {
            var workspace = try JSONCoding.decode(Workspace.self, from: JSONCoding.encode(value))
            try workspace.validate()
            workspace.items.sort { $0.id < $1.id }
            workspace.timeBlocks?.sort { $0.id < $1.id }
            return workspace
        }
        for iteration in 0..<400 {
            let base = Workspace(items: (0..<random(10)).map {
                WorkItem(id: "base-\($0)", name: "Name \(random(100))", remainingMinutes: random(100))
            })
            var local = base, remote = base
            for side in 0..<2 {
                var edited = base
                for index in edited.items.indices.reversed() {
                    switch random(5) {
                    case 0: edited.items.remove(at: index)
                    case 1: edited.items[index].name = "Edit \(random(100))"
                    case 2: edited.items[index].remainingMinutes = random(100)
                    default: break
                    }
                }
                for index in 0..<random(4) {
                    edited.items.append(WorkItem(id: "added-\(side)-\(index)", name: "New", remainingMinutes: random(100)))
                }
                if let item = edited.items.first(where: { $0.id.hasPrefix("added-") }) {
                    for index in 0..<random(3) {
                        let start = Date(timeIntervalSince1970: 1_900_000_000 + Double(side * 3600 + index * 600))
                        let block = WorkTimeBlock(id: "block-\(side)-\(index)", itemID: item.id, start: start, end: start.addingTimeInterval(300))
                        edited.timeBlocks = (edited.timeBlocks ?? []) + [block]
                    }
                }
                if side == 0 { local = edited } else { remote = edited }
            }
            if iteration % 5 == 0 { local = base }
            if iteration % 7 == 0 { remote = base }
            let b = try json(base), l = try json(local), r = try json(remote)
            let result = WorkspaceMerge.merge(base: b, local: l, remote: r, preferLocal: true)
            if local == base { #expect(result.value == r) }
            if remote == base { #expect(result.value == l) }
            let merged = try ordered(result.value)
            for item in local.items + remote.items where item.id.hasPrefix("added-") {
                #expect(merged.items.contains(item))
            }
            for block in (local.timeBlocks ?? []) + (remote.timeBlocks ?? []) {
                #expect(merged.timeBlocks?.contains(block) == true)
            }
            let reverse = WorkspaceMerge.merge(base: b, local: r, remote: l, preferLocal: true)
            #expect(result.conflicted == reverse.conflicted)
            if !result.conflicted { #expect(merged == (try ordered(reverse.value))) }
        }
    }
}
