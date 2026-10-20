import SwiftUI
import CubicCore

private enum StructureField: Hashable {
    case nodeName(String), workName(String), workDuration(String)
}

@MainActor func persistStructureChange(_ model: AppModel, _ change: @escaping (inout Workspace) throws -> Void) async -> Bool {
    await model.mutateWhenReady(change)
}

private extension View {
    @ViewBuilder func structurePopoverSurface() -> some View {
        #if os(iOS)
        self.presentationCompactAdaptation(.popover)
        #else
        self
        #endif
    }
}

/// The project detail is one editable row per node and two rows per work.
struct ProjectStructureEditorView: View {
    let projectID: String
    @Environment(AppModel.self) private var model
    @State private var sheet: ProjectUISheet?
    @State private var collapsed: Set<String> = []
    @State private var ordering = false
    @State private var complete = false
    @State private var includeArchived = false
    @State private var detailItemID: String?
    @FocusState private var focusedField: StructureField?
    private var project: Project? { model.workspace.projects.first { $0.id == projectID } }

    var body: some View {
        let structure = model.workspace.projectStructure(projectID: projectID)
        List {
            if let project {
                VStack(alignment: .leading, spacing: 6) {
                    ProjectListTitle(text: project.name, showsFullName: true)
                    if let description = project.description, !description.isEmpty { Text(description).foregroundStyle(.secondary) }
                    Text("\(ProjectUI.projectStatus(project.effectiveStatus)) · \(ProjectUI.importance(project.importance))").font(.caption).foregroundStyle(.secondary)
                    if project.deadline != nil {
                        ProjectDeadlineDisplay(date: project.deadline, timeZoneID: project.deadlineTimeZoneID, dateOnly: project.deadlineIsDateOnly == true)
                    }
                }
                if structure.nodes.count > 1 {
                    Button { ordering = true } label: { Label("调整节点顺序", systemImage: "arrow.up.arrow.down").frame(minHeight: 44) }
                        .accessibilityIdentifier("project.structure.reorderNodes")
                }
                ForEach(structure.nodes, id: \.id) { node in
                    CompactNodeRow(projectID: projectID, node: node, collapsed: $collapsed, sheet: $sheet, focused: $focusedField)
                    if !collapsed.contains(node.id) {
                        ForEach(structure.membersByNode[node.id] ?? [], id: \.id) { item in
                            CompactWorkRow(projectID: projectID, item: item, depth: 1, focused: $focusedField, openDetail: { detailItemID = item.id })
                        }
                    }
                }
                ForEach(structure.directItems, id: \.id) { item in
                    CompactWorkRow(projectID: projectID, item: item, depth: 0, focused: $focusedField, openDetail: { detailItemID = item.id })
                }
                Button { sheet = .newNode(projectID: projectID) } label: { Label("添加节点", systemImage: "plus.rectangle").frame(minHeight: 44) }
                    .accessibilityIdentifier("project.structure.addNode")
                Button { sheet = .newItem(projectID: projectID, nodeID: nil) } label: { Label("添加直属工作", systemImage: "plus").frame(minHeight: 44) }
                    .accessibilityIdentifier("project.structure.addDirectWork")
                if model.workspace.nodes.contains(where: { $0.projectID == projectID && $0.archived }) {
                    Toggle("包含归档节点", isOn: $includeArchived).accessibilityIdentifier("project.includeArchivedNodes")
                    if includeArchived {
                        ForEach(model.workspace.nodes.filter { $0.projectID == projectID && $0.archived }, id: \.id) { node in
                            VStack(alignment: .leading) {
                                Text(node.name)
                                ProjectMutationButton("恢复节点", symbol: "archivebox", identifier: "project.structure.restore.\(node.id)") {
                                    try $0.setArchived(.node(node.id), archived: false, now: Date())
                                }
                            }
                        }
                    }
                }
            } else { Text("项目已不可用，请返回列表。") }
        }
        .buttonStyle(.borderless)
        .scrollDismissesKeyboard(.interactively)
        .cubicNavigationTitle("项目详情").cubicInlineNavigationTitle()
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focusedField = nil }.accessibilityIdentifier("project.structure.keyboard.done")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if let project {
                        Button("编辑项目属性", systemImage: "pencil") { sheet = .project(project) }
                        Button("保存为模板", systemImage: "doc.on.doc") { sheet = .saveProjectTemplate(projectID: projectID) }
                            .accessibilityIdentifier("project.saveTemplate")
                        NavigationLink { CalendarView() } label: { Label("查看日历安排", systemImage: "calendar") }
                        NavigationLink { RiskOverviewView(projectID: projectID) } label: { Label("排期问题", systemImage: "calendar.badge.exclamationmark") }
                        NavigationLink { SharedReferencesView(projectID: projectID, nodeID: nil) } label: { Label("关联已有工作或节点", systemImage: "link") }
                        if project.effectiveStatus == .completed {
                            ProjectMutationButton("重开项目", symbol: "arrow.uturn.backward", identifier: "project.reopen") { try $0.reopenProject(id: projectID, now: Date()) }
                        } else {
                            Button("确认项目完成", systemImage: "checkmark.seal") { complete = true }.accessibilityIdentifier("project.complete")
                        }
                        ProjectMutationButton(project.archived ? "恢复显示" : "归档项目", symbol: "archivebox", identifier: "project.archive") {
                            try $0.setProjectArchived(id: projectID, archived: !project.archived, now: Date())
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("项目操作").accessibilityIdentifier("project.operations")
            }
        }
        .task(id: model.dataVersion) {
            guard !model.loading, !model.saving,
                  model.workspace.nodes.contains(where: { $0.projectID == projectID && !$0.archived && $0.sequentialDependenciesInitialized != true }) else { return }
            _ = await model.mutate { try $0.initializeSequentialDependencies(projectID: projectID, now: Date()) }
        }
        .sheet(item: $sheet) { ProjectUISheetContent(sheet: $0) }
        .navigationDestination(item: $detailItemID) { WorkDetailView(itemID: $0) }
        .sheet(isPresented: $ordering) { ProjectNodeOrderEditor(projectID: projectID) }
        .confirmationDialog("确认项目已交付？", isPresented: $complete, titleVisibility: .visible) {
            ProjectMutationButton("确认项目完成", symbol: "checkmark", identifier: "project.complete.confirm") { try $0.completeProject(id: projectID, now: Date()) }
            Button("取消", role: .cancel) { }
        } message: { Text("检查必需工作、节点验收和成果复核，确认后记录项目已交付。") }
    }

}

private struct CompactNodeRow: View {
    let projectID: String
    let node: Node
    @Binding var collapsed: Set<String>
    @Binding var sheet: ProjectUISheet?
    var focused: FocusState<StructureField?>.Binding
    @Environment(AppModel.self) private var model
    @State private var name: String
    @State private var showInfo = false
    init(projectID: String, node: Node, collapsed: Binding<Set<String>>, sheet: Binding<ProjectUISheet?>, focused: FocusState<StructureField?>.Binding) {
        self.projectID = projectID
        self.node = node
        _collapsed = collapsed
        _sheet = sheet
        self.focused = focused
        _name = State(initialValue: node.name)
    }
    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            Button {
                if collapsed.contains(node.id) { collapsed.remove(node.id) } else { collapsed.insert(node.id) }
            } label: {
                Image(systemName: collapsed.contains(node.id) ? "chevron.right" : "chevron.down")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(collapsed.contains(node.id) ? "展开节点" : "收起节点")
            .accessibilityIdentifier("project.structure.node.\(node.id)")
            TextField("节点名称", text: $name, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.headline)
                .focused(focused, equals: .nodeName(node.id))
                .submitLabel(.done)
                .onSubmit { focused.wrappedValue = nil }
                .frame(minHeight: 44)
                .accessibilityIdentifier("project.structure.node.name.\(node.id)")
            infoButton
        }
        .padding(.vertical, 4)
        .onChange(of: node.name) { _, new in
            if focused.wrappedValue != .nodeName(node.id) { name = new }
        }
        .onChange(of: focused.wrappedValue) { _, new in
            if new != .nodeName(node.id) { commitName() }
        }
    }
    private var infoButton: some View {
        Button {
            focused.wrappedValue = nil
            showInfo = true
        } label: {
            Text("ℹ️").font(.title3).frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("详情")
        .accessibilityIdentifier("project.structure.node.info.\(node.id)")
        .popover(isPresented: $showInfo, attachmentAnchor: .rect(.bounds)) {
            NodeInfoPopover(projectID: projectID, nodeID: node.id, sheet: $sheet) { showInfo = false }
                .structurePopoverSurface()
        }
    }
    private func commitName() {
        let trimmed = ProjectUI.trim(name)
        guard let current = model.workspace.nodes.first(where: { $0.id == node.id }) else { return }
        guard trimmed != current.name else { return }
        guard !trimmed.isEmpty else {
            name = current.name
            model.errorMessage = "请输入节点名称。"
            return
        }
        let id = node.id
        Task {
            _ = await persistStructureChange(model) { workspace in
                guard var value = workspace.nodes.first(where: { $0.id == id }) else { return }
                value.name = trimmed
                try workspace.updateNode(value, now: Date())
            }
        }
    }
}

private struct NodeInfoPopover: View {
    let projectID: String
    let nodeID: String
    @Binding var sheet: ProjectUISheet?
    let dismissPopover: () -> Void
    @Environment(AppModel.self) private var model
    @State private var required = true
    @State private var blockers: Set<String> = []
    private var node: Node? { model.workspace.nodes.first { $0.id == nodeID } }
    var body: some View {
        NavigationStack {
            List {
                if let node {
                    Text(ProjectUI.nodeSummary(node.id, in: model.workspace)).font(.caption).foregroundStyle(.secondary)
                    if let predecessor = node.sequentialPredecessorNodeID {
                        Text("前置节点：\(ProjectUI.sourceName(.node(predecessor), in: model.workspace))")
                            .font(.subheadline)
                            .accessibilityIdentifier("project.structure.node.predecessor.\(node.id)")
                    }
                    InlineDisclosure("验收与完成", identifier: "project.structure.node.acceptance.\(node.id)") {
                        VStack(alignment: .leading, spacing: 10) {
                            if model.workspace.activeAcceptances(for: .node(node.id)).isEmpty {
                                Text("默认验收条件：完成自身。必需工作完成后即通过。").font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(model.workspace.acceptances.filter { $0.isActive && $0.subject == .node(node.id) }, id: \.id) { acceptance in
                                AcceptanceCriterionRow(gate: acceptance)
                            }
                            Button("添加验收条件") { sheet = .acceptance(.node(node.id)) }
                            ProjectMutationButton("确认节点完成", symbol: "checkmark.seal", identifier: "node.complete.\(node.id)") { try $0.completeNode(id: node.id, now: Date()) }
                            ProjectMutationButton("归档节点", symbol: "archivebox", identifier: "node.archive.\(node.id)") { try $0.setArchived(.node(node.id), archived: true, now: Date()) }
                        }
                    }
                    Toggle("交付必需", isOn: $required).frame(minHeight: 44)
                        .accessibilityIdentifier("project.structure.node.required.\(node.id)")
                    if model.workspace.blockers.isEmpty {
                        Text("还没有外部等待。需要时先到外部等待页新建，再回到这里勾选。").font(.caption).foregroundStyle(.secondary)
                    } else {
                        InlineDisclosure("整个节点的等待", identifier: "project.structure.node.waiting.\(node.id)") {
                            ForEach(model.workspace.blockers, id: \.id) { blocker in
                                ProjectSetToggle(title: blocker.name, id: blocker.id, selection: $blockers, identifier: "project.structure.node.blocker.\(node.id).\(blocker.id)")
                            }
                        }
                    }
                    Button {
                        dismissPopover()
                        let project = projectID
                        let node = node.id
                        Task { @MainActor in sheet = .newItem(projectID: project, nodeID: node) }
                    } label: { Label("添加工作", systemImage: "plus").frame(minHeight: 44) }
                    .accessibilityIdentifier("project.structure.addWork.\(node.id)")
                } else { Text("节点已不可用。") }
            }
            .buttonStyle(.borderless)
            .cubicNavigationTitle("节点")
            .cubicInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismissPopover() }.accessibilityIdentifier("project.structure.node.info.done.\(nodeID)")
                }
            }
        }
        .frame(minWidth: 320, idealWidth: 360, minHeight: 420)
        .onAppear {
            if let node { required = node.required; blockers = Set(node.blockerIDs ?? []) }
        }
        .onChange(of: required) { _, new in commitRequired(new) }
        .onChange(of: blockers) { _, new in commitBlockers(new) }
    }
    private func commitRequired(_ new: Bool) {
        Task {
            _ = await persistStructureChange(model) { workspace in
                guard var value = workspace.nodes.first(where: { $0.id == nodeID }), value.required != new else { return }
                value.isRequired = new
                try workspace.updateNode(value, now: Date())
            }
        }
    }
    private func commitBlockers(_ new: Set<String>) {
        Task {
            _ = await persistStructureChange(model) { workspace in
                guard var value = workspace.nodes.first(where: { $0.id == nodeID }) else { return }
                guard Set(value.blockerIDs ?? []) != new else { return }
                value.blockerIDs = new.sorted()
                try workspace.updateNode(value, now: Date())
            }
        }
    }
}

private struct CompactWorkRow: View {
    let projectID: String
    let itemID: String
    let depth: Int
    var focused: FocusState<StructureField?>.Binding
    let openDetail: () -> Void
    @Environment(AppModel.self) private var model
    @State private var name: String
    @State private var duration: String
    @State private var showInfo = false
    @State private var picking = false
    init(projectID: String, item: WorkItem, depth: Int, focused: FocusState<StructureField?>.Binding, openDetail: @escaping () -> Void) {
        self.projectID = projectID
        itemID = item.id
        self.depth = depth
        self.focused = focused
        self.openDetail = openDetail
        _name = State(initialValue: item.name)
        _duration = State(initialValue: item.remainingMinutes.map(String.init) ?? "")
    }
    private var item: WorkItem? { model.item(itemID) }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 6) {
                TextField("工作名称", text: $name, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .focused(focused, equals: .workName(itemID))
                    .submitLabel(.done)
                    .onSubmit { focused.wrappedValue = nil }
                    .frame(minHeight: 44)
                    .layoutPriority(1)
                    .accessibilityIdentifier("project.structure.item.name.\(itemID)")
                HStack(spacing: 4) {
                    TextField("分钟", text: $duration)
                        .textFieldStyle(.roundedBorder)
                        .cubicNumberKeyboard()
                        .multilineTextAlignment(.trailing)
                        .focused(focused, equals: .workDuration(itemID))
                        .submitLabel(.done)
                        .onSubmit { focused.wrappedValue = nil }
                        .frame(width: 56, height: 44)
                        .disabled(item?.status == .completed)
                        .accessibilityLabel("耗时")
                        .accessibilityIdentifier("project.structure.item.duration.\(itemID)")
                    Text("分钟").font(.subheadline).foregroundStyle(.secondary).fixedSize()
                    infoButton
                }.fixedSize(horizontal: true, vertical: false)
            }
            Button { focused.wrappedValue = nil; picking = true } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(predecessorSummary)
                        .font(.subheadline)
                        .foregroundStyle(hasPredecessor ? Color.primary : Color.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(predecessorSummary)
            .accessibilityIdentifier("project.structure.item.predecessors.\(itemID)")
            .popover(isPresented: $picking, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                PredecessorPicker(projectID: projectID, itemID: itemID) { picking = false }
                    .structurePopoverSurface()
            }
        }
        .padding(.leading, CGFloat(depth) * 26)
        .padding(.vertical, 4)
        .overlay(alignment: .leading) {
            if depth > 0 { Rectangle().fill(Color.cubicAccent.opacity(0.25)).frame(width: 2).padding(.leading, 8) }
        }
        .onChange(of: item?.name) { _, new in
            if focused.wrappedValue != .workName(itemID), let new { name = new }
        }
        .onChange(of: item?.remainingMinutes) { _, minutes in
            if focused.wrappedValue != .workDuration(itemID) { duration = minutes.map(String.init) ?? "" }
        }
        .onChange(of: focused.wrappedValue) { _, new in
            // The text binding flushes after this callback. Commit on the next turn so one history row sees the finished number.
            let commitNameNow = new != .workName(itemID)
            let commitDurationNow = new != .workDuration(itemID)
            Task { @MainActor in
                if commitNameNow { commitName() }
                if commitDurationNow { commitDuration() }
            }
        }
    }
    private var activeDependencies: [Dependency] {
        model.workspace.dependencies.filter { $0.isActive && $0.targetItemID == itemID }
    }
    private var hasPredecessor: Bool { !activeDependencies.isEmpty }
    private var predecessorSummary: String {
        let names = activeDependencies.map { ProjectUI.sourceName($0.source, in: model.workspace) }
        if names.isEmpty { return "前置：无，点击选择" }
        return "前置：" + names.joined(separator: "、")
    }
    private var infoButton: some View {
        Button {
            focused.wrappedValue = nil
            showInfo = true
        } label: {
            Text("ℹ️").font(.title3).frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("详情")
        .accessibilityIdentifier("project.structure.item.info.\(itemID)")
        .popover(isPresented: $showInfo, attachmentAnchor: .rect(.bounds)) {
            WorkInfoPopover(itemID: itemID, openDetail: {
                openDetail()
                showInfo = false
            }) { showInfo = false }
            .structurePopoverSurface()
        }
    }
    private func commitName() {
        let trimmed = ProjectUI.trim(name)
        guard let current = item else { return }
        guard trimmed != current.name else { return }
        guard !trimmed.isEmpty else { name = current.name; model.errorMessage = "请输入工作名称。"; return }
        let id = itemID
        Task {
            _ = await persistStructureChange(model) { workspace in
                guard var value = workspace.items.first(where: { $0.id == id }) else { return }
                value.name = trimmed
                try workspace.updateItem(value, now: Date())
            }
        }
    }
    private func commitDuration() {
        guard item?.status != .completed else { return }
        guard let current = item else { return }
        let saved = current.remainingMinutes.map(String.init) ?? ""
        guard duration != saved else { return }
        if let message = ProjectUI.minutesValidation(duration, title: "耗时") {
            duration = saved
            model.errorMessage = message
            return
        }
        guard let minutes = ProjectUI.optionalMinutes(duration) else {
            duration = saved
            model.errorMessage = "耗时请输入非负整数分钟。"
            return
        }
        let id = itemID
        Task {
            let savedChange = await persistStructureChange(model) { workspace in
                guard workspace.items.first(where: { $0.id == id })?.remainingMinutes != minutes else { return }
                try workspace.updateRemaining(itemID: id, minutes: minutes, now: Date(), reason: .revision)
            }
            if !savedChange, model.item(id)?.remainingMinutes != minutes { duration = model.item(id)?.remainingMinutes.map(String.init) ?? saved }
        }
    }
}

private struct WorkInfoPopover: View {
    let itemID: String
    let openDetail: () -> Void
    let dismissPopover: () -> Void
    @Environment(AppModel.self) private var model
    @State private var detail = ""
    @State private var required = true
    @State private var energy = Energy.normal.rawValue
    @State private var continuous = false
    @State private var continuousMinutes = ""
    @State private var focusedWork = false
    @State private var contexts = ""
    @State private var nodeID = ""
    @State private var projectIDs: Set<String> = []
    @State private var hasDeadline = false
    @State private var deadline = Date()
    @State private var dateOnly = true
    @State private var zone = TimeZone.current.identifier
    @State private var ready = false
    @FocusState private var editingDetail: Bool
    private var item: WorkItem? { model.item(itemID) }
    private var selectedNode: Node? { model.workspace.nodes.first { $0.id == nodeID } }
    var body: some View {
        NavigationStack {
            List {
                if let item {
                    Button(action: openDetail) {
                        Label("执行与投入记录", systemImage: "play.circle").frame(minHeight: 44)
                    }.accessibilityIdentifier("project.item.\(item.id)")
                    InlineDisclosure("耗时修改历史", identifier: "project.structure.item.history.\(item.id)") {
                        let revisions = model.workspace.estimateRevisions?.filter { $0.itemID == item.id }.sorted { $0.date > $1.date } ?? []
                        if revisions.isEmpty { Text("还没有耗时修改。").font(.caption).foregroundStyle(.secondary) }
                        ForEach(revisions, id: \.id) { revision in
                            ProjectInfoLine(title: ProjectUI.dateLabel(revision.date),
                                            value: "\(minutesLabel(revision.previousMinutes)) → \(minutesLabel(revision.minutes))")
                        }
                    }
                    Text(ProjectUI.statusLabel(item, blocked: !ProjectUI.predecessorsSatisfied(item.id, in: model.workspace)))
                        .font(.subheadline).foregroundStyle(.secondary)
                    TextField("工作说明", text: $detail, axis: .vertical)
                        .focused($editingDetail)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("project.structure.item.description.\(item.id)")
                    Toggle("交付必需", isOn: $required).frame(minHeight: 44)
                        .accessibilityIdentifier("project.structure.item.required.\(item.id)")
                    Picker("精力要求", selection: $energy) {
                        Text("低负荷").tag(Energy.low.rawValue)
                        Text("普通").tag(Energy.normal.rawValue)
                        Text("高专注").tag(Energy.high.rawValue)
                    }.accessibilityIdentifier("project.structure.item.energy.\(item.id)")
                    ProjectDeadlineFields(enabled: $hasDeadline, date: $deadline, dateOnly: $dateOnly, zone: $zone, identifier: "project.structure.item.deadline.\(item.id)")
                    TextField("标签，例如办公室、电脑", text: $contexts, axis: .vertical).frame(minHeight: 44)
                    Toggle("我关注的", isOn: $focusedWork).frame(minHeight: 44)
                    Toggle("需要一段不中断的时间", isOn: $continuous).frame(minHeight: 44)
                    if continuous {
                        ProjectMinutesField(title: "至少连续多少分钟", text: $continuousMinutes, identifier: "project.structure.item.continuous.\(item.id)")
                    }
                    Picker("所属节点", selection: $nodeID) {
                        Text("直属工作").tag("")
                        ForEach(model.workspace.nodes.filter { !$0.archived || $0.id == nodeID }, id: \.id) { node in
                            Text(node.name).tag(node.id)
                        }
                    }
                    .onChange(of: nodeID) { old, new in if ready, old != new, !new.isEmpty { required = true } }
                    ForEach(model.workspace.projects.filter { !$0.archived || projectIDs.contains($0.id) }, id: \.id) { project in
                        if project.id != selectedNode?.projectID {
                            ProjectSetToggle(title: project.name, id: project.id, selection: $projectIDs, identifier: "project.structure.item.project.\(item.id).\(project.id)")
                        }
                    }
                } else { Text("这项工作已不可用。") }
            }
            .buttonStyle(.borderless)
            .cubicNavigationTitle("工作")
            .cubicInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { Task { if await commit() { dismissPopover() } } }
                        .disabled(model.saving)
                        .accessibilityIdentifier("project.structure.item.info.done.\(itemID)")
                }
            }
        }
        .frame(minWidth: 320, idealWidth: 360, minHeight: 480)
        .onAppear { load(); Task { ready = true } }
        .onChange(of: editingDetail) { _, editing in if ready && !editing { Task { await commit() } } }
        .onChange(of: required) { _, _ in if ready { Task { await commit() } } }
        .onChange(of: energy) { _, _ in if ready { Task { await commit() } } }
        .onChange(of: focusedWork) { _, _ in if ready { Task { await commit() } } }
        .onChange(of: continuous) { _, _ in if ready { Task { await commit() } } }
        .onChange(of: nodeID) { _, _ in if ready { Task { await commit() } } }
        .onChange(of: projectIDs) { _, _ in if ready { Task { await commit() } } }
        .onChange(of: hasDeadline) { _, _ in if ready { Task { await commit() } } }
        .onChange(of: dateOnly) { _, _ in if ready { Task { await commit() } } }
        .onChange(of: zone) { _, _ in if ready { Task { await commit() } } }
        .onDisappear { if ready { Task { await commit() } } }
    }
    private func load() {
        guard let item else { return }
        detail = item.description ?? ""
        required = item.required
        energy = item.energy.rawValue
        continuous = item.requiresContinuous
        continuousMinutes = item.continuousMinutes.map(String.init) ?? ""
        focusedWork = item.isFocused ?? false
        contexts = (item.contextTags ?? []).joined(separator: "、")
        nodeID = item.nodeID ?? ""
        projectIDs = Set(item.projectIDs)
        hasDeadline = item.deadline != nil
        deadline = item.deadline ?? Date()
        dateOnly = item.deadlineIsDateOnly ?? true
        zone = item.deadlineTimeZoneID ?? TimeZone.current.identifier
    }
    private func commit() async -> Bool {
        guard ready, let current = item else { return false }
        if let message = ProjectUI.minutesValidation(continuousMinutes, title: "连续时长") {
            model.errorMessage = message
            return false
        }
        var value = current
        let trimmedDetail = ProjectUI.trim(detail)
        value.description = trimmedDetail.isEmpty ? nil : detail
        value.nodeID = nodeID.isEmpty ? nil : nodeID
        var projects = projectIDs
        if let selectedNode { projects.insert(selectedNode.projectID) }
        value.projectIDs = projects.sorted()
        if required != current.required { value.isRequired = required }
        if focusedWork { value.isFocused = true }
        else if current.isFocused == true { value.isFocused = false }
        let tags = contexts.components(separatedBy: CharacterSet(charactersIn: ",，、\n")).map(ProjectUI.trim).filter { !$0.isEmpty }
        value.contextTags = tags.isEmpty ? nil : tags
        value.energy = Energy(rawValue: energy) ?? .normal
        value.requiresContinuous = continuous
        value.continuousMinutes = continuous ? ProjectUI.optionalMinutes(continuousMinutes) : nil
        do {
            if hasDeadline {
                value.deadline = try ProjectUI.deadline(deadline, zone: zone, dateOnly: dateOnly)
                value.deadlineTimeZoneID = zone
                value.deadlineIsDateOnly = dateOnly
            } else {
                value.deadline = nil
            }
        } catch { model.errorMessage = error.localizedDescription; return false }
        guard value != current else { return true }
        return await persistStructureChange(model) { workspace in
            guard var latest = workspace.items.first(where: { $0.id == itemID }) else { return }
            latest.description = value.description
            latest.nodeID = value.nodeID
            latest.projectIDs = value.projectIDs
            latest.isRequired = value.isRequired
            latest.isFocused = value.isFocused
            latest.contextTags = value.contextTags
            latest.energy = value.energy
            latest.requiresContinuous = value.requiresContinuous
            latest.continuousMinutes = value.continuousMinutes
            latest.deadline = value.deadline
            latest.deadlineTimeZoneID = value.deadlineTimeZoneID
            latest.deadlineIsDateOnly = value.deadlineIsDateOnly
            guard latest != workspace.items.first(where: { $0.id == itemID }) else { return }
            try workspace.updateItem(latest, now: Date())
        }
    }
}

private struct PredecessorPicker: View {
    let projectID: String
    let itemID: String
    let dismissPopover: () -> Void
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var selected: Set<String> = []
    @State private var kept: Set<String> = []
    @State private var removedRetained: Set<String> = []
    @State private var loaded = false
    private var offers: [PredecessorWorkOffer] {
        model.workspace.predecessorWorkOffers(for: itemID, inProject: projectID, keeping: kept)
    }
    private var visibleOffers: [PredecessorWorkOffer] {
        let text = ProjectUI.trim(query)
        guard !text.isEmpty else { return offers }
        return offers.filter { $0.name.localizedCaseInsensitiveContains(text) || $0.affiliation.localizedCaseInsensitiveContains(text) }
    }
    private var retained: [Dependency] {
        model.workspace.dependencies.filter { dependency in
            guard dependency.isActive, dependency.targetItemID == itemID else { return false }
            if case .item = dependency.source { return false }
            return true
        }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("只能选择工作。所有选中的前置都完成后，当前工作才能开始。")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("搜索工作、节点或项目", text: $query)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("project.structure.predecessors.search.\(itemID)")
                }
                if !retained.isEmpty && ProjectUI.trim(query).isEmpty {
                    Section("已有的节点或等待") {
                        ForEach(retained, id: \.id) { dependency in
                            let removing = removedRetained.contains(dependency.id)
                            Button { if removing { removedRetained.remove(dependency.id) } else { removedRetained.insert(dependency.id) } } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: removing ? "circle" : "checkmark.circle.fill")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(ProjectUI.sourceName(dependency.source, in: model.workspace))
                                        Text(retainedKind(dependency.source)).font(.caption).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.frame(minHeight: 44)
                            }
                            .accessibilityIdentifier("project.structure.predecessor.keep.\(itemID).\(dependency.id)")
                        }
                    }
                }
                Section {
                    if visibleOffers.isEmpty { Text("没有可选择的工作").foregroundStyle(.secondary) }
                    ForEach(visibleOffers) { offer in
                        let on = selected.contains(offer.itemID)
                        Button {
                            guard offer.cycleReason == nil else { return }
                            if on { selected.remove(offer.itemID) } else { selected.insert(offer.itemID) }
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(offer.cycleReason == nil ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(offer.name).foregroundStyle(offer.cycleReason == nil ? Color.primary : Color.secondary)
                                    Text(offer.cycleReason ?? offer.affiliation)
                                        .font(.caption)
                                        .foregroundStyle(offer.cycleReason == nil ? Color.secondary : Color.cubicAmber)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(minHeight: 44, alignment: .leading)
                        }
                        .disabled(offer.cycleReason != nil)
                        .accessibilityLabel(offer.name)
                        .accessibilityValue(offer.cycleReason ?? offer.affiliation)
                        .accessibilityIdentifier("project.structure.predecessor.option.\(itemID).\(offer.itemID)")
                    }
                }
            }
            .buttonStyle(.borderless)
            .cubicNavigationTitle("选择前置工作")
            .cubicInlineNavigationTitle()
            .safeAreaInset(edge: .bottom) {
                Button("完成") { Task { if await apply() { dismissPopover() } } }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .disabled(model.saving)
                    .accessibilityIdentifier("project.structure.predecessors.done.\(itemID)")
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
        }
        .frame(minWidth: 320, idealWidth: 360, minHeight: 460)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            let current = Set(model.workspace.dependencies.compactMap { dependency -> String? in
                guard dependency.isActive, dependency.targetItemID == itemID, case .item(let id) = dependency.source else { return nil }
                return id
            })
            selected = current
            kept = current
        }
    }
    private func retainedKind(_ source: DependencySource) -> String {
        switch source { case .node: "节点前置，可取消。新增候选只提供工作。"; case .blocker: "等待前置，可取消。新增候选只提供工作。"; case .item: "" }
    }
    private func apply() async -> Bool {
        let desired = selected
        let drop = removedRetained
        let current = model.workspace.dependencies.filter { $0.isActive && $0.targetItemID == itemID }
        let currentItems = Set(current.compactMap { dependency -> String? in
            if case .item(let id) = dependency.source { return id }
            return nil
        })
        let removals = current.filter { dependency in
            if case .item(let id) = dependency.source { return !desired.contains(id) }
            return drop.contains(dependency.id)
        }
        let additions = desired.subtracting(currentItems)
        if removals.isEmpty && additions.isEmpty { return true }
        let targetID = itemID
        return await persistStructureChange(model) { workspace in
            for dependency in removals { try workspace.removeDependency(id: dependency.id, now: Date()) }
            for id in additions.sorted() {
                try workspace.addDependency(Dependency(source: .item(id), targetItemID: targetID), now: Date())
            }
        }
    }
}

/// Explicit expansion controls work consistently inside hierarchy rows on iOS and macOS.
struct InlineDisclosure<Content: View>: View {
    let title: String
    let identifier: String
    let content: Content
    @State private var expanded = false
    init(_ title: String, identifier: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.identifier = identifier; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { expanded.toggle() } label: {
                HStack {
                    Text(title)
                    Spacer()
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier(identifier)
                .accessibilityValue(expanded ? "已展开" : "已收起")
            if expanded { content }
        }
    }
}

/// Compact rows keep the whole node sequence easy to inspect on a small phone.
private struct ProjectNodeOrderEditor: View {
    let projectID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let nodes = model.workspace.projectStructure(projectID: projectID).nodes
        NavigationStack {
            List {
                Section {
                    Text("按顺序执行：后一个节点等待前一个节点完成。上下移动会立即保存，并更新默认依赖。手工添加的前置条件保留。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("节点顺序") {
                    ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(index + 1). \(node.name)").font(.headline)
                                .accessibilityIdentifier("project.nodeOrder.name.\(node.id)")
                            Text(index == 0 ? "无默认前置节点" : "前置：\(nodes[index - 1].name)")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                ProjectActionButton("上移", symbol: "arrow.up", identifier: "project.nodeOrder.up.\(node.id)") {
                                    await move(node.id, offset: -1)
                                }.disabled(index == 0 || model.saving)
                                Spacer()
                                ProjectActionButton("下移", symbol: "arrow.down", identifier: "project.nodeOrder.down.\(node.id)") {
                                    await move(node.id, offset: 1)
                                }.disabled(index == nodes.count - 1 || model.saving)
                            }
                        }.padding(.vertical, 4)
                    }
                }
            }.buttonStyle(.borderless)
                .cubicNavigationTitle("调整节点顺序").cubicInlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }.disabled(model.saving).accessibilityIdentifier("project.nodeOrder.done")
                    }
                }
        }
    }
    private func move(_ id: String, offset: Int) async -> Bool {
        await model.mutate { workspace in
            var ids = workspace.projectStructure(projectID: projectID).nodes.map(\.id)
            guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return }
            ids.swapAt(index, index + offset)
            try workspace.reorderProjectNodes(projectID: projectID, orderedNodeIDs: ids, now: Date())
        }
    }
}
