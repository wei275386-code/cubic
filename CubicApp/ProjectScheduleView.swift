import SwiftUI
import CubicCore

enum ProjectDetailMode: String, CaseIterable, Identifiable {
    case structure, schedule
    var id: Self { self }
    var title: String { self == .structure ? "结构" : "排期" }
}

/// Project detail: one header, then 结构 (outline editing) or 排期 (can it be done in time, and why).
struct CubicProjectDetailView: View {
    let projectID: String
    var initialMode: ProjectDetailMode = .structure
    @State private var mode: ProjectDetailMode?
    var body: some View {
        let current = mode ?? initialMode
        Group {
            switch current {
            case .structure: ProjectStructureEditorView(projectID: projectID)
            case .schedule: ProjectScheduleView(projectID: projectID)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("视图", selection: Binding(get: { current }, set: { mode = $0 })) {
                ForEach(ProjectDetailMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .frame(maxWidth: 320)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("project.mode")
        }
    }
}

/// Name, deadline, health and progress, shared by both project modes.
struct ProjectHeader: View {
    let project: Project
    @Environment(AppModel.self) private var model
    var body: some View {
        let health = model.health(ofProject: project.id)
        HStack(alignment: .center, spacing: 14) {
            ProgressRing(fraction: model.progress(ofProject: project.id), size: 52, lineWidth: 6, tint: health.tint, showsLabel: true)
            VStack(alignment: .leading, spacing: 5) {
                ProjectListTitle(text: project.name, showsFullName: true).font(.title3.weight(.semibold))
                HStack(spacing: 6) {
                    HealthChip(health: health)
                    if let date = project.deadline {
                        Text("截止 \(ProjectUI.datePart(date, zone: project.deadlineTimeZoneID))\(project.deadlineIsDateOnly == true ? "" : " " + ProjectUI.timePart(date, zone: project.deadlineTimeZoneID))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if project.archived { StatusChip(text: "已归档") }
                }
                if let description = project.description, !description.isEmpty {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("project.header")
    }
}

// MARK: - Schedule

struct ProjectScheduleView: View {
    let projectID: String
    @Environment(AppModel.self) private var model
    private var project: Project? { model.workspace.projects.first { $0.id == projectID } }
    private var assessment: PlanningProjectAssessment? { model.planning?.projects.first { $0.projectID == projectID } }

    var body: some View {
        List {
            if let project {
                Section { ProjectHeader(project: project) }
                Section { capacity(project) } header: { Text("需要 vs 可用") }
                let risks = model.projectRisks(projectID)
                if !risks.isEmpty {
                    Section("原因") {
                        ForEach(Array(risks.prefix(6).enumerated()), id: \.offset) { _, risk in RiskRow(risk: risk) }
                        NavigationLink { RiskOverviewView(projectID: projectID) } label: { Label("全部排期说明", systemImage: "list.bullet") }
                    }
                }
                Section {
                    ProjectGantt(projectID: projectID)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                } header: { Text("时间线") } footer: { legend }
                if model.calculationIsStale || model.isRefreshing {
                    Label("正在更新，上面的安排暂用上次结果", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else { Text("项目已不可用，请返回列表。") }
        }
        .cubicNavigationTitle(project?.name ?? "排期").cubicInlineNavigationTitle()
        .refreshable { await model.refresh(background: false) }
    }

    @ViewBuilder private func capacity(_ project: Project) -> some View {
        if let assessment {
            let demand = assessment.totalDemandMinutes ?? assessment.knownDemandMinutes
            let available = assessment.knownCapacityMinutes
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    metric("还需要", shortMinutesLabel(demand) + (assessment.totalDemandMinutes == nil ? "+" : ""))
                    Spacer()
                    metric("截止前可用", shortMinutesLabel(available))
                    Spacer()
                    let gap = demand - available
                    metric(gap > 0 ? "缺口" : "余量", shortMinutesLabel(abs(gap)), tint: gap > 0 ? .cubicLate : .cubicOnTrack)
                }
                CapacityBar(planned: demand, available: max(available, 1), height: 6)
                if assessment.totalDemandMinutes == nil {
                    Text("部分工作还没有估计用时，实际需要可能更多。").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 4).accessibilityIdentifier("project.schedule.capacity")
        } else if project.deadline == nil {
            Text("设置截止日期后，这里会对比需要的时间和截止前的可用时间。").foregroundStyle(.secondary)
        } else {
            Label("正在计算…", systemImage: "hourglass").foregroundStyle(.secondary)
        }
    }

    private func metric(_ title: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(tint)
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            Label { Text("已排") } icon: { RoundedRectangle(cornerRadius: 2).fill(Color.cubicAccent).frame(width: 14, height: 8) }
            Label { Text("推算") } icon: {
                RoundedRectangle(cornerRadius: 2).strokeBorder(Color.cubicAccent, style: StrokeStyle(lineWidth: 1, dash: [3, 2])).frame(width: 14, height: 8)
            }
            Label { Text("最晚开始") } icon: { Image(systemName: "diamond.fill").foregroundStyle(Color.cubicAmber) }
            Label { Text("截止") } icon: { Rectangle().fill(Color.cubicLate).frame(width: 2, height: 10) }
        }.font(.caption2).labelStyle(.titleAndIcon)
    }
}

/// Day-scale Gantt: solid bars are time blocks the user placed, dashed bars are the planner's allocations.
struct ProjectGantt: View {
    let projectID: String
    @Environment(AppModel.self) private var model
    private let labelWidth: CGFloat = 116
    private let rowHeight: CGFloat = 30
    private let dayWidth: CGFloat = 34

    private var items: [WorkItem] {
        let structure = model.workspace.projectStructure(projectID: projectID)
        let ordered = structure.nodes.flatMap { structure.membersByNode[$0.id] ?? [] } + structure.directItems
        var seen = Set<String>()
        return ordered.filter { item in
            guard seen.insert(item.id).inserted else { return false }
            return item.status != .completed && !item.archived && item.effectiveDisposition != .cancelled
        }
    }

    var body: some View {
        let cal = model.workCalendar
        let rows = items
        let ids = Set(rows.map(\.id))
        let allocations = model.planning?.witness.allocations.filter { ids.contains($0.itemID) } ?? []
        let blocks = (model.workspace.timeBlocks ?? []).filter { ids.contains($0.itemID) }
        let suggestions = model.latestStartSuggestions.filter { ids.contains($0.itemID) }
        let project = model.workspace.projects.first { $0.id == projectID }
        let start = cal.startOfDay(for: model.now)
        let candidates = [project?.deadline] + allocations.map(\.end) + blocks.map(\.end) as [Date?]
        let last = candidates.compactMap { $0 }.max() ?? start
        let days = max(7, min(120, (cal.dateComponents([.day], from: start, to: last).day ?? 0) + 2))
        let width = CGFloat(days) * dayWidth
        let dayWidth = dayWidth
        // Day index plus the share of that calendar day, so 23/25-hour DST days stay aligned with the header.
        let x: (Date) -> CGFloat = { date in
            let dayStart = cal.startOfDay(for: date)
            let index = cal.dateComponents([.day], from: start, to: dayStart).day ?? 0
            let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
            let fraction = date.timeIntervalSince(dayStart) / dayEnd.timeIntervalSince(dayStart)
            return (CGFloat(index) + CGFloat(fraction)) * dayWidth
        }

        if rows.isEmpty {
            Text("没有未完成的工作").foregroundStyle(.secondary).padding(.horizontal, 16)
        } else {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 24)
                    ForEach(rows, id: \.id) { item in
                        NavigationLink { WorkDetailView(itemID: item.id) } label: {
                            Text(item.name).font(.caption).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).frame(height: rowHeight)
                    }
                }.frame(width: labelWidth).padding(.leading, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    ZStack(alignment: .topLeading) {
                        // Day header and grid.
                        HStack(spacing: 0) {
                            ForEach(0..<days, id: \.self) { offset in
                                let date = cal.date(byAdding: .day, value: offset, to: start)!
                                let weekend = cal.isDateInWeekend(date)
                                VStack(spacing: 0) {
                                    Text("\(cal.component(.day, from: date))").font(.caption2).monospacedDigit()
                                        .foregroundStyle(offset == 0 ? Color.cubicAccent : .secondary).frame(height: 24)
                                    Rectangle().fill(weekend ? Color.secondary.opacity(0.06) : .clear)
                                }
                                .frame(width: dayWidth)
                                .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.12)).frame(width: 0.5) }
                            }
                        }
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                            let y = 24 + CGFloat(index) * rowHeight
                            ForEach(Array(allocations.filter { $0.itemID == item.id }.enumerated()), id: \.offset) { _, allocation in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.cubicAccent.opacity(0.1))
                                    .strokeBorder(Color.cubicAccent, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                                    .frame(width: max(5, x(allocation.end) - x(allocation.start)), height: 14)
                                    .offset(x: x(allocation.start), y: y + 8)
                            }
                            ForEach(blocks.filter { $0.itemID == item.id }, id: \.id) { block in
                                RoundedRectangle(cornerRadius: 3).fill(Color.cubicAccent)
                                    .frame(width: max(5, x(block.end) - x(block.start)), height: 14)
                                    .offset(x: x(block.start), y: y + 8)
                            }
                            if let date = suggestions.first(where: { $0.itemID == item.id })?.latestStart, date >= start {
                                Image(systemName: "diamond.fill").font(.system(size: 9)).foregroundStyle(Color.cubicAmber)
                                    .offset(x: x(date) - 4, y: y + 10)
                            }
                        }
                        Rectangle().fill(Color.cubicAccent.opacity(0.5)).frame(width: 1, height: 24 + CGFloat(rows.count) * rowHeight)
                            .offset(x: x(model.now))
                        if let deadline = project?.deadline, deadline >= start {
                            Rectangle().fill(Color.cubicLate).frame(width: 2, height: 24 + CGFloat(rows.count) * rowHeight)
                                .offset(x: x(deadline) - 1)
                        }
                    }
                    .frame(width: width, height: 24 + CGFloat(rows.count) * rowHeight, alignment: .topLeading)
                    .padding(.trailing, 16)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("project.schedule.gantt")
        }
    }
}
