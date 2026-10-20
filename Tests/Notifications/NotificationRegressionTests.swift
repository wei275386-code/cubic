import Foundation
import CubicCore
import UserNotifications

actor FakeNotificationCenter: ReminderNotificationCenter {
    var authorized = true
    var requests: [String: ImmutableNotificationRequest] = [:]
    var additions = 0
    var removals = 0
    var inFlight = 0
    var maximumInFlight = 0
    var failNextAdd = false
    var deferredRemoval = false
    var pendingRemovalIDs = Set<String>()
    enum Failure: Error { case injected }
    func isAuthorized() async -> Bool { authorized }
    func pendingRequests() async -> [ImmutableNotificationRequest] { Array(requests.values) }
    func removePendingRequests(_ identifiers: [String]) async {
        removals += identifiers.count
        if deferredRemoval { pendingRemovalIDs.formUnion(identifiers); return }
        for id in identifiers { requests[id] = nil }
    }
    func add(_ request: ImmutableNotificationRequest) async throws {
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
        defer { inFlight -= 1 }
        await Task.yield()
        if failNextAdd { failNextAdd = false; throw Failure.injected }
        additions += 1
        requests[request.request.identifier] = request
    }
    func seed(_ values: [ImmutableNotificationRequest]) { for value in values { requests[value.request.identifier] = value } }
    func setAuthorized(_ value: Bool) { authorized = value }
    func injectFailure() { failNextAdd = true }
    func setDeferredRemoval(_ value: Bool) { deferredRemoval = value }
    func completeRemovals() {
        for id in pendingRemovalIDs { requests[id] = nil }
        pendingRemovalIDs.removeAll()
    }
    func counts() -> (Int, Int, Int) { (additions, removals, maximumInFlight) }
}

@main @MainActor struct NotificationRegressionTests {
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) {
        checks += 1
        precondition(condition, message)
    }
    static func notice(kind: String, date: Date?) -> RiskNotice {
        RiskNotice(id: kind, rootObjectID: "root", kind: kind, title: "标题", body: "内容",
                   projectIDs: [], itemIDs: [], createdAt: Date(), changedAt: Date(),
                   dueAt: date, fingerprint: "same")
    }
    static func reminders(_ notices: [RiskNotice]) -> [FollowUpReminder] {
        notices.compactMap { notice in
            notice.nextNotificationDate.map { FollowUpReminder(id: notice.id, title: notice.title, date: $0, noticeID: notice.id) }
        }
    }
    static func main() async throws {
        let now = Date(), future = now.addingTimeInterval(3600), past = now.addingTimeInterval(-3600)
        for kind in ["capacityConflict", "projectRisk", "syncConflict", "review", "acceptanceFailed", "unlock"] {
            var old = notice(kind: kind, date: now.addingTimeInterval(2))
            check(old.nextNotificationDate == nil, "Legacy immediate risks must stay in app: \(kind)")
            old.isRead = true; old.snoozedUntil = future
            check(old.nextNotificationDate == future, "An explicit snooze must work after acknowledgement")
            old.isResolved = true
            check(old.nextNotificationDate == nil, "Resolved notices must not alert")
        }
        var followUp = notice(kind: "followUp", date: future)
        check(followUp.nextNotificationDate == future, "Future declared dates must survive")
        followUp.isRead = true
        check(followUp.nextNotificationDate == nil, "Read follow-ups must not alert")
        check(ReminderSchedule.foregroundPresentation.isEmpty, "Foreground must be quiet")

        // Reproduce opening a workspace with fifteen overdue waits and fifteen reviews.
        var workspace = Workspace(
            items: (0..<15).map { WorkItem(id: "item\($0)", name: "成果\($0)", remainingMinutes: 0, status: .completed, completedAt: past, needsReview: true) },
            blockers: (0..<15).map { Blocker(id: "wait\($0)", name: "等待\($0)", state: .active, expectedResolution: past, triggeredAt: past.addingTimeInterval(-3600), followUpAt: past) })
        let planning = try Engine.plan(workspace: workspace, input: PlanningInput(slots: [], now: now))
        let changes = RiskNoticeEngine.changes(workspace: workspace, planning: planning, now: now)
        check(changes.filter { $0.kind == "review" }.count == 15, "In-app risks must remain visible")
        check(changes.filter { $0.kind == "followUp" }.allSatisfy { $0.dueAt == past }, "Overdue dates must not be shifted to launch time")
        check(ReminderSchedule.requests(reminders(changes), now: now).isEmpty, "Opening this workspace must schedule zero alerts")
        for value in changes { workspace.history.append(try RiskNoticeEngine.event(value, at: now)) }
        let later = now.addingTimeInterval(60)
        let refreshed = try Engine.plan(workspace: workspace, input: PlanningInput(slots: [], now: later))
        check(RiskNoticeEngine.changes(workspace: workspace, planning: refreshed, now: later).isEmpty, "Unchanged notices must not be regenerated")
        var earlierReview = changes.first { $0.kind == "review" }!
        earlierReview.fingerprint = "previous-round"
        earlierReview.snoozedUntil = future
        workspace.history.append(try RiskNoticeEngine.event(earlierReview, at: later))
        let changedReview = RiskNoticeEngine.changes(workspace: workspace, planning: refreshed, now: later.addingTimeInterval(1))
            .first { $0.id == earlierReview.id }!
        check(changedReview.nextNotificationDate == future, "Recalculated risk must preserve the user's explicit reminder")

        var scheduledWorkspace = Workspace(blockers: [Blocker(id: "future", name: "未来等待", state: .active,
            expectedResolution: future, triggeredAt: past, followUpAt: future.addingTimeInterval(60))])
        let scheduledPlan = try Engine.plan(workspace: scheduledWorkspace, input: PlanningInput(slots: [], now: now))
        let scheduledChanges = RiskNoticeEngine.changes(workspace: scheduledWorkspace, planning: scheduledPlan, now: now)
        check(scheduledChanges.count == 2 && reminders(scheduledChanges).count == 2, "Both declared future dates must remain schedulable")
        var snoozed = scheduledChanges.first { $0.kind == "followUp" }!
        snoozed.isRead = true
        scheduledWorkspace.history.append(try RiskNoticeEngine.event(snoozed, at: now))
        snoozed.snoozedUntil = future.addingTimeInterval(86400)
        scheduledWorkspace.history.append(try RiskNoticeEngine.event(snoozed, at: later))
        let restored = RiskNoticeEngine.stored(in: scheduledWorkspace)[0]
        check(restored.nextNotificationDate == snoozed.snoozedUntil, "Persisted snooze must survive monotonic read acknowledgement")
        snoozed.snoozedUntil = nil
        scheduledWorkspace.history.append(try RiskNoticeEngine.event(snoozed, at: later.addingTimeInterval(1)))
        check(RiskNoticeEngine.stored(in: scheduledWorkspace)[0].nextNotificationDate == nil, "Marking read again must cancel a persisted snooze")

        var legacyTimedWorkspace = Workspace(blockers: [Blocker(id: "legacy-timed", name: "旧跟进", state: .active,
            triggeredAt: past.addingTimeInterval(-3600), followUpAt: past)])
        let legacyTimedPlan = try Engine.plan(workspace: legacyTimedWorkspace, input: PlanningInput(slots: [], now: now))
        var legacyTimed = RiskNoticeEngine.changes(workspace: legacyTimedWorkspace, planning: legacyTimedPlan, now: now)[0]
        legacyTimed.dueAt = future
        legacyTimedWorkspace.history.append(try RiskNoticeEngine.event(legacyTimed, at: now))
        let repairedLegacy = RiskNoticeEngine.changes(workspace: legacyTimedWorkspace, planning: legacyTimedPlan, now: later)
        check(repairedLegacy.count == 1 && repairedLegacy[0].dueAt == past, "Legacy timed notice must recover its real declared date")
        check(ReminderSchedule.requests(reminders(repairedLegacy), now: later).isEmpty, "A legacy artificial future date must not alert")

        let next = FollowUpReminder(id: "next", title: "跟进", date: future, noticeID: "followup.next")
        let desired = ReminderSchedule.requests([next], now: now)
        let trigger = desired[0].trigger as! UNCalendarNotificationTrigger
        check(!trigger.repeats && abs(trigger.nextTriggerDate()!.timeIntervalSince(future)) < 1, "Absolute trigger must fire at the requested instant")
        check(trigger.nextTriggerDate()! >= future, "Second precision must never schedule before the declared date")
        check(desired[0].content.userInfo["cubic.noticeID"] as? String == "followup.next", "Tapping must retain the detail route")
        check(ReminderSchedule.matches(desired[0], ReminderSchedule.requests([next], now: later)[0]), "Refresh must produce the same request")
        check(ReminderSchedule.requests([FollowUpReminder(id: "past", title: "过期", date: past)], now: now).isEmpty, "Never catch up overdue reminders")
        let many = (0..<70).map { FollowUpReminder(id: String(format: "%02d", $0), title: "跟进", date: future) }
        check(ReminderSchedule.requests(many.reversed(), now: now).map(\.identifier) == (0..<50).map { String(format: "cubic.%02d", $0) }, "Capacity limit must keep a deterministic earliest fifty")

        let center = FakeNotificationCenter(), service = ReminderService(center: center)
        let legacyContent = UNMutableNotificationContent(); legacyContent.body = "旧风险"
        let legacy = UNNotificationRequest(identifier: "cubic.legacy", content: legacyContent,
                                           trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false))
        let unrelated = UNNotificationRequest(identifier: "unrelated", content: legacyContent, trigger: nil)
        await center.seed([legacy, unrelated].map { ImmutableNotificationRequest(request: $0) })
        try await service.replace([next])
        var counts = await center.counts()
        check(counts.0 == 1 && counts.1 == 1, "Replace must remove legacy requests and add only the future reminder")
        try await service.replace([next])
        counts = await center.counts()
        check(counts.0 == 1 && counts.1 == 1, "Repeated refresh must do no SDK mutations")
        let changed = FollowUpReminder(id: "next", title: "已更新", date: future.addingTimeInterval(60), noticeID: "followup.next")
        try await service.replace([changed])
        counts = await center.counts()
        check(counts.0 == 2 && counts.1 == 2, "Changed date must remove the old request before replacement")
        try await service.replace([])
        let remaining = await center.pendingRequests()
        check(remaining.map { $0.request.identifier } == ["unrelated"], "Disable/read/resolve must cancel only Cubic requests")
        await center.setAuthorized(false)
        await center.seed(desired.map { ImmutableNotificationRequest(request: $0) })
        try await service.replace([next])
        check(await center.pendingRequests().map { $0.request.identifier } == ["unrelated"], "Revoked permission must cancel stale Cubic requests")

        await center.setAuthorized(true)
        await center.injectFailure()
        do { try await service.replace([next]); preconditionFailure("Expected injected SDK error") }
        catch FakeNotificationCenter.Failure.injected { }
        try await service.replace([next])
        check(await center.pendingRequests().contains { $0.request.identifier == "cubic.next" }, "Queue must recover after SDK failure")
        await center.injectFailure()
        do { try await service.replace([changed]); preconditionFailure("Expected replacement error") }
        catch FakeNotificationCenter.Failure.injected { }
        check(await center.pendingRequests().allSatisfy { $0.request.identifier != "cubic.next" }, "A failed update must not keep an alert at the old date")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { try await service.replace([changed]) } }
            try await group.waitForAll()
        }
        counts = await center.counts()
        check(counts.2 == 1, "Concurrent refreshes must never overlap SDK adds")
        check(await center.pendingRequests().filter { $0.request.identifier.hasPrefix("cubic.") }.count == 1, "Concurrent refreshes must leave exactly one future request")

        let delayedCenter = FakeNotificationCenter(), delayedService = ReminderService(center: delayedCenter)
        await delayedCenter.seed(desired.map { ImmutableNotificationRequest(request: $0) })
        await delayedCenter.setDeferredRemoval(true)
        let disabling = Task { try await delayedService.replace([]) }
        let flush = Task { try await Task.sleep(for: .milliseconds(40)); await delayedCenter.completeRemovals() }
        try await disabling.value
        try await flush.value
        try await delayedService.replace([next])
        check(await delayedCenter.pendingRequests().contains { $0.request.identifier == "cubic.next" }, "Re-enable must add after delayed deletion is confirmed")

        var removalTimedOut = false
        do { try await delayedService.replace([]) } catch { removalTimedOut = true }
        check(removalTimedOut, "Unconfirmed deletion must fail within the bounded wait")
        let issuedBeforeRetry = await delayedCenter.counts().1
        await delayedCenter.completeRemovals()
        try await delayedService.replace([next])
        check(await delayedCenter.counts().1 == issuedBeforeRetry, "Retry must not issue a second delayed deletion")
        check(await delayedCenter.pendingRequests().contains { $0.request.identifier == "cubic.next" }, "Retry must restore the future reminder after confirmation")
        let pastDeadline = now.addingTimeInterval(-4 * 86400)
        let slot = CapacitySlot(start: now, end: now.addingTimeInterval(8 * 3600))
        var archivedWorkspace = Workspace(
            projects: [
                Project(id: "archived", name: "项目1", deadline: pastDeadline),
                Project(id: "live", name: "仍在进行", deadline: pastDeadline)
            ],
            items: [
                WorkItem(id: "archived-work", name: "归档工作", projectIDs: ["archived"], remainingMinutes: 60),
                WorkItem(id: "live-work", name: "进行中的工作", projectIDs: ["live"], remainingMinutes: 60)
            ])
        let openPlan = try Engine.plan(workspace: archivedWorkspace, input: PlanningInput(slots: [slot], now: now))
        let opened = RiskNoticeEngine.changes(workspace: archivedWorkspace, planning: openPlan, now: now)
        check(opened.contains { !$0.isResolved && $0.kind == "capacityConflict" && $0.projectIDs.contains("archived") }, "An active overdue project must still raise a reminder")
        check(opened.contains { !$0.isResolved && $0.kind == "capacityConflict" && $0.projectIDs.contains("live") }, "A second overdue project must still raise a reminder")
        for value in opened { archivedWorkspace.history.append(try RiskNoticeEngine.event(value, at: now)) }
        let archivedIndex = archivedWorkspace.projects.firstIndex { $0.id == "archived" }!
        archivedWorkspace.projects[archivedIndex].isArchived = true
        let hiddenPlan = try Engine.plan(workspace: archivedWorkspace, input: PlanningInput(slots: [slot], now: later))
        let hidden = RiskNoticeEngine.changes(workspace: archivedWorkspace, planning: hiddenPlan, now: later)
        check(!hidden.contains { !$0.isResolved && $0.projectIDs.contains("archived") }, "Archived projects must not keep an overdue reminder")
        check(hidden.contains { $0.isResolved && $0.projectIDs.contains("archived") }, "An existing reminder must close when its project is archived")
        var settled = archivedWorkspace
        for value in hidden { settled.history.append(try RiskNoticeEngine.event(value, at: later)) }
        let stored = RiskNoticeEngine.stored(in: settled)
        check(!stored.contains { !$0.isResolved && $0.projectIDs.contains("archived") }, "Stored reminders must not list the archived project as open")
        check(stored.contains { !$0.isResolved && $0.projectIDs.contains("live") }, "Archiving one project must leave the other project's reminder")
        print("PASS: \(checks) notification regression checks")
    }
}
