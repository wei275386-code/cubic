import EventKit
import UserNotifications
import Foundation

struct DeviceCalendar: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    var sourceTitle: String? = nil
    var sourceType: Int? = nil
}
struct BusyEvent: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    var calendarID = ""
    var availabilityKnown = true
}
struct CalendarSnapshot: Sendable, Equatable {
    var calendars: [DeviceCalendar] = []
    var events: [BusyEvent] = []
    var authorized = false
    var fetchedAt: Date?
    var missingCalendarIDs: Set<String> = []
}

actor CalendarReader {
    private let store = EKEventStore()
    func requestAccess() async throws -> Bool {
        try await store.requestFullAccessToEvents()
    }
    func read(from: Date, to: Date, selectedIDs: Set<String>?, excludingCalendarID: String? = nil) -> CalendarSnapshot {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return CalendarSnapshot() }
        store.reset() // EventKit change notifications invalidate previously fetched objects.
        let calendars = store.calendars(for: .event)
        let selected = (selectedIDs.map { ids in calendars.filter { ids.contains($0.calendarIdentifier) } } ?? calendars)
            .filter { $0.calendarIdentifier != excludingCalendarID }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: selected)
        let events = selected.isEmpty ? [] : store.events(matching: predicate)
        return CalendarSnapshot(
            calendars: calendars.map { DeviceCalendar(id: $0.calendarIdentifier, title: $0.title, sourceTitle: $0.source.title, sourceType: $0.source.sourceType.rawValue) },
            events: events.filter { $0.availability != .free && $0.status != .canceled }.map {
                BusyEvent(id: "\($0.eventIdentifier ?? UUID().uuidString)-\($0.startDate.timeIntervalSince1970)", title: $0.title ?? "日历占用", start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay,
                          calendarID: $0.calendar.calendarIdentifier, availabilityKnown: $0.availability != .notSupported)
            }.sorted { $0.start < $1.start },
            authorized: true, fetchedAt: Date(), missingCalendarIDs: (selectedIDs ?? []).subtracting(Set(calendars.map(\.calendarIdentifier))))
    }
}

struct FollowUpReminder: Sendable {
    let id: String
    let title: String
    let date: Date
    var noticeID: String?
}

// UNNotificationRequest copies its content and trigger at initialization and is
// immutable. The SDK does not annotate it Sendable; only immutable requests cross
// this boundary, never UNMutableNotificationContent.
struct ImmutableNotificationRequest: @unchecked Sendable {
    let request: UNNotificationRequest
}

protocol ReminderNotificationCenter: Sendable {
    func isAuthorized() async -> Bool
    func pendingRequests() async -> [ImmutableNotificationRequest]
    func removePendingRequests(_ identifiers: [String]) async
    func add(_ request: ImmutableNotificationRequest) async throws
}

struct SystemReminderNotificationCenter: ReminderNotificationCenter {
    func isAuthorized() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }
    func pendingRequests() async -> [ImmutableNotificationRequest] {
        await UNUserNotificationCenter.current().pendingNotificationRequests().map { ImmutableNotificationRequest(request: $0) }
    }
    func removePendingRequests(_ identifiers: [String]) async {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }
    func add(_ request: ImmutableNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request.request)
    }
}

enum ReminderSchedule {
    static func requests(_ reminders: [FollowUpReminder], now: Date) -> [UNNotificationRequest] {
        reminders.filter { $0.date > now }.sorted {
            $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date
        }.prefix(50).map { reminder in
            let content = UNMutableNotificationContent()
            content.title = "Cubic 提醒"
            content.body = reminder.title
            content.sound = .default
            if let noticeID = reminder.noticeID { content.userInfo = ["cubic.noticeID": noticeID] }
            // Absolute dates stay identical across launches and minute-by-minute refreshes.
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let roundedDate = Date(timeIntervalSince1970: ceil(reminder.date.timeIntervalSince1970))
            let components = calendar.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second], from: roundedDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            return UNNotificationRequest(identifier: "cubic.\(reminder.id)", content: content, trigger: trigger)
        }
    }
    static func matches(_ lhs: UNNotificationRequest, _ rhs: UNNotificationRequest) -> Bool {
        lhs.content.isEqual(rhs.content) && lhs.trigger?.isEqual(rhs.trigger) == true
    }
    static var foregroundPresentation: UNNotificationPresentationOptions { [] }
}

// Actor isolation alone does not serialize SDK operations across suspension points.
// Hold the queue until the last in-flight add has returned, including on failure.
actor ReminderReplacementQueue {
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run(_ operation: @Sendable () async throws -> Void) async throws {
        if occupied {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            occupied = true
        }
        defer {
            if waiters.isEmpty { occupied = false }
            else { waiters.removeFirst().resume() }
        }
        try await operation()
    }
}
actor ReminderService {
    private let replacements = ReminderReplacementQueue()
    private let center: any ReminderNotificationCenter
    private var unconfirmedRemovalIDs = Set<String>()
    private enum ReplacementError: LocalizedError {
        case removalNotConfirmed
        var errorDescription: String? { "系统尚未确认取消提醒，下次刷新会重试。" }
    }
    init(center: any ReminderNotificationCenter = SystemReminderNotificationCenter()) {
        self.center = center
    }
    func enable() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }
    func status() async -> Bool {
        await center.isAuthorized()
    }
    func replace(_ reminders: [FollowUpReminder]) async throws {
        try await replacements.run { [self] in try await replaceNow(reminders) }
    }
    private func replaceNow(_ reminders: [FollowUpReminder]) async throws {
        // A failed/cancelled confirmation must finish before a later enable can
        // compare pending requests; a stale read must never skip a necessary add.
        if !unconfirmedRemovalIDs.isEmpty { try await removeAndConfirm(Array(unconfirmedRemovalIDs)) }
        let previous = await center.pendingRequests().map(\.request).filter { $0.identifier.hasPrefix("cubic.") }
        let authorized = await status()
        let desired = authorized ? ReminderSchedule.requests(reminders, now: Date()) : []
        let desiredByID = Dictionary(uniqueKeysWithValues: desired.map { ($0.identifier, $0) })
        let obsolete = previous.filter { old in
            guard let new = desiredByID[old.identifier] else { return true }
            return !ReminderSchedule.matches(old, new)
        }.map(\.identifier)
        if !obsolete.isEmpty { try await removeAndConfirm(obsolete) }
        let removedIDs = Set(obsolete)
        let existing = Dictionary(uniqueKeysWithValues: previous.filter { !removedIDs.contains($0.identifier) }.map { ($0.identifier, $0) })
        for request in desired {
            if let old = existing[request.identifier], ReminderSchedule.matches(old, request) { continue }
            // A request may expire while SDK operations are in flight. Never turn it
            // into an immediate catch-up alert or schedule the same event again.
            guard let trigger = request.trigger as? UNCalendarNotificationTrigger,
                  let date = trigger.nextTriggerDate(), date > Date() else {
                if existing[request.identifier] != nil { try await removeAndConfirm([request.identifier]) }
                continue
            }
            try await center.add(ImmutableNotificationRequest(request: request))
        }
    }
    private func removeAndConfirm(_ identifiers: [String]) async throws {
        let removing = Set(identifiers)
        let newlyRemoving = removing.subtracting(unconfirmedRemovalIDs)
        unconfirmedRemovalIDs.formUnion(removing)
        // Retry confirmation, not the same outstanding removal command. A second
        // delayed remove could otherwise erase a request added after the first.
        if !newlyRemoving.isEmpty { await center.removePendingRequests(Array(newlyRemoving)) }
        // The SDK removal method has no completion. Only an observed absence is
        // confirmation; bound the wait and retain failed IDs for the next retry.
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        repeat {
            let pendingIDs = Set(await center.pendingRequests().map { $0.request.identifier })
            if removing.isDisjoint(with: pendingIDs) {
                unconfirmedRemovalIDs.subtract(removing)
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        throw ReplacementError.removalNotConfirmed
    }
}

extension Notification.Name {
    static let cubicNotificationOpened = Notification.Name("cubic.notification.opened")
}

@MainActor final class CubicNotificationRoute {
    static let shared = CubicNotificationRoute()
    private var pendingNoticeID: String?
    func receive(_ noticeID: String) {
        pendingNoticeID = noticeID
        NotificationCenter.default.post(name: .cubicNotificationOpened, object: noticeID)
    }
    func takePendingNoticeID() -> String? {
        defer { pendingNoticeID = nil }
        return pendingNoticeID
    }
}

final class CubicNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = CubicNotificationDelegate()
    // The async ObjC witness can complete on the cooperative executor. UIKit's
    // notification-open state restoration requires the completion on the main thread.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let id = response.notification.request.content.userInfo["cubic.noticeID"] as? String
        Task { @MainActor in
            if let id { CubicNotificationRoute.shared.receive(id) }
            completionHandler()
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in completionHandler(ReminderSchedule.foregroundPresentation) }
    }
}

protocol SuggestionProvider: Sendable {
    func suggestion() async -> String?
}
struct SilentSuggestionProvider: SuggestionProvider {
    func suggestion() async -> String? { nil }
}
