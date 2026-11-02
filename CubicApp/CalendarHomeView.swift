import SwiftUI
import CubicCore

// MARK: - Calendar data

extension AppModel {
    func capacitySlots(on day: Date) -> [CapacitySlot] {
        let cal = workCalendar
        let start = cal.startOfDay(for: day), end = cal.date(byAdding: .day, value: 1, to: start)!
        // The planner can coalesce adjacent days. Display only the selected
        // day's intersection, including slots that began on an earlier day.
        return visibleCapacitySlots.compactMap { slot in
            let lower = max(start, slot.start), upper = min(end, slot.end)
            guard lower < upper else { return nil }
            return CapacitySlot(start: lower, end: upper, energy: slot.energy)
        }
    }
    func busyEvents(on day: Date) -> [BusyEvent] {
        let cal = workCalendar
        let start = cal.startOfDay(for: day), end = cal.date(byAdding: .day, value: 1, to: start)!
        return calendar.events.filter { $0.start < end && $0.end > start }
    }
    func availableMinutes(on day: Date) -> Int {
        capacitySlots(on: day).reduce(0) { $0 + Int($1.end.timeIntervalSince($1.start) / 60) }
    }
    func plannedMinutes(on day: Date, itemIDs: Set<String>? = nil) -> Int {
        let cal = workCalendar
        let start = cal.startOfDay(for: day), end = cal.date(byAdding: .day, value: 1, to: start)!
        return (workspace.timeBlocks ?? []).reduce(0) { total, block in
            guard itemIDs?.contains(block.itemID) ?? true, let item = item(block.itemID),
                  !item.archived, item.effectiveDisposition != .cancelled else { return total }
            let lower = max(start, block.start), upper = min(end, block.end)
            return lower < upper ? total + Int(upper.timeIntervalSince(lower) / 60) : total
        }
    }
    /// Work that can start now, soonest deadline first.
    var availableWork: [WorkItem] {
        let ids = Set(snapshot?.availableActions.map(\.itemID) ?? [])
        func deadline(_ item: WorkItem) -> Date {
            min(item.deadline ?? .distantFuture, workspace.projects.filter { relatedProjectIDs(for: item).contains($0.id) }.compactMap(\.deadline).min() ?? .distantFuture)
        }
        return PlanningDisplay.actionItems(workspace: workspace) { relatedProjectIDs(for: $0) }
            .filter { ids.contains($0.id) && !$0.needsReview }
            .sorted { deadline($0) == deadline($1) ? $0.name < $1.name : deadline($0) < deadline($1) }
    }
    func workContext(_ item: WorkItem) -> String {
        let projects = workspace.projects.filter { relatedProjectIDs(for: item).contains($0.id) }.map(\.name)
        let node = workspace.nodes.first { $0.id == item.nodeID }?.name
        let base = projects.isEmpty ? "独立工作" : projects.joined(separator: "、")
        return node.map { "\(base) › \($0)" } ?? base
    }
}

extension Calendar {
    /// Monday-first week containing `day`.
    func workWeek(containing day: Date, includeWeekend: Bool = true) -> [Date] {
        var cal = self
        cal.firstWeekday = 2
        let start = cal.dateInterval(of: .weekOfYear, for: day)?.start ?? cal.startOfDay(for: day)
        return (0..<(includeWeekend ? 7 : 5)).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }
}

enum CalendarFormat {
    static func month(_ date: Date, calendar: Calendar) -> String {
        date.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).locale(Locale(identifier: "zh_CN")).year().month(.wide))
    }
    static func weekday(_ date: Date, calendar: Calendar) -> String {
        date.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).locale(Locale(identifier: "zh_CN")).weekday(.narrow))
    }
    static func dayTitle(_ date: Date, calendar: Calendar) -> String {
        date.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).locale(Locale(identifier: "zh_CN")).month(.defaultDigits).day().weekday(.abbreviated))
    }
    static func time(_ date: Date, calendar: Calendar) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, calendar: calendar, timeZone: calendar.timeZone))
    }
}

// MARK: - Calendar

/// Scheduling surface: the week's capacity, a day's timeline and the work still to place.
struct CalendarHomeView: View {
    @Environment(AppModel.self) private var model
    @State private var day = Date()
    @State private var hiddenProjectIDs: Set<String> = []
    #if os(macOS)
    @State private var weekMode = true
    #endif
    private var cal: Calendar { model.workCalendar }
    private var isToday: Bool { cal.isDate(day, inSameDayAs: Date()) }
    /// Display filter only; scheduling still considers every project.
    private var visibleItemIDs: Set<String> {
        Set(model.workspace.items.filter { item in
            guard !item.archived, item.effectiveDisposition != .cancelled else { return false }
            let projects = model.relatedProjectIDs(for: item)
            let visible = projects.filter { id in !hiddenProjectIDs.contains(id) && model.workspace.projects.contains { $0.id == id && !$0.archived } }
            return projects.isEmpty ? true : !visible.isEmpty
        }.map(\.id))
    }
    private func allocations(on date: Date) -> [TrialAllocation] {
        let ids = visibleItemIDs
        return model.planning?.witness.allocations.filter { ids.contains($0.itemID) && cal.isDate($0.start, inSameDayAs: date) } ?? []
    }

    var body: some View {
        content
            .navigationTitle(CalendarFormat.month(day, calendar: cal))
            .toolbar { toolbar }
            .refreshable { await model.refresh(background: false); await model.refreshCalendarBridge() }
            .task { model.ensureCalendarBridge() }
    }

    #if os(iOS)
    private var content: some View {
        List {
            Section {
                WeekStrip(day: $day, calendar: cal, itemIDs: visibleItemIDs)
            }.listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 4, trailing: 4))
            Section {
                CalendarTimelineView(day: day, calendar: cal, slots: model.capacitySlots(on: day), events: model.busyEvents(on: day),
                                     itemIDs: visibleItemIDs, allocations: allocations(on: day), markers: model.waitMarkers(on: day))
            } header: { DayHeader(day: day, calendar: cal, itemIDs: visibleItemIDs) }
            Section {
                NavigationLink { CalendarDayDetailsView(day: day, itemIDs: visibleItemIDs) } label: {
                    Label("这一天的空档、占用与最晚开始", systemImage: "list.bullet.rectangle")
                }.accessibilityIdentifier("calendar.dayDetails")
            }
        }
        .listSectionSpacing(.compact)
    }
    #else
    private var content: some View {
        let days = weekMode ? cal.workWeek(containing: day, includeWeekend: showsWeekend) : [cal.startOfDay(for: day)]
        return HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("可安排").font(.headline)
                        Spacer()
                        Text("拖到日历上").font(.caption).foregroundStyle(.secondary)
                    }
                    CalendarCandidateRail(itemIDs: visibleItemIDs, allocations: allocations(on: day), calendar: cal,
                                          defaultStart: model.capacitySlots(on: day).first?.start ?? day, axis: .vertical)
                    if model.calendarCandidates(itemIDs: visibleItemIDs).isEmpty {
                        Text("没有待安排的工作").font(.callout).foregroundStyle(.secondary).padding(.top, 8)
                    }
                }.padding(14)
            }.frame(width: 250).background(.background.secondary)
            Divider()
            MacWeekGrid(days: days, selected: $day, calendar: cal, itemIDs: visibleItemIDs,
                        allocations: { allocations(on: $0) }, onSelectDay: { day = $0; weekMode = false })
        }
    }
    private var showsWeekend: Bool {
        let week = cal.workWeek(containing: day)
        return week.suffix(2).contains { model.availableMinutes(on: $0) > 0 || model.plannedMinutes(on: $0) > 0 }
    }
    #endif

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        #if os(macOS)
        ToolbarItemGroup(placement: .navigation) {
            Button("上一页", systemImage: "chevron.left") { move(-1) }
            Button("今天") { day = Date() }.accessibilityIdentifier("calendar.today")
            Button("下一页", systemImage: "chevron.right") { move(1) }
        }
        ToolbarItem(placement: .primaryAction) {
            Picker("视图", selection: $weekMode) {
                Text("日").tag(false)
                Text("周").tag(true)
            }.pickerStyle(.segmented).accessibilityIdentifier("calendar.mode")
        }
        #else
        ToolbarItem(placement: .primaryAction) {
            Button("今天") { withAnimation { day = Date() } }.disabled(isToday).accessibilityIdentifier("calendar.today")
        }
        #endif
        ToolbarItem(placement: .primaryAction) { projectFilter }
    }

    private var projectFilter: some View {
        Menu {
            Button("显示所有项目") { hiddenProjectIDs = [] }
            Divider()
            ForEach(model.workspace.projects.filter { !$0.archived }, id: \.id) { project in
                Toggle(project.name, isOn: Binding(get: { !hiddenProjectIDs.contains(project.id) }, set: { visible in
                    if visible { hiddenProjectIDs.remove(project.id) } else { hiddenProjectIDs.insert(project.id) }
                }))
            }
        } label: {
            Label("筛选项目", systemImage: hiddenProjectIDs.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }.accessibilityIdentifier("calendar.filter")
    }

    #if os(macOS)
    private func move(_ direction: Int) {
        day = cal.date(byAdding: .day, value: direction * (weekMode ? 7 : 1), to: day) ?? day
    }
    #endif
}

/// Kept for deep links that push the calendar from other pages.
struct CalendarView: View {
    var body: some View { CalendarHomeView() }
}

// MARK: - Week strip (iPhone)

struct WeekStrip: View {
    @Binding var day: Date
    let calendar: Calendar
    let itemIDs: Set<String>
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack(spacing: 0) {
            ForEach(calendar.workWeek(containing: day), id: \.self) { date in
                let selected = calendar.isDate(date, inSameDayAs: day)
                let today = calendar.isDate(date, inSameDayAs: Date())
                Button { withAnimation(.snappy) { day = date } } label: {
                    VStack(spacing: 5) {
                        Text(CalendarFormat.weekday(date, calendar: calendar)).font(.caption2).foregroundStyle(.secondary)
                        Text("\(calendar.component(.day, from: date))")
                            .font(.body.weight(selected || today ? .semibold : .regular)).monospacedDigit()
                            .foregroundStyle(selected ? Color.cubicOnAccent : today ? Color.cubicAccent : .primary)
                            .frame(width: 34, height: 34)
                            .background { if selected { Circle().fill(Color.cubicAccent) } }
                        CapacityBar(planned: model.plannedMinutes(on: date, itemIDs: itemIDs), available: model.availableMinutes(on: date), height: 3)
                            .frame(width: 22)
                    }.frame(maxWidth: .infinity).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(CalendarFormat.dayTitle(date, calendar: calendar))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("calendar.week.day.\(calendar.component(.day, from: date))")
            }
        }
        .padding(.vertical, 4)
        .gesture(DragGesture(minimumDistance: 30).onEnded { value in
            guard abs(value.translation.width) > abs(value.translation.height) else { return }
            withAnimation(.snappy) { day = calendar.date(byAdding: .day, value: value.translation.width < 0 ? 7 : -7, to: day) ?? day }
        })
    }
}

struct DayHeader: View {
    let day: Date
    let calendar: Calendar
    let itemIDs: Set<String>
    var title: String? = nil
    @Environment(AppModel.self) private var model
    var body: some View {
        let planned = model.plannedMinutes(on: day, itemIDs: itemIDs), available = model.availableMinutes(on: day)
        HStack(spacing: 8) {
            Text(title ?? CalendarFormat.dayTitle(day, calendar: calendar)).font(.headline).foregroundStyle(.primary)
            Spacer()
            Text(available == 0 && planned == 0 ? "无工作时段" : "已排 \(shortMinutesLabel(planned)) / 可用 \(shortMinutesLabel(available))")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if available > 0 { CapacityBar(planned: planned, available: available).frame(width: 44) }
        }.textCase(nil)
    }
}

// MARK: - Next action

struct NextActionCard: View {
    var compact = false
    @Environment(AppModel.self) private var model
    @State private var sheet: ProjectUISheet?
    private var choice: NextActionChoice? {
        guard let choice = model.workspace.currentNextAction, let id = choice.itemID,
              let item = model.item(id), item.status != .completed else { return nil }
        return choice
    }
    private var target: WorkItem? {
        if let id = choice?.itemID { return model.item(id) }
        return model.availableWork.first
    }
    var body: some View {
        Group {
            if let item = target { card(item) } else { empty }
        }
        .padding(.horizontal, compact ? 0 : 16)
        .sheet(item: $sheet) { ProjectUISheetContent(sheet: $0) }
    }
    private func card(_ item: WorkItem) -> some View {
        let chosen = choice != nil
        return VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            HStack {
                Label(chosen ? "当前下一步" : "建议下一步", systemImage: chosen ? "arrow.right.circle.fill" : "sparkles")
                    .font(.caption.weight(.semibold)).foregroundStyle(Color.cubicAccent)
                Spacer()
                if chosen {
                    Button { Task { _ = await model.chooseNextAction(itemID: nil) } } label: {
                        Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .frame(width: 28, height: 28).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("取消当前选择").accessibilityIdentifier("actions.clearChoice")
                }
            }
            NavigationLink { WorkDetailView(itemID: item.id) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(compact ? .title3.weight(.bold) : .title2.weight(.bold)).foregroundStyle(.primary)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    Text(model.workContext(item)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("next.item.\(item.id)")
            HStack(spacing: 8) {
                Label(shortMinutesLabel(item.remainingMinutes), systemImage: "clock").font(.subheadline.weight(.medium)).monospacedDigit()
                    .labelStyle(.titleAndIcon).fixedSize()
                if item.status == .inProgress { StatusChip(text: "进行中", tint: .cubicAccent) }
                if item.energy != .normal { StatusChip(text: ProjectUI.energyLabel(item.energy)) }
                Spacer(minLength: 4)
                Button("试算") { sheet = .trial(item.id) }
                    .buttonStyle(.bordered).accessibilityIdentifier("next.trial")
                primaryButton(item, chosen: chosen)
            }
            if let choice {
                NavigationLink { ChoiceDetailView(choice: choice) } label: {
                    Text("选择于 \(choice.date.formatted(date: .omitted, time: .shortened)) · 查看记录")
                        .font(.caption).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
                    .accessibilityIdentifier("actions.choice.record.\(choice.id).count.\(model.workspace.choices?.count ?? 0)")
            }
        }.glassCard(tint: .cubicAccent)
    }
    @ViewBuilder private func primaryButton(_ item: WorkItem, chosen: Bool) -> some View {
        if !chosen {
            Button("设为下一步") { Task { _ = await model.chooseNextAction(itemID: item.id) } }
                .buttonStyle(.borderedProminent).foregroundStyle(Color.cubicOnAccent)
                .disabled(model.saving).accessibilityIdentifier("next.choose")
        } else if item.status == .inProgress {
            Button { sheet = .record(item) } label: { Label("记录进展", systemImage: "pause.fill") }
                .buttonStyle(.borderedProminent).foregroundStyle(Color.cubicOnAccent).accessibilityIdentifier("next.record")
        } else {
            Button { sheet = .startFeedback(item) } label: { Label("开始", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent).foregroundStyle(Color.cubicOnAccent)
                .disabled(model.isBlocked(item.id)).accessibilityIdentifier("next.start")
        }
    }
    private var empty: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle").font(.title2).foregroundStyle(Color.cubicAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text("暂时没有可开始的工作").font(.headline)
                Text("记录一件事，或在项目里添加工作。").font(.caption).foregroundStyle(.secondary)
            }
        }.glassCard()
    }
}

// MARK: - Attention strip

struct AttentionStrip: View {
    var vertical = false
    @Environment(AppModel.self) private var model
    @Environment(AppNavigation.self) private var navigation
    var body: some View {
        let summary = model.attention
        if let headline = summary.headline {
            Button { navigation.section = .attention } label: {
                HStack(spacing: 8) {
                    Image(systemName: summary.dueFollowUps.isEmpty ? "exclamationmark.circle.fill" : "flag.fill")
                    Text(headline).fontWeight(.semibold).lineLimit(vertical ? 2 : 1)
                    Spacer(minLength: 4)
                    if summary.count > 1 { Text("+\(summary.count - 1)").font(.caption.weight(.semibold)) }
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }
                .font(.subheadline).foregroundStyle(tint(summary))
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(tint(summary).opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
                .padding(.horizontal, vertical ? 0 : 16)
                .accessibilityIdentifier("attention.strip")
        }
    }
    private func tint(_ summary: AttentionSummary) -> Color {
        summary.lateProjects.isEmpty ? Color.cubicAmber : Color.cubicLate
    }
}

// MARK: - Available work

struct AvailableWorkSection: View {
    var limit: Int? = nil
    @Environment(AppModel.self) private var model
    @State private var trialID: String?
    var body: some View {
        let available = model.availableWork
        Section {
            if available.isEmpty {
                Text("暂时没有可开始的工作").foregroundStyle(.secondary)
            }
            ForEach(Array(available.prefix(limit ?? available.count)), id: \.id) { item in
                HStack(spacing: 10) {
                    NavigationLink { WorkDetailView(itemID: item.id) } label: { ActionRow(item: item) }
                        .accessibilityIdentifier("action.item.\(item.id)")
                    Button("试算") { trialID = item.id }
                        .buttonStyle(.bordered).controlSize(.small)
                        .accessibilityLabel("试算 \(item.name)").accessibilityIdentifier("action.trial.\(item.id)")
                }
            }
            if let limit, available.count > limit {
                NavigationLink("查看全部 \(available.count) 项") { AvailableWorkView() }
                    .accessibilityIdentifier("actions.all")
            }
        } header: { Text("现在可开始") }
        .sheet(isPresented: Binding(get: { trialID != nil }, set: { if !$0 { trialID = nil } })) {
            if let trialID { TrialView(itemID: trialID) }
        }
    }
}

struct AvailableWorkView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        List {
            AvailableWorkSection()
            let available = Set(model.availableWork.map(\.id))
            let focused = PlanningDisplay.actionItems(workspace: model.workspace) { model.relatedProjectIDs(for: $0) }
                .filter { $0.isFocused == true && !$0.needsReview && !available.contains($0.id) }
            if !focused.isEmpty {
                Section("我关注的工作") {
                    ForEach(focused, id: \.id) { item in
                        NavigationLink { WorkDetailView(itemID: item.id) } label: { ActionRow(item: item) }
                    }
                }
            }
        }
        .cubicNavigationTitle("可开始的工作").cubicInlineNavigationTitle()
        .refreshable { await model.refresh(background: false) }
    }
}

#if os(macOS)
struct AvailableWorkCompactList: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let available = model.availableWork
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("现在可开始").font(.headline)
                Spacer()
                if available.count > 6 {
                    NavigationLink("全部") { AvailableWorkView() }.font(.caption)
                }
            }
            if available.isEmpty { Text("暂时没有可开始的工作").font(.callout).foregroundStyle(.secondary) }
            ForEach(Array(available.prefix(6)), id: \.id) { item in
                NavigationLink { WorkDetailView(itemID: item.id) } label: {
                    HStack(spacing: 6) {
                        HealthDot(health: model.health(ofItem: item))
                        Text(item.name).lineLimit(1)
                        Spacer()
                        Text(shortMinutesLabel(item.remainingMinutes)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Mac week grid

private struct MacWeekGrid: View {
    let days: [Date]
    @Binding var selected: Date
    let calendar: Calendar
    let itemIDs: Set<String>
    let allocations: (Date) -> [TrialAllocation]
    let onSelectDay: (Date) -> Void
    @Environment(AppModel.self) private var model
    private var hourRange: ClosedRange<Int> {
        var lower = 8, upper = 19
        for day in days {
            let start = calendar.startOfDay(for: day)
            let dates = model.capacitySlots(on: day).flatMap { [$0.start, $0.end] } +
                (model.workspace.timeBlocks ?? []).filter { calendar.isDate($0.start, inSameDayAs: day) }.flatMap { [$0.start, $0.end] }
            for date in dates {
                let hour = Int(date.timeIntervalSince(start) / 3600)
                lower = min(lower, max(0, hour - 1)); upper = max(upper, min(24, hour + 1))
            }
        }
        return lower...max(lower + 6, upper)
    }
    var body: some View {
        let range = hourRange
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 52)
                ForEach(days, id: \.self) { day in header(day).frame(maxWidth: .infinity) }
            }.padding(.vertical, 8).padding(.trailing, 8)
            Divider()
            ScrollView {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(days.enumerated()), id: \.element) { index, day in
                        let today = calendar.isDate(day, inSameDayAs: Date())
                        CalendarTimelineView(day: day, calendar: calendar, slots: model.capacitySlots(on: day), events: model.busyEvents(on: day),
                                             itemIDs: itemIDs, allocations: allocations(day), markers: model.waitMarkers(on: day),
                                             showsRail: false, showsHourLabels: index == 0, hourRange: range, hourHeight: days.count == 1 ? 64 : 52)
                            .frame(width: nil).frame(maxWidth: .infinity)
                            .layoutPriority(index == 0 ? 1 : 0)
                            .background(today ? Color.cubicAccent.opacity(0.03) : .clear)
                            .overlay(alignment: .leading) { if index > 0 { Rectangle().fill(Color.secondary.opacity(0.15)).frame(width: 0.5) } }
                    }
                }.padding(.trailing, 8)
            }
        }
    }
    private func header(_ day: Date) -> some View {
        let today = calendar.isDate(day, inSameDayAs: Date())
        let planned = model.plannedMinutes(on: day, itemIDs: itemIDs), available = model.availableMinutes(on: day)
        return Button { onSelectDay(day) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(CalendarFormat.weekday(day, calendar: calendar)).font(.caption).foregroundStyle(today ? Color.cubicAccent : .secondary)
                    Text("\(calendar.component(.day, from: day))").font(.title3.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(today ? Color.cubicAccent : .primary)
                    if today { Text("今天").font(.caption2.weight(.semibold)).foregroundStyle(Color.cubicAccent) }
                }
                HStack(spacing: 6) {
                    CapacityBar(planned: planned, available: available, height: 3).frame(maxWidth: 70)
                    Text(available == 0 ? "休息" : "\(shortMinutesLabel(planned))/\(shortMinutesLabel(available))")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8).contentShape(Rectangle())
        }.buttonStyle(.plain).help("查看这一天")
            .accessibilityIdentifier("calendar.week.day.\(calendar.component(.day, from: day))")
    }
}
#endif
