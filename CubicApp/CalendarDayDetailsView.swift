import SwiftUI
import CubicCore

/// Secondary calendar layers for one day: free slots, Apple Calendar occupancy,
/// deadlines, latest starts, waits, the last trial and recorded effort.
struct CalendarDayDetailsView: View {
    let day: Date
    let itemIDs: Set<String>
    @Environment(AppModel.self) private var model
    @State private var showSelectedTrial = true
    private var cal: Calendar { model.workCalendar }
    private var events: [BusyEvent] { model.busyEvents(on: day) }
    private var slots: [CapacitySlot] { model.capacitySlots(on: day) }
    private var projects: [Project] {
        model.workspace.projects.filter { project in
            let members = model.projectItemIDs(project.id)
            return !project.archived && (members.isEmpty || !members.isDisjoint(with: itemIDs))
        }
    }
    private func isCalendarVisible(_ id: String) -> Bool { itemIDs.contains(id) }
    var body: some View {
        List {
            CalendarIntegrationStatusSection()
            Section("可用时间") {
                if slots.isEmpty {
                    Label("这一天没有已设置的空档", systemImage: "moon.zzz")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                        HStack(alignment: .top, spacing: 12) {
                            RoundedRectangle(cornerRadius: 2).fill(Color.cubicAccent).frame(width: 4)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(calendarDate(slot.start, includeDate: false)) – \(calendarDate(slot.end, includeDate: false))")
                                    .font(.headline).monospacedDigit()
                                Text("\(minutesLabel(Int(slot.end.timeIntervalSince(slot.start) / 60))) · \(slot.energy == .high ? "高专注" : slot.energy == .low ? "低负荷" : "普通精力")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 6)
                    }
                }
                Text("空档由工作时段减去日历占用计算。可到设置调整每天的工作时间。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Apple 日历占用") {
                if !model.preferences.calendarEnabled && model.calendarBridge?.enabled != true {
                    Label("尚未启用日历", systemImage: "calendar.badge.exclamationmark")
                    Text("到设置中选择日历占用来源，或开启 Apple Calendar 同步。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !model.calendar.authorized {
                    Text("尚无日历权限，事件占用未计入排期。")
                        .foregroundStyle(Color.cubicAmber)
                } else if events.isEmpty {
                    Text("所选日历在这一天没有占用。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(events) { event in
                        VStack(alignment: .leading, spacing: 6) {
                            Label(event.title, systemImage: "calendar")
                            Text(event.allDay ? "全天 · \(model.preferences.rule(for: event.calendarID).allDay.label)" : "\(calendarDate(event.start, includeDate: false)) – \(calendarDate(event.end, includeDate: false))")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                }
                if !model.calendar.missingCalendarIDs.isEmpty {
                    Label("部分日历在此设备上不可用，请检查日历来源。", systemImage: "exclamationmark.triangle")
                }
                if let date = model.calendar.fetchedAt {
                    Text("更新于 \(calendarDate(date, includeDate: false))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            planningLayers
            selectedTrialLayer
            let actual = model.workspace.effectiveWorkSessions.filter { record in
                guard isCalendarVisible(record.itemID) else { return false }
                if record.hasExactInterval {
                    let start = cal.startOfDay(for: day), end = cal.date(byAdding: .day, value: 1, to: start)!
                    return record.start < end && record.end > start
                }
                return cal.isDate(record.occurredOn ?? record.end, inSameDayAs: day)
            }
            if !actual.isEmpty {
                Section("这一天的投入记录") {
                    ForEach(actual, id: \.id) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.item(record.itemID)?.name ?? "工作记录")
                            Text("\(record.hasExactInterval ? "实际时段" : "大约时长 · 时段未记录")")
                                .font(.caption).foregroundStyle(.secondary)
                            if record.hasExactInterval {
                                Text("\(calendarDate(record.start)) – \(calendarDate(record.end))")
                            }
                            if model.workspace.effortSummary().unresolvedSessionIDs.contains(record.id) {
                                Label("这条投入与其他记录重叠，请核对时间。", systemImage: "exclamationmark.triangle")
                            }
                            Text("\(minutesLabel(record.actualMinutes)) · 剩余 \(minutesLabel(record.remainingMinutesAfter))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .cubicNavigationTitle(CalendarFormat.dayTitle(day, calendar: cal)).cubicInlineNavigationTitle()
        .refreshable { await model.refresh(background: false); await model.refreshCalendarBridge() }
    }
    @ViewBuilder private var planningLayers: some View {
        if model.planning != nil {
            let ids = Set(projects.map(\.id))
            Section("项目截止") {
                let due = projects.filter { $0.deadline.map { cal.isDate($0, inSameDayAs: day) } == true }
                if due.isEmpty { Text("这一天没有所选项目到期").foregroundStyle(.secondary) }
                ForEach(due, id: \.id) { project in
                    NavigationLink { CubicProjectDetailView(projectID: project.id) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Label { ProjectListTitle(text: project.name) } icon: { Image(systemName: "flag.checkered") }
                            if let date = project.deadline {
                                Text("\(ProjectUI.datePart(date, zone: project.deadlineTimeZoneID)) \(ProjectUI.timePart(date, zone: project.deadlineTimeZoneID))")
                            }
                            if let zone = project.deadlineTimeZoneID { Text("截止时区 \(zone)").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            Section("建议的最晚开始时间") {
                // 每项叶子工作一行：节点聚合与“按前置/单项目/全局”分层重复已在投影中折叠。
                let suggestions = model.latestStartSuggestions.filter { suggestion in
                    guard let item = model.item(suggestion.itemID), isCalendarVisible(suggestion.itemID) else { return false }
                    // 按工作自身归属判断可见性：全局/前置层的 projectIDs 含全部项目，不能代表该工作的归属。
                    let scope = model.relatedProjectIDs(for: item)
                    return (scope.isEmpty || !ids.isDisjoint(with: scope)) &&
                    (suggestion.latestStart.map { cal.isDate($0, inSameDayAs: day) } == true || suggestion.latestFinish.map { cal.isDate($0, inSameDayAs: day) } == true)
                }
                if suggestions.isEmpty { Text("这一天没有可显示的最晚开始时间。信息不全时暂不推算。").foregroundStyle(.secondary) }
                ForEach(suggestions) { suggestion in
                    DisclosureGroup {
                        ForEach(Array(suggestion.boundaries.enumerated()), id: \.offset) { _, original in
                            Text(boundaryScope(original)).font(.caption).foregroundStyle(.secondary)
                        }
                        if let date = suggestion.latestStart { Text("最晚开始 \(calendarDate(date))") }
                        if let date = suggestion.latestFinish { Text("最晚完成 \(calendarDate(date))") }
                        Text(suggestion.precision == .necessaryUpperBound ? "这是必须遵守的最晚时间，还需核对其他项目是否排得下。" : suggestion.precision == .feasibleCandidate ? "这是按当前估计和假设排出的时间。" : "信息未齐，暂时无法确认")
                        ForEach(suggestion.conditionIDs.compactMap { model.planningConditionsByID[$0] }, id: \.id) { Text(PlanningCopy.condition($0)).font(.caption) }
                        Text(suggestion.chain.map { name($0) }.joined(separator: " → ")).font(.caption)
                        NavigationLink("查看工作与试算") { WorkDetailView(itemID: suggestion.itemID) }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Label(name(suggestion.itemID), systemImage: "hourglass")
                            Text(suggestion.layers.map(layerName).joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                            if let date = suggestion.latestStart ?? suggestion.latestFinish {
                                Text(calendarDate(date)).font(.caption).foregroundStyle(.secondary)
                            }
                        }.fixedSize(horizontal: false, vertical: true)
                    }.accessibilityIdentifier("calendar.latestStart.\(suggestion.itemID)")
                }
            }
            Section("外部等待") {
                ForEach(model.workspace.blockers.filter { $0.state != .resolved && $0.isArchived != true }, id: \.id) { blocker in
                    DisclosureGroup(blocker.name) {
                        Text(blocker.state == .inactive ? "等待尚未发起" : "等待中，预计时间到后请确认是否结束")
                        if let expected = blocker.estimatedResolution { Text("预计解除 \(calendarDate(expected))") }
                        if let followUp = blocker.followUpAt { Text("跟进日期 \(calendarDate(followUp))") }
                        ForEach(model.workspace.affectedItemIDs(by: .blocker(blocker.id)).compactMap { model.item($0) }, id: \.id) { item in
                            NavigationLink { WorkDetailView(itemID: item.id) } label: { ActionRow(item: item) }
                        }
                    }
                }
            }
            if model.calculationIsStale || model.isRefreshing {
                Label("正在更新，上面的安排暂用上次结果", systemImage: "arrow.triangle.2.circlepath")
            }
        }
    }
    @ViewBuilder private var selectedTrialLayer: some View {
        if let choice = model.workspace.currentNextAction,
           let event = model.workspace.history.last(where: { $0.objectID == choice.id && $0.kind == .choiceRecorded && $0.detail != nil }),
           let detail = event.detail?.data(using: .utf8),
           let trial = try? JSONCoding.decode(PlanningTrialResult.self, from: detail) {
            Section("上次选择时的试算") {
                Toggle("显示当时的建议安排", isOn: $showSelectedTrial)
                Text("选择于 \(calendarDate(choice.date))。这是当时的试算，当前条件可能已经变化。")
                    .font(.caption).foregroundStyle(.secondary)
                if showSelectedTrial {
                    let allocations = trial.allocations.filter { isCalendarVisible($0.itemID) && cal.isDate($0.start, inSameDayAs: day) }
                    if allocations.isEmpty { Text("这次试算没有安排到这一天").foregroundStyle(.secondary) }
                    ForEach(Array(allocations.enumerated()), id: \.offset) { _, allocation in
                        VStack(alignment: .leading, spacing: 5) {
                            Label(trial.source.items.first { $0.id == allocation.itemID }?.name ?? name(allocation.itemID), systemImage: "square.stack.3d.up")
                            Text("\(calendarDate(allocation.start, includeDate: false)) – \(calendarDate(allocation.end, includeDate: false)) · 试算安排")
                                .font(.caption).foregroundStyle(Color.cubicAccent)
                        }
                    }
                }
                NavigationLink("查看这次选择的记录") { ChoiceDetailView(choice: choice) }
            }
        }
    }
    private func name(_ id: String) -> String {
        model.planningReferenceName(id)
    }
    private func calendarDate(_ date: Date, includeDate: Bool = true) -> String {
        date.formatted(Date.FormatStyle(date: includeDate ? .abbreviated : .omitted, time: .shortened, calendar: cal, timeZone: cal.timeZone))
    }
    private func layerName(_ layer: PlanningLayer) -> String {
        switch layer { case .dependency: "按前置关系计算"; case .singleProject: "只考虑本项目"; case .global: "同时考虑所有项目" }
    }
    private func boundaryScope(_ boundary: PlanningBoundary) -> String {
        layerName(boundary.layer) + "：" + boundary.projectIDs.map { model.businessIssue($0) }.joined(separator: "、")
    }
}
