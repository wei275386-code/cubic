import SwiftUI

struct CapacitySettingsSection: View {
    @Binding var preferences: UserPreferences

    var body: some View {
        Section("工作时间") {
            if !preferences.hasDeclaredWorkSchedule {
                Label("以下是默认时段，请按你的实际情况调整并保存。", systemImage: "questionmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if preferences.workPeriods == nil {
                Picker("开始", selection: $preferences.workStartHour) {
                    ForEach(0..<24) { Text(String(format: "%02d:00", $0)).tag($0) }
                }
                Picker("结束", selection: $preferences.workEndHour) {
                    ForEach(1...24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                }
                Picker("这个时段适合做什么", selection: $preferences.slotEnergy) {
                    Text("低负荷").tag("low")
                    Text("普通").tag("normal")
                    Text("高专注").tag("high")
                }
                Button("设置多个工作时段") { preferences.workPeriods = preferences.effectiveWorkPeriods }
                    .accessibilityIdentifier("capacity.multiplePeriods")
            } else {
                ForEach(preferences.workPeriods ?? []) { period in
                    WorkPeriodFields(period: periodBinding(period.id))
                    Button("移除这个时段", role: .destructive) {
                        preferences.workPeriods?.removeAll { $0.id == period.id }
                    }.accessibilityIdentifier("capacity.remove.\(period.id)")
                }
                Button("添加工作时段", systemImage: "plus") {
                    preferences.workPeriods?.append(WorkPeriod(startMinute: 540, endMinute: 600))
                }.accessibilityIdentifier("capacity.addPeriod")
            }
            Toggle("周末也可工作", isOn: $preferences.workWeekends)
                .accessibilityIdentifier("capacity.weekends")
            TextField("工作时区，例如 Asia/Shanghai", text: Binding(get: {
                preferences.workTimeZoneID ?? TimeZone.current.identifier
            }, set: { preferences.workTimeZoneID = $0 }))
                .cubicVerbatimInput().autocorrectionDisabled()
                .accessibilityIdentifier("capacity.timeZone")
            NavigationLink("调整某一天的工作时间") { DayCapacityEditor(preferences: $preferences) }
                .accessibilityIdentifier("capacity.dayOverride")
            Text("可用时间由工作时段减去日历占用计算。高专注时段也能做普通工作，重叠时段只计算一次。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func periodBinding(_ id: String) -> Binding<WorkPeriod> {
        Binding(get: { preferences.workPeriods?.first { $0.id == id } ?? WorkPeriod(id: id, startMinute: 540, endMinute: 600) }, set: { value in
            if let index = preferences.workPeriods?.firstIndex(where: { $0.id == id }) { preferences.workPeriods?[index] = value }
        })
    }
}

private struct WorkPeriodFields: View {
    @Binding var period: WorkPeriod
    private var times: [Int] { Array(Set(stride(from: 0, through: 1440, by: 15)).union([period.startMinute, period.endMinute])).sorted() }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("开始", selection: $period.startMinute) {
                ForEach(times.filter { $0 < 1440 }, id: \.self) { Text(timeLabel($0)).tag($0) }
            }.accessibilityIdentifier("capacity.start.\(period.id)")
            Picker("结束", selection: $period.endMinute) {
                ForEach(times.filter { $0 > 0 }, id: \.self) { Text(timeLabel($0)).tag($0) }
            }.accessibilityIdentifier("capacity.end.\(period.id)")
            Picker("这个时段适合做什么", selection: $period.energy) {
                Text("普通").tag("normal")
                Text("高专注").tag("high")
                Text("低负荷").tag("low")
            }.accessibilityIdentifier("capacity.energy.\(period.id)")
            if period.startMinute >= period.endMinute {
                Label("结束时间必须晚于开始", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
        }.padding(.vertical, 6)
    }
    private func timeLabel(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
}

private struct DayCapacityEditor: View {
    @Binding var preferences: UserPreferences
    @State private var date = Date()
    private var key: String { preferences.dateKey(date) }
    private var value: DayAvailabilityOverride? { preferences.dayOverrides?.first { $0.id == key } }
    var body: some View {
        Form {
            Section {
                DatePicker("日期", selection: $date, displayedComponents: .date)
                    .environment(\.timeZone, preferences.workTimeZone)
                Text("按工作时区 \(preferences.workTimeZone.identifier) 的 \(key) 保存。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if let value {
                    Toggle("这一天不安排工作", isOn: Binding(get: { value.unavailable }, set: { unavailable in
                        update { $0.unavailable = unavailable }
                    })).accessibilityIdentifier("capacity.dayUnavailable")
                    if !value.unavailable {
                        ForEach(value.periods) { period in
                            WorkPeriodFields(period: Binding(get: {
                                self.value?.periods.first { $0.id == period.id } ?? period
                            }, set: { edited in
                                update { override in
                                    if let index = override.periods.firstIndex(where: { $0.id == edited.id }) { override.periods[index] = edited }
                                }
                            }))
                            Button("移除时段", role: .destructive) { update { $0.periods.removeAll { $0.id == period.id } } }
                        }
                        Button("添加当天时段") { update { $0.periods.append(WorkPeriod(startMinute: 540, endMinute: 600)) } }
                    }
                    Button("恢复默认工作时段", role: .destructive) { preferences.dayOverrides?.removeAll { $0.id == key } }
                } else {
                    Text("这一天使用常规工作时段和周末设置。")
                    Button("单独设置这一天") {
                        if preferences.dayOverrides == nil { preferences.dayOverrides = [] }
                        preferences.dayOverrides?.append(DayAvailabilityOverride(id: key, periods: preferences.effectiveWorkPeriods))
                    }.accessibilityIdentifier("capacity.createOverride")
                }
            } footer: { Text("仅调整这一天的工作时间。返回设置并保存后生效。") }
        }
        .cubicNavigationTitle("单日工作时间")
    }
    private func update(_ change: (inout DayAvailabilityOverride) -> Void) {
        guard let index = preferences.dayOverrides?.firstIndex(where: { $0.id == key }), var value = preferences.dayOverrides?[index] else { return }
        change(&value)
        preferences.dayOverrides?[index] = value
    }
}
