import Foundation
import CubicCore

struct WorkPeriod: Codable, Sendable, Identifiable, Equatable {
    var id = UUID().uuidString
    var startMinute: Int
    var endMinute: Int
    var energy = "normal"
}

struct DayAvailabilityOverride: Codable, Sendable, Identifiable, Equatable {
    /// Local date in the configured work timezone; independent of device timezone changes.
    var id: String
    var unavailable = false
    var periods: [WorkPeriod] = []
}

enum CalendarOccupancyPolicy: String, Codable, Sendable, CaseIterable {
    case occupies, ignore, uncertain
    var label: String {
        switch self {
        case .occupies: "计入占用"
        case .ignore: "不计占用"
        case .uncertain: "未确认，暂按忙碌计算"
        }
    }
}

struct CalendarOccupancyRule: Codable, Sendable, Equatable {
    var allDay: CalendarOccupancyPolicy = .uncertain
    var unknownAvailability: CalendarOccupancyPolicy = .uncertain
}

/// EventKit identifiers are local. Match a selected calendar by source and title on another device.
struct SyncedCalendarSelection: Codable, Sendable, Equatable {
    var localID: String
    var title: String?
    var sourceTitle: String?
    var sourceType: Int?
    var rule: CalendarOccupancyRule
    func resolvedID(in calendars: [DeviceCalendar]) -> String {
        if calendars.contains(where: { $0.id == localID }) { return localID }
        let matches = calendars.filter { title != nil && $0.title == title && $0.sourceTitle == sourceTitle && $0.sourceType == sourceType }
        // An ambiguous/missing match remains missing capacity, never silently selects another calendar.
        return matches.count == 1 ? matches[0].id : localID
    }
}

private struct SyncedWorkSchedule: Codable {
    var workStartHour: Int
    var workEndHour: Int
    var workWeekends: Bool
    var slotEnergy: String
    var workTimeZoneID: String?
    var workScheduleConfigured: Bool?
    var workPeriods: [WorkPeriod]?
}
private struct SyncedCalendarSettings: Codable {
    var selected: [SyncedCalendarSelection]?
    var countAllDayEvents: Bool
}

enum ReminderCategory: String, CaseIterable, Sendable {
    case risks, waiting, results, unlocks
    var label: String {
        switch self {
        case .risks: "截止与时间不足"
        case .waiting: "等待与跟进到期"
        case .results: "验收未通过与成果复核"
        case .unlocks: "等待结束与可开始的工作"
        }
    }
    static func category(for kind: String) -> Self {
        switch kind {
        case "followUp", "waitingExpected": .waiting
        case "review", "acceptanceFailed": .results
        case "unlock": .unlocks
        default: .risks
        }
    }
}

struct UserPreferences: Codable, Sendable, Equatable {
    var workStartHour = 9
    var workEndHour = 18
    // Decode old backups without carrying their former daily cap into the PRD resource model.
    var dailyLimitMinutes = 240
    var workWeekends = false
    var slotEnergy = "normal"
    var selectedCalendarIDs: Set<String>?
    var countAllDayEvents = true
    var calendarEnabled = false
    var remindersEnabled = false
    // Optional so existing preferences/backups retain their prior all-category behavior.
    var disabledReminderCategories: Set<String>?
    func allowsReminder(kind: String) -> Bool {
        remindersEnabled && !(disabledReminderCategories ?? []).contains(ReminderCategory.category(for: kind).rawValue)
    }
    var demoCapacityStart: Date?
    var demoScenarioVersion: Int?
    var workTimeZoneID: String?
    var workScheduleConfigured: Bool?
    var workPeriods: [WorkPeriod]?
    var dayOverrides: [DayAvailabilityOverride]?
    var calendarOccupancyRules: [String: CalendarOccupancyRule]?
    var syncedCalendarSelection: [SyncedCalendarSelection]?
    /// Device-only cache, excluded from syncValues, preserves identities while permission is unavailable.
    var calendarIDBindings: [String: String]?
    /// 旧数据“验收规则已更新”一次性提示是否已确认（可选以兼容旧偏好）。
    var acceptanceNoticeAcknowledged: Bool?

    var workTimeZone: TimeZone { TimeZone(identifier: workTimeZoneID ?? TimeZone.current.identifier) ?? .current }
    var hasDeclaredWorkSchedule: Bool { workScheduleConfigured ?? (workPeriods != nil) }
    var effectiveWorkPeriods: [WorkPeriod] {
        workPeriods ?? [WorkPeriod(id: "legacy-work-period", startMinute: workStartHour * 60, endMinute: workEndHour * 60, energy: slotEnergy)]
    }
    func dateKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = workTimeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    func rule(for calendarID: String) -> CalendarOccupancyRule {
        calendarOccupancyRules?[calendarID] ?? CalendarOccupancyRule()
    }

    static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: "cubic.preferences"),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func save(defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: "cubic.preferences") }
    }
    func syncValues(calendars: [DeviceCalendar]) throws -> [String: JSONValue] {
        func value<T: Encodable>(_ value: T) throws -> JSONValue {
            try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        }
        let selections = selectedCalendarIDs.map { ids in
            ids.sorted().map { id in
                let calendar = calendars.first { $0.id == id }
                let previous = syncedCalendarSelection?.first { $0.resolvedID(in: calendars) == id || calendarIDBindings?[id] == $0.localID }
                return SyncedCalendarSelection(localID: previous?.localID ?? id, title: calendar?.title ?? previous?.title,
                    sourceTitle: calendar?.sourceTitle ?? previous?.sourceTitle, sourceType: calendar?.sourceType ?? previous?.sourceType, rule: rule(for: id))
            }.sorted { $0.localID < $1.localID }
        }
        return ["workSchedule": try value(SyncedWorkSchedule(workStartHour: workStartHour, workEndHour: workEndHour,
            workWeekends: workWeekends, slotEnergy: slotEnergy, workTimeZoneID: workTimeZoneID,
            workScheduleConfigured: workScheduleConfigured, workPeriods: workPeriods)),
            "dayOverrides": try value((dayOverrides ?? []).sorted { $0.id < $1.id }),
            "calendarEnabled": .bool(calendarEnabled),
            "calendarSelection": try value(SyncedCalendarSettings(selected: selections, countAllDayEvents: countAllDayEvents)),
            "remindersEnabled": .bool(remindersEnabled),
            "disabledReminderCategories": try value((disabledReminderCategories ?? []).sorted())]
    }
    func applyingSyncValues(_ fields: [String: JSONValue], calendars: [DeviceCalendar]) throws -> Self {
        var result = self
        func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue) throws -> T {
            try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
        }
        if let field = fields["workSchedule"] {
            let schedule = try decode(SyncedWorkSchedule.self, field)
            result.workStartHour = schedule.workStartHour; result.workEndHour = schedule.workEndHour
            result.workWeekends = schedule.workWeekends; result.slotEnergy = schedule.slotEnergy
            result.workTimeZoneID = schedule.workTimeZoneID; result.workScheduleConfigured = schedule.workScheduleConfigured
            result.workPeriods = schedule.workPeriods; result.demoCapacityStart = nil
        }
        if let field = fields["dayOverrides"] { result.dayOverrides = try decode([DayAvailabilityOverride].self, field) }
        if let field = fields["calendarEnabled"] { result.calendarEnabled = try decode(Bool.self, field) }
        if let field = fields["calendarSelection"] {
            let settings = try decode(SyncedCalendarSettings.self, field)
            result.syncedCalendarSelection = settings.selected; result.countAllDayEvents = settings.countAllDayEvents
            if settings.selected == nil { result.selectedCalendarIDs = nil; result.calendarOccupancyRules = nil; result.calendarIDBindings = nil }
            result.resolveCalendarSelection(in: calendars)
        }
        if let field = fields["remindersEnabled"] { result.remindersEnabled = try decode(Bool.self, field) }
        if let field = fields["disabledReminderCategories"] { result.disabledReminderCategories = Set(try decode([String].self, field)) }
        try result.validate()
        return result
    }
    mutating func resolveCalendarSelection(in calendars: [DeviceCalendar]) {
        guard let selection = syncedCalendarSelection else { return }
        selectedCalendarIDs = Set(selection.map { $0.resolvedID(in: calendars) })
        calendarOccupancyRules = Dictionary(selection.map { ($0.resolvedID(in: calendars), $0.rule) }, uniquingKeysWith: { first, _ in first })
        calendarIDBindings = Dictionary(selection.map { ($0.resolvedID(in: calendars), $0.localID) }, uniquingKeysWith: { first, _ in first })
    }
    func validate() throws {
        guard (0...23).contains(workStartHour), (1...24).contains(workEndHour), workStartHour < workEndHour,
              ["low", "normal", "high"].contains(slotEnergy),
              workTimeZoneID.map({ TimeZone(identifier: $0) != nil }) ?? true else {
            throw PreferenceError.invalid
        }
        guard effectiveWorkPeriods.count <= 48, (dayOverrides ?? []).count <= 3660,
              (dayOverrides ?? []).allSatisfy({ $0.periods.count <= 48 }) else { throw PreferenceError.invalid }
        for period in effectiveWorkPeriods + (dayOverrides ?? []).flatMap(\.periods) {
            guard (0..<1440).contains(period.startMinute), (1...1440).contains(period.endMinute),
                  period.startMinute < period.endMinute, ["low", "normal", "high"].contains(period.energy) else {
                throw PreferenceError.invalid
            }
        }
        guard Set((dayOverrides ?? []).map(\.id)).count == (dayOverrides ?? []).count else { throw PreferenceError.invalid }
    }
}
enum PreferenceError: LocalizedError {
    case invalid
    var errorDescription: String? { "工作时段、日期例外或时区不正确，请检查后重试。" }
}
