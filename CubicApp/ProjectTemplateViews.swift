import SwiftUI
import CubicCore

/// Every case ends at a validated Core command boundary. Preparation runs off MainActor.
enum ProjectTemplateMutation: Sendable {
    case save(projectID: String, title: String, baseline: Date?, timeZoneID: String, dateOnly: Bool)
    case instantiate(templateID: String, deadline: Date, timeZoneID: String, dateOnly: Bool)
    case rename(templateID: String, title: String)
    case delete(templateID: String)

    func prepare(in workspace: Workspace, now: Date) throws -> (workspace: Workspace, id: String) {
        var candidate = workspace
        // Defaults run first; the template command validates the final graph once.
        try candidate.applyDefaultRemainingEstimates(now: now)
        let id: String
        switch self {
        case .save(let projectID, let title, let baseline, let zone, let dateOnly):
            id = try candidate.saveProjectTemplate(projectID: projectID, title: title, baselineDeadline: baseline,
                baselineTimeZoneID: zone, baselineIsDateOnly: dateOnly, now: now)
        case .instantiate(let templateID, let deadline, let zone, let dateOnly):
            id = try candidate.instantiateProjectTemplate(templateID: templateID, deadline: deadline,
                timeZoneID: zone, dateOnly: dateOnly, now: now)
        case .rename(let templateID, let title):
            try candidate.renameProjectTemplate(templateID: templateID, title: title, now: now); id = templateID
        case .delete(let templateID):
            try candidate.deleteProjectTemplate(templateID: templateID, now: now); id = templateID
        }
        return (candidate, id)
    }
}

struct ProjectTemplatesView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let templates = model.workspace.availableProjectTemplates()
        List {
            Section {
                Text("选择一个模板，设置截止时间即可创建独立项目。").foregroundStyle(.secondary)
            }
            if templates.isEmpty {
                ContentUnavailableView("还没有项目模板", systemImage: "doc.on.doc",
                    description: Text("打开已有项目，在右上角“项目操作”中选择“保存为模板”。"))
                    .accessibilityIdentifier("templates.empty")
            } else {
                ForEach(templates) { template in
                    NavigationLink { ProjectTemplateDetailView(templateID: template.id) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(template.title).font(.headline)
                            if let payload = template.payload {
                                Text("\(payload.nodes.count) 个节点 · \(payload.items.count) 项工作")
                                    .font(.caption).foregroundStyle(.secondary)
                                if template.title != payload.project.name { Text("项目：\(payload.project.name)").font(.caption) }
                            }
                            if template.availabilityIssue != nil || template.payload == nil {
                                Label("暂不可用，点开查看原因", systemImage: "exclamationmark.circle").font(.caption)
                            }
                        }.fixedSize(horizontal: false, vertical: true).frame(minHeight: 44)
                    }.accessibilityIdentifier("templates.template.\(template.id)")
                }
            }
        }
        .cubicNavigationTitle("项目模板")
    }
}

struct SaveProjectTemplateView: View {
    let projectID: String
    @Environment(AppModel.self) private var model
    @State private var title = ""
    @State private var titleInitialized = false
    @State private var preview: ProjectTemplatePreview?
    @State private var useAnchor = false
    @State private var anchor = Date()
    @State private var dateOnly = true
    @State private var zone = TimeZone.current.identifier
    @State private var refreshing = true
    private var refreshKey: String {
        "\(model.dataVersion):\(useAnchor):\(anchor.timeIntervalSince1970):\(dateOnly):\(zone)"
    }
    private var validation: String? {
        if ProjectUI.trim(title).isEmpty { return "请输入模板名称。" }
        if refreshing { return "正在读取项目内容。" }
        if preview?.canSave != true { return "请先处理预览中的提示。" }
        return nil
    }
    var body: some View {
        ProjectEditorContainer(title: "保存为模板", identifier: "template.editor", validation: validation, save: save) {
            Section("模板名称") {
                TextField("模板名称", text: $title, axis: .vertical).frame(minHeight: 44)
                    .accessibilityIdentifier("template.editor.name")
                Text("模板名称用于查找；新项目保留原项目名称。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if preview?.needsDeadlineAnchor == true || useAnchor {
                Section("基准截止时间") {
                    Text("原项目没有截止时间。设置一个基准，仅用于保存各项工作与项目截止时间的间隔。原项目不会改变。")
                        .font(.caption).foregroundStyle(.secondary)
                    ProjectDeadlineFields(enabled: $useAnchor, date: $anchor, dateOnly: $dateOnly, zone: $zone,
                        identifier: "template.editor.anchor")
                }
            }
            if refreshing { Section { ProgressView("正在读取项目内容") } }
            if let preview {
                if !preview.errors.isEmpty {
                    Section("需要处理") { TemplateIssueRows(issues: preview.errors) }
                        .accessibilityIdentifier("template.editor.issues")
                }
                if let payload = preview.payload { TemplateContentRows(payload: payload) }
                if !preview.warnings.isEmpty {
                    Section("保存说明") { TemplateIssueRows(issues: preview.warnings) }
                }
            }
        }
        .task(id: refreshKey) {
            refreshing = true
            if !titleInitialized {
                title = model.workspace.projects.first { $0.id == projectID }?.name ?? ""
                titleInitialized = true
            }
            let workspace = model.workspace
            let sourceProjectID = projectID, baseline = useAnchor ? anchor : nil, timeZoneID = zone, dateOnly = dateOnly
            let result = await Task.detached(priority: .userInitiated) {
                workspace.previewProjectTemplate(projectID: sourceProjectID, baselineDeadline: baseline,
                    baselineTimeZoneID: timeZoneID, baselineIsDateOnly: dateOnly)
            }.value
            guard !Task.isCancelled else { return }
            preview = result; refreshing = false
        }
    }
    private func save() async -> Bool {
        let name = ProjectUI.trim(title), baseline = useAnchor ? anchor : nil, timeZoneID = zone, dateOnly = dateOnly
        return await model.mutateProjectTemplate(.save(projectID: projectID, title: name, baseline: baseline,
            timeZoneID: timeZoneID, dateOnly: dateOnly)) != nil
    }
}

struct ProjectTemplateDetailView: View {
    let templateID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var create = false
    @State private var rename = false
    @State private var title = ""
    @State private var delete = false
    @State private var createdProjectID: String?
    @State private var pendingProjectID: String?
    @State private var issues: [ProjectTemplateIssue] = []
    @State private var checking = true
    private var template: ProjectTemplate? { model.workspace.projectTemplate(id: templateID) }
    var body: some View {
        List {
            if let template, !template.isRemoved {
                Section {
                    Text(template.title).font(.title2).accessibilityIdentifier("template.detail.title")
                    Text("创建时只需设置截止时间。内容、耗时与前置关系将原样恢复，执行进度重新开始。")
                        .foregroundStyle(.secondary)
                    Button { create = true } label: {
                        Label("使用模板创建项目", systemImage: "plus").frame(minHeight: 44)
                    }.disabled(checking || !issues.isEmpty || model.loading || model.saving)
                        .accessibilityIdentifier("template.detail.create")
                }
                if checking { ProgressView("正在检查模板") }
                if !issues.isEmpty { Section("暂不可用") { TemplateIssueRows(issues: issues) } }
                if !checking, issues.isEmpty, let payload = template.payload { TemplateContentRows(payload: payload) }
            } else { ContentUnavailableView("模板已不可用", systemImage: "doc.on.doc") }
        }
        .cubicNavigationTitle("模板详情").cubicInlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("重命名模板", systemImage: "pencil") { title = template?.title ?? ""; rename = true }
                        .accessibilityIdentifier("template.detail.rename")
                    Button("删除模板", systemImage: "trash", role: .destructive) { delete = true }
                        .accessibilityIdentifier("template.detail.delete")
                } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
                    .disabled(template == nil || template?.isRemoved == true || model.saving || model.loading)
                    .accessibilityLabel("模板操作").accessibilityIdentifier("template.detail.operations")
            }
        }
        .task(id: model.dataVersion) {
            checking = true
            let template = template
            let result = await Task.detached(priority: .userInitiated) { template?.validationIssues ?? [] }.value
            guard !Task.isCancelled else { return }
            issues = result; checking = false
        }
        .alert("重命名模板", isPresented: $rename) {
            TextField("模板名称", text: $title).accessibilityIdentifier("template.rename.name")
            Button("取消", role: .cancel) { }
            Button("保存") {
                let name = ProjectUI.trim(title)
                Task { _ = await model.mutateProjectTemplate(.rename(templateID: templateID, title: name)) }
            }.disabled(ProjectUI.trim(title).isEmpty)
        } message: { Text("只修改模板名称，保留模板内的项目名称。") }
        .confirmationDialog("删除这个模板？", isPresented: $delete, titleVisibility: .visible) {
            Button("删除模板", role: .destructive) {
                Task {
                    if await model.mutateProjectTemplate(.delete(templateID: templateID)) != nil { dismiss() }
                }
            }.accessibilityIdentifier("template.delete.confirm")
            Button("取消", role: .cancel) { }
        } message: { Text("已经从模板创建的项目不受影响。") }
        .sheet(isPresented: $create, onDismiss: {
            if let id = pendingProjectID { pendingProjectID = nil; createdProjectID = id }
        }) {
            CreateTemplateProjectView(templateID: templateID) { pendingProjectID = $0 }
        }
        .navigationDestination(item: $createdProjectID) { CubicProjectDetailView(projectID: $0) }
    }
}

struct CreateTemplateProjectView: View {
    let templateID: String
    let onCreated: (String) -> Void
    @Environment(AppModel.self) private var model
    @State private var enabled = true
    @State private var deadline = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var dateOnly = true
    @State private var zone = TimeZone.current.identifier
    @State private var issues: [ProjectTemplateIssue] = []
    @State private var checking = true
    private var template: ProjectTemplate? { model.workspace.projectTemplate(id: templateID) }
    private var validation: String? {
        if checking { return "正在检查模板。" }
        if template == nil { return "模板已不可用。" }
        if !issues.isEmpty { return "模板暂不可用，请查看提示。" }
        if !enabled { return "请选择新项目的截止时间。" }
        return nil
    }
    var body: some View {
        ProjectEditorContainer(title: "从模板创建项目", identifier: "template.create", validation: validation, save: save, saveLabel: "创建") {
            Section("截止时间") {
                ProjectDeadlineFields(enabled: $enabled, date: $deadline, dateOnly: $dateOnly, zone: $zone,
                    identifier: "template.create.deadline")
                Text("工作自身的截止时间按模板中的间隔自动调整。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !issues.isEmpty { Section("需要处理") { TemplateIssueRows(issues: issues) } }
            if !checking, issues.isEmpty, let payload = template?.payload {
                TemplateContentRows(payload: payload, deadline: enabled ? deadline : nil, timeZoneID: zone, dateOnly: dateOnly)
            }
        }
        .task(id: model.dataVersion) {
            checking = true
            let template = template
            let result = await Task.detached(priority: .userInitiated) { template?.validationIssues ?? [] }.value
            guard !Task.isCancelled else { return }
            issues = result; checking = false
        }
    }
    private func save() async -> Bool {
        let deadline = deadline, timeZoneID = zone, dateOnly = dateOnly
        guard let createdID = await model.mutateProjectTemplate(.instantiate(templateID: templateID,
            deadline: deadline, timeZoneID: timeZoneID, dateOnly: dateOnly)) else { return false }
        onCreated(createdID)
        return true
    }
}

private struct TemplateIssueRows: View {
    let issues: [ProjectTemplateIssue]
    var body: some View {
        ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
            Text(issue.message).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Builds indexes once per snapshot; each graph relationship is rendered once.
private struct TemplateContentRows: View {
    let payload: ProjectTemplatePayload
    let deadline: Date?
    let timeZoneID: String
    let dateOnly: Bool
    let structure: ProjectTemplateStructure
    let sourcesByItem: [String: [ProjectTemplateDependency]]
    let names: [String: String]
    init(payload: ProjectTemplatePayload, deadline: Date? = nil,
         timeZoneID: String = TimeZone.current.identifier, dateOnly: Bool = true) {
        self.payload = payload; self.deadline = deadline; self.timeZoneID = timeZoneID; self.dateOnly = dateOnly
        structure = payload.structure
        sourcesByItem = Dictionary(grouping: payload.dependencies, by: \.targetItemID)
        names = ([payload.project.id: payload.project.name]).merging(
            (payload.nodes.map { ($0.id, $0.name) } + payload.items.map { ($0.id, $0.name) } + payload.blockers.map { ($0.id, $0.name) })
                .reduce(into: [String: String]()) { $0[$1.0] = $1.1 }, uniquingKeysWith: { _, rhs in rhs })
    }
    var body: some View {
        Section("项目内容") {
            Text(payload.project.name).font(.headline).accessibilityIdentifier("template.preview.project")
            if let description = payload.project.description, !description.isEmpty { Text(description) }
            Text("\(payload.nodes.count) 个节点 · \(payload.items.count) 项工作 · \(payload.dependencies.count) 条前置关系")
                .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("template.preview.summary")
            Text("总耗时：\(minutesLabel(payload.items.reduce(0) { $0 + $1.durationMinutes }))")
                .font(.caption).accessibilityIdentifier("template.preview.duration")
        }
        ForEach(structure.nodes, id: \.id) { node in
            Section {
                if let outcome = node.outcome, !outcome.isEmpty { Text(outcome).font(.caption) }
                if !node.isRequired { Text("非必需节点").font(.caption).foregroundStyle(.secondary) }
                ForEach(structure.membersByNode[node.id] ?? [], id: \.id) { workRow($0) }
                ForEach(structure.linksByNode[node.id] ?? [], id: \.id) { linkRow($0) }
                ForEach(node.blockerIDs, id: \.self) { id in Text("等待：\(names[id] ?? "等待条件")").font(.caption) }
                if (structure.membersByNode[node.id] ?? []).isEmpty && (structure.linksByNode[node.id] ?? []).isEmpty { Text("空节点").foregroundStyle(.secondary) }
            } header: { Text(node.name).accessibilityIdentifier("template.preview.node.\(node.id)") }
        }
        if !structure.directItems.isEmpty || !structure.directLinks.isEmpty {
            Section("直属工作与引用") {
                ForEach(structure.directItems, id: \.id) { workRow($0) }
                ForEach(structure.directLinks, id: \.id) { linkRow($0) }
            }
        }
        if !payload.acceptances.isEmpty {
            Section("验收条件") {
                ForEach(payload.acceptances, id: \.id) { condition in
                    ProjectInfoLine(title: names[condition.subject.id] ?? "验收对象", value: condition.name)
                    if let candidates = condition.candidateItemIDs, !candidates.isEmpty {
                        Text("返工候选工作：\(candidates.map { names[$0] ?? "工作" }.joined(separator: "、"))").font(.caption)
                    }
                    if let candidates = condition.candidateBlockerIDs, !candidates.isEmpty {
                        Text("返工可能涉及的等待：\(candidates.map { names[$0] ?? "等待" }.joined(separator: "、"))").font(.caption)
                    }
                }
            }
        }
        if !payload.blockers.isEmpty {
            Section("等待条件") {
                ForEach(payload.blockers, id: \.id) { blocker in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(blocker.name)
                        if let condition = blocker.resolutionCondition { Text(condition).font(.caption) }
                        if let duration = blocker.expectedDurationMinutes { Text("等待时长：\(minutesLabel(duration))").font(.caption) }
                    }.fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
    private func workRow(_ work: ProjectTemplateWork) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(work.name).font(.headline)
            if let description = work.description, !description.isEmpty { Text(description).font(.caption) }
            Text("耗时：\(minutesLabel(work.durationMinutes)) · \(work.isRequired ? "交付必需" : "非必需")")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(sourcesByItem[work.id] ?? [], id: \.id) { dependency in
                Label("前置：\(names[dependency.source.id] ?? "前置条件")", systemImage: "arrow.turn.down.right").font(.caption)
            }
            if let rule = work.deadlineRule { deadlineRow(rule) }
        }.fixedSize(horizontal: false, vertical: true).frame(minHeight: 44, alignment: .leading)
            .accessibilityIdentifier("template.preview.work.\(work.id)")
    }
    private func linkRow(_ link: ProjectTemplateWorkLink) -> some View {
        Label("引用：\(names[link.source.id] ?? "关联内容")\(link.isRequired ? "（必需）" : "")", systemImage: "link")
            .font(.caption).fixedSize(horizontal: false, vertical: true)
    }
    @ViewBuilder private func deadlineRow(_ rule: ProjectTemplateDeadlineRule) -> some View {
        if let deadline, let zone = TimeZone(identifier: timeZoneID) {
            let anchor = dateOnly ? (try? Workspace.dateOnlyDeadline(on: deadline, timeZoneID: timeZoneID)) ?? deadline : deadline
            var calendar = Calendar(identifier: .gregorian)
            let _ = calendar.timeZone = zone
            switch rule {
            case .calendarDays(let days):
                if let shifted = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: anchor)),
                   let due = try? Workspace.dateOnlyDeadline(on: shifted, timeZoneID: timeZoneID) {
                    ProjectDeadlineDisplay(date: due, timeZoneID: timeZoneID, dateOnly: true).font(.caption)
                }
            case .seconds(let seconds):
                ProjectDeadlineDisplay(date: anchor.addingTimeInterval(seconds), timeZoneID: timeZoneID, dateOnly: false).font(.caption)
            }
        } else {
            switch rule {
            case .calendarDays(let days):
                Text(days == 0 ? "截止：与项目同一天" : "截止：项目截止\(days < 0 ? "前" : "后") \(abs(days)) 天")
                    .font(.caption).foregroundStyle(.secondary)
            case .seconds(let seconds):
                Text(seconds == 0 ? "截止：与项目同一时间" : "截止：项目截止\(seconds < 0 ? "前" : "后") \(minutesLabel(Int(abs(seconds) / 60)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
