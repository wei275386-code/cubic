import SwiftUI
import CubicCore

struct WorkDetailView: View {
    let itemID: String
    @Environment(AppModel.self) private var model
    @State private var sheet: ProjectUISheet?
    @State private var complete = false
    @State private var disposition: String?
    @Environment(\.dismiss) private var dismiss
    @State private var delete = false
    @State private var copy = false
    @State private var copyProject = ""
    var body: some View {
        List {
            if let item = model.item(itemID) {
                Section("工作概况") {
                    ProjectWorkRow(item: item, showsFullName: true)
                    Text(item.description ?? "尚未填写工作说明").fixedSize(horizontal: false, vertical: true)
                    Text("工作第 \(item.currentRound) 轮")
                    if let date = item.started { ProjectInfoLine(title: "首次开始", value: ProjectUI.dateLabel(date)) }
                    if let date = item.completedAt { ProjectInfoLine(title: "本轮完成", value: ProjectUI.dateLabel(date)) }
                    if item.description == nil && item.projectIDs.isEmpty && item.nodeID == nil {
                        Button { sheet = .clarify(item) } label: { Label("整理这条事项", systemImage: "tray.and.arrow.up").frame(minHeight: 44) }.accessibilityIdentifier("work.clarify")
                    }
                    Button { sheet = .editItem(item) } label: { Label("编辑工作", systemImage: "pencil").frame(minHeight: 44) }.accessibilityIdentifier("work.edit")
                }
                Section("开始与记录") {
                    if model.workspace.currentNextAction?.itemID == itemID { Label("当前下一步", systemImage: "arrow.right.circle") }
                    if item.status != .completed && item.effectiveDisposition == .active {
                    ProjectMutationButton("设为下一步", symbol: "arrow.right.circle", identifier: "work.choose") {
                        try $0.chooseNextAction(itemID: itemID, now: Date(), displayedItemIDs: [itemID], dataVersion: model.sourceVersion, impactWasVerified: false, note: "详情直接选择，未核验投入影响")
                    }
                    }
                    if item.status != .completed && item.effectiveDisposition == .active {
                        Button { sheet = .startFeedback(item) } label: {
                            Label(item.status == .pending ? "现在开始" : "继续这项工作", systemImage: "play").frame(minHeight: 44)
                        }.accessibilityIdentifier(item.status == .pending ? "work.start" : "work.resume")
                        if item.status == .inProgress {
                            Button { sheet = .record(item) } label: { Label("暂停并记录进展", systemImage: "pause.circle").frame(minHeight: 44) }.accessibilityIdentifier("work.pauseFeedback")
                        }
                        Button { sheet = .trial(itemID) } label: { Label("试算投入时间", systemImage: "cube.transparent").frame(minHeight: 44) }.accessibilityIdentifier("work.trial")
                        Button { sheet = .record(item) } label: { Label("记录投入与剩余", systemImage: "clock.badge.checkmark").frame(minHeight: 44) }.accessibilityIdentifier("work.record")
                        Button { complete = true } label: { Label("确认完成", systemImage: "checkmark.circle").frame(minHeight: 44) }.accessibilityIdentifier("work.complete")
                    }
                    if item.status == .completed {
                        Button { sheet = .historicalRecord(item) } label: {
                            Label("补录以前已发生的投入", systemImage: "clock.arrow.circlepath").frame(minHeight: 44)
                        }.accessibilityIdentifier("work.recordHistorical")
                    }
                    Button { sheet = .rework(item) } label: { Label("开始返工", systemImage: "arrow.uturn.backward").frame(minHeight: 44) }.accessibilityIdentifier("work.rework")
                    if !ProjectUI.predecessorsSatisfied(itemID, in: model.workspace) { Text("前置条件尚未满足，暂时不能开始新工作。可以先检查关系，或复核已有成果是否仍可用。").font(.caption).foregroundStyle(.secondary) }
                }
                if item.needsReview { WorkReviewSection(item: item) }
                Section("开始前需要完成") {
                    ForEach(model.workspace.dependencies.filter { $0.isActive && $0.targetItemID == itemID }, id: \.id) { DependencyRelationshipRow(dependency: $0) }
                    Button { sheet = .dependency(itemID) } label: { Label("添加前置条件", systemImage: "link").frame(minHeight: 44) }.accessibilityIdentifier("work.addDependency")
                    DependencyPathsView(itemID: itemID)
                    NavigationLink { WaitingView() } label: { Label("新建外部等待", systemImage: "hourglass").frame(minHeight: 44) }.accessibilityIdentifier("work.waiting")
                }
                Section("哪些工作会受影响") { ImpactItemsView(source: .item(itemID), itemIDs: []) }
                ProjectAcceptanceSection(subject: .item(itemID)) { sheet = .acceptance(.item(itemID)) }
                Section("归属与整理") {
                    ForEach(model.workspace.projects.filter { item.projectIDs.contains($0.id) }, id: \.id) { project in
                        NavigationLink { CubicProjectDetailView(projectID: project.id) } label: { ProjectInfoLine(title: "关联项目", value: project.name).frame(minHeight: 44) }.accessibilityIdentifier("work.project.\(project.id)")
                    }
                    if let nodeID = item.nodeID { WorkReferenceLink(subject: .node(nodeID), label: "归属节点：\(ProjectUI.referenceName(.node(nodeID), in: model.workspace))", identifier: "work.node") }
                    ForEach(model.workspace.workLinks?.filter { $0.source == .item(itemID) && $0.removedAt == nil } ?? [], id: \.id) { link in
                        ProjectInfoLine(title: "共享至", value: "\(model.workspace.projects.first { $0.id == link.projectID }?.name ?? link.projectID)\n\(link.nodeID.flatMap { id in model.workspace.nodes.first { $0.id == id }?.name } ?? "项目直属")")
                    }
                    Button { disposition = item.effectiveDisposition == .deferred ? "active" : "deferred" } label: { Label(item.effectiveDisposition == .deferred ? "恢复工作" : "留到以后再做", systemImage: "tray").frame(minHeight: 44) }.accessibilityIdentifier("work.defer")
                    Button(role: .destructive) { delete = true } label: {
                        Label("删除工作", systemImage: "trash").frame(minHeight: 44)
                    }.disabled(model.saving).accessibilityIdentifier("work.delete")
                    Button { copy = true } label: { Label("创建独立副本", systemImage: "doc.on.doc").frame(minHeight: 44) }.accessibilityIdentifier("work.copy")
                }
                Section("下一步选择记录") {
                    ForEach(model.workspace.choices?.filter { $0.itemID == itemID }.sorted { $0.date > $1.date } ?? [], id: \.id) { choice in
                        NavigationLink { ChoiceDetailView(choice: choice) } label: { ProjectInfoLine(title: choice.impactWasVerified ? "已试算后选择" : "直接选择，未试算影响", value: ProjectUI.dateLabel(choice.date)).frame(minHeight: 44) }.accessibilityIdentifier("work.choice.\(choice.id)")
                    }
                }
                WorkEstimateHistorySection(itemID: itemID)
                WorkEffortHistorySection(itemID: itemID)
                Section("历次工作与返工") {
                    ForEach(model.workspace.workRounds?.filter { $0.itemID == itemID }.sorted { $0.round > $1.round } ?? [], id: \.id) { round in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("第 \(round.round) 轮").font(.headline)
                            if let date = round.startedAt { ProjectInfoLine(title: "当轮开始时间", value: ProjectUI.dateLabel(date)) }
                            if let date = round.completedAt { ProjectInfoLine(title: "当轮完成时间", value: ProjectUI.dateLabel(date)) }
                        }.accessibilityIdentifier("work.round.\(round.id)")
                    }
                    ForEach(model.workspace.reviews?.filter { $0.itemID == itemID } ?? [], id: \.id) { review in
                        ProjectInfoLine(title: review.outcome == .stillValid ? "已确认成果仍可用" : "等待前置恢复", value: "\(ProjectUI.dateLabel(review.date))\n\(review.note)")
                            .accessibilityIdentifier("work.review.history.\(review.id)")
                    }
                }
            } else { Text("这项工作已不可用，请返回列表。") }
        }.cubicNavigationTitle("工作详情").cubicInlineNavigationTitle()
            .sheet(item: $sheet) { ProjectUISheetContent(sheet: $0) }
            .alert("删除这项工作？", isPresented: $delete) {
                Button("删除工作", role: .destructive) {
                    Task { if await model.mutate({ try $0.deleteItem(id: itemID, now: Date()) }) { dismiss() } }
                }.disabled(model.saving).accessibilityIdentifier("work.delete.confirm")
                Button("取消", role: .cancel) { }.accessibilityIdentifier("work.delete.cancel")
            } message: { Text("将从所有项目、日历和工作选择中删除，并移除时间块与有效关联。历史投入保留；依赖它的成果可能需要复核。共享工作会从所有项目中一起删除。") }
            .confirmationDialog("确认这项工作已完成？", isPresented: $complete, titleVisibility: .visible) {
                Button("确认完成") {
                    if let item = model.item(itemID) { sheet = .feedback(item, .complete(itemID)) }
                }.accessibilityIdentifier("work.complete.confirm")
                Button("取消", role: .cancel) { }.accessibilityIdentifier("work.complete.cancel")
            } message: { Text("完成后剩余时间设为 0，投入时间需另外记录。所属节点按验收条件判断：默认（完成自身）时全部必需工作完成即通过。") }
            .sheet(isPresented: Binding(get: { disposition != nil }, set: { if !$0 { disposition = nil } })) {
                WorkDispositionEditor(itemID: itemID, disposition: WorkDisposition(rawValue: disposition ?? "active") ?? .active)
            }
            .sheet(isPresented: $copy) {
                ProjectEditorContainer(title: "创建独立副本", identifier: "work.copy.editor", validation: copyProject.isEmpty ? "请选择副本项目；副本会形成新的工作量。" : nil, save: {
                    await model.mutate { _ = try $0.copyItem(id: itemID, projectID: copyProject, now: Date()) }
                }) {
                    Section("独立副本") {
                        Text("副本单独记录进度和投入，会增加工作量。多个项目共用同一工作时，请使用关联。").fixedSize(horizontal: false, vertical: true)
                        Picker("副本项目", selection: $copyProject) {
                            Text("请选择").tag(""); ForEach(model.workspace.projects, id: \.id) { Text($0.name).tag($0.id) }
                        }.frame(minHeight: 44).accessibilityIdentifier("work.copy.project")
                    }
                }
            }
    }
}

struct WorkDispositionEditor: View {
    let itemID: String
    let disposition: WorkDisposition
    @Environment(AppModel.self) private var model
    @State private var note = ""
    var body: some View {
        ProjectEditorContainer(title: disposition == .active ? "恢复待办" : "将来 / 也许", identifier: "work.disposition", validation: nil, save: {
            await model.mutate { try $0.setItemDisposition(id: itemID, disposition: disposition, now: Date(), note: note) }
        }) {
            Section("确认工作状态") {
                Text(disposition == .deferred ? "暂缓后不再列为当前行动。若仍属于项目的必需工作，项目截止仍有效，请检查受影响的工作。" : "恢复后，前置条件满足时即可开始。")
                TextField("说明（可选）", text: $note, axis: .vertical).frame(minHeight: 44).accessibilityIdentifier("work.disposition.note")
            }
            Section("受影响的工作") { ImpactItemsView(source: .item(itemID), itemIDs: []) }
        }
    }
}

struct WorkReviewSection: View {
    let item: WorkItem
    @Environment(AppModel.self) private var model
    @State private var note = ""
    @State private var confirm = false
    var body: some View {
        Section("确认已有成果是否仍可用") {
            Text("前置条件变了，请确认已有成果是否仍可使用。确认可用后会保留原成果；新增工作仍需满足当前前置条件。")
                .fixedSize(horizontal: false, vertical: true)
            TextField("复核说明（可选）", text: $note, axis: .vertical).frame(minHeight: 44).accessibilityIdentifier("work.review.note")
            Button { confirm = true } label: { Label("确认成果仍可用", systemImage: "checkmark.shield").frame(minHeight: 44) }.accessibilityIdentifier("work.review.valid")
            ProjectMutationButton("等待前置恢复", symbol: "pause", identifier: "work.review.wait") { try $0.reviewItem(id: item.id, outcome: .waitForUpstream, now: Date(), note: note) }
        }.confirmationDialog("确认已有成果仍可用？", isPresented: $confirm, titleVisibility: .visible) {
            ProjectMutationButton("确认成果可用", symbol: "checkmark.shield", identifier: "work.review.valid.confirm") { try $0.reviewItem(id: item.id, outcome: .stillValid, now: Date(), note: note) }
            Button("取消", role: .cancel) { }.accessibilityIdentifier("work.review.valid.cancel")
        } message: { Text("只确认这项工作的已有成果，不改变前置工作的状态。") }
    }
}

struct ProjectAcceptanceSection: View {
    let subject: WorkReference
    let add: () -> Void
    @Environment(AppModel.self) private var model
    var body: some View {
        Section {
            ForEach(model.workspace.acceptances.filter { $0.isActive && $0.subject == subject }, id: \.id) { gate in AcceptanceCriterionRow(gate: gate) }
            if model.workspace.activeAcceptances(for: subject).isEmpty {
                Label("默认验收条件：完成自身。添加条件后需逐条人工通过。", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button(action: add) { Label("新增验收条件", systemImage: "plus").frame(minHeight: 44) }.accessibilityIdentifier("acceptance.add.\(subject.id)")
        } header: { Text("验收条件") } footer: { Text("逐条确认验收结果。未通过时，再选择需要返工的工作；测试或审批有耗时时，可单独建工作或等待。") }
    }
}
struct AcceptanceCriterionRow: View {
    let gate: Acceptance
    @Environment(AppModel.self) private var model
    @State private var sheet: ProjectUISheet?
    @State private var remove = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(gate.name).font(.headline).fixedSize(horizontal: false, vertical: true)
            Text("第 \(gate.currentRound) 轮 · \(ProjectUI.acceptanceLabel(gate.state))")
            if let date = gate.acceptedAt { ProjectInfoLine(title: "验收通过时间", value: ProjectUI.dateLabel(date)) }
            if gate.state == .failed {
                Text(gate.reworkScopeConfirmed == true ? "返工工作已选定，做完后需要重新验收" : "还没确定哪些工作需要返工，请补充确认")
                Text(gate.reason ?? "未填写原因")
            }
            if gate.state != .accepted {
                ProjectMutationButton("确认通过", symbol: "checkmark.circle", identifier: "acceptance.accept.\(gate.id)") { try $0.accept(id: gate.id, now: Date()) }
                Button { sheet = .failure(gate) } label: { Label(gate.state == .failed ? "选择返工工作" : "标记未通过", systemImage: "xmark.circle").frame(minHeight: 44) }.accessibilityIdentifier("acceptance.fail.\(gate.id)")
            } else {
                Button { sheet = .failure(gate) } label: { Label("改为未通过并处理返工", systemImage: "arrow.uturn.backward").frame(minHeight: 44) }.accessibilityIdentifier("acceptance.refail.\(gate.id)")
            }
            Button { sheet = .editAcceptance(gate) } label: { Label("编辑验收条件", systemImage: "pencil").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle()) }.accessibilityIdentifier("acceptance.edit.\(gate.id)")
            Button(role: .destructive) { remove = true } label: { Label("移除验收条件", systemImage: "minus.circle").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle()) }.accessibilityIdentifier("acceptance.remove.\(gate.id)")
            DisclosureGroup("查看历史结果与人工沿用") {
                ForEach(model.workspace.acceptanceResults?.filter { $0.acceptanceID == gate.id }.sorted { $0.date > $1.date } ?? [], id: \.id) { result in
                    ProjectInfoLine(title: "第 \(result.round) 轮 · \(ProjectUI.acceptanceLabel(result.state))", value: "\(ProjectUI.dateLabel(result.date))\n\(result.reason)")
                    if result.state == .accepted && gate.state != .accepted {
                        ProjectMutationButton("沿用这次通过结果", symbol: "checkmark.shield", identifier: "acceptance.reuse.\(result.id)") { try $0.reuseAcceptanceResult(id: gate.id, resultID: result.id, now: Date(), note: "人工确认旧验收成果本轮不受影响") }
                    }
                }
            }.frame(minHeight: 44).accessibilityIdentifier("acceptance.history.\(gate.id)")
        }.padding(.vertical, 4).buttonStyle(.borderless)
            .sheet(item: $sheet) { ProjectUISheetContent(sheet: $0) }
            .alert("移除这条验收条件？", isPresented: $remove) {
                Button("确认移除", role: .destructive) {
                    Task { await model.mutate { try $0.removeAcceptance(id: gate.id, now: Date()) } }
                }.disabled(model.saving).accessibilityIdentifier("acceptance.remove.confirm.\(gate.id)")
                Button("取消", role: .cancel) { }.accessibilityIdentifier("acceptance.remove.cancel.\(gate.id)")
            } message: { Text("移除后不再要求这条验收。关联工作可能需要重新核对，历史结果会保留。") }
    }
}

struct AcceptanceFailureEditor: View {
    let acceptance: Acceptance
    @Environment(AppModel.self) private var model
    @State private var reason = ""
    @State private var confirmScope = false
    @State private var itemIDs: Set<String> = []
    @State private var blockerIDs: Set<String> = []
    @State private var estimates: [String: String] = [:]
    @State private var newWork = ""
    @State private var newBlocker = ""
    @State private var newCondition = ""
    init(acceptance: Acceptance) { self.acceptance = acceptance; _reason = State(initialValue: acceptance.reason ?? "") }
    private var validation: String? {
        for id in itemIDs { if let message = ProjectUI.minutesValidation(estimates[id] ?? "", title: "返工估计") { return message } }
        if !ProjectUI.trim(newBlocker).isEmpty && ProjectUI.trim(newCondition).isEmpty { return "请填写这项等待在什么情况下结束。" }
        return nil
    }
    var body: some View {
        ProjectEditorContainer(title: "验收未通过与返工", identifier: "acceptance.failure", validation: validation, save: save) {
            Section("未通过原因") {
                Text(acceptance.name).font(.headline)
                TextField("原因（可选）", text: $reason, axis: .vertical).frame(minHeight: 44).accessibilityIdentifier("acceptance.failure.reason")
                Toggle("现在选择返工工作", isOn: $confirmScope).frame(minHeight: 44).accessibilityIdentifier("acceptance.failure.confirmScope")
                Text("关闭时只记录验收未通过。开启后，请选择实际需要返工的工作。").font(.caption).foregroundStyle(.secondary)
            }
            if confirmScope {
                Section("需要返工的工作") {
                    ForEach(model.workspace.items, id: \.id) { item in
                        ProjectSetToggle(title: item.name, id: item.id, selection: $itemIDs, identifier: "acceptance.failure.item.\(item.id)")
                        if itemIDs.contains(item.id) {
                            ProjectMinutesField(title: "返工还需多少分钟（可留空）", text: Binding(get: { estimates[item.id] ?? "" }, set: { estimates[item.id] = $0 }), identifier: "acceptance.failure.remaining.\(item.id)")
                            ImpactItemsView(source: .item(item.id), itemIDs: [])
                        }
                    }
                }
                Section("需要重新发起的等待") {
                    ForEach(model.workspace.blockers.filter { $0.state != .active }, id: \.id) { blocker in
                        ProjectSetToggle(title: blocker.name, id: blocker.id, selection: $blockerIDs, identifier: "acceptance.failure.blocker.\(blocker.id)")
                        if blockerIDs.contains(blocker.id) { ImpactItemsView(source: .blocker(blocker.id), itemIDs: []) }
                    }
                }
                Section("新增返工（可选）") {
                    TextField("新返工工作名称", text: $newWork, axis: .vertical).frame(minHeight: 44).accessibilityIdentifier("acceptance.failure.newWork")
                    TextField("新外部等待名称", text: $newBlocker, axis: .vertical).frame(minHeight: 44).accessibilityIdentifier("acceptance.failure.newBlocker")
                    TextField("等待结束的条件", text: $newCondition, axis: .vertical).frame(minHeight: 44).accessibilityIdentifier("acceptance.failure.newCondition")
                    Text("新增返工仍需满足当前前置条件。新增等待会关联到返工工作或整个节点。")
                }
            }
        }
    }
    private func save() async -> Bool {
        let memo = reason, choose = confirmScope, selectedItems = itemIDs.sorted(), selectedBlockers = blockerIDs.sorted()
        let minutes = estimates.compactMapValues(ProjectUI.optionalMinutes)
        let workName = ProjectUI.trim(newWork), blockerName = ProjectUI.trim(newBlocker), condition = newCondition
        return await model.mutate { workspace in
            guard let gate = workspace.acceptances.first(where: { $0.id == acceptance.id && $0.isActive }) else { throw CoreError.missing(acceptance.id) }
            guard choose else {
                if gate.state != .failed || gate.reworkScopeConfirmed == true { try workspace.failAcceptance(id: gate.id, now: Date(), reason: memo) }
                else { var value = gate; value.reason = memo; try workspace.updateAcceptance(value, now: Date(), note: "补充失败原因") }
                return
            }
            var newItemID: String?
            let nodeID: String?
            let projects: [String]
            switch gate.subject {
            case .node(let id): nodeID = id; projects = workspace.nodes.first { $0.id == id }.map { [$0.projectID] } ?? []
            case .item(let id): nodeID = workspace.items.first { $0.id == id }?.nodeID; projects = workspace.items.first { $0.id == id }?.projectIDs ?? []
            }
            if !workName.isEmpty {
                let item = WorkItem(name: workName, nodeID: nodeID, projectIDs: projects, description: "验收失败新增返工：\(gate.name)")
                try workspace.addItem(item, now: Date()); newItemID = item.id
                // New labor keeps the current prerequisites of the affected result.
                let subjectIDs: Set<String>
                switch gate.subject { case .item(let id): subjectIDs = [id]; case .node(let id): subjectIDs = Set(workspace.items.filter { $0.nodeID == id && $0.id != item.id }.map(\.id)) }
                let sources = workspace.dependencies.filter { $0.isActive && subjectIDs.contains($0.targetItemID) }.map(\.source)
                var seen: [DependencySource] = []
                for source in sources where !seen.contains(source) { seen.append(source); try workspace.addDependency(Dependency(source: source, targetItemID: item.id), now: Date()) }
                guard var currentGate = workspace.acceptances.first(where: { $0.id == gate.id }) else { throw CoreError.missing(gate.id) }
                currentGate.candidateItemIDs = Array(Set((currentGate.candidateItemIDs ?? []) + [item.id])).sorted()
                try workspace.updateAcceptance(currentGate, now: Date())
            }
            if !blockerName.isEmpty {
                let blocker = Blocker(name: blockerName, resolutionCondition: condition)
                try workspace.addBlocker(blocker, now: Date())
                if let target = newItemID ?? (gate.subject.itemID) { try workspace.addDependency(Dependency(source: .blocker(blocker.id), targetItemID: target), now: Date()) }
                else if let nodeID, var node = workspace.nodes.first(where: { $0.id == nodeID }) { node.blockerIDs = Array(Set((node.blockerIDs ?? []) + [blocker.id])).sorted(); try workspace.updateNode(node, now: Date()) }
                guard var currentGate = workspace.acceptances.first(where: { $0.id == gate.id }) else { throw CoreError.missing(gate.id) }
                currentGate.candidateBlockerIDs = Array(Set((currentGate.candidateBlockerIDs ?? []) + [blocker.id])).sorted()
                try workspace.updateAcceptance(currentGate, now: Date())
            }
            guard let current = workspace.acceptances.first(where: { $0.id == gate.id }) else { throw CoreError.missing(gate.id) }
            if current.state != .failed || current.reworkScopeConfirmed == true { try workspace.failAcceptance(id: gate.id, now: Date(), reason: memo) }
            try workspace.confirmAcceptanceRework(id: gate.id, itemIDs: selectedItems, blockerIDs: selectedBlockers, remainingByItem: minutes.filter { selectedItems.contains($0.key) }, now: Date(), note: memo)
        }
    }
}

extension WorkReference { var itemID: String? { if case .item(let id) = self { id } else { nil } } }
extension ProjectUI {
    static func acceptanceLabel(_ value: AcceptanceState) -> String { switch value { case .pending: "待验收"; case .accepted: "已通过"; case .failed: "未通过" } }
    static func workHistoryIDs(_ id: String, in workspace: Workspace) -> Set<String> {
        var ids: Set<String> = [id]
        for gate in workspace.acceptances where gate.subject == .item(id) { ids.insert(gate.id) }
        for dependency in workspace.dependencies where dependency.targetItemID == id { ids.insert(dependency.id); ids.insert(dependency.source.id) }
        for choice in workspace.choices ?? [] where choice.itemID == id { ids.insert(choice.id) }
        for decision in workspace.decisions where decision.trial.selections.contains(where: { $0.itemID == id }) { ids.insert(decision.id) }
        return ids
    }
}


/// Started means a historical fact, not an automatic active timer. The user identifies
/// which prior work they are actually leaving; choosing an intention never invokes this.
struct WorkStartFeedbackView: View {
    let itemID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var feedbackItem: WorkItem?
    @State private var submitting = false
    private var previous: [WorkItem] {
        model.workspace.items.filter { $0.id != itemID && $0.status == .inProgress && !$0.archived }
    }
    var body: some View {
        if let feedbackItem {
            CubicWorkRecordEditor(item: feedbackItem, transition: .start(itemID))
        } else {
            NavigationStack {
                List {
                    Section("开始工作") {
                        Text(model.item(itemID)?.name ?? "工作当前不可用").font(.headline)
                        Text("开始前可以先记录上一项工作的进展。下方列出曾经开始、尚未完成的工作。")
                            .foregroundStyle(.secondary)
                        Button {
                            guard !submitting, !model.saving, !model.loading else { return }
                            submitting = true
                            let version = model.sourceVersion
                            Task {
                                let saved = await model.mutate { try WorkFeedbackTransition.start(itemID).apply(in: &$0, now: Date(), dataVersion: version) }
                                submitting = false
                                if saved { dismiss() }
                            }
                        } label: { Label(submitting ? "保存中…" : "跳过反馈，开始工作", systemImage: "play").frame(minHeight: 44) }
                        .disabled(submitting || model.saving || model.loading).accessibilityIdentifier("work.start.skip")
                    }
                    if !previous.isEmpty {
                        Section("先记录上一项工作的进展") {
                            ForEach(previous, id: \.id) { item in
                                Button { feedbackItem = item } label: { Text(item.name).frame(minHeight: 44) }
                                    .accessibilityIdentifier("work.start.previous.\(item.id)")
                            }
                        }
                    }
                }.disabled(submitting).cubicNavigationTitle("开始工作").cubicInlineNavigationTitle()
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(submitting) } }
            }.interactiveDismissDisabled(submitting).modifier(ModalMessages())
        }
    }
}
