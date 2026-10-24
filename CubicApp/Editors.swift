import SwiftUI
import CubicCore

enum WorkFeedbackTransition: Equatable {
    case none, complete(String), start(String)
    var skipLabel: String {
        switch self { case .none: "暂不记录"; case .complete: "跳过反馈，确认完成"; case .start: "跳过反馈，开始工作" }
    }
    func apply(in workspace: inout Workspace, now: Date, dataVersion: String = "explicit-execution") throws {
        switch self {
        case .none: break
        case .complete(let id):
            try ProjectUI.requireCurrentDependencies(id, in: workspace)
            try workspace.completeItem(id: id, now: now)
        case .start(let id):
            try ProjectUI.requireCurrentDependencies(id, in: workspace)
            guard let item = workspace.items.first(where: { $0.id == id }), item.status != .completed,
                  item.effectiveDisposition == .active, !item.needsReview,
                  workspace.effectiveItemDependencies(itemID: id).allSatisfy({ workspace.sourceSatisfied($0.source) }) else {
                throw CoreError.invalid("当前工作不能开始或继续，请核对最新状态。")
            }
            if item.status == .pending { try workspace.startItem(id: id, now: now) }
            // Resuming preserves first-start/pre-start facts and all prior choices.
            try workspace.chooseNextAction(itemID: id, now: now, displayedItemIDs: [id], dataVersion: dataVersion,
                                           impactWasVerified: false, note: "明确真实开始 / 切换，未核验完整投入影响")
        }
    }
}

enum ProjectUISheet: Identifiable {
    case saveProjectTemplate(projectID: String)
    case project(Project?), newProject(onCreated: (String) -> Void), newNode(projectID: String), editNode(Node)
    case markdownProject(onCreated: (String) -> Void)
    case newItem(projectID: String?, nodeID: String?), editItem(WorkItem)
    case acceptance(WorkReference), editAcceptance(Acceptance), failure(Acceptance)
    case dependency(String), editDependency(Dependency)
    case blocker(Blocker?), record(WorkItem), rework(WorkItem), trial(String)
    case feedback(WorkItem, WorkFeedbackTransition), startFeedback(WorkItem), historicalRecord(WorkItem)
    case correctSession(WorkSession), correctEstimate(EstimateRevision), allocation([String]), clarify(WorkItem), baseline(WorkItem, String)
    var id: String {
        switch self {
        case .saveProjectTemplate(let id): "template.save.\(id)"
        case .project(let p): "project.\(p?.id ?? "new")"
        case .newProject: "project.new.auto"
        case .markdownProject: "project.new.markdown"
        case .newNode(let id): "node.new.\(id)"
        case .editNode(let n): "node.edit.\(n.id)"
        case .newItem(let p, let n): "item.new.\(p ?? "inbox").\(n ?? "none")"
        case .editItem(let i): "item.edit.\(i.id)"
        case .acceptance(let s): "acceptance.new.\(s.id)"
        case .editAcceptance(let a): "acceptance.edit.\(a.id)"
        case .failure(let a): "acceptance.fail.\(a.id)"
        case .dependency(let id): "dependency.new.\(id)"
        case .editDependency(let d): "dependency.edit.\(d.id)"
        case .blocker(let b): "blocker.\(b?.id ?? "new")"
        case .record(let i): "record.\(i.id)"
        case .feedback(let i, _): "feedback.\(i.id)"
        case .startFeedback(let i): "start-feedback.\(i.id)"
        case .historicalRecord(let i): "historical-record.\(i.id)"
        case .rework(let i): "rework.\(i.id)"
        case .trial(let id): "trial.\(id)"
        case .correctSession(let s): "correct.session.\(s.id)"
        case .correctEstimate(let r): "correct.estimate.\(r.id)"
        case .baseline(let i, let kind): "baseline.\(i.id).\(kind)"
        case .clarify(let i): "clarify.\(i.id)"
        case .allocation(let ids): "allocate.\(ids.sorted().joined(separator: "."))"
        }
    }
}
struct ProjectUISheetContent: View {
    let sheet: ProjectUISheet
    @ViewBuilder var body: some View {
        switch sheet {
        case .saveProjectTemplate(let id): SaveProjectTemplateView(projectID: id)
        case .project(let p): CubicProjectEditor(project: p)
        case .newProject(let onCreated): CubicProjectEditor(project: nil, onCreated: onCreated)
        case .markdownProject(let onCreated): MarkdownProjectEditor(onCreated: onCreated)
        case .newNode(let id): CubicNodeEditor(projectID: id)
        case .editNode(let n): CubicNodeEditor(projectID: n.projectID, node: n)
        case .newItem(let p, let n): CubicWorkEditor(projectID: p, nodeID: n)
        case .editItem(let i): CubicWorkEditor(item: i)
        case .acceptance(let s): CubicAcceptanceEditor(subject: s)
        case .editAcceptance(let a): CubicAcceptanceEditor(subject: a.subject, acceptance: a)
        case .failure(let a): AcceptanceFailureEditor(acceptance: a)
        case .dependency(let id): CubicDependencyEditor(itemID: id)
        case .editDependency(let d): CubicDependencyEditor(itemID: d.targetItemID, dependency: d)
        case .blocker(let b): CubicBlockerEditor(blocker: b)
        case .record(let i): CubicWorkRecordEditor(item: i)
        case .feedback(let i, let transition): CubicWorkRecordEditor(item: i, transition: transition)
        case .startFeedback(let i): WorkStartFeedbackView(itemID: i.id)
        case .historicalRecord(let i): CubicWorkRecordEditor(item: i, historicalOnly: true)
        case .rework(let i): CubicReworkEditor(item: i)
        case .trial(let id): TrialView(itemID: id)
        case .correctSession(let s): WorkSessionCorrectionEditor(session: s)
        case .correctEstimate(let r): EstimateCorrectionEditor(revision: r)
        case .allocation(let ids): EffortAllocationEditor(sessionIDs: ids)
        case .clarify(let i): InboxClarificationEditor(item: i)
        case .baseline(let i, let kind): BaselineCorrectionEditor(item: i, kind: kind)
        }
    }
}

/// Only successful persistence dismisses a draft; modal errors are shown inside the sheet.
struct ProjectEditorContainer<Content: View>: View {
    let title: String
    let identifier: String
    let validation: String?
    let save: @MainActor () async -> Bool
    let content: Content
    let operationInFlight: Bool
    let saveLabel: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    init(title: String, identifier: String, validation: String?, save: @escaping @MainActor () async -> Bool, operationInFlight: Bool = false, saveLabel: String = "保存", @ViewBuilder content: () -> Content) {
        self.title = title; self.identifier = identifier; self.validation = validation; self.save = save; self.operationInFlight = operationInFlight; self.content = content(); self.saveLabel = saveLabel
    }
    var body: some View {
        NavigationStack {
            Form {
                content
                if let validation { Section("填写提示") { Text(validation).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("\(identifier).validation") } }
            }.disabled(saving || operationInFlight).scrollDismissesKeyboard(.interactively)
                .cubicNavigationTitle(title).cubicInlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }.frame(minWidth: 44, minHeight: 44).disabled(saving || operationInFlight).accessibilityIdentifier("\(identifier).cancel")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(saving ? "\(saveLabel)中" : saveLabel) {
                            guard !saving, !operationInFlight, !model.saving, validation == nil else { return }
                            saving = true
                            Task { let saved = await save(); saving = false; if saved { dismiss() } }
                        }.frame(minWidth: 44, minHeight: 44).disabled(saving || operationInFlight || model.saving || model.loading || validation != nil).accessibilityIdentifier("\(identifier).save")
                    }
                }
        }.interactiveDismissDisabled(saving || operationInFlight).modifier(ModalMessages())
    }
}

struct CubicProjectEditor: View {
    let project: Project?
    var onCreated: ((String) -> Void)? = nil
    @Environment(AppModel.self) private var model
    @State private var name: String
    @State private var goal: String
    @State private var importance: Int
    @State private var status: String
    @State private var buffer: String
    @State private var hasDeadline: Bool
    @State private var deadline: Date
    @State private var dateOnly: Bool
    @State private var zone: String
    @State private var note = ""
    init(project: Project? = nil, onCreated: ((String) -> Void)? = nil) {
        self.project = project
        self.onCreated = onCreated
        _name = State(initialValue: project?.name ?? ""); _goal = State(initialValue: project?.description ?? "")
        _importance = State(initialValue: project?.importance ?? 0); _status = State(initialValue: (project?.effectiveStatus ?? .planning).rawValue)
        _buffer = State(initialValue: project?.warningBufferMinutes.map(String.init) ?? "")
        _hasDeadline = State(initialValue: project?.deadline != nil); _deadline = State(initialValue: project?.deadline ?? Date())
        _dateOnly = State(initialValue: project?.deadlineIsDateOnly ?? true); _zone = State(initialValue: project?.deadlineTimeZoneID ?? TimeZone.current.identifier)
    }
    private var validation: String? {
        if ProjectUI.trim(name).isEmpty { return "请输入项目名称，其他信息可以稍后补充。" }
        return ProjectUI.minutesValidation(buffer, title: "时间余量提醒")
    }
    var body: some View {
        ProjectEditorContainer(title: project == nil ? "创建项目" : "编辑项目", identifier: "editor.project", validation: validation, save: save) {
            Section("目标") {
                TextField("项目名称", text: $name, axis: .vertical).frame(minHeight: 44).accessibilityIdentifier("editor.project.name")
                TextField("目标说明", text: $goal, axis: .vertical).frame(minHeight: 44).accessibilityIdentifier("editor.project.goal")
                Stepper("重要性：\(ProjectUI.importance(importance))", value: $importance, in: 0...5).frame(minHeight: 44).accessibilityIdentifier("editor.project.importance")
                Text("0 表示未分级，5 表示最重要。").font(.caption).foregroundStyle(.secondary)
            }
            Section("截止时间") {
                ProjectDeadlineFields(enabled: $hasDeadline, date: $deadline, dateOnly: $dateOnly, zone: $zone, identifier: "editor.project.deadline")
            }
            Section("状态与提醒") {
                ProjectMinutesField(title: "时间余量低于多少分钟时提醒", text: $buffer, identifier: "editor.project.buffer")
                Text("可留空。当截止前可用时间的余量低于此值时提醒；仍可随时添加新工作。").font(.caption).foregroundStyle(.secondary)
                if project?.effectiveStatus == .completed {
                    Text("项目已完成。如要继续交付，请先重开项目。修改工作范围后可能需要复核成果。")
                } else {
                    Picker("项目状态", selection: $status) {
                        Text("待拆分").tag(ProjectStatus.planning.rawValue); Text("进行中").tag(ProjectStatus.active.rawValue)
                        Text("暂缓，截止仍有效").tag(ProjectStatus.deferred.rawValue); Text("取消项目").tag(ProjectStatus.cancelled.rawValue)
                    }.frame(minHeight: 44).accessibilityIdentifier("editor.project.status")
                }
                TextField("修改说明（可选）", text: $note, axis: .vertical).frame(minHeight: 44).accessibilityIdentifier("editor.project.note")
                if status == ProjectStatus.cancelled.rawValue { ImpactItemsView(source: nil, itemIDs: model.workspace.items.filter { $0.projectIDs.contains(project?.id ?? "") }.map(\.id)) }
            }
        }
    }
    private func save() async -> Bool {
        var value = project ?? Project(name: ProjectUI.trim(name), importance: importance)
        value.name = ProjectUI.trim(name); value.description = goal; value.importance = importance
        value.warningBufferMinutes = ProjectUI.optionalMinutes(buffer)
        if value.effectiveStatus != .completed { value.status = ProjectStatus(rawValue: status) ?? .planning }
        value.deadlineTimeZoneID = zone; value.deadlineIsDateOnly = dateOnly
        do { value.deadline = hasDeadline ? try ProjectUI.deadline(deadline, zone: zone, dateOnly: dateOnly) : nil }
        catch { model.errorMessage = error.localizedDescription; return false }
        let savedValue = value; let memo = note
        let created = project == nil
        let saved = await model.mutate { workspace in
            if created { try workspace.addProject(savedValue, now: Date()) }
            else { try workspace.updateProject(savedValue, now: Date(), note: memo) }
        }
        if saved, created { onCreated?(savedValue.id) }
        return saved
    }
}

struct MarkdownProjectEditor: View {
    let onCreated: (String) -> Void
    @Environment(AppModel.self) private var model
    @State private var source = ""
    @State private var referenceDate = Date()
    @State private var timeZone = TimeZone.current
    private var parsed: Result<MarkdownProjectDraft, Error> {
        Result { try MarkdownProjectParser.parse(source, now: referenceDate, timeZone: timeZone) }
    }
    private var referenceYear: Int {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        return calendar.component(.year, from: referenceDate)
    }
    private var validation: String? {
        if case .failure(let error) = parsed { return error.localizedDescription }
        return nil
    }
    private static let example = """
    家庭财务复盘, 10.10
    - 支出分类
        - 大额消费校对, 2h
        - 标签化, 2h
        - 数据分布统计, 1h
    - 复盘
        - 具体调整目标, 2h
    """
    var body: some View {
        ProjectEditorContainer(title: "Markdown 快速创建", identifier: "editor.markdown", validation: validation, save: save) {
            Section {
                HStack {
                    PasteButton(payloadType: String.self) { values in source = values.joined(separator: "\n") }
                        .accessibilityIdentifier("editor.markdown.paste")
                    Spacer()
                    Button("填入示例") { source = Self.example }.accessibilityIdentifier("editor.markdown.example")
                }
                TextEditor(text: $source).font(.system(.body, design: .monospaced))
                    .frame(minHeight: 220).autocorrectionDisabled().cubicVerbatimInput()
                    .accessibilityLabel("Markdown 项目文本").accessibilityIdentifier("editor.markdown.source")
            } header: { Text("粘贴 Markdown") } footer: {
                Text("首行是项目；一级列表是节点，多缩进一级是工作。支持 -、*、+ 和有序列表。")
            }
            Section("参数格式") {
                Text("用英文或中文逗号分隔名称与参数。截止日期如 10.10、2026-10-10；工作耗时如 2h、1.5h、30min。未写耗时的工作默认 1 小时。")
                Text("未写年份时使用 \(String(referenceYear)) 年，日期按 \(timeZone.identifier) 日末保存。工作也可设置截止日期。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if case .success(let draft) = parsed {
                Section("识别预览：\(draft.nodes.count) 个节点 · \(draft.workCount) 项工作") {
                    Label(draft.name, systemImage: "folder").accessibilityIdentifier("editor.markdown.preview.project")
                    if let deadline = draft.deadline { deadlineLabel(deadline) }
                    ForEach(draft.nodes, id: \.line) { node in
                        Label(node.name, systemImage: "square.stack").accessibilityIdentifier("editor.markdown.preview.node.\(node.line)")
                        ForEach(node.works, id: \.line) { work in
                            VStack(alignment: .leading, spacing: 4) {
                                Label(work.name, systemImage: "circle")
                                Text("预估：\(minutesLabel(work.estimatedMinutes))").font(.caption).foregroundStyle(.secondary)
                                if let deadline = work.deadline { deadlineLabel(deadline) }
                            }.padding(.leading, 24).accessibilityIdentifier("editor.markdown.preview.work.\(work.line)")
                        }
                    }
                }
            }
        }
    }
    private func deadlineLabel(_ date: Date) -> some View {
        Text("截止：\(ProjectUI.datePart(date, zone: timeZone.identifier)) 日末").font(.caption).foregroundStyle(.secondary)
    }
    private func save() async -> Bool {
        guard case .success(let draft) = parsed else { return false }
        var projectID: String?
        let saved = await model.mutate { workspace in projectID = try workspace.addMarkdownProject(draft, now: Date()) }
        if saved, let projectID { onCreated(projectID) }
        return saved
    }
}

struct CubicNodeEditor: View {
    let projectID: String
    let node: Node?
    @Environment(AppModel.self) private var model
    @State private var name: String
    @State private var required: Bool
    @State private var blockers: Set<String>
    init(projectID: String, node: Node? = nil) {
        self.projectID = projectID; self.node = node
        _name = State(initialValue: node?.name ?? "")
        _required = State(initialValue: node?.required ?? true)
        _blockers = State(initialValue: Set(node?.blockerIDs ?? []))
    }
    var body: some View {
        ProjectEditorContainer(title: node == nil ? "创建节点" : "编辑节点", identifier: "editor.node", validation: ProjectUI.trim(name).isEmpty ? "请输入节点名称。" : nil, save: save) {
                Section("成果与范围") {
                    TextField("节点名称", text: $name, axis: .vertical).frame(minHeight: 44).accessibilityIdentifier("editor.node.name")
                    Toggle("交付时必须完成", isOn: $required).frame(minHeight: 44).accessibilityIdentifier("editor.node.required")
                    Text("验收方式：默认（完成自身）。没有添加验收条件时，节点在全部必需工作完成后即通过；添加条件后需逐条人工通过，可在节点详情添加。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("整个节点需要等待") {
                    ForEach(model.workspace.blockers, id: \.id) { blocker in
                        ProjectSetToggle(title: blocker.name, id: blocker.id, selection: $blockers, identifier: "editor.node.blocker.\(blocker.id)")
                    }
                    Text("这里选择的等待影响整个节点。只影响一项工作时，请到工作详情添加前置条件。").font(.caption).foregroundStyle(.secondary)
                }
        }
        .onChange(of: node.flatMap { old in model.workspace.nodes.first { $0.id == old.id } }) { old, new in
            guard let old, let new else { return }
            if name == old.name { name = new.name }
            if required == old.required { required = new.required }
            if blockers == Set(old.blockerIDs ?? []) { blockers = Set(new.blockerIDs ?? []) }
        }
    }
    private func save() async -> Bool {
        var value = node.flatMap { old in model.workspace.nodes.first { $0.id == old.id } } ?? Node(projectID: projectID, name: ProjectUI.trim(name))
        value.name = ProjectUI.trim(name); value.isRequired = required
        value.blockerIDs = blockers.sorted()
        let savedValue = value
        return await model.mutate { if node == nil { try $0.addNode(savedValue, now: Date()) } else { try $0.updateNode(savedValue, now: Date()) } }
    }
}

struct CubicWorkEditor: View {
    let itemID: String?
    @Environment(AppModel.self) private var model
    @State private var name: String
    @State private var detail: String
    @State private var projectIDs: Set<String>
    @State private var nodeID: String
    @State private var remaining: String
    @State private var energy: String
    @State private var continuous: Bool
    @State private var continuousMinutes: String
    @State private var required: Bool
    @State private var focused: Bool
    @State private var contexts: String
    @State private var hasDeadline: Bool
    @State private var deadline: Date
    @State private var dateOnly: Bool
    @State private var zone: String
    @State private var note = ""
    init(item: WorkItem? = nil, projectID: String? = nil, nodeID: String? = nil) {
        itemID = item?.id
        _name = State(initialValue: item?.name ?? ""); _detail = State(initialValue: item?.description ?? "")
        _projectIDs = State(initialValue: Set(item?.projectIDs ?? projectID.map { [$0] } ?? [])); _nodeID = State(initialValue: item?.nodeID ?? nodeID ?? "")
        _remaining = State(initialValue: item?.remainingMinutes.map(String.init) ?? "60"); _energy = State(initialValue: (item?.energy ?? .normal).rawValue)
        _continuous = State(initialValue: item?.requiresContinuous ?? false); _continuousMinutes = State(initialValue: item?.continuousMinutes.map(String.init) ?? "")
        _required = State(initialValue: item?.required ?? true); _focused = State(initialValue: item?.isFocused ?? false)
        _contexts = State(initialValue: (item?.contextTags ?? []).joined(separator: "、"))
        _hasDeadline = State(initialValue: item?.deadline != nil); _deadline = State(initialValue: item?.deadline ?? Date())
        _dateOnly = State(initialValue: item?.deadlineIsDateOnly ?? true); _zone = State(initialValue: item?.deadlineTimeZoneID ?? TimeZone.current.identifier)
    }
    private var current: WorkItem? { itemID.flatMap(model.item) }
    private var selectedNode: Node? { model.workspace.nodes.first { $0.id == nodeID } }
    private var validation: String? {
        if ProjectUI.trim(name).isEmpty { return "请输入工作名称。" }
        if itemID != nil && current == nil { return "这项工作已不可用。" }
        if let error = ProjectUI.minutesValidation(remaining, title: "耗时") { return error }
        return ProjectUI.minutesValidation(continuousMinutes, title: "连续时长")
    }
    var body: some View {
        ProjectEditorContainer(title: itemID == nil ? "新建工作" : "编辑工作", identifier: "editor.item", validation: validation, save: save) {
                Section("工作内容") {
                    TextField("标题", text: $name, axis: .vertical).frame(minHeight: 44).accessibilityIdentifier("editor.item.name")
                    TextField("工作说明", text: $detail, axis: .vertical).frame(minHeight: 44).accessibilityIdentifier("editor.item.description")
                    TextField("标签，例如办公室、电脑", text: $contexts, axis: .vertical).frame(minHeight: 44).accessibilityIdentifier("editor.item.contexts")
                    Toggle("我关注的", isOn: $focused).frame(minHeight: 44).accessibilityIdentifier("editor.item.focused")
                    Toggle("交付时必须完成", isOn: $required).frame(minHeight: 44).accessibilityIdentifier("editor.item.required")
                }
                Section("归属与共享") {
                    // 归档节点/项目不再作为新的归属候选；已关联的归档项目仍保留可见（标注已归档）以便取消关联。
                    let archivedProjectIDs = Set(model.workspace.projects.filter(\.archived).map(\.id))
                    let nodeOptions = model.workspace.nodes.filter { (!$0.archived && !archivedProjectIDs.contains($0.projectID)) || $0.id == nodeID }
                    let projectOptions = model.workspace.projects.filter { !$0.archived || projectIDs.contains($0.id) }
                    Picker("所属节点", selection: $nodeID) {
                        Text("不属于节点").tag("")
                        ForEach(nodeOptions, id: \.id) { node in Text(node.archived ? "\(node.name)（已归档）" : node.name).tag(node.id) }
                    }.frame(minHeight: 44).accessibilityIdentifier("editor.item.node")
                        .onChange(of: nodeID) { oldID, newID in
                            if !newID.isEmpty && newID != oldID { required = true }
                        }
                    if !nodeID.isEmpty {
                        Text("加入节点时默认必须完成。只是可选工作时，可以关闭上方的“交付时必须完成”。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(projectOptions, id: \.id) { project in
                        if project.id == selectedNode?.projectID { ProjectInfoLine(title: "节点所属项目", value: project.archived ? "\(project.name)（已归档）" : project.name) }
                        else { ProjectSetToggle(title: project.archived ? "\(project.name)（已归档）" : project.name, id: project.id, selection: $projectIDs, identifier: "editor.item.project.\(project.id)") }
                    }
                    Text("可关联多个项目，共用同一份进度和投入。移除关联不会删除原工作。").font(.caption).foregroundStyle(.secondary)
                    if let current { ImpactItemsView(source: .item(current.id), itemIDs: []) }
                }
                Section("耗时与工作要求") {
                    if current?.status == .completed { Text("工作已完成，剩余时间为 0。需要重做时，请到详情开始返工。") }
                    else { ProjectMinutesField(title: "耗时（分钟）", text: $remaining, identifier: "editor.item.remaining") }
                    Picker("精力要求", selection: $energy) {
                        Text("低负荷").tag(Energy.low.rawValue); Text("普通").tag(Energy.normal.rawValue); Text("高专注").tag(Energy.high.rawValue)
                    }.frame(minHeight: 44).accessibilityIdentifier("editor.item.energy")
                    Toggle("需要一段不中断的时间", isOn: $continuous).frame(minHeight: 44).accessibilityIdentifier("editor.item.continuous")
                    if continuous {
                        ProjectMinutesField(title: "至少连续多少分钟（可留空）", text: $continuousMinutes, identifier: "editor.item.continuousMinutes")
                        Text("排期会寻找足够长的连续空档。留空时按当前剩余时间计算；例如需要连续 60 分钟，两个 30 分钟空档不能替代。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("仅影响排期和试算，不会限制实际投入记录。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("修改说明（可选）", text: $note, axis: .vertical).frame(minHeight: 44).accessibilityIdentifier("editor.item.note")
                }
                Section("这项工作的截止") {
                    ProjectDeadlineFields(enabled: $hasDeadline, date: $deadline, dateOnly: $dateOnly, zone: $zone, identifier: "editor.item.deadline")
                }
        }
        .onChange(of: current) { old, new in
            guard let old, let new else { return }
            if name == old.name { name = new.name }
            if detail == (old.description ?? "") { detail = new.description ?? "" }
            if remaining == (old.remainingMinutes.map(String.init) ?? "60") || new.status == .completed { remaining = new.remainingMinutes.map(String.init) ?? "60" }
            if required == old.required { required = new.required }
            if energy == old.energy.rawValue { energy = new.energy.rawValue }
            if focused == (old.isFocused ?? false) { focused = new.isFocused ?? false }
            if contexts == (old.contextTags ?? []).joined(separator: "、") { contexts = (new.contextTags ?? []).joined(separator: "、") }
            if nodeID == (old.nodeID ?? "") { nodeID = new.nodeID ?? "" }
            if projectIDs == Set(old.projectIDs) { projectIDs = Set(new.projectIDs) }
            if continuous == old.requiresContinuous { continuous = new.requiresContinuous }
            if continuousMinutes == (old.continuousMinutes.map(String.init) ?? "") { continuousMinutes = new.continuousMinutes.map(String.init) ?? "" }
            if hasDeadline == (old.deadline != nil), deadline == (old.deadline ?? deadline),
               dateOnly == (old.deadlineIsDateOnly ?? true), zone == (old.deadlineTimeZoneID ?? TimeZone.current.identifier) {
                hasDeadline = new.deadline != nil; deadline = new.deadline ?? deadline
                dateOnly = new.deadlineIsDateOnly ?? true; zone = new.deadlineTimeZoneID ?? TimeZone.current.identifier
            }
        }
    }
    private func save() async -> Bool {
        var value = current ?? WorkItem(name: ProjectUI.trim(name))
        value.name = ProjectUI.trim(name); value.description = detail; value.nodeID = nodeID.isEmpty ? nil : nodeID
        var projects = projectIDs; if let selectedNode { projects.insert(selectedNode.projectID) }; value.projectIDs = projects.sorted()
        value.isRequired = required; value.isFocused = focused
        value.contextTags = contexts.components(separatedBy: CharacterSet(charactersIn: ",，、\n")).map(ProjectUI.trim).filter { !$0.isEmpty }
        value.energy = Energy(rawValue: energy) ?? .normal; value.requiresContinuous = continuous; value.continuousMinutes = continuous ? ProjectUI.optionalMinutes(continuousMinutes) : nil
        value.deadlineTimeZoneID = zone; value.deadlineIsDateOnly = dateOnly
        do { value.deadline = hasDeadline ? try ProjectUI.deadline(deadline, zone: zone, dateOnly: dateOnly) : nil }
        catch { model.errorMessage = error.localizedDescription; return false }
        let minutes = current?.status == .completed ? 0 : ProjectUI.optionalMinutes(remaining) ?? 60
        if itemID == nil { value.remainingMinutes = minutes; value.initialMinutes = minutes }
        let savedValue = value; let id = itemID; let memo = note
        return await model.mutate { workspace in
            if let id {
                try workspace.updateItem(savedValue, now: Date(), note: memo)
                if workspace.items.first(where: { $0.id == id })?.remainingMinutes != minutes { try workspace.updateRemaining(itemID: id, minutes: minutes, now: Date(), reason: .revision, note: memo) }
            } else { try workspace.addItem(savedValue, now: Date()) }
        }
    }
}

struct CubicBlockerEditor: View {
    let blocker: Blocker?
    @Environment(AppModel.self) private var model
    @State private var name: String
    @State private var condition: String
    @State private var duration: String
    @State private var contact: String
    @State private var followUpID: String
    @State private var hasExpected: Bool
    @State private var expected: Date
    @State private var hasFollowUp: Bool
    @State private var followUp: Date
    init(blocker: Blocker? = nil) {
        self.blocker = blocker; _name = State(initialValue: blocker?.name ?? ""); _condition = State(initialValue: blocker?.resolutionCondition ?? "")
        _duration = State(initialValue: blocker?.expectedDurationMinutes.map(String.init) ?? ""); _contact = State(initialValue: blocker?.contactNote ?? "")
        _followUpID = State(initialValue: blocker?.followUpItemID ?? ""); _hasExpected = State(initialValue: blocker?.expectedResolution != nil)
        _expected = State(initialValue: blocker?.expectedResolution ?? Date()); _hasFollowUp = State(initialValue: blocker?.followUpAt != nil)
        _followUp = State(initialValue: blocker?.followUpAt ?? Date())
    }
    private var validation: String? {
        if ProjectUI.trim(name).isEmpty || ProjectUI.trim(condition).isEmpty { return "请填写等待名称，以及什么情况下等待可以结束。" }
        return ProjectUI.minutesValidation(duration, title: "预计自然经过时长")
    }
    var body: some View {
        ProjectEditorContainer(title: blocker == nil ? "新建外部等待" : "编辑等待", identifier: "editor.blocker", validation: validation, save: save) {
            Section("条件") {
                TextField("等待名称", text: $name, axis: .vertical).frame(minHeight: 44).accessibilityIdentifier("editor.blocker.name")
                TextField("等待结束的条件", text: $condition, axis: .vertical).frame(minHeight: 44).accessibilityIdentifier("editor.blocker.condition")
                TextField("联系人 / 备注", text: $contact, axis: .vertical).frame(minHeight: 44).accessibilityIdentifier("editor.blocker.contact")
                Text("保存后，到详情确认等待何时开始。").font(.caption).foregroundStyle(.secondary)
            }
            Section("预计要等多久") {
                ProjectMinutesField(title: "预计等待分钟数（可留空）", text: $duration, identifier: "editor.blocker.duration")
                Toggle("指定预计结束时间", isOn: $hasExpected).frame(minHeight: 44).accessibilityIdentifier("editor.blocker.hasExpected")
                if hasExpected { ProjectDateField(title: "预计结束", date: $expected, identifier: "editor.blocker.expected") }
                Text("优先使用指定的结束时间，否则按开始时间加等待时长推算。等待不占用工作时间，到期后请确认是否结束。").font(.caption).foregroundStyle(.secondary)
            }
            Section("什么时候跟进") {
                Toggle("设置跟进日期", isOn: $hasFollowUp).frame(minHeight: 44).accessibilityIdentifier("editor.blocker.hasFollowUp")
                if hasFollowUp { ProjectDateField(title: "下次跟进", date: $followUp, identifier: "editor.blocker.followUp") }
                Picker("关联跟进工作", selection: $followUpID) {
                    Text("尚未关联").tag("")
                    ForEach(model.workspace.items, id: \.id) { Text($0.name).tag($0.id) }
                }.frame(minHeight: 44).accessibilityIdentifier("editor.blocker.followUpItem")
                Text("发邮件、催办等需要花时间的事情，可以单独建工作。跟进日期与等待结束时间分别设置。").font(.caption).foregroundStyle(.secondary)
            }
            if let blocker { Section("受影响的工作") { ImpactItemsView(source: .blocker(blocker.id), itemIDs: []) } }
        }
    }
    private func save() async -> Bool {
        var value = blocker ?? Blocker(name: ProjectUI.trim(name))
        value.name = ProjectUI.trim(name); value.resolutionCondition = condition; value.expectedDurationMinutes = ProjectUI.optionalMinutes(duration)
        value.expectedResolution = hasExpected ? expected : nil; value.followUpAt = hasFollowUp ? followUp : nil
        value.contactNote = contact; value.followUpItemID = followUpID.isEmpty ? nil : followUpID
        let savedValue = value
        return await model.mutate { if blocker == nil { try $0.addBlocker(savedValue, now: Date()) } else { try $0.updateBlocker(savedValue, now: Date()) } }
    }
}

struct CubicDependencyEditor: View {
    let itemID: String
    let dependency: Dependency?
    @Environment(AppModel.self) private var model
    @State private var sourceID: String
    @State private var query = ""
    @State private var note = ""
    init(itemID: String, dependency: Dependency? = nil) {
        self.itemID = itemID; self.dependency = dependency
        if case .item(let id) = dependency?.source { _sourceID = State(initialValue: id) }
        else { _sourceID = State(initialValue: "") }
    }
    private var source: DependencySource? { sourceID.isEmpty ? nil : .item(sourceID) }
    private var keptItemID: String? { if case .item(let id) = dependency?.source { return id }; return nil }
    private var contextProjectID: String {
        guard let item = model.item(itemID) else { return "" }
        if let nodeID = item.nodeID, let projectID = model.workspace.nodes.first(where: { $0.id == nodeID })?.projectID { return projectID }
        return item.projectIDs.first ?? ""
    }
    private var offers: [PredecessorWorkOffer] {
        let keeping = keptItemID.map { Set([$0]) } ?? []
        let all = model.workspace.predecessorWorkOffers(for: itemID, inProject: contextProjectID, keeping: keeping)
        let text = ProjectUI.trim(query)
        guard !text.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(text) || $0.affiliation.localizedCaseInsensitiveContains(text) }
    }
    var body: some View {
        ProjectEditorContainer(title: dependency == nil ? "添加前置条件" : "修改前置关系", identifier: "editor.dependency", validation: source == nil ? "请选择需要先完成的工作。" : nil, save: save) {
            Section("受影响的工作") {
                ProjectInfoLine(title: "需要此前置的工作", value: model.item(itemID)?.name ?? "待办不可用")
                ImpactItemsView(source: .item(itemID), itemIDs: [itemID])
                Text("所有前置都满足后，这项工作才能开始。其他不相关的工作可以继续。").font(.caption).foregroundStyle(.secondary)
            }
            Section("开始前需要完成的工作") {
                if let dependency, keptItemID == nil {
                    Text("当前前置是\(retainedLabel(dependency.source))。新增候选只能选择工作；选择一项工作会替换它，也可以返回后移除。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextField("搜索工作、节点或项目", text: $query).frame(minHeight: 44).accessibilityIdentifier("editor.dependency.search")
                if offers.isEmpty { Text("没有可选择的工作").foregroundStyle(.secondary) }
                ForEach(offers) { offer in
                    ProjectOptionChoice(title: offer.name, subtitle: offer.cycleReason ?? offer.affiliation, value: offer.itemID, selection: $sourceID, identifier: "editor.dependency.item.\(offer.itemID)", isEnabled: offer.cycleReason == nil)
                }
                Text("候选按本节点、本项目、其他项目排列。会互相等待的工作不能选择。").font(.caption).foregroundStyle(.secondary)
                TextField("关系变化说明（可选）", text: $note, axis: .vertical).frame(minHeight: 44).accessibilityIdentifier("editor.dependency.note")
            }
            if let source { Section("关联方向与影响") { Text("\(ProjectUI.sourceName(source, in: model.workspace)) → \(model.item(itemID)?.name ?? itemID)"); ImpactItemsView(source: source, itemIDs: [itemID]) } }
        }
    }
    private func retainedLabel(_ source: DependencySource) -> String {
        switch source { case .node: "节点「\(ProjectUI.sourceName(source, in: model.workspace))」"; case .blocker: "等待「\(ProjectUI.sourceName(source, in: model.workspace))」"; case .item: "工作" }
    }
    private func save() async -> Bool {
        guard let source else { return false }
        var value = dependency ?? Dependency(source: source, targetItemID: itemID); value.source = source
        let savedValue = value; let memo = note
        return await model.mutate { if dependency == nil { try $0.addDependency(savedValue, now: Date()) } else { try $0.updateDependency(savedValue, now: Date(), note: memo) } }
    }
}

struct CubicAcceptanceEditor: View {
    let subject: WorkReference
    let acceptance: Acceptance?
    @Environment(AppModel.self) private var model
    @State private var name: String
    @State private var blockerIDs: Set<String>
    init(subject: WorkReference, acceptance: Acceptance? = nil) {
        self.subject = subject; self.acceptance = acceptance
        _name = State(initialValue: acceptance?.name ?? "")
        _blockerIDs = State(initialValue: Set(acceptance?.candidateBlockerIDs ?? []))
    }
    var body: some View {
        ProjectEditorContainer(title: acceptance == nil ? "添加验收条件" : "编辑验收条件", identifier: "editor.acceptance", validation: ProjectUI.trim(name).isEmpty ? "请填写可以判断是否通过的验收条件。" : nil, save: save) {
            Section("验收要求") {
                TextField("验收条件", text: $name, axis: .vertical).frame(minHeight: 44).accessibilityIdentifier("editor.acceptance.name")
                Text("验收条件一旦添加就是必需的；保存后需逐条人工确认通过才能交付。需要耗时测试或审批时，请另建工作或等待。").font(.caption).foregroundStyle(.secondary)
            }
            Section("返工可能涉及的等待") {
                ForEach(model.workspace.blockers, id: \.id) { blocker in ProjectSetToggle(title: blocker.name, id: blocker.id, selection: $blockerIDs, identifier: "editor.acceptance.blocker.\(blocker.id)") }
            }
        }
    }
    private func save() async -> Bool {
        var value = acceptance ?? Acceptance(subject: subject, name: ProjectUI.trim(name))
        value.name = ProjectUI.trim(name); value.candidateBlockerIDs = blockerIDs.sorted()
        let savedValue = value
        return await model.mutate { if acceptance == nil { try $0.addAcceptance(savedValue, now: Date()) } else { try $0.updateAcceptance(savedValue, now: Date()) } }
    }
}

struct CubicWorkRecordEditor: View {
    let itemID: String
    let transition: WorkFeedbackTransition
    let historicalOnly: Bool
    @State private var submitting = false
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var actual = ""
    @State private var remaining = ""
    @State private var update = "unchanged"
    @State private var exact = false
    @State private var hasDay = false
    @State private var historical = false
    @State private var historicalRound = 1
    @State private var day = Date()
    @State private var start = Date().addingTimeInterval(-1800)
    @State private var end = Date()
    @State private var note = ""
    init(item: WorkItem, transition: WorkFeedbackTransition = .none, historicalOnly: Bool = false) {
        itemID = item.id; self.transition = transition; self.historicalOnly = historicalOnly
        _historicalRound = State(initialValue: item.currentRound)
        _remaining = State(initialValue: item.remainingMinutes.map(String.init) ?? "")
        _historical = State(initialValue: historicalOnly); _hasDay = State(initialValue: historicalOnly)
    }
    private var validation: String? {
        if let error = ProjectUI.minutesValidation(actual, title: "投入") { return error }
        if historical, (ProjectUI.optionalMinutes(actual) ?? 0) <= 0 { return "补录时请填写大于 0 的实际投入分钟数。" }
        if !historical && update == "minutes" {
            if ProjectUI.optionalMinutes(remaining) == nil { return "请填写剩余分钟数，或选择待估计。" }
            if let error = ProjectUI.minutesValidation(remaining, title: "剩余") { return error }
        }
        if !ProjectUI.trim(actual).isEmpty && exact && (end < start || end > Date()) { return "结束时间不能早于开始，也不能晚于现在。" }
        return nil
    }
    private var workCalendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = model.preferences.workTimeZone
        return value
    }
    private var remainingUpdate: RemainingUpdate {
        switch update { case "unknown": .unknown; case "minutes": .minutes(ProjectUI.optionalMinutes(remaining) ?? 0); default: .unchanged }
    }
    var body: some View {
        ProjectEditorContainer(title: historicalOnly ? "补录历史投入" : "记录工作进展", identifier: "editor.record", validation: validation, save: save, operationInFlight: submitting) {
            if transition != .none {
                Section("先记录进展（可跳过）") {
                    Text("保存后记录填写的进展，再完成或切换工作。也可以跳过反馈；取消会退出这次操作。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button {
                        guard !submitting, !model.saving, !model.loading else { return }
                        submitting = true
                        let version = model.sourceVersion
                        Task {
                            let saved = await model.mutate { try transition.apply(in: &$0, now: Date(), dataVersion: version) }
                            submitting = false
                            if saved { dismiss() }
                        }
                    } label: { Label(submitting ? "保存中…" : transition.skipLabel, systemImage: "arrow.right").frame(minHeight: 44) }
                    .disabled(submitting || model.saving || model.loading).accessibilityIdentifier("editor.record.skip")
                }
            }
            Section("投入与剩余时间") {
                ProjectMinutesField(title: historical ? "实际投入分钟数（必填）" : "实际投入分钟数（可留空）", text: $actual, identifier: "editor.record.actual", placeholder: historical ? "填写大于 0 的分钟数" : "可留空")
                Picker("更新剩余时间", selection: $update) { Text("暂不更新").tag("unchanged"); Text("按默认 1 小时估计").tag("unknown"); Text("填写新的估计").tag("minutes") }.frame(minHeight: 44).disabled(historical).accessibilityIdentifier("editor.record.remainingMode")
                if !historical && update == "minutes" { ProjectMinutesField(title: "耗时（分钟）", text: $remaining, identifier: "editor.record.remaining") }
                Text("投入和剩余分别记录。记录投入后，请按实际进展更新剩余估计。").font(.caption).foregroundStyle(.secondary)
            }
            if ProjectUI.optionalMinutes(actual) != nil {
                Section("这次工作发生在何时") {
                    Toggle("补录以前的投入", isOn: $historical)
                        .frame(minHeight: 44).accessibilityIdentifier("editor.record.historical").disabled(transition != .none || historicalOnly)
                        .onChange(of: historical) { _, selected in if selected { exact = false; hasDay = true; update = "unchanged" } }
                    if historical {
                        Picker("补录到哪一轮", selection: $historicalRound) {
                            ForEach(1...(model.item(itemID)?.currentRound ?? 1), id: \.self) { round in Text("第 \(round) 轮").tag(round) }
                        }.frame(minHeight: 44).accessibilityIdentifier("editor.record.round")
                        Text("补录只增加所选轮次的投入记录，不改变当前进度。请填写该轮次实际发生的日期。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("填写准确起止时间", isOn: $exact).frame(minHeight: 44).accessibilityIdentifier("editor.record.exact").disabled(historical)
                    if exact {
                        ProjectDateField(title: "开始", date: $start, identifier: "editor.record.start")
                        ProjectDateField(title: "结束", date: $end, identifier: "editor.record.end")
                    } else {
                        Toggle("指定发生日期", isOn: $hasDay).frame(minHeight: 44).accessibilityIdentifier("editor.record.hasDay").disabled(historical)
                        if hasDay {
                            DatePicker("发生日期", selection: $day, in: ...Date(), displayedComponents: .date)
                                .environment(\.calendar, workCalendar).environment(\.timeZone, workCalendar.timeZone)
                                .frame(minHeight: 44).accessibilityIdentifier("editor.record.day")
                        }
                        Text("发生日期按工作时区 \(workCalendar.timeZone.identifier) 解释。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("不指定日期时记在今天。没有起止时间的记录只统计时长。").font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("说明（可选）", text: $note, axis: .vertical).frame(minHeight: 44).accessibilityIdentifier("editor.record.note")
                }
            }
        }
    }
    private func save() async -> Bool {
        let minutes = ProjectUI.optionalMinutes(actual); let remainingValue = remainingUpdate
        let began = start, ended = end, occurred = hasDay ? day : Date(), memo = note, exactValue = exact
        let historicalValue = historical, selectedRound = historicalRound, zone = model.preferences.workTimeZone
        let version = model.sourceVersion
        return await model.mutate { workspace in
            if let minutes, historicalValue {
                guard let item = workspace.items.first(where: { $0.id == itemID }) else { throw CoreError.missing(itemID) }
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
                let dayStart = calendar.startOfDay(for: occurred)
                let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
                let rounds = (workspace.workRounds ?? []).filter { $0.itemID == itemID }
                let selected = rounds.first { $0.round == selectedRound }
                let began = selected?.startedAt ?? (selectedRound == 1 && item.currentRound == 1 ? item.started : nil)
                let ended = selected?.completedAt ?? (selectedRound == item.currentRound ? item.completedAt : nil)
                let next = rounds.filter { $0.round > selectedRound }.map(\.openedAt).min()
                let recorded = Date()
                let lower = max(dayStart, began ?? (selectedRound > 1 ? selected?.openedAt : nil) ?? dayStart)
                let upper = min(dayEnd, ended ?? recorded, next ?? recorded, recorded)
                guard lower <= upper, lower < recorded else { throw CoreError.invalid("所选日期不属于这轮已发生的工作，请核对日期与轮次。") }
                // A representative date inside the declared day is not an exact labor block.
                let occurrence = lower.addingTimeInterval(min(1, max(0, upper.timeIntervalSince(lower) / 2)))
                try workspace.recordHistoricalApproximateWork(itemID: itemID, occurredOn: occurrence, round: selectedRound,
                    recordedAt: recorded, actualMinutes: minutes, note: memo)
            } else if let minutes {
                try ProjectUI.requireCurrentDependencies(itemID, in: workspace)
                if exactValue { try workspace.recordWork(itemID: itemID, start: began, end: ended, actualMinutes: minutes, remaining: remainingValue, note: memo) }
                else { try workspace.recordApproximateWork(itemID: itemID, occurredOn: occurred, recordedAt: Date(), actualMinutes: minutes, remaining: remainingValue, note: memo) }
            } else {
                switch remainingValue {
                case .unchanged: break
                case .unknown: try workspace.updateRemaining(itemID: itemID, minutes: nil, now: Date(), reason: .revision, note: memo)
                case .minutes(let value): try workspace.updateRemaining(itemID: itemID, minutes: value, now: Date(), reason: .revision, note: memo)
                }
            }
            try transition.apply(in: &workspace, now: Date(), dataVersion: version)
        }
    }
}

struct CubicReworkEditor: View {
    let itemID: String
    @Environment(AppModel.self) private var model
    @State private var remaining = ""
    @State private var note = ""
    init(item: WorkItem) { itemID = item.id }
    var body: some View {
        ProjectEditorContainer(title: "开始返工", identifier: "editor.rework", validation: ProjectUI.minutesValidation(remaining, title: "返工剩余"), save: save) {
            Section("返工需要多久") {
                ProjectMinutesField(title: "预计返工分钟数（可留空）", text: $remaining, identifier: "editor.rework.remaining")
                TextField("原因（可选）", text: $note, axis: .vertical).frame(minHeight: 44).accessibilityIdentifier("editor.rework.note")
                Text("返工会开启新一轮，原来的进度、投入和验收记录会保留。开始工作时再确认开工。").font(.caption).foregroundStyle(.secondary)
            }
            Section("受影响的工作") { ImpactItemsView(source: .item(itemID), itemIDs: []) }
        }
    }
    private func save() async -> Bool {
        let minutes = ProjectUI.optionalMinutes(remaining), memo = note
        return await model.mutate { try $0.reworkItem(id: itemID, remainingMinutes: minutes, now: Date(), note: memo) }
    }
}

struct ProjectMinutesField: View {
    let title: String
    @Binding var text: String
    let identifier: String
    var placeholder = "可留空"
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            TextField(placeholder, text: $text).cubicNumberKeyboard().frame(minHeight: 44).accessibilityLabel(title).accessibilityIdentifier(identifier)
        }
    }
}
struct ProjectDateField: View {
    let title: String
    @Binding var date: Date
    let identifier: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).fixedSize(horizontal: false, vertical: true)
            DatePicker("日期", selection: $date, displayedComponents: .date).frame(minHeight: 44).accessibilityLabel("\(title)日期").accessibilityIdentifier("\(identifier).date")
            DatePicker("时间", selection: $date, displayedComponents: .hourAndMinute).frame(minHeight: 44).accessibilityLabel("\(title)时刻").accessibilityIdentifier("\(identifier).time")
        }
    }
}
struct ProjectDeadlineFields: View {
    @Binding var enabled: Bool
    @Binding var date: Date
    @Binding var dateOnly: Bool
    @Binding var zone: String
    let identifier: String
    var body: some View {
        Toggle("设置截止时间", isOn: $enabled).frame(minHeight: 44).accessibilityIdentifier("\(identifier).enabled")
        if enabled {
            Toggle("只设置日期，当天结束前完成", isOn: $dateOnly).frame(minHeight: 44).accessibilityIdentifier("\(identifier).dateOnly")
            DatePicker("截止日期", selection: $date, displayedComponents: .date).frame(minHeight: 44).environment(\.timeZone, TimeZone(identifier: zone) ?? .current).accessibilityIdentifier("\(identifier).date")
            if !dateOnly { DatePicker("截止时刻", selection: $date, displayedComponents: .hourAndMinute).frame(minHeight: 44).environment(\.timeZone, TimeZone(identifier: zone) ?? .current).accessibilityIdentifier("\(identifier).time") }
            NavigationLink { ProjectTimeZonePicker(selection: $zone, identifier: identifier) } label: { ProjectInfoLine(title: "截止时区", value: zone).frame(minHeight: 44) }.accessibilityIdentifier("\(identifier).zone")
            Text("截止按所选时区保存。每天可工作到几点，请在工作时段中设置。").font(.caption).foregroundStyle(.secondary)
        }
    }
}
struct ProjectTimeZonePicker: View {
    @Binding var selection: String
    let identifier: String
    @State private var query = ""
    var body: some View {
        List {
            TextField("搜索时区", text: $query).frame(minHeight: 44).accessibilityIdentifier("\(identifier).zone.search")
            ForEach(TimeZone.knownTimeZoneIdentifiers.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }, id: \.self) { zone in
                ProjectOptionChoice(title: zone, value: zone, selection: $selection, identifier: "\(identifier).zone.\(zone)")
            }
        }.cubicNavigationTitle("截止时区")
    }
}
struct ProjectOptionChoice: View {
    let title: String
    var subtitle: String? = nil
    let value: String
    @Binding var selection: String
    let identifier: String
    var isEnabled: Bool = true
    var body: some View {
        Button { selection = value } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selection == value ? "checkmark.circle.fill" : "circle").accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    ProjectListTitle(text: title)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(isEnabled ? Color.secondary : Color.cubicAmber) }
                }.foregroundStyle(isEnabled ? Color.primary : Color.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!isEnabled).accessibilityAddTraits(selection == value ? [.isSelected] : []).accessibilityIdentifier(identifier)
    }
}
struct ProjectSetToggle: View {
    let title: String
    let id: String
    @Binding var selection: Set<String>
    let identifier: String
    var body: some View {
        Toggle(isOn: Binding(get: { selection.contains(id) }, set: { if $0 { selection.insert(id) } else { selection.remove(id) } })) {
            Text(title).fixedSize(horizontal: false, vertical: true)
        }.frame(minHeight: 44).accessibilityIdentifier(identifier)
    }
}
extension ProjectUI {
    static func minutesValidation(_ text: String, title: String) -> String? {
        let value = trim(text); guard !value.isEmpty else { return nil }
        guard value.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(value), number >= 0 else { return "\(title)请输入非负整数分钟。" }
        return nil
    }
    static func optionalMinutes(_ text: String) -> Int? { Int(trim(text)) }
    static func parseMinutes(_ text: String, title: String) throws -> Int? {
        if let message = minutesValidation(text, title: title) { throw CoreError.invalid(message) }; return optionalMinutes(text)
    }
    static func deadline(_ date: Date, zone: String, dateOnly: Bool) throws -> Date {
        guard TimeZone(identifier: zone) != nil else { throw CoreError.invalid("请选择有效截止时区。") }
        return dateOnly ? try Workspace.dateOnlyDeadline(on: date, timeZoneID: zone) : date
    }
}

struct InboxClarificationEditor: View {
    let item: WorkItem
    @Environment(AppModel.self) private var model
    @State private var kind = "action"
    @State private var name: String
    @State private var detail = ""
    init(item: WorkItem) { self.item = item; _name = State(initialValue: item.name) }
    var body: some View {
        ProjectEditorContainer(title: "整理事项", identifier: "inbox.clarify", validation: ProjectUI.trim(name).isEmpty ? "请输入标题。" : kind == "wait" && ProjectUI.trim(detail).isEmpty ? "请填写等待结束的条件。" : nil, save: save) {
            Section("这条事项是什么") {
                Picker("整理为", selection: $kind) {
                    Text("独立工作").tag("action"); Text("新项目").tag("project"); Text("外部等待").tag("wait")
                }.frame(minHeight: 44).accessibilityIdentifier("inbox.clarify.kind")
                TextField(kind == "project" ? "新项目标题" : kind == "wait" ? "等待名称" : "工作名称", text: $name, axis: .vertical).frame(minHeight: 44).accessibilityIdentifier("inbox.clarify.name")
                TextField(kind == "wait" ? "等待结束的条件" : "说明（可选）", text: $detail, axis: .vertical).frame(minHeight: 44).accessibilityIdentifier("inbox.clarify.detail")
                if kind == "project" { Text("这条事项将作为新项目的第一项工作。节点和截止等信息可以稍后补充。") }
                if kind == "wait" { Text("原事项会取消并归档，历史保留。创建等待后，到详情确认开始时间，并关联受影响的工作。") }
                Text("也可以到工作详情关联已有项目或节点，或留到以后再做。").font(.caption).foregroundStyle(.secondary)
            }
            if kind == "wait" { Section("原事项影响的工作") { ImpactItemsView(source: .item(item.id), itemIDs: []) } }
        }
    }
    private func save() async -> Bool {
        let type = kind, title = ProjectUI.trim(name), memo = detail
        return await model.mutate { workspace in
            guard var value = workspace.items.first(where: { $0.id == item.id }) else { throw CoreError.missing(item.id) }
            if type == "wait" {
                let blocker = Blocker(name: title, resolutionCondition: memo)
                try workspace.addBlocker(blocker, now: Date())
                try workspace.setItemDisposition(id: item.id, disposition: .cancelled, now: Date(), note: "澄清为外部条件：\(blocker.id)")
                try workspace.setArchived(.item(item.id), archived: true, now: Date())
                workspace.history.append(HistoryEvent(date: Date(), kind: .scopeChanged, objectID: item.id, note: "由收集条目澄清为等待，尚未实际发起", relatedIDs: [blocker.id]))
            } else {
                value.description = memo
                if type == "project" {
                    let project = Project(name: title, importance: 0, description: memo, status: .planning, planningCompleteness: .incomplete)
                    try workspace.addProject(project, now: Date())
                    value.projectIDs = Array(Set(value.projectIDs + [project.id])).sorted()
                } else { value.name = title }
                try workspace.updateItem(value, now: Date(), note: "人工澄清收件箱")
            }
        }
    }
}
