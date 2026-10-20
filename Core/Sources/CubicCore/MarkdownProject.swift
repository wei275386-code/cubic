import Foundation

public struct MarkdownWorkDraft: Sendable, Equatable {
    public let name: String
    public let estimatedMinutes: Int
    public let deadline: Date?
    public let line: Int
}

public struct MarkdownNodeDraft: Sendable, Equatable {
    public let name: String
    public fileprivate(set) var works: [MarkdownWorkDraft]
    public let line: Int
}

public struct MarkdownProjectDraft: Sendable, Equatable {
    public let name: String
    public let deadline: Date?
    public let timeZoneID: String
    public fileprivate(set) var nodes: [MarkdownNodeDraft]
    public var workCount: Int { nodes.reduce(0) { $0 + $1.works.count } }
}

public struct MarkdownProjectError: Error, LocalizedError, Sendable, Equatable {
    public let line: Int
    public let message: String
    public var errorDescription: String? { line > 0 ? "第 \(line) 行：\(message)" : message }
}

/// One project title, first-level list nodes, second-level list work. Blank lines are ignored.
public enum MarkdownProjectParser {
    public static func parse(_ text: String, now: Date = Date(), timeZone: TimeZone = .current) throws -> MarkdownProjectDraft {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").enumerated().compactMap { index, raw -> (line: Int, raw: String)? in
                trim(raw).isEmpty ? nil : (index + 1, raw)
            }
        if let first = lines.first, ["```", "```md", "```markdown"].contains(trim(first.raw).lowercased()) {
            guard lines.count >= 2, trim(lines.last!.raw) == "```" else {
                throw issue(first.line, "Markdown 代码块缺少结束标记。")
            }
            lines.removeLast(); lines.removeFirst()
        }
        guard let first = lines.first else { throw issue(0, "请粘贴项目名称和节点、工作列表。") }
        var title = trim(first.raw)
        if let match = captures(#"^#{1,6}\s+(.+)$"#, title) { title = match[0] }
        guard listEntry(first.raw) == nil else { throw issue(first.line, "首行应为项目名称，后面再列出节点和工作。") }
        let project = try parameters(title, line: first.line, now: now, timeZone: timeZone)
        guard project.minutes == nil else { throw issue(first.line, "项目支持截止日期；预估耗时请写在工作行。") }
        var draft = MarkdownProjectDraft(name: project.name, deadline: project.deadline, timeZoneID: timeZone.identifier, nodes: [])
        var nodeIndent: Int?
        var workIndent: Int?
        for line in lines.dropFirst() {
            guard let entry = listEntry(line.raw) else {
                throw issue(line.line, "节点和工作请使用 Markdown 列表（-、*、+ 或 1.），工作比节点多缩进一级。")
            }
            if nodeIndent == nil { nodeIndent = entry.indent }
            let value = try parameters(entry.content, line: line.line, now: now, timeZone: timeZone)
            if entry.indent == nodeIndent {
                guard value.minutes == nil, value.deadline == nil else {
                    throw issue(line.line, "节点没有截止或耗时参数；工作及其参数请多缩进一级。")
                }
                draft.nodes.append(MarkdownNodeDraft(name: value.name, works: [], line: line.line))
                workIndent = nil
            } else if entry.indent > nodeIndent! {
                if workIndent == nil { workIndent = entry.indent }
                guard entry.indent == workIndent else {
                    throw issue(line.line, "只支持项目 → 节点 → 工作；同级工作请使用一致的缩进。")
                }
                draft.nodes[draft.nodes.count - 1].works.append(MarkdownWorkDraft(name: value.name,
                    estimatedMinutes: value.minutes ?? 60, deadline: value.deadline, line: line.line))
            } else {
                throw issue(line.line, "同级节点请使用一致的缩进。")
            }
        }
        return draft
    }

    private static func listEntry(_ raw: String) -> (indent: Int, content: String)? {
        guard let match = captures(#"^([ \t]*)(?:[-+*]|[0-9]+[.)])(?:[ \t]+(.*))?$"#, raw) else { return nil }
        // Tabs advance to a four-space stop, matching common Markdown editors.
        let indent = match[0].reduce(0) { $1 == "\t" ? ($0 / 4 + 1) * 4 : $0 + 1 }
        return (indent, match[1])
    }

    private static func parameters(_ content: String, line: Int, now: Date, timeZone: TimeZone) throws
        -> (name: String, deadline: Date?, minutes: Int?) {
        let parts = content.components(separatedBy: CharacterSet(charactersIn: ",，"))
        var name = [trim(parts[0])]
        var deadline: Date?
        var minutes: Int?
        for part in parts.dropFirst() {
            let token = trim(part).lowercased()
            if let duration = captures(#"^([+-]?[0-9]+(?:\.[0-9]+)?)\s*(h|hr|hrs|hour|hours|小时|m|min|mins|minute|minutes|分钟)$"#, token) {
                guard minutes == nil else { throw issue(line, "预估耗时重复，请只保留一个。") }
                let hours = ["h", "hr", "hrs", "hour", "hours", "小时"].contains(duration[1])
                guard let number = Double(duration[0]) else { throw issue(line, "预估耗时无效。") }
                let value = number * (hours ? 60 : 1)
                guard value.isFinite, value >= 0, value <= 5_256_000, abs(value - value.rounded()) < 0.000001 else {
                    throw issue(line, "预估耗时需换算为 0–5256000 之间的整数分钟，如 2h、1.5h 或 30min。")
                }
                minutes = Int(value.rounded())
            } else if let date = captures(#"^(?:([0-9]{4})[./-])?([0-9]{1,2})[./-]([0-9]{1,2})$"#, token) {
                guard deadline == nil else { throw issue(line, "截止日期重复，请只保留一个。") }
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
                let year = date[0].isEmpty ? calendar.component(.year, from: now) : Int(date[0])!
                let month = Int(date[1])!, day = Int(date[2])!
                let components = DateComponents(year: year, month: month, day: day, hour: 12)
                guard year >= 1, let parsed = calendar.date(from: components),
                      calendar.component(.year, from: parsed) == year,
                      calendar.component(.month, from: parsed) == month,
                      calendar.component(.day, from: parsed) == day else {
                    throw issue(line, "截止日期无效，请使用 10.10 或 2026-10-10 等真实日期。")
                }
                deadline = try Workspace.dateOnlyDeadline(on: parsed, timeZoneID: timeZone.identifier)
            } else {
                // Unrecognized comma-separated text stays in the name, rather than disappearing.
                name.append(trim(part))
            }
        }
        let title = name.joined(separator: ", ")
        guard !trim(name[0]).isEmpty else { throw issue(line, "名称不能为空。") }
        return (title, deadline, minutes)
    }

    private static func trim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func issue(_ line: Int, _ message: String) -> MarkdownProjectError { MarkdownProjectError(line: line, message: message) }
    private static func captures(_ pattern: String, _ text: String) -> [String]? {
        let expression = try! NSRegularExpression(pattern: pattern)
        guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}

extension Workspace {
    /// Parse and create on a candidate; validation failure leaves the original workspace untouched.
    @discardableResult public mutating func addMarkdownProject(_ text: String, now: Date, timeZone: TimeZone = .current) throws -> String {
        let value = try MarkdownProjectParser.parse(text, now: now, timeZone: timeZone)
        return try addMarkdownProject(value, now: now)
    }

    @discardableResult public mutating func addMarkdownProject(_ value: MarkdownProjectDraft, now: Date) throws -> String {
        let project = Project(name: value.name, deadline: value.deadline, status: .planning,
            deadlineTimeZoneID: value.deadline == nil ? nil : value.timeZoneID, deadlineIsDateOnly: value.deadline == nil ? nil : true)
        try command(at: now) { draft in
            draft.projects.append(project)
            draft.appendHistory(.created, id: project.id, now: now, note: "从 Markdown 创建")
            for entry in value.nodes {
                var node = Node(projectID: project.id, name: entry.name, structureOrder: entry.line)
                node.sequentialPredecessorNodeID = draft.nodes.last { $0.projectID == project.id }?.id
                draft.nodes.append(node)
                draft.appendHistory(.created, id: node.id, now: now, note: "从 Markdown 创建")
                for work in entry.works {
                    draft.items.append(WorkItem(name: work.name, nodeID: node.id, projectIDs: [project.id],
                        remainingMinutes: work.estimatedMinutes, initialMinutes: work.estimatedMinutes, deadline: work.deadline,
                        deadlineTimeZoneID: work.deadline == nil ? nil : value.timeZoneID, deadlineIsDateOnly: work.deadline == nil ? nil : true,
                        structureOrder: work.line))
                    draft.captureCreatedItemHistory(at: draft.items.count - 1, now: now, note: "从 Markdown 创建")
                }
                try draft.initializeSequentialDependencies(nodeID: node.id, now: now)
            }
        }
        return project.id
    }
}
