import SwiftUI
import CubicCore

struct RelationshipView: View {
    let nodeID: String
    @Environment(AppModel.self) private var model
    @State private var sheet: ProjectUISheet?
    var body: some View {
        List {
            Section("节点工作与前置关系") { NodeRelationshipList(nodeID: nodeID) }
            Section("编辑前置关系") {
                ForEach(model.workspace.items.filter { $0.nodeID == nodeID }, id: \.id) { item in
                    DisclosureGroup(item.name) {
                        ForEach(model.workspace.dependencies.filter { $0.isActive && $0.targetItemID == item.id }, id: \.id) { dependency in
                            DependencyRelationshipRow(dependency: dependency)
                        }
                        Button { sheet = .dependency(item.id) } label: { Label("添加前置条件", systemImage: "plus").frame(minHeight: 44) }.accessibilityIdentifier("relationships.add.\(item.id)")
                        DependencyPathsView(itemID: item.id)
                    }.frame(minHeight: 44).accessibilityIdentifier("relationships.branch.\(item.id)")
                }
            }
            Section {
                NavigationLink { WaitingView() } label: { Label("查看或新建外部等待", systemImage: "hourglass").frame(minHeight: 44) }.accessibilityIdentifier("relationships.waiting")
                Text("所有前置满足后才能开始工作。移除关系不会改变前置工作的完成状态。").font(.caption).foregroundStyle(.secondary)
            }
        }.cubicNavigationTitle("前置关系").cubicInlineNavigationTitle()
            .sheet(item: $sheet) { ProjectUISheetContent(sheet: $0) }
    }
}

struct NodeRelationshipList: View {
    let nodeID: String
    @Environment(AppModel.self) private var model
    var body: some View {
        ForEach(model.workspace.items.filter { $0.nodeID == nodeID }, id: \.id) { item in
            NavigationLink { WorkDetailView(itemID: item.id) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    ProjectWorkRow(item: item)
                    let dependencies = model.workspace.effectiveItemDependencies(itemID: item.id)
                    if dependencies.isEmpty { Text("没有前置，可以独立开始") }
                    else {
                        Text(dependencies.count > 1 ? "以下前置都需要完成" : "开始前需要完成")
                        ForEach(dependencies, id: \.id) { dependency in
                            Label(ProjectUI.sourceName(dependency.source, in: model.workspace), systemImage: model.workspace.sourceSatisfied(dependency.source) ? "checkmark.circle" : "hourglass")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }.font(.caption)
            }.accessibilityIdentifier("node.branch.\(item.id)")
        }
        ForEach(model.workspace.workLinks?.filter { $0.nodeID == nodeID && $0.removedAt == nil } ?? [], id: \.id) { link in
            WorkReferenceLink(subject: link.source, label: "共享\(link.isRequired ? "必需" : "非必需")成果：\(ProjectUI.referenceName(link.source, in: model.workspace))", identifier: "node.shared.\(link.id)")
        }
        ForEach(model.workspace.nodes.first { $0.id == nodeID }?.blockerIDs ?? [], id: \.self) { id in
            NavigationLink { BlockerDetailView(blockerID: id) } label: { ProjectInfoLine(title: "整个节点的条件", value: ProjectUI.sourceName(.blocker(id), in: model.workspace)).frame(minHeight: 44) }.accessibilityIdentifier("node.blocker.\(id)")
        }
    }
}

struct DependencyRelationshipRow: View {
    let dependency: Dependency
    @Environment(AppModel.self) private var model
    @State private var sheet: ProjectUISheet?
    @State private var removing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DependencySourceLink(source: dependency.source)
            Label(model.workspace.sourceSatisfied(dependency.source) ? "此前置已完成" : "等待此前置完成", systemImage: model.workspace.sourceSatisfied(dependency.source) ? "checkmark.circle" : "hourglass")
            Text("\(ProjectUI.sourceName(dependency.source, in: model.workspace)) → \(model.item(dependency.targetItemID)?.name ?? dependency.targetItemID)")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            Button { sheet = .editDependency(dependency) } label: { Label("修改前置", systemImage: "pencil").frame(minHeight: 44) }.accessibilityIdentifier("dependency.edit.\(dependency.id)")
            Button { removing = true } label: { Label("移除前置关系", systemImage: "link.badge.minus").frame(minHeight: 44) }.accessibilityIdentifier("dependency.remove.\(dependency.id)")
        }.padding(.vertical, 4)
            .sheet(item: $sheet) { ProjectUISheetContent(sheet: $0) }
            .sheet(isPresented: $removing) {
                RelationshipRemovalEditor(dependency: dependency)
            }
    }
}
struct RelationshipRemovalEditor: View {
    let dependency: Dependency
    @Environment(AppModel.self) private var model
    @State private var note = ""
    var body: some View {
        ProjectEditorContainer(title: "确认移除依赖", identifier: "dependency.remove.confirm.\(dependency.id)", validation: nil, save: {
            await model.mutate { try $0.removeDependency(id: dependency.id, now: Date(), note: note) }
        }) {
            Section("确认移除关系") {
                Text("\(ProjectUI.sourceName(dependency.source, in: model.workspace)) → \(model.item(dependency.targetItemID)?.name ?? dependency.targetItemID)")
                Text("只移除这条关系，原工作仍保留。已使用其成果的关联工作可能需要复核。")
                TextField("为什么不再需要（可选）", text: $note, axis: .vertical).frame(minHeight: 44).accessibilityIdentifier("dependency.remove.note")
            }
            Section("受影响的工作") { ImpactItemsView(source: .item(dependency.targetItemID), itemIDs: [dependency.targetItemID]) }
        }
    }
}

struct DependencySourceLink: View {
    let source: DependencySource
    @Environment(AppModel.self) private var model
    @ViewBuilder var body: some View {
        switch source {
        case .item(let id): WorkReferenceLink(subject: .item(id), label: "待办完成：\(ProjectUI.sourceName(source, in: model.workspace))", identifier: "dependency.source.item.\(id)")
        case .node(let id): WorkReferenceLink(subject: .node(id), label: "节点人工验收：\(ProjectUI.sourceName(source, in: model.workspace))", identifier: "dependency.source.node.\(id)")
        case .blocker(let id):
            NavigationLink { BlockerDetailView(blockerID: id) } label: { ProjectInfoLine(title: "外部条件", value: ProjectUI.sourceName(source, in: model.workspace)).frame(minHeight: 44) }.accessibilityIdentifier("dependency.source.blocker.\(id)")
        }
    }
}
struct WorkReferenceLink: View {
    let subject: WorkReference
    let label: String
    var subtitle: String? = nil
    let identifier: String
    var body: some View {
        NavigationLink {
            switch subject { case .item(let id): WorkDetailView(itemID: id); case .node(let id): CubicNodeDetailView(nodeID: id) }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                ProjectListTitle(text: label)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }.fixedSize(horizontal: false, vertical: true).frame(minHeight: 44, alignment: .leading)
        }.accessibilityIdentifier(identifier)
    }
}

struct ImpactItemsView: View {
    let source: DependencySource?
    let itemIDs: [String]
    @Environment(AppModel.self) private var model
    private var direct: Set<String> {
        var ids = Set(itemIDs)
        if let source {
            ids.formUnion(model.workspace.dependencies.filter { $0.isActive && $0.source == source }.map(\.targetItemID))
            if case .blocker(let id) = source {
                let nodes = model.workspace.nodes.filter { ($0.blockerIDs ?? []).contains(id) }.map(\.id)
                ids.formUnion(model.workspace.items.filter { nodes.contains($0.nodeID ?? "") }.map(\.id))
            }
        }
        return ids
    }
    private var all: Set<String> {
        var ids = direct
        if let source { ids.formUnion(model.workspace.affectedItemIDs(by: source)) }
        for id in direct { ids.formUnion(model.workspace.affectedItemIDs(by: .item(id))) }
        return ids
    }
    var body: some View {
        if all.isEmpty { Text("没有后续工作受影响。").font(.caption).foregroundStyle(.secondary) }
        ForEach(model.workspace.items.filter { all.contains($0.id) }, id: \.id) { item in
            NavigationLink { WorkDetailView(itemID: item.id) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(direct.contains(item.id) ? "直接影响" : "间接影响").font(.caption).foregroundStyle(.secondary)
                    ProjectListTitle(text: item.name)
                    WorkAffiliationRows(item: item)
                    Text(ProjectUI.statusLabel(item, blocked: !ProjectUI.predecessorsSatisfied(item.id, in: model.workspace))).font(.caption)
                }.frame(minHeight: 44)
            }.accessibilityIdentifier("impact.item.\(item.id)")
        }
    }
}

struct DependencyPathsView: View {
    let itemID: String
    @Environment(AppModel.self) private var model
    var body: some View {
        let paths = ProjectUI.paths(to: itemID, in: model.workspace)
        DisclosureGroup("可朗读的前置路径（\(paths.count)）") {
            ForEach(Array(paths.enumerated()), id: \.offset) { index, path in Text(path).font(.subheadline).fixedSize(horizontal: false, vertical: true).padding(.vertical, 6).accessibilityIdentifier("paths.\(itemID).\(index)") }
            if paths.isEmpty { Text("没有前置关系。") }
        }.frame(minHeight: 44).accessibilityIdentifier("paths.expand.\(itemID)")
    }
}

struct WaitingView: View {
    @Environment(AppModel.self) private var model
    @State private var sheet: ProjectUISheet?
    @State private var includeArchived = false
    var body: some View {
        List {
            Section { Toggle("包含归档等待", isOn: $includeArchived).frame(minHeight: 44).accessibilityIdentifier("waiting.archived") }
            ForEach(model.workspace.blockers.filter { includeArchived || $0.isArchived != true }, id: \.id) { blocker in
                NavigationLink { BlockerDetailView(blockerID: blocker.id) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(blocker.name).font(.headline)
                        Text("\(ProjectUI.blockerLabel(blocker.state)) · 第 \(blocker.currentRound) 轮")
                        Text(blocker.resolutionCondition ?? "等待结束条件待填写")
                        if let date = blocker.followUpAt { ProjectInfoLine(title: "跟进", value: ProjectUI.dateLabel(date)) }
                        if let date = blocker.estimatedResolution { ProjectInfoLine(title: "预计结束", value: ProjectUI.dateLabel(date)) }
                    }.fixedSize(horizontal: false, vertical: true).frame(minHeight: 44, alignment: .leading)
                }.accessibilityIdentifier("waiting.blocker.\(blocker.id)")
            }
            if model.workspace.blockers.isEmpty { Text("创建等待后，请关联受影响的工作或节点。") }
        }.cubicNavigationTitle("外部等待")
            .toolbar { ToolbarItem(placement: .primaryAction) { Button { sheet = .blocker(nil) } label: { Label("新建等待", systemImage: "plus").frame(minWidth: 44, minHeight: 44) }.accessibilityIdentifier("waiting.new") } }
            .sheet(item: $sheet) { ProjectUISheetContent(sheet: $0) }
    }
}

struct BlockerDetailView: View {
    let blockerID: String
    @Environment(AppModel.self) private var model
    @State private var sheet: ProjectUISheet?
    @State private var confirming = false
    @State private var startedAt = Date()
    @State private var backdate = false
    var body: some View {
        List {
            if let blocker = model.workspace.blockers.first(where: { $0.id == blockerID }) {
                Section("等待结束的条件") {
                    Text(blocker.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text(blocker.resolutionCondition ?? "待补充").fixedSize(horizontal: false, vertical: true)
                    Text("\(ProjectUI.blockerLabel(blocker.state)) · 第 \(blocker.currentRound) 轮")
                    Text(blocker.contactNote ?? "联系人备注未填")
                    Button { sheet = .blocker(blocker) } label: { Label("编辑等待", systemImage: "pencil").frame(minHeight: 44) }.accessibilityIdentifier("blocker.edit")
                }
                Section("开始与结束时间") {
                    if let date = blocker.triggeredAt { ProjectInfoLine(title: "本轮开始", value: ProjectUI.dateLabel(date)) }
                    else { Text("等待尚未开始，请确认开始时间。") }
                    ProjectInfoLine(title: "预计要等多久", value: minutesLabel(blocker.expectedDurationMinutes))
                    if let date = blocker.estimatedResolution { ProjectInfoLine(title: "预计结束", value: ProjectUI.dateLabel(date)) }
                    if let date = blocker.followUpAt { ProjectInfoLine(title: "下次跟进", value: ProjectUI.dateLabel(date)) }
                    if blocker.state != .resolved, let date = blocker.estimatedResolution, date <= Date() { Label("预计结束时间已过。请确认等待是否结束，或更新预计时间。", systemImage: "exclamationmark.clock").fixedSize(horizontal: false, vertical: true) }
                    if blocker.state == .inactive {
                        Toggle("补录开始时间", isOn: $backdate).frame(minHeight: 44).accessibilityIdentifier("blocker.backdate")
                        if backdate { ProjectDateField(title: "开始时间", date: $startedAt, identifier: "blocker.startedAt") }
                        ProjectActionButton("确认等待已开始", symbol: "paperplane", identifier: "blocker.trigger") {
                            guard !backdate || startedAt <= Date() else { model.errorMessage = "实际发起不能在未来。"; return false }
                            return await model.mutate { try $0.triggerBlocker(id: blockerID, now: backdate ? startedAt : Date()) }
                        }
                    }
                    if blocker.state != .inactive {
                        Button { confirming = true } label: { Label(blocker.state == .resolved ? "重新发起等待" : "确认等待已结束", systemImage: blocker.state == .resolved ? "arrow.uturn.backward" : "checkmark.circle").frame(minHeight: 44) }.accessibilityIdentifier("blocker.changeState")
                    }
                    if let date = blocker.resolvedAt { ProjectInfoLine(title: "最近结束", value: ProjectUI.dateLabel(date)) }
                }
                Section("跟进行动") {
                    if let id = blocker.followUpItemID { WorkReferenceLink(subject: .item(id), label: model.item(id)?.name ?? "跟进待办不可用", identifier: "blocker.followUpItem") }
                    Button { sheet = .newItem(projectID: nil, nodeID: nil) } label: { Label("新建跟进工作", systemImage: "plus").frame(minHeight: 44) }.accessibilityIdentifier("blocker.newFollowUp")
                }
                Section("受影响的工作") { ImpactItemsView(source: .blocker(blockerID), itemIDs: []) }
                Section("历次等待记录") {
                    ForEach(model.workspace.blockerRounds?.filter { $0.blockerID == blockerID }.sorted { $0.round > $1.round } ?? [], id: \.id) { round in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("第 \(round.round) 轮").font(.headline)
                            if let date = round.triggeredAt { ProjectInfoLine(title: "开始时间", value: ProjectUI.dateLabel(date)) }
                            if let date = round.resolvedAt { ProjectInfoLine(title: "结束时间", value: ProjectUI.dateLabel(date)) }
                            if let date = round.expectedResolution { ProjectInfoLine(title: "该轮预计结束", value: ProjectUI.dateLabel(date)) }
                        }.accessibilityIdentifier("blocker.round.\(round.id)")
                    }
                }
                Section {
                    ProjectMutationButton(blocker.isArchived == true ? "恢复等待显示" : "归档等待", symbol: "archivebox", identifier: "blocker.archive") { try $0.setBlockerArchived(id: blockerID, archived: blocker.isArchived != true, now: Date()) }
                    Text("归档只隐藏等待，不会把它标为结束。").font(.caption).foregroundStyle(.secondary)
                }
            } else { Text("这项等待已不可用，请返回列表。") }
        }.cubicNavigationTitle("等待详情").cubicInlineNavigationTitle()
            .sheet(item: $sheet) { ProjectUISheetContent(sheet: $0) }
            .confirmationDialog("确认修改等待状态？", isPresented: $confirming, titleVisibility: .visible) {
                ProjectMutationButton("确认", symbol: "checkmark", identifier: "blocker.changeState.confirm") { workspace in
                    guard let blocker = workspace.blockers.first(where: { $0.id == blockerID }) else { throw CoreError.missing(blockerID) }
                    if blocker.state == .resolved { try workspace.triggerBlocker(id: blockerID, now: Date()) }
                    else { try workspace.resolveBlocker(id: blockerID, now: Date()) }
                }
                Button("取消", role: .cancel) { }.accessibilityIdentifier("blocker.changeState.cancel")
            } message: { Text("所有关联工作都会受到影响。重新发起等待后，已使用相关成果的工作可能需要复核；历史记录保留。") }
    }
}

struct SharedReferencesView: View {
    let projectID: String
    let nodeID: String?
    @Environment(AppModel.self) private var model
    @State private var sourceKind = "item"
    @State private var sourceID = ""
    @State private var required = true
    @State private var removal: WorkLink?
    var body: some View {
        List {
            Section("关联已有工作或节点") {
                Picker("关联类型", selection: $sourceKind) { Text("工作完成").tag("item"); Text("节点验收").tag("node") }.frame(minHeight: 44).accessibilityIdentifier("references.kind")
                if sourceKind == "item" {
                    ForEach(model.workspace.items, id: \.id) { item in ProjectOptionChoice(title: item.name, subtitle: model.workspace.projects.filter { model.relatedProjectIDs(for: item).contains($0.id) }.map { "项目：" + $0.name }.joined(separator: "\n"), value: item.id, selection: $sourceID, identifier: "references.item.\(item.id)") }
                } else {
                    ForEach(model.workspace.nodes.filter { $0.id != nodeID }, id: \.id) { node in ProjectOptionChoice(title: node.name, subtitle: model.workspace.projects.first { $0.id == node.projectID }.map { "项目：" + $0.name }, value: node.id, selection: $sourceID, identifier: "references.node.\(node.id)") }
                }
                Toggle("交付时必须完成", isOn: $required).frame(minHeight: 44).accessibilityIdentifier("references.required")
                ProjectActionButton("添加关联", symbol: "link", identifier: "references.add") {
                    guard !sourceID.isEmpty else { model.errorMessage = "请选择源对象。"; return false }
                    let source: WorkReference = sourceKind == "item" ? .item(sourceID) : .node(sourceID)
                    return await model.mutate { try $0.addWorkLink(WorkLink(source: source, projectID: projectID, nodeID: nodeID, isRequired: required), now: Date()) }
                }
                Text("把其他位置的同一项工作或节点加入这里的交付清单，已有进度会共用，不会复制一份工作。标为必需后，这里的交付也要等它完成；关联节点时还要等它通过验收。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("已有关联") {
                ForEach(model.workspace.workLinks?.filter { $0.projectID == projectID && $0.nodeID == nodeID && $0.removedAt == nil } ?? [], id: \.id) { link in
                    WorkReferenceLink(subject: link.source, label: "\(link.isRequired ? "必需" : "非必需") · \(ProjectUI.referenceName(link.source, in: model.workspace))", identifier: "references.source.\(link.id)")
                    Button { removal = link } label: { Label("移除关联", systemImage: "link.badge.minus").frame(minHeight: 44) }.accessibilityIdentifier("references.remove.\(link.id)")
                }
            }
        }.cubicNavigationTitle("关联已有工作或节点").onChange(of: sourceKind) { _, _ in sourceID = "" }
            .sheet(isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })) {
                if let link = removal {
                    ProjectEditorContainer(title: "移除共享引用", identifier: "references.remove.confirm", validation: nil, save: { await model.mutate { try $0.removeWorkLink(id: link.id, now: Date()) } }) {
                        Section("确认移除关联") {
                            Text("移除 \(ProjectUI.referenceName(link.source, in: model.workspace)) 在此位置的引用。源工作与其他项目引用保留。")
                            ImpactItemsView(source: link.source.dependencySource, itemIDs: [])
                        }
                    }
                }
            }
    }
}

struct NodeMoveView: View {
    let nodeID: String
    @Environment(AppModel.self) private var model
    @State private var projectID = ""
    @State private var note = ""
    @State private var confirm = false
    var body: some View {
        List {
            Section("目标项目") {
                ForEach(model.workspace.projects.filter { $0.id != model.workspace.nodes.first { $0.id == nodeID }?.projectID }, id: \.id) { project in ProjectOptionChoice(title: project.name, value: project.id, selection: $projectID, identifier: "node.move.project.\(project.id)") }
                TextField("移动说明（可选）", text: $note, axis: .vertical).frame(minHeight: 44).accessibilityIdentifier("node.move.note")
            }
            Section("受影响的工作") {
                ImpactItemsView(source: .node(nodeID), itemIDs: model.workspace.items.filter { $0.nodeID == nodeID }.map(\.id))
                Text("节点及其工作一起移到目标项目，进度和历史保留。两个项目的交付条件和排期会按新结构自动更新。")
                Button { confirm = true } label: { Label("移到目标项目", systemImage: "folder").frame(minHeight: 44) }.accessibilityIdentifier("node.move.save")
            }
        }.cubicNavigationTitle("移动节点")
            .confirmationDialog("将节点及其工作一起移到目标项目？", isPresented: $confirm, titleVisibility: .visible) {
                ProjectActionButton("确认移动", symbol: "folder", identifier: "node.move.confirm") {
                    guard !projectID.isEmpty else { model.errorMessage = "请选择目标项目。"; return false }
                    return await model.mutate { workspace in
                        try workspace.moveNode(id: nodeID, projectID: projectID, now: Date(), note: note)
                    }
                }
                Button("取消", role: .cancel) { }.accessibilityIdentifier("node.move.cancel")
            }
    }
}

extension WorkReference {
    var dependencySource: DependencySource { switch self { case .item(let id): .item(id); case .node(let id): .node(id) } }
}
extension ProjectUI {
    static func sourceName(_ source: DependencySource, in workspace: Workspace) -> String {
        switch source { case .item(let id): workspace.items.first { $0.id == id }?.name ?? "待办不可用：\(id)"; case .node(let id): workspace.nodes.first { $0.id == id }?.name ?? "节点不可用：\(id)"; case .blocker(let id): workspace.blockers.first { $0.id == id }?.name ?? "等待不可用：\(id)" }
    }
    static func referenceName(_ ref: WorkReference, in workspace: Workspace) -> String { sourceName(ref.dependencySource, in: workspace) }
    static func paths(to itemID: String, in workspace: Workspace) -> [String] {
        func walk(_ id: String, visited: Set<String>, tail: [String]) -> [String] {
            guard !visited.contains(id) else { return [( ["循环：\(workspace.items.first { $0.id == id }?.name ?? id)"] + tail).joined(separator: " → ")] }
            let nextVisited = visited.union([id]); let title = workspace.items.first { $0.id == id }?.name ?? id
            let dependencies = workspace.effectiveItemDependencies(itemID: id)
            if dependencies.isEmpty { return [([title] + tail).joined(separator: " → ")] }
            return dependencies.flatMap { dependency -> [String] in
                switch dependency.source {
                case .item(let sourceID): return walk(sourceID, visited: nextVisited, tail: [title] + tail)
                case .node(let nodeID):
                    let members = workspace.items.filter { $0.nodeID == nodeID && $0.required }
                    let gate = "节点逐项验收：\(sourceName(.node(nodeID), in: workspace))"
                    if members.isEmpty { return [([gate, title] + tail).joined(separator: " → ")] }
                    return members.flatMap { walk($0.id, visited: nextVisited, tail: [gate, title] + tail) }
                case .blocker(let id): return [(["外部条件：\(sourceName(.blocker(id), in: workspace))", title] + tail).joined(separator: " → ")]
                }
            }
        }
        guard !workspace.effectiveItemDependencies(itemID: itemID).isEmpty else { return [] }
        return Array(Set(walk(itemID, visited: [], tail: []))).sorted()
    }
}
