import SwiftUI
import CubicCore

struct InboxView: View {
    @Environment(AppModel.self) private var model
    @State private var title = ""
    @State private var sheet: ProjectUISheet?
    @State private var filter = "inbox"
    @State private var query = ""
    private var items: [WorkItem] {
        model.workspace.items.filter { item in
            let matches: Bool
            switch filter {
            case "deferred": matches = item.effectiveDisposition == .deferred && !item.archived
            case "focused": matches = item.isFocused == true && !item.archived && item.effectiveDisposition == .active
            case "archived": matches = item.archived || item.effectiveDisposition == .cancelled
            case "independent": matches = item.projectIDs.isEmpty && item.nodeID == nil && item.description != nil && !item.archived && item.effectiveDisposition == .active
            default: matches = model.pendingInboxItems.contains { $0.id == item.id }
            }
            return matches && (query.isEmpty || item.name.localizedCaseInsensitiveContains(query) || (item.contextTags ?? []).contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }
    var body: some View {
        List {
            Section("添加事项") {
                TextField("记下要做的事", text: $title, axis: .vertical)
                    .frame(minHeight: 44).accessibilityIdentifier("inbox.quick.title")
                ProjectActionButton("加入收件箱", symbol: "plus", identifier: "inbox.quick.save") {
                    let name = ProjectUI.trim(title)
                    guard !name.isEmpty else { model.errorMessage = "请输入标题。"; return false }
                    let saved = await model.mutate { try $0.addItem(WorkItem(name: name), now: Date()) }
                    if saved { title = "" }
                    return saved
                }
            }
            Section("查看") {
                Picker("分类", selection: $filter) {
                    Text("待整理").tag("inbox")
                    Text("独立工作").tag("independent")
                    Text("以后再做").tag("deferred")
                    Text("我关注的").tag("focused")
                    Text("已取消或归档").tag("archived")
                }.frame(minHeight: 44).accessibilityIdentifier("inbox.filter")
                TextField("搜索名称或标签", text: $query)
                    .frame(minHeight: 44).accessibilityIdentifier("inbox.search")
                NavigationLink { ReviewView() } label: { Label("待处理事项", systemImage: "arrow.clockwise").frame(minHeight: 44) }
                    .accessibilityIdentifier("inbox.review")
                NavigationLink { WaitingView() } label: { Label("等待与跟进", systemImage: "hourglass").frame(minHeight: 44) }
                    .accessibilityIdentifier("inbox.waiting")
            }
            Section("事项（\(items.count)）") {
                ForEach(items, id: \.id) { item in
                    NavigationLink { WorkDetailView(itemID: item.id) } label: { ProjectWorkRow(item: item) }
                        .accessibilityIdentifier("inbox.item.\(item.id)")
                }
                if items.isEmpty { Text("这个分类还没有事项。").foregroundStyle(.secondary) }
            }
        }
        .cubicNavigationTitle("收件箱")
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { sheet = .newItem(projectID: nil, nodeID: nil) } label: { Label("新建", systemImage: "square.and.pencil").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityIdentifier("inbox.newItem")
            }
        }
        .sheet(item: $sheet) { ProjectUISheetContent(sheet: $0) }
    }
}

struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    @State private var sheet: ProjectUISheet?
    @State private var pendingCreatedProjectID: String?
    @State private var createdProjectID: String?
    @State private var includeArchived = false
    var body: some View {
        List {
            Section {
                NavigationLink { ProjectTemplatesView() } label: {
                    Label("从模板创建", systemImage: "doc.on.doc").frame(minHeight: 44)
                }.accessibilityIdentifier("projects.templates")
                Button { sheet = .markdownProject { pendingCreatedProjectID = $0 } } label: {
                    Label("从 Markdown 快速创建", systemImage: "text.badge.plus").frame(minHeight: 44)
                }.accessibilityIdentifier("projects.createMarkdown")
                NavigationLink { ReviewView() } label: { Label("待处理事项", systemImage: "arrow.clockwise").frame(minHeight: 44) }
                    .accessibilityIdentifier("projects.review")
                NavigationLink { WaitingView() } label: { Label("外部等待", systemImage: "hourglass").frame(minHeight: 44) }
                    .accessibilityIdentifier("projects.waiting")
                Toggle("包含归档项目", isOn: $includeArchived).frame(minHeight: 44).accessibilityIdentifier("projects.includeArchived")
            }
            Section("项目") {
                ForEach(model.workspace.projects.filter { includeArchived || !$0.archived }, id: \.id) { project in
                    NavigationLink { CubicProjectDetailView(projectID: project.id) } label: { ProjectSummaryRow(project: project) }
                        .accessibilityIdentifier("projects.project.\(project.id)")
                }
                if model.workspace.projects.isEmpty { Text("还没有项目。点击右上角创建，也可以先在收件箱记下第一步。").foregroundStyle(.secondary) }
            }
        }
        .cubicNavigationTitle("项目")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { sheet = .newProject { pendingCreatedProjectID = $0 } } label: { Label("创建项目", systemImage: "plus").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityIdentifier("projects.create")
            }
        }
        .sheet(item: $sheet, onDismiss: {
            if let id = pendingCreatedProjectID { pendingCreatedProjectID = nil; createdProjectID = id }
        }) { ProjectUISheetContent(sheet: $0) }
        .navigationDestination(item: $createdProjectID) { id in CubicProjectDetailView(projectID: id) }
    }
}

struct ProjectSummaryRow: View {
    let project: Project
    var showsDetails = false
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProjectListTitle(text: project.name, showsFullName: showsDetails)
            Text("\(ProjectUI.projectStatus(project.effectiveStatus))\(project.archived ? " · 已归档" : "")")
            if showsDetails {
                ProjectDeadlineDisplay(date: project.deadline, timeZoneID: project.deadlineTimeZoneID, dateOnly: project.deadlineIsDateOnly == true)
            } else if let date = project.deadline {
                Text("截止：\(ProjectUI.datePart(date, zone: project.deadlineTimeZoneID)) \(project.deadlineIsDateOnly == true ? "日末" : ProjectUI.timePart(date, zone: project.deadlineTimeZoneID))")
            }
            Text("重要性：\(ProjectUI.importance(project.importance))").font(.caption).foregroundStyle(.secondary)
            if showsDetails, let buffer = project.warningBufferMinutes {
                Text("时间余量低于 \(minutesLabel(buffer)) 时提醒").font(.caption)
            }
            let items = model.workspace.items.filter { $0.projectIDs.contains(project.id) }
            let waiting = items.filter { $0.status != .completed && !ProjectUI.predecessorsSatisfied($0.id, in: model.workspace) }.count
            let review = items.filter(\.needsReview).count
            if waiting > 0 { Text("\(waiting) 项工作等待前置完成").font(.caption) }
            if review > 0 { Text("\(review) 项成果需要复核").font(.caption) }
            ProjectRiskSummary(projectID: project.id)
            if !showsDetails && !model.workspace.projectCompletionIssues(id: project.id).isEmpty {
                Label("查看待处理事项", systemImage: "checklist").font(.caption).foregroundStyle(Color.cubicAccent)
            }
        }
        .font(.subheadline).fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: 44, alignment: .leading).padding(.vertical, 4)
    }
}

struct CubicProjectDetailView: View {
    let projectID: String
    var body: some View { ProjectStructureEditorView(projectID: projectID) }
}

struct CubicNodeDetailView: View {
    let nodeID: String
    @Environment(AppModel.self) private var model
    @State private var sheet: ProjectUISheet?
    var body: some View {
        List {
            if let node = model.workspace.nodes.first(where: { $0.id == nodeID }) {
                Section("节点概况") {
                    ProjectListTitle(text: node.name, showsFullName: true)
                    Text("\(node.required ? "交付必需" : "可选节点") · 第 \(node.currentRound) 轮 · \(ProjectUI.nodeSummary(node.id, in: model.workspace))")
                    if node.archived { Text("已归档").foregroundStyle(.secondary) }
                    ForEach(Array(model.workspace.nodeCompletionIssues(id: nodeID).enumerated()), id: \.offset) { _, issue in
                        CompletionIssueRow(issue: issue, contextNodeID: nodeID)
                    }
                    Button { sheet = .editNode(node) } label: { Label("编辑节点", systemImage: "pencil").frame(minHeight: 44) }.accessibilityIdentifier("node.edit")
                    ProjectMutationButton("确认节点完成", symbol: "checkmark.seal", identifier: "node.complete") { try $0.completeNode(id: nodeID, now: Date()) }
                    ProjectMutationButton(node.archived ? "取消归档" : "归档节点", symbol: "archivebox", identifier: "node.archive") { try $0.setArchived(.node(nodeID), archived: !node.archived, now: Date()) }
                    Text("归档只改变显示，不会重新开工，也不改变节点的完成、验收和依赖状态。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("节点工作与前置关系") {
                    NodeRelationshipList(nodeID: nodeID)
                    NavigationLink { RelationshipView(nodeID: nodeID) } label: { Label("查看和编辑前置关系", systemImage: "point.3.connected.trianglepath.dotted").frame(minHeight: 44) }.accessibilityIdentifier("node.relationships")
                    Button { sheet = .newItem(projectID: node.projectID, nodeID: nodeID) } label: { Label("添加节点工作", systemImage: "plus").frame(minHeight: 44) }.accessibilityIdentifier("node.newItem")
                    NavigationLink { SharedReferencesView(projectID: node.projectID, nodeID: nodeID) } label: { Label("关联已有工作或节点", systemImage: "link").frame(minHeight: 44) }.accessibilityIdentifier("node.references")
                    NavigationLink { NodeMoveView(nodeID: nodeID) } label: { Label("移到其他项目", systemImage: "folder").frame(minHeight: 44) }.accessibilityIdentifier("node.move")
                }
                ProjectAcceptanceSection(subject: .node(nodeID)) { sheet = .acceptance(.node(nodeID)) }
            } else { Text("节点已不可用。") }
        }
        .cubicNavigationTitle("节点详情").cubicInlineNavigationTitle()
        .sheet(item: $sheet) { ProjectUISheetContent(sheet: $0) }
    }
}

struct ProjectWorkRow: View {
    let item: WorkItem
    var contextProjectID: String? = nil
    var showsFullName = false
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProjectListTitle(text: item.name, showsFullName: showsFullName)
            Text(ProjectUI.statusLabel(item, blocked: !ProjectUI.predecessorsSatisfied(item.id, in: model.workspace)))
            Text("\(item.required ? "必需" : "非必需") · 耗时：\(minutesLabel(item.remainingMinutes)) · \(ProjectUI.energyLabel(item.energy))")
            WorkAffiliationRows(item: item, contextProjectID: contextProjectID)
            if !(item.contextTags ?? []).isEmpty { Text("标签：\((item.contextTags ?? []).joined(separator: "、"))").font(.caption) }
            if item.isFocused == true { Label("我关注的", systemImage: "star") }
            if let due = item.deadline { ProjectDeadlineDisplay(date: due, timeZoneID: item.deadlineTimeZoneID, dateOnly: item.deadlineIsDateOnly == true) }
        }.font(.subheadline).fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 44, alignment: .leading).padding(.vertical, 4)
    }
}

struct ProjectInfoLine: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 2)
    }
}

struct ProjectDeadlineDisplay: View {
    let date: Date?
    let timeZoneID: String?
    let dateOnly: Bool
    var body: some View {
        if let date {
            VStack(alignment: .leading, spacing: 3) {
                Text("截止：\(ProjectUI.datePart(date, zone: timeZoneID))")
                Text(dateOnly ? "该时区当日结束" : "时间：\(ProjectUI.timePart(date, zone: timeZoneID))")
                if let timeZoneID { Text("时区：\(timeZoneID)").font(.caption).foregroundStyle(.secondary) }
            }.fixedSize(horizontal: false, vertical: true)
        } else { Text("未设置截止").foregroundStyle(.secondary) }
    }
}

struct ProjectRiskSummary: View {
    let projectID: String
    @Environment(AppModel.self) private var model
    private var project: Project? { model.workspace.projects.first { $0.id == projectID } }
    var body: some View {
        if let project {
            let overdue = project.hasDeliveryCommitment && project.deadline.map { $0 < Date() } == true
            if overdue {
                Label("已过截止，尚未交付", systemImage: "clock.badge.exclamationmark")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color.cubicAmber)
            }
            if model.planning == nil && (model.calculationIsStale || model.isRefreshing) {
                Text("排期正在更新…").font(.caption).foregroundStyle(.secondary)
            } else if let assessment = model.planning?.projects.first(where: { $0.projectID == projectID }) {
                let risks = model.presentedRisks.filter { risk in
                    risk.projectID == projectID || (risk.projectID == nil && !Set(risk.itemIDs).isDisjoint(with: model.projectItemIDs(projectID)))
                }
                if !overdue, let risk = risks.first(where: { $0.kind != .conditionalUnlock && $0.kind != .insufficientInformation }) {
                    Text(PlanningCopy.title(risk)).font(.subheadline.weight(.semibold)).foregroundStyle(Color.cubicAmber)
                    Text(PlanningCopy.summary(risk)).font(.caption).foregroundStyle(.secondary)
                } else if !overdue && [.insufficient, .boundaryReached].contains(assessment.warningState) {
                    Text("截止前的时间余量偏少").font(.subheadline.weight(.semibold)).foregroundStyle(Color.cubicAmber)
                }
                if assessment.totalDemandMinutes == nil {
                    Text("还有排期信息需要补充")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let total = assessment.totalDemandMinutes {
                    Text("剩余工作约 \(minutesLabel(total))").font(.caption).foregroundStyle(.secondary)
                }
            } else { Text("排期尚未核对").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// Names stay intact in storage; list context replaces repeated name paths.
struct ProjectListTitle: View {
    let text: String
    var showsFullName = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        Text(text).font(.headline)
            .lineLimit(showsFullName || dynamicTypeSize.isAccessibilitySize ? nil : 2)
            .truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(text)
    }
}

struct WorkAffiliationRows: View {
    let item: WorkItem
    var contextProjectID: String? = nil
    @Environment(AppModel.self) private var model
    var body: some View {
        let projects = model.workspace.projects.filter { item.projectIDs.contains($0.id) && $0.id != contextProjectID }
        ForEach(projects, id: \.id) { project in
            Text("\(contextProjectID == nil ? "项目" : "共享至")：\(project.name)")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let node = model.workspace.nodes.first(where: { $0.id == item.nodeID }) {
            Text("节点：\(node.name)").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct CompletionIssueRow: View {
    let issue: String
    var contextNodeID: String? = nil
    @Environment(AppModel.self) private var model
    private var parts: [String] { issue.components(separatedBy: ": ") }
    private var item: WorkItem? { model.workspace.items.first { parts.contains($0.id) } }
    private var gate: Acceptance? { model.workspace.acceptances.first { parts.contains($0.id) } }
    private var node: Node? { model.workspace.nodes.first { parts.contains($0.id) || $0.id == contextNodeID } }
    private var label: String {
        if issue.contains("节点还没有工作") { return "为节点添加工作" }
        if issue.contains("验收未通过") { return gate?.state == .failed ? "处理未通过的验收" : "确认验收结果" }
        if issue.contains("等待未解除") { return "确认外部等待是否已解除" }
        if issue.contains("需复核"), item?.needsReview == true || node?.needsReview == true { return "复核已有成果" }
        if issue.contains("工作未完成") { return item?.status == .completed ? "核对工作完成与前置条件" : "完成必需工作" }
        if issue.contains("共享节点") { return "检查引用节点的交付状态" }
        return "检查交付条件"
    }
    private var subject: WorkReference? {
        if let item { return .item(item.id) }
        if let gate { return gate.subject }
        if let node { return .node(node.id) }
        return nil
    }
    var body: some View {
        if let subject {
            if subject == .node(contextNodeID ?? "") {
                VStack(alignment: .leading, spacing: 5) {
                    Text(label)
                    Text("请使用本页的编辑、验收或前置关系操作处理。")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(minHeight: 44)
            } else {
                NavigationLink {
                    switch subject {
                    case .item(let id): WorkDetailView(itemID: id)
                    case .node(let id): CubicNodeDetailView(nodeID: id)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(label)
                        Text(gate?.name ?? item?.name ?? node?.name ?? model.businessIssue(issue))
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(minHeight: 44)
                }
            }
        } else { Text(model.businessIssue(issue)).fixedSize(horizontal: false, vertical: true) }
    }
}

/// Human-facing copy is separate from the engine's saved proof and assumptions.
enum PlanningCopy {
    static func capturedWorkspace(_ source: PlanningSource) -> Workspace {
        var workspace = Workspace.empty
        workspace.projects = source.projects; workspace.nodes = source.nodes; workspace.items = source.items
        workspace.blockers = source.blockers; workspace.dependencies = source.dependencies; workspace.acceptances = source.acceptances
        workspace.workLinks = source.workLinks; workspace.reviews = source.reviews; workspace.workRounds = source.workRounds
        return workspace
    }
    static func impact(_ impact: PlanningImpact) -> String {
        switch impact.kind {
        case .sharedProgress:
            return "这项工作可能同时推进关联项目；实际进度仍需记录。"
        case .dependencyRelease:
            return "按估计完成后，后续工作可能可以开始；其他前置和验收仍需满足。"
        case .boundaryImprovement:
            return "后续工作的预计开始时间有所改善。"
        case .compatibleCapacityLoss:
            return "这段投入会减少其他工作在截止前可用的时间。"
        case .slackLoss:
            return "项目的时间余量发生变化；共用时间的冲突仍需单独检查。"
        case .shortageIncrease:
            return "截止前缺少的工作时间增加了；目前无法确定会延期多久。"
        case .unresolvedCompetition:
            if let minutes = impact.afterMinutes, minutes > 0 { return "这些工作在截止前至少还差 \(minutesLabel(minutes))，请检查工作范围和可用时间。" }
            return "暂时没排出完整安排，请查看缺失信息、日期和前置条件。"
        case .unknown:
            if impact.chain.contains("resource:next-compatible-slot") { return "所选开始时间没有合适空档，将从下一个空档开始。" }
            if impact.chain.contains("resource:split-slots") { return "投入会分成多段，中间的忙碌时间不计入投入。" }
            if impact.message.contains("剩余未知") { return "剩余时间还没估计，暂时无法判断是否能做完及后续能否开始。" }
            return "本次投入的影响还不完整，请检查时长、剩余估计和可用空档。"
        }
    }
    static func referenceName(_ reference: String, names: [String: String]) -> String {
        if let name = names[reference] { return name }
        switch reference {
        case "resource:low": return "所有工作时段"
        case "resource:normal": return "普通及高专注时段"
        case "resource:high": return "高专注时段"
        case "resource:shared": return "各项目共用的时间"
        case "resource:next-compatible-slot": return "下一个合适空档"
        case "resource:split-slots": return "分段投入"
        case "constraint:continuous": return "所需连续时间"
        case "constraint:capacity": return "可用工作时间"
        default: return PlanningDisplay.referenceName(reference, names: names)
        }
    }
    static func title(_ risk: Risk) -> String {
        switch risk.kind {
        case .provenCapacityShortfall: risk.shortageMinutes == nil ? "交付时间赶不上截止" : "截止前的时间不够"
        case .conditionalUnlock: "推算中尚未实现的条件"
        case .sharedResourceConflict: (risk.shortageMinutes ?? 0) > 0 ? "截止前至少还差 \(minutesLabel(risk.shortageMinutes))" : "这些工作的安排还没确认"
        case .insufficientInformation: "剩余工作还没确认清楚"
        case .energyConstraint: "适合专注工作的时间不够"
        case .continuousConstraint: "没有足够长的连续空档"
        }
    }
    static func summary(_ risk: Risk) -> String {
        switch risk.kind {
        case .provenCapacityShortfall:
            if let shortage = risk.shortageMinutes { return "截止前可用时间至少还差 \(minutesLabel(shortage))。请调整工作范围或可用时间。" }
            return "预计最早能交付的时间已晚于截止。请检查等待、验收日期和项目截止。"
        case .conditionalUnlock:
            if risk.message.contains("预警阈值") { return "截止前可用的时间余量偏少，请检查下一步安排。" }
            return "推算假设剩余工作会完成、所需验收或等待会通过；这些条件还需要实际确认。"
        case .sharedResourceConflict:
            if let shortage = risk.shortageMinutes, shortage > 0 { return "这些工作在截止前至少还差 \(minutesLabel(shortage))。请核对工作量和可用空档，再调整范围、工作时间或截止。" }
            return "目前还没排出完整安排，请查看缺失信息、前置条件和可用空档。"
        case .insufficientInformation: return "请逐项补充下面的缺失信息，再确认剩余工作和排期。"
        case .energyConstraint: return "工作需要的专注时段不足，请调整可用时段或工作要求。"
        case .continuousConstraint: return "这项工作需要连续完成，请检查空档长度或连续时间要求。"
        }
    }
    static func condition(_ condition: PlanningCondition) -> String {
        switch condition.kind {
        case .estimatedCompletion: condition.id.hasPrefix("trial-progress:") ? "假设投入后按当前估计减少剩余时间，实际进度需另行记录。" : "推算假设这项工作会按剩余时间估计完成。"
        case .manualAcceptance: "推算假设这条验收会通过，仍需人工确认。"
        case .externalResolution: "推算假设外部等待会按预计时间解除，仍需确认。"
        case .assumedWaitStart: "推算假设等待会在指定时间发起。"
        case .capacityUnverified: "日历占用还没核对，可用时间可能变化。"
        case .counterfactualReadiness: "这是试算中的完成假设，真实进度尚未改变。"
        case .trialResourceUse: "这是试算使用的时间，不是已预约的安排。"
        }
    }
    static func unknown(_ unknown: PlanningUnknown, in workspace: Workspace) -> String {
        if unknown.message.contains("\n") {
            var messages: [String] = []
            for line in unknown.message.split(separator: "\n") {
                let text = Self.unknown(PlanningUnknown(objectID: unknown.objectID, message: String(line)), in: workspace)
                if !messages.contains(text) { messages.append(text) }
            }
            return messages.joined(separator: "\n")
        }
        if unknown.message.contains("容量窗口未覆盖") { return "可用时间只记录了一部分，请补充截止前的工作时段。" }
        if unknown.objectID == "capacity" {
            return capacityGaps(unknown).joined(separator: "\n")
        }
        if let item = workspace.items.first(where: { $0.id == unknown.objectID }) {
            if unknown.message.contains("连续时长要求大于") { return "连续时间要求大于剩余时间，请核对这两个估计。" }
            if item.effectiveDisposition == .cancelled { return "这项工作已取消，请检查仍然引用它的前置关系。" }
            if item.needsReview { return "已有成果需要复核，请确认是否返工，并填写返工时间。" }
            if item.remainingMinutes == nil { return "剩余时间未填写，请补充估计。" }
            if item.status == .completed { return "工作已标记完成，但前置条件尚未满足，请核对成果是否仍有效。" }
            return "请确认剩余工作范围和时间估计。"
        }
        if let node = workspace.nodes.first(where: { $0.id == unknown.objectID }) {
            var gaps: [String] = []
            if node.needsReview == true { gaps.append("复核节点成果") }
            let gates = workspace.acceptances.filter { $0.isActive && $0.subject == .node(node.id) }
            if gates.contains(where: { $0.state == .failed && $0.reworkScopeConfirmed != true }) { gaps.append("确认实际返工范围") }
            return gaps.isEmpty ? "请检查节点的验收与交付条件。" : "需要" + gaps.joined(separator: "、") + "。"
        }
        if let project = workspace.projects.first(where: { $0.id == unknown.objectID }) {
            return project.deadline == nil ? "截止时间未设置。" : "请检查当前工作的时间估计和前置条件。"
        }
        if workspace.blockers.contains(where: { $0.id == unknown.objectID }) { return "等待何时开始或何时解除还不清楚，请补充预计时间。" }
        if workspace.acceptances.contains(where: { $0.id == unknown.objectID }) { return "验收未通过，请确认哪些工作需要返工。" }
        return unknown.message
    }
    static func capacityGaps(_ unknown: PlanningUnknown) -> [String] {
        var gaps: [String] = []
        let message = unknown.message
        if message.contains("工作时段尚未保存") { gaps.append("工作时间还没保存。请到设置填写可工作的开始、结束时间并保存。") }
        if message.contains("尚未启用日历") { gaps.append("日历占用还没计入，目前只按你设置的工作时间计算。请确认是否需要启用系统日历。") }
        if message.contains("未授权") || message.contains("已撤权") { gaps.append("没有日历读取权限，会议等占用还没计入。请在系统设置允许访问日历。") }
        if message.contains("本设备不可用") { gaps.append("部分所选日历在这台设备上不可用。请在设置重新选择日历来源。") }
        if message.contains("日历数据已过时") { gaps.append("日历数据需要更新。请打开日历页刷新后再查看排期。") }
        if message.contains("未确认的全天或忙闲规则") { gaps.append("有些日历事件是否占用时间还没确认，暂按忙碌计算。请在设置确认全天事件和忙闲规则。") }
        return gaps.isEmpty ? ["可用时间还没核对，请到设置检查工作时间和所选日历，再刷新日历页。"] : gaps
    }
}

struct ProjectActionButton: View {
    let title: String
    let symbol: String
    let identifier: String
    let action: @MainActor () async -> Bool
    @Environment(AppModel.self) private var model
    @State private var busy = false
    init(_ title: String, symbol: String, identifier: String, action: @escaping @MainActor () async -> Bool) {
        self.title = title; self.symbol = symbol; self.identifier = identifier; self.action = action
    }
    var body: some View {
        Button {
            guard !busy, !model.saving, !model.loading else { return }
            busy = true
            Task { _ = await action(); busy = false }
        } label: {
            Label(busy ? "保存中…" : title, systemImage: symbol)
                .fixedSize(horizontal: false, vertical: true).frame(minHeight: 44, alignment: .leading)
        }.disabled(busy || model.saving || model.loading).accessibilityIdentifier(identifier)
    }
}
struct ProjectMutationButton: View {
    let title: String
    let symbol: String
    let identifier: String
    let change: (inout Workspace) throws -> Void
    @Environment(AppModel.self) private var model
    init(_ title: String, symbol: String, identifier: String, change: @escaping (inout Workspace) throws -> Void) {
        self.title = title; self.symbol = symbol; self.identifier = identifier; self.change = change
    }
    var body: some View { ProjectActionButton(title, symbol: symbol, identifier: identifier) { await model.mutate(change) } }
}

enum ProjectUI {
    static func trim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    static func dateLabel(_ date: Date) -> String { datePart(date) + "\n" + timePart(date) }
    static func datePart(_ date: Date, zone: String? = nil) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.timeZone = zone.flatMap(TimeZone.init(identifier:)) ?? .current; formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
    static func timePart(_ date: Date, zone: String? = nil) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.timeZone = zone.flatMap(TimeZone.init(identifier:)) ?? .current; formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    static func importance(_ value: Int) -> String { value == 0 ? "未分级" : "\(value)/5" }
    static func projectStatus(_ value: ProjectStatus) -> String {
        switch value { case .planning: "待拆分"; case .active: "进行中"; case .deferred: "暂缓，截止仍有效"; case .completed: "已完成"; case .cancelled: "已取消" }
    }
    static func energyLabel(_ energy: Energy) -> String { switch energy { case .low: "低负荷"; case .normal: "普通"; case .high: "高专注" } }
    static func statusLabel(_ item: WorkItem, blocked: Bool) -> String {
        var labels = [item.status == .completed ? "工作已完成" : item.status == .inProgress ? "进行中" : "未开工"]
        if item.needsReview { labels.append("成果待复核") }
        if blocked { labels.append("等待前置完成") }
        if item.effectiveDisposition == .deferred { labels.append("以后再做") }
        if item.effectiveDisposition == .cancelled { labels.append("已取消") }
        if item.archived { labels.append("已归档") }
        return labels.joined(separator: " · ")
    }
    static func subjectWorkComplete(_ subject: WorkReference, in workspace: Workspace) -> Bool {
        switch subject {
        case .item(let id): return workspace.items.contains { $0.id == id && $0.status == .completed && !$0.needsReview && $0.effectiveDisposition != .cancelled }
        case .node(let id): return workspace.nodeCompletionIssues(id: id, includeAcceptance: false).isEmpty
        }
    }
    static func subjectSatisfied(_ subject: WorkReference, in workspace: Workspace) -> Bool {
        switch subject { case .item(let id): workspace.sourceSatisfied(.item(id)); case .node(let id): workspace.sourceSatisfied(.node(id)) }
    }
    static func nodeComplete(_ id: String, in workspace: Workspace) -> Bool { workspace.sourceSatisfied(.node(id)) }
    static func nodeSummary(_ id: String, in workspace: Workspace) -> String {
        let items = workspace.items.filter { $0.nodeID == id }
        let blocked = items.filter { $0.status != .completed && !predecessorsSatisfied($0.id, in: workspace) }.count
        let ready = items.filter { $0.status != .completed && !$0.needsReview && $0.effectiveDisposition == .active && predecessorsSatisfied($0.id, in: workspace) }.count
        let complete = nodeComplete(id, in: workspace)
        let hasExplicitAcceptance = workspace.acceptanceMode(for: .node(id)) == .explicit
        var labels = [complete ? (hasExplicitAcceptance ? "已通过验收" : "已完成") : "未完成"]
        if ready > 0 { labels.append("可开始 \(ready) 项") }
        if blocked > 0 { labels.append("等待前置 \(blocked) 项") }
        let review = items.filter(\.needsReview).count
        if review > 0 { labels.append("待复核 \(review) 项") }
        return labels.joined(separator: " · ")
    }
    static func sourceSatisfied(_ source: DependencySource, in workspace: Workspace) -> Bool { workspace.sourceSatisfied(source) }
    static func predecessorsSatisfied(_ id: String, in workspace: Workspace) -> Bool {
        workspace.unsatisfiedItemDependencies(itemID: id).isEmpty
    }
    static func requireCurrentDependencies(_ id: String, in workspace: Workspace) throws {
        let missing = workspace.unsatisfiedItemDependencies(itemID: id).map { sourceName($0.source, in: workspace) }
        if !missing.isEmpty { throw CoreError.blocked("请先处理：" + missing.joined(separator: "、") + "。需要新增投入时，这些前置也必须满足。") }
    }
    static func blockerLabel(_ state: BlockerState) -> String { switch state { case .inactive: "未发起"; case .active: "等待中"; case .resolved: "等待已结束" } }
    static func downstreamItems(_ id: String, in workspace: Workspace) -> [WorkItem] {
        let ids = Set(workspace.affectedItemIDs(by: .item(id)))
        return workspace.items.filter { ids.contains($0.id) }
    }
    static func projectHistoryIDs(_ id: String, in workspace: Workspace) -> Set<String> {
        let items = workspace.items.filter { $0.projectIDs.contains(id) }
        let nodeIDs = workspace.nodes.filter { $0.projectID == id }.map(\.id)
        var ids = Set([id] + items.map(\.id) + nodeIDs)
        // Removed references also remain part of the historical delivery context.
        var sources = (workspace.workLinks ?? []).filter { $0.projectID == id }
        var cursor = 0
        while cursor < sources.count {
            let link = sources[cursor]; cursor += 1
            ids.insert(link.id); ids.insert(link.source.id)
            if case .node(let nodeID) = link.source {
                ids.formUnion(workspace.items.filter { $0.nodeID == nodeID }.map(\.id))
                for nested in workspace.workLinks ?? [] where nested.nodeID == nodeID && !ids.contains(nested.id) {
                    ids.insert(nested.id); sources.append(nested)
                }
            }
        }
        for dependency in workspace.dependencies where ids.contains(dependency.targetItemID) { ids.insert(dependency.id); ids.insert(dependency.source.id) }
        for gate in workspace.acceptances where ids.contains(gate.subject.id) { ids.insert(gate.id) }
        for choice in workspace.choices ?? [] where choice.itemID.map(ids.contains) == true { ids.insert(choice.id) }
        return ids
    }
}
