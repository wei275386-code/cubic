import XCTest
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

@MainActor final class NotificationRegressionTests: XCTestCase {
    func notice(kind: String, date: Date?) -> RiskNotice {
        RiskNotice(id: kind, rootObjectID: "root", kind: kind, title: "标题", body: "内容",
                   projectIDs: [], itemIDs: [], createdAt: Date(), changedAt: Date(),
                   dueAt: date, fingerprint: "same")
    }
    func reminders(_ notices: [RiskNotice]) -> [FollowUpReminder] {
        notices.compactMap { notice in
            notice.nextNotificationDate.map { FollowUpReminder(id: notice.id, title: notice.title, date: $0, noticeID: notice.id) }
        }
    }
    func testNotificationRegressions() async throws {
        let now = Date(), future = now.addingTimeInterval(3600), past = now.addingTimeInterval(-3600)
        for kind in ["capacityConflict", "projectRisk", "syncConflict", "review", "acceptanceFailed", "unlock"] {
            var old = notice(kind: kind, date: now.addingTimeInterval(2))
            XCTAssertTrue(old.nextNotificationDate == nil, "Legacy immediate risks must stay in app: \(kind)")
            old.isRead = true; old.snoozedUntil = future
            XCTAssertTrue(old.nextNotificationDate == future, "An explicit snooze must work after acknowledgement")
            old.isResolved = true
            XCTAssertTrue(old.nextNotificationDate == nil, "Resolved notices must not alert")
        }
        var followUp = notice(kind: "followUp", date: future)
        XCTAssertTrue(followUp.nextNotificationDate == future, "Future declared dates must survive")
        followUp.isRead = true
        XCTAssertTrue(followUp.nextNotificationDate == nil, "Read follow-ups must not alert")
        XCTAssertTrue(ReminderSchedule.foregroundPresentation.isEmpty, "Foreground must be quiet")

        // Reproduce opening a workspace with fifteen overdue waits and fifteen reviews.
        var workspace = Workspace(
            items: (0..<15).map { WorkItem(id: "item\($0)", name: "成果\($0)", remainingMinutes: 0, status: .completed, completedAt: past, needsReview: true) },
            blockers: (0..<15).map { Blocker(id: "wait\($0)", name: "等待\($0)", state: .active, expectedResolution: past, triggeredAt: past.addingTimeInterval(-3600), followUpAt: past) })
        let planning = try Engine.plan(workspace: workspace, input: PlanningInput(slots: [], now: now))
        let changes = RiskNoticeEngine.changes(workspace: workspace, planning: planning, now: now)
        XCTAssertTrue(changes.filter { $0.kind == "review" }.count == 15, "In-app risks must remain visible")
        XCTAssertTrue(changes.filter { $0.kind == "followUp" }.allSatisfy { $0.dueAt == past }, "Overdue dates must not be shifted to launch time")
        XCTAssertTrue(ReminderSchedule.requests(reminders(changes), now: now).isEmpty, "Opening this workspace must schedule zero alerts")
        for value in changes { workspace.history.append(try RiskNoticeEngine.event(value, at: now)) }
        let later = now.addingTimeInterval(60)
        let refreshed = try Engine.plan(workspace: workspace, input: PlanningInput(slots: [], now: later))
        XCTAssertTrue(RiskNoticeEngine.changes(workspace: workspace, planning: refreshed, now: later).isEmpty, "Unchanged notices must not be regenerated")
        var earlierReview = changes.first { $0.kind == "review" }!
        earlierReview.fingerprint = "previous-round"
        earlierReview.snoozedUntil = future
        workspace.history.append(try RiskNoticeEngine.event(earlierReview, at: later))
        let changedReview = RiskNoticeEngine.changes(workspace: workspace, planning: refreshed, now: later.addingTimeInterval(1))
            .first { $0.id == earlierReview.id }!
        XCTAssertTrue(changedReview.nextNotificationDate == future, "Recalculated risk must preserve the user's explicit reminder")

        var scheduledWorkspace = Workspace(blockers: [Blocker(id: "future", name: "未来等待", state: .active,
            expectedResolution: future, triggeredAt: past, followUpAt: future.addingTimeInterval(60))])
        let scheduledPlan = try Engine.plan(workspace: scheduledWorkspace, input: PlanningInput(slots: [], now: now))
        let scheduledChanges = RiskNoticeEngine.changes(workspace: scheduledWorkspace, planning: scheduledPlan, now: now)
        XCTAssertTrue(scheduledChanges.count == 2 && reminders(scheduledChanges).count == 2, "Both declared future dates must remain schedulable")
        var snoozed = scheduledChanges.first { $0.kind == "followUp" }!
        snoozed.isRead = true
        scheduledWorkspace.history.append(try RiskNoticeEngine.event(snoozed, at: now))
        snoozed.snoozedUntil = future.addingTimeInterval(86400)
        scheduledWorkspace.history.append(try RiskNoticeEngine.event(snoozed, at: later))
        let restored = RiskNoticeEngine.stored(in: scheduledWorkspace)[0]
        XCTAssertTrue(restored.nextNotificationDate == snoozed.snoozedUntil, "Persisted snooze must survive monotonic read acknowledgement")
        snoozed.snoozedUntil = nil
        scheduledWorkspace.history.append(try RiskNoticeEngine.event(snoozed, at: later.addingTimeInterval(1)))
        XCTAssertTrue(RiskNoticeEngine.stored(in: scheduledWorkspace)[0].nextNotificationDate == nil, "Marking read again must cancel a persisted snooze")

        var legacyTimedWorkspace = Workspace(blockers: [Blocker(id: "legacy-timed", name: "旧跟进", state: .active,
            triggeredAt: past.addingTimeInterval(-3600), followUpAt: past)])
        let legacyTimedPlan = try Engine.plan(workspace: legacyTimedWorkspace, input: PlanningInput(slots: [], now: now))
        var legacyTimed = RiskNoticeEngine.changes(workspace: legacyTimedWorkspace, planning: legacyTimedPlan, now: now)[0]
        legacyTimed.dueAt = future
        legacyTimedWorkspace.history.append(try RiskNoticeEngine.event(legacyTimed, at: now))
        let repairedLegacy = RiskNoticeEngine.changes(workspace: legacyTimedWorkspace, planning: legacyTimedPlan, now: later)
        XCTAssertTrue(repairedLegacy.count == 1 && repairedLegacy[0].dueAt == past, "Legacy timed notice must recover its real declared date")
        XCTAssertTrue(ReminderSchedule.requests(reminders(repairedLegacy), now: later).isEmpty, "A legacy artificial future date must not alert")

        let next = FollowUpReminder(id: "next", title: "跟进", date: future, noticeID: "followup.next")
        let desired = ReminderSchedule.requests([next], now: now)
        let trigger = desired[0].trigger as! UNCalendarNotificationTrigger
        XCTAssertTrue(!trigger.repeats && abs(trigger.nextTriggerDate()!.timeIntervalSince(future)) < 1, "Absolute trigger must fire at the requested instant")
        XCTAssertTrue(trigger.nextTriggerDate()! >= future, "Second precision must never schedule before the declared date")
        XCTAssertTrue(desired[0].content.userInfo["cubic.noticeID"] as? String == "followup.next", "Tapping must retain the detail route")
        XCTAssertTrue(ReminderSchedule.matches(desired[0], ReminderSchedule.requests([next], now: later)[0]), "Refresh must produce the same request")
        XCTAssertTrue(ReminderSchedule.requests([FollowUpReminder(id: "past", title: "过期", date: past)], now: now).isEmpty, "Never catch up overdue reminders")
        let many = (0..<70).map { FollowUpReminder(id: String(format: "%02d", $0), title: "跟进", date: future) }
        XCTAssertTrue(ReminderSchedule.requests(many.reversed(), now: now).map(\.identifier) == (0..<50).map { String(format: "cubic.%02d", $0) }, "Capacity limit must keep a deterministic earliest fifty")

        let center = FakeNotificationCenter(), service = ReminderService(center: center)
        let legacyContent = UNMutableNotificationContent(); legacyContent.body = "旧风险"
        let legacy = UNNotificationRequest(identifier: "cubic.legacy", content: legacyContent,
                                           trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false))
        let unrelated = UNNotificationRequest(identifier: "unrelated", content: legacyContent, trigger: nil)
        await center.seed([legacy, unrelated].map { ImmutableNotificationRequest(request: $0) })
        try await service.replace([next])
        var counts = await center.counts()
        XCTAssertTrue(counts.0 == 1 && counts.1 == 1, "Replace must remove legacy requests and add only the future reminder")
        try await service.replace([next])
        counts = await center.counts()
        XCTAssertTrue(counts.0 == 1 && counts.1 == 1, "Repeated refresh must do no SDK mutations")
        let changed = FollowUpReminder(id: "next", title: "已更新", date: future.addingTimeInterval(60), noticeID: "followup.next")
        try await service.replace([changed])
        counts = await center.counts()
        XCTAssertTrue(counts.0 == 2 && counts.1 == 2, "Changed date must remove the old request before replacement")
        try await service.replace([])
        let remaining = await center.pendingRequests()
        XCTAssertTrue(remaining.map { $0.request.identifier } == ["unrelated"], "Disable/read/resolve must cancel only Cubic requests")
        await center.setAuthorized(false)
        await center.seed(desired.map { ImmutableNotificationRequest(request: $0) })
        try await service.replace([next])
        let condition1 = await center.pendingRequests().map { $0.request.identifier } == ["unrelated"]
        XCTAssertTrue(condition1, "Revoked permission must cancel stale Cubic requests")

        await center.setAuthorized(true)
        await center.injectFailure()
        do { try await service.replace([next]); XCTFail("Expected injected SDK error") }
        catch FakeNotificationCenter.Failure.injected { }
        try await service.replace([next])
        let condition2 = await center.pendingRequests().contains { $0.request.identifier == "cubic.next" }
        XCTAssertTrue(condition2, "Queue must recover after SDK failure")
        await center.injectFailure()
        do { try await service.replace([changed]); XCTFail("Expected replacement error") }
        catch FakeNotificationCenter.Failure.injected { }
        let condition3 = await center.pendingRequests().allSatisfy { $0.request.identifier != "cubic.next" }
        XCTAssertTrue(condition3, "A failed update must not keep an alert at the old date")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { try await service.replace([changed]) } }
            try await group.waitForAll()
        }
        counts = await center.counts()
        XCTAssertTrue(counts.2 == 1, "Concurrent refreshes must never overlap SDK adds")
        let condition4 = await center.pendingRequests().filter { $0.request.identifier.hasPrefix("cubic.") }.count == 1
        XCTAssertTrue(condition4, "Concurrent refreshes must leave exactly one future request")

        let delayedCenter = FakeNotificationCenter(), delayedService = ReminderService(center: delayedCenter)
        await delayedCenter.seed(desired.map { ImmutableNotificationRequest(request: $0) })
        await delayedCenter.setDeferredRemoval(true)
        let disabling = Task { try await delayedService.replace([]) }
        let flush = Task { try await Task.sleep(for: .milliseconds(40)); await delayedCenter.completeRemovals() }
        try await disabling.value
        try await flush.value
        try await delayedService.replace([next])
        let condition5 = await delayedCenter.pendingRequests().contains { $0.request.identifier == "cubic.next" }
        XCTAssertTrue(condition5, "Re-enable must add after delayed deletion is confirmed")

        var removalTimedOut = false
        do { try await delayedService.replace([]) } catch { removalTimedOut = true }
        XCTAssertTrue(removalTimedOut, "Unconfirmed deletion must fail within the bounded wait")
        let issuedBeforeRetry = await delayedCenter.counts().1
        await delayedCenter.completeRemovals()
        try await delayedService.replace([next])
        let condition6 = await delayedCenter.counts().1 == issuedBeforeRetry
        XCTAssertTrue(condition6, "Retry must not issue a second delayed deletion")
        let condition7 = await delayedCenter.pendingRequests().contains { $0.request.identifier == "cubic.next" }
        XCTAssertTrue(condition7, "Retry must restore the future reminder after confirmation")
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
        XCTAssertTrue(opened.contains { !$0.isResolved && $0.kind == "capacityConflict" && $0.projectIDs.contains("archived") }, "An active overdue project must still raise a reminder")
        XCTAssertTrue(opened.contains { !$0.isResolved && $0.kind == "capacityConflict" && $0.projectIDs.contains("live") }, "A second overdue project must still raise a reminder")
        for value in opened { archivedWorkspace.history.append(try RiskNoticeEngine.event(value, at: now)) }
        let archivedIndex = archivedWorkspace.projects.firstIndex { $0.id == "archived" }!
        archivedWorkspace.projects[archivedIndex].isArchived = true
        let hiddenPlan = try Engine.plan(workspace: archivedWorkspace, input: PlanningInput(slots: [slot], now: later))
        let hidden = RiskNoticeEngine.changes(workspace: archivedWorkspace, planning: hiddenPlan, now: later)
        XCTAssertTrue(!hidden.contains { !$0.isResolved && $0.projectIDs.contains("archived") }, "Archived projects must not keep an overdue reminder")
        XCTAssertTrue(hidden.contains { $0.isResolved && $0.projectIDs.contains("archived") }, "An existing reminder must close when its project is archived")
        var settled = archivedWorkspace
        for value in hidden { settled.history.append(try RiskNoticeEngine.event(value, at: later)) }
        let stored = RiskNoticeEngine.stored(in: settled)
        XCTAssertTrue(!stored.contains { !$0.isResolved && $0.projectIDs.contains("archived") }, "Stored reminders must not list the archived project as open")
        XCTAssertTrue(stored.contains { !$0.isResolved && $0.projectIDs.contains("live") }, "Archiving one project must leave the other project's reminder")
    }
}
