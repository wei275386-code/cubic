import Foundation

extension Workspace {
    /// PRD sample A, with literal local 14–16 today and 10–12 tomorrow windows.
    /// Calling this creates only an explicitly labelled example; it never rewrites user facts.
    public static func prdExample(start: Date, calendar: Calendar = .current) -> Workspace {
        let firstEnd = start.addingTimeInterval(120 * 60)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start))!
        let secondStart = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: tomorrow)!
        let secondEnd = secondStart.addingTimeInterval(120 * 60)
        let zone = calendar.timeZone.identifier
        return Workspace(
            projects: [
                Project(id: "project-a", name: "A · 完成报价表", deadline: secondEnd, importance: 3, status: .active, planningCompleteness: .complete, deadlineTimeZoneID: zone),
                Project(id: "project-b", name: "B · 提交申请", deadline: firstEnd, importance: 3, status: .active, planningCompleteness: .complete, deadlineTimeZoneID: zone),
                Project(id: "project-c", name: "C · 制作合同", deadline: secondEnd, importance: 3, status: .active, planningCompleteness: .complete, deadlineTimeZoneID: zone)
            ],
            items: [
                WorkItem(id: "item-a", name: "A：完成报价表", projectIDs: ["project-a"], remainingMinutes: 60, initialMinutes: 60),
                WorkItem(id: "item-b", name: "B：提交申请", projectIDs: ["project-b"], remainingMinutes: 90, initialMinutes: 90),
                WorkItem(id: "item-c", name: "C：制作合同", projectIDs: ["project-c"], remainingMinutes: 60, initialMinutes: 60)
            ],
            dependencies: [Dependency(id: "dependency-a-c", source: .item("item-a"), targetItemID: "item-c")]
        )
    }
}
