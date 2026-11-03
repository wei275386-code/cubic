import SwiftUI
import CubicCore

/// The four top-level destinations shared by the iPhone tab bar and the Mac sidebar.
enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case today, calendar, projects, attention
    var id: Self { self }
    var title: String {
        switch self {
        case .today: "今天"
        case .calendar: "日历"
        case .projects: "项目"
        case .attention: "待处理"
        }
    }
    var symbol: String {
        switch self {
        case .today: "sun.max"
        case .calendar: "calendar"
        case .projects: "square.stack.3d.up"
        case .attention: "tray"
        }
    }
    var shortcut: KeyEquivalent {
        switch self {
        case .today: "1"
        case .calendar: "2"
        case .projects: "3"
        case .attention: "4"
        }
    }
}

@MainActor @Observable final class AppNavigation {
    var section: AppSection = .today
    /// Mac sidebar selection of a single project; nil shows the project list.
    var selectedProjectID: String?
    var settings = false
    var startupRoute: WorkspaceStartRoute?
    var editor: ProjectUISheet?
    var capture = false

    func openSettings(_ route: WorkspaceStartRoute? = nil) { startupRoute = route; settings = true }
    func openProject(_ id: String) { selectedProjectID = id; section = .projects }
}

// MARK: - Attention

/// Everything that should come to the user instead of waiting to be found.
struct AttentionSummary {
    var dueFollowUps: [Blocker] = []
    var laterWaits: [Blocker] = []
    var lateProjects: [Project] = []
    var tightProjects: [Project] = []
    var reviewItems: [WorkItem] = []
    var inboxItems: [WorkItem] = []
    var unreadNotices: [RiskNotice] = []

    /// Items that need a decision now; drives the badge.
    var count: Int { dueFollowUps.count + lateProjects.count + reviewItems.count + inboxItems.count }
    var headline: String? {
        if let blocker = dueFollowUps.first { return "跟进：\(blocker.name)" }
        if let project = lateProjects.first { return "\(project.name) 来不及" }
        if let item = reviewItems.first { return "\(item.name) 需要复核" }
        if let project = tightProjects.first { return "\(project.name) 需要关注排期" }
        if !inboxItems.isEmpty { return "\(inboxItems.count) 项待整理" }
        return nil
    }
}

extension AppModel {
    var workCalendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = preferences.workTimeZone
        return value
    }

    var attention: AttentionSummary {
        let cal = workCalendar
        let endOfToday = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now
        let waits = workspace.blockers.filter { $0.state != .resolved && $0.isArchived != true }
        let now = now
        func dueDate(_ blocker: Blocker) -> Date? {
            let expected = blocker.state == .active ? blocker.estimatedResolution : nil
            // Once the expected end has passed, a later follow-up is the user's chosen time to check again.
            if let expected, expected <= now, let followUp = blocker.followUpAt, followUp > now { return followUp }
            return [blocker.followUpAt, expected].compactMap { $0 }.min()
        }
        var summary = AttentionSummary()
        summary.dueFollowUps = waits.filter { dueDate($0).map { $0 < endOfToday } == true }
            .sorted { (dueDate($0) ?? .distantFuture) < (dueDate($1) ?? .distantFuture) }
        let dueIDs = Set(summary.dueFollowUps.map(\.id))
        summary.laterWaits = waits.filter { !dueIDs.contains($0.id) }
            .sorted { (dueDate($0) ?? .distantFuture) < (dueDate($1) ?? .distantFuture) }
        let active = workspace.projects.filter { !$0.archived && $0.hasDeliveryCommitment }
        let health = healthByProject
        summary.lateProjects = active.filter { health[$0.id] == .late }
        summary.tightProjects = active.filter { health[$0.id] == .tight || health[$0.id] == .contested }
        summary.reviewItems = workspace.items.filter { $0.needsReview && !$0.archived && $0.effectiveDisposition != .cancelled }
        summary.inboxItems = pendingInboxItems
        summary.unreadNotices = notices.filter { !$0.isResolved && !$0.isRead }
        return summary
    }

    /// Follow-up and expected-end moments on a given day, drawn as timeline flags.
    func waitMarkers(on day: Date) -> [CalendarMarker] {
        let cal = workCalendar
        return workspace.blockers.filter { $0.state != .resolved && $0.isArchived != true }.flatMap { blocker -> [CalendarMarker] in
            var markers: [CalendarMarker] = []
            if let date = blocker.followUpAt, cal.isDate(date, inSameDayAs: day) {
                markers.append(CalendarMarker(id: "followup.\(blocker.id)", date: date, title: "跟进：\(blocker.name)"))
            }
            if blocker.state == .active, let date = blocker.estimatedResolution, cal.isDate(date, inSameDayAs: day) {
                markers.append(CalendarMarker(id: "expected.\(blocker.id)", date: date, title: "预计结束：\(blocker.name)"))
            }
            return markers
        }
    }
}
