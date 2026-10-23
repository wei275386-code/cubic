import SwiftUI
import CubicCore

@MainActor @Observable final class AppModel {
    var workspace = Workspace.empty { didSet { cachedProjectScopes = nil; cachedItemProjects = nil; cachedBusinessNames = nil } }
    @ObservationIgnored private var cachedProjectScopes: [String: Set<String>]?
    @ObservationIgnored private var cachedItemProjects: [String: Set<String>]?
    @ObservationIgnored private var cachedBusinessNames: [String: String]?
    var snapshot: EngineSnapshot? { didSet { presentedRisks = PlanningDisplay.risks(snapshot?.risks ?? []) } }
    var planning: PlanningSnapshot? {
        didSet {
            let proofs = planning?.certificates ?? []
            certificateGroups = PlanningDisplay.certificates(proofs)
            latestStartSuggestions = PlanningDisplay.latestStartSuggestions(PlanningDisplay.boundaries(planning?.boundaries ?? []))
            riskCertificateGroups = PlanningDisplay.certificatesByRisk(proofs)
            planningConditionsByID = Dictionary((planning?.conditions ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            planningUnknownsByObject = Dictionary(grouping: planning?.unknowns ?? [], by: \.objectID)
        }
    }
    private(set) var planningConditionsByID: [String: PlanningCondition] = [:]
    private(set) var planningUnknownsByObject: [String: [PlanningUnknown]] = [:]
    private(set) var riskCertificateGroups: [PlanningDisplay.RiskKey: [PlanningDisplay.CertificateGroup]] = [:]
    private(set) var presentedRisks: [Risk] = []
    private var planningVisibility: PlanningDisplay.PlanningVisibility {
        PlanningDisplay.PlanningVisibility(workspace: workspace) { relatedProjectIDs(for: $0) }
    }
    var visiblePlanningRisks: [Risk] {
        planningVisibility.risks(snapshot?.risks ?? [], certificates: planning?.certificates ?? [], unknowns: planning?.unknowns ?? [])
    }
    func visiblePlanningUnknowns(_ unknowns: [PlanningUnknown]) -> [PlanningUnknown] {
        planningVisibility.unknowns(unknowns)
    }
    func visiblePlanningCertificates(_ certificates: [PlanningCertificate]) -> [PlanningCertificate] {
        planningVisibility.certificates(certificates)
    }
    /// 日历“建议的最晚开始时间”投影：每项叶子工作一行，折叠节点聚合与分层重复。
    private(set) var latestStartSuggestions: [PlanningDisplay.LatestStartSuggestion] = []
    private(set) var certificateGroups: [PlanningDisplay.CertificateGroup] = []
    var notices: [RiskNotice] = []
    /// 旧数据重新解释的一次性提示；确认后写偏好并不再显示。
    var acceptanceNotice: String?
    var openingNoticeID: String?
    var calendarBridge: CalendarBridge?
    private var calendarBridgeGeneration = 0
    private var externalCalendarInputRevision = 0
    private var calendarPreferencesRevision = 0
    private var externalCalendarSnapshot = CalendarSnapshot() {
        didSet {
            // A successful refresh timestamp alone is not a new Calendar input.
            if oldValue.events != externalCalendarSnapshot.events || oldValue.calendars != externalCalendarSnapshot.calendars ||
                oldValue.authorized != externalCalendarSnapshot.authorized || oldValue.missingCalendarIDs != externalCalendarSnapshot.missingCalendarIDs {
                externalCalendarInputRevision += 1
            }
        }
    }
    private var calendarStorageReady: Bool { !loading && store != nil }
    private var calendarIntegrationSourceVersion: String {
        "\(revision):\(planningContextRevision):\(calendarPreferencesRevision):\(externalCalendarInputRevision):\(calendarBridgeGeneration):\(calendarBridge?.boundCalendarID ?? ""):\(calendarStorageReady)"
    }
    private(set) var syncState = SyncState()
    private var store: WorkspaceStore?
    /// Version of the published `workspace`; saves based on an older version are rejected.
    private var documentVersion: String?
    @ObservationIgnored private var syncLoop: Task<Void, Never>?
    private var syncing = false
    private var syncAgain = false
    @ObservationIgnored private var writeWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    nonisolated private static var calendarBridgeID: String { workCalendarQAMode ? "cubic.work-calendar.qa.local" : "cubic.primary.local" }
    #if DEBUG
    @ObservationIgnored private var testingDefaults: UserDefaults?
    @ObservationIgnored private var isIntegrationTest = false
    #endif
    private var syncDefaults: UserDefaults {
        #if DEBUG
        if let testingDefaults { return testingDefaults }
        #endif
        return Self.workCalendarQAMode ? UserDefaults(suiteName: "cubic.work-calendar.qa.sync")! : .standard
    }
    var fileSyncConnection: FileSyncConnection? {
        guard let data = syncDefaults.data(forKey: "cubic.sync.folder") else { return nil }
        return try? JSONDecoder().decode(FileSyncConnection.self, from: data)
    }
    var syncDirectoryLabel: String? { fileSyncConnection?.directoryLabel }
    var loading = true
    var loadFailure: String?
    var saving = false
    private var messagePages: [UUID] = []
    private var modalMessageHosts: [UUID] = []
    private(set) var messageContextVersion = 0
    var activeModalCount: Int { modalMessageHosts.count }
    var errorMessage: String? { didSet { errorTitle = "操作未完成" } }
    private(set) var errorTitle = "操作未完成"
    var statusMessage: String?
    private(set) var serviceIssues: [String: String] = [:]
    var primaryServiceIssue: String? { serviceIssues.keys.sorted().first }
    var preferences = UserPreferences.load() { didSet { calendarPreferencesRevision += 1 } }
    var calendar = CalendarSnapshot() { didSet { calendarSnapshotRevision += 1 } }
    private var calendarSnapshotRevision = 0
    private var planningContextRevision = 0
    var now = Date()
    var visibleCapacitySlots: [CapacitySlot] = []
    var isRefreshing = false
    var calculationIsStale = false
    var calculationUpdatedAt: Date?
    var sourceVersion: String { "\(revision):\(refreshGeneration):\(calendarSnapshotRevision):\(planningContextRevision)" }
    var dataVersion: Int { revision }
    private var loaded = false
    private var revision = 0
    private var refreshGeneration = 0
    private let storeURL: URL
    nonisolated private static var workCalendarQAMode: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-CubicWorkCalendarQA")
        #else
        false
        #endif
    }
    private static var resetWorkCalendarQA: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-CubicWorkCalendarQAReset")
        #else
        false
        #endif
    }
    private let calendarReader = CalendarReader()
    private let reminders = ReminderService()
    private var noticeRefreshGeneration = 0

    init() {
        let documents = URL.documentsDirectory
        if Self.workCalendarQAMode {
            let qaDirectory = documents.appendingPathComponent("CubicQA")
            if Self.resetWorkCalendarQA {
                try? FileManager.default.removeItem(at: qaDirectory)
                UserDefaults(suiteName: "cubic.work-calendar.qa.sync")?.removePersistentDomain(forName: "cubic.work-calendar.qa.sync")
            }
            storeURL = qaDirectory.appendingPathComponent("work-calendar.json")
            preferences = syncDefaults.data(forKey: "cubic.preferences") == nil ? Self.workCalendarQAPreferences(now: Date()) : UserPreferences.load(defaults: syncDefaults)
        } else {
            storeURL = documents.appendingPathComponent("Cubic/workspace.json")
        }
    }
    #if DEBUG
    /// Isolated composition seam for testing the REAL AppModel; never touches Documents or system services.
    init(testDirectory: URL, defaults: UserDefaults, workspace: Workspace = .empty) async throws {
        storeURL = testDirectory.appendingPathComponent("workspace.json")
        testingDefaults = defaults
        isIntegrationTest = true
        let store = try WorkspaceStore(url: storeURL, deviceID: "test-device")
        self.store = store
        await publish(try await store.save(workspace: workspace))
        preferences.calendarEnabled = false; preferences.remindersEnabled = false
        preferences.workScheduleConfigured = true; preferences.workTimeZoneID = TimeZone.current.identifier
        preferences.workWeekends = true
        preferences.workPeriods = [WorkPeriod(id: "test", startMinute: 0, endMinute: 1440, energy: "normal")]
        loading = false; loaded = true
    }
    #endif
    private static func workCalendarQAPreferences(now: Date) -> UserPreferences {
        var value = UserPreferences()
        value.calendarEnabled = false
        value.workScheduleConfigured = true
        value.workTimeZoneID = TimeZone.current.identifier
        value.demoCapacityStart = now.addingTimeInterval(5 * 60)
        value.demoScenarioVersion = nil
        value.workPeriods = [WorkPeriod(id: "qa-all-day", startMinute: 0, endMinute: 24 * 60, energy: "normal")]
        return value
    }
    private static func workCalendarQAWorkspace(now: Date) -> Workspace {
        let start = now.addingTimeInterval(5 * 60)
        let deadline = start.addingTimeInterval(4 * 60 * 60)
        return Workspace(
            projects: [Project(id: "qa-project", name: "QA 工作删除与日历", deadline: deadline, importance: 5, planningCompleteness: .complete)],
            nodes: [Node(id: "qa-node", projectID: "qa-project", name: "QA 交付")],
            items: [WorkItem(id: "qa-drag", name: "QA 拖拽时间块", nodeID: "qa-node", projectIDs: ["qa-project"], remainingMinutes: 45),
                    WorkItem(id: "qa-delete", name: "QA 删除工作", nodeID: "qa-node", projectIDs: ["qa-project"], remainingMinutes: 30),
                    WorkItem(id: "qa-keep", name: "QA 保留工作", nodeID: "qa-node", projectIDs: ["qa-project"], remainingMinutes: 30)],
            dependencies: [Dependency(id: "qa-delete-to-keep", source: .item("qa-delete"), targetItemID: "qa-keep", createdAt: now, effectiveAt: now)]
        )
    }
    func boot() async {
        guard !loaded else { return }
        loaded = true
        do {
            let date = Date(), url = storeURL, deviceID = Self.deviceID(syncDefaults)
            let opened = try await Task.detached(priority: .userInitiated) { try WorkspaceStore(url: url, deviceID: deviceID) }.value
            store = opened
            var document = await opened.document
            if Self.workCalendarQAMode, Self.resetWorkCalendarQA || opened.isNew {
                document = try await opened.save(workspace: Self.workCalendarQAWorkspace(now: date))
            }
            if !Self.workCalendarQAMode, !opened.isNew, preferences.acceptanceNoticeAcknowledged != true,
               document.workspace.needsAcceptanceReinterpretationNotice {
                acceptanceNotice = "验收规则已更新：没有添加验收条件的节点，在必需工作完成后即视为验收通过；以前标记为“非必需”的验收条件现在按必需处理。"
            }
            if !Self.workCalendarQAMode, preferences.workTimeZoneID == nil { preferences.workTimeZoneID = TimeZone.current.identifier; preferences.save() }
            if !Self.workCalendarQAMode, opened.isNew {
                preferences.demoCapacityStart = nil
                preferences.demoScenarioVersion = nil
                preferences.workTimeZoneID = TimeZone.current.identifier
                preferences.save()
            }
            // Settings saved before they were part of the document start syncing from this device.
            if document.preferences.isEmpty {
                document = try await opened.save(preferences: preferences.syncValues(calendars: calendar.calendars))
            }
            await publish(document)
            loading = false
            ensureCalendarBridge()
            startSync()
            await refresh()
        } catch { loadFailure = "无法读取本地数据：\(error.localizedDescription)" }
        loading = false
        resumeWriteWaiters()
    }
    private static func deviceID(_ defaults: UserDefaults) -> String {
        if let id = defaults.string(forKey: "cubic.sync.deviceID") { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: "cubic.sync.deviceID")
        return id
    }
    func retryLoad() async { loaded = false; loading = true; loadFailure = nil; await boot() }
    func item(_ id: String) -> WorkItem? { workspace.items.first { $0.id == id } }
    func acknowledgeAcceptanceNotice() {
        acceptanceNotice = nil
        preferences.acceptanceNoticeAcknowledged = true
        preferences.save()
    }
    func enterMessagePage(_ id: UUID) {
        guard !messagePages.contains(id) else { return }
        messagePages.append(id)
        invalidateActionMessages()
    }
    func leaveMessagePage(_ id: UUID) {
        let wasCurrent = messagePages.last == id
        messagePages.removeAll { $0 == id }
        if wasCurrent { invalidateActionMessages() }
    }
    func enterModalMessageHost(_ id: UUID) {
        guard !modalMessageHosts.contains(id) else { return }
        modalMessageHosts.append(id)
        invalidateActionMessages()
    }
    func leaveModalMessageHost(_ id: UUID) {
        let wasCurrent = modalMessageHosts.last == id
        modalMessageHosts.removeAll { $0 == id }
        if wasCurrent { invalidateActionMessages() }
    }
    func isCurrentModalMessageHost(_ id: UUID) -> Bool { modalMessageHosts.last == id }
    private func invalidateActionMessages() {
        messageContextVersion += 1
        errorMessage = nil
        statusMessage = nil
    }
    func reportFailure(_ title: String, message: String, context: Int? = nil) {
        guard !Task.isCancelled, context == nil || context == messageContextVersion else { return }
        statusMessage = nil
        errorMessage = message
        errorTitle = title
    }
    private func reportStatus(_ message: String, context: Int) {
        guard context == messageContextVersion else { return }
        statusMessage = message
    }
    var pendingInboxItems: [WorkItem] {
        workspace.items.filter { $0.projectIDs.isEmpty && $0.nodeID == nil && $0.description == nil && !$0.archived && $0.effectiveDisposition == .active && $0.status != .completed }
    }
    func isBlocked(_ id: String) -> Bool { snapshot?.itemStates.first { $0.itemID == id }?.isBlocked ?? true }
    func relatedProjectIDs(for item: WorkItem) -> Set<String> {
        prepareProjectScopes()
        return (cachedItemProjects?[item.id] ?? []).union(item.projectIDs)
    }
    func projectNames(for item: WorkItem) -> String {
        let ids = relatedProjectIDs(for: item)
        let names = workspace.projects.filter { ids.contains($0.id) }.map(\.name)
        return names.isEmpty ? "独立待办" : names.joined(separator: " · ")
    }
    func projectItemIDs(_ projectID: String) -> Set<String> {
        prepareProjectScopes()
        return cachedProjectScopes?[projectID] ?? []
    }
    private func prepareProjectScopes() {
        let current = workspace // Keep Observation tied to the workspace even when cached.
        guard cachedProjectScopes == nil else { return }
        let incoming = Dictionary(grouping: current.dependencies.filter(\.isActive), by: \.targetItemID)
        let members = Dictionary(grouping: current.items.filter { $0.nodeID != nil }, by: { $0.nodeID! })
        let links = (current.workLinks ?? []).filter { $0.removedAt == nil }
        let nodeLinks = Dictionary(grouping: links.filter { $0.nodeID != nil }, by: { $0.nodeID! })
        let projectLinks = Dictionary(grouping: links, by: \.projectID)
        let projectNodes = Dictionary(grouping: current.nodes, by: \.projectID)
        let directItems = current.items.reduce(into: [String: [String]]()) { map, item in
            for projectID in item.projectIDs { map[projectID, default: []].append(item.id) }
        }
        var scopes: [String: Set<String>] = [:], reverse: [String: Set<String>] = [:]
        for project in current.projects {
            var queue: [WorkReference] = (directItems[project.id] ?? []).map(WorkReference.item)
            queue += (projectNodes[project.id] ?? []).map { .node($0.id) }
            queue += (projectLinks[project.id] ?? []).map(\.source)
            var itemIDs = Set<String>(), nodeIDs = Set<String>(), position = 0
            while position < queue.count {
                let reference = queue[position]; position += 1
                switch reference {
                case .item(let id):
                    guard itemIDs.insert(id).inserted else { continue }
                    for dependency in incoming[id] ?? [] {
                        switch dependency.source {
                        case .item(let source): queue.append(.item(source))
                        case .node(let source): queue.append(.node(source))
                        case .blocker: break
                        }
                    }
                case .node(let id):
                    guard nodeIDs.insert(id).inserted else { continue }
                    queue += (members[id] ?? []).map { .item($0.id) }
                    queue += (nodeLinks[id] ?? []).map(\.source)
                }
            }
            scopes[project.id] = itemIDs
            for itemID in itemIDs { reverse[itemID, default: []].insert(project.id) }
        }
        cachedProjectScopes = scopes; cachedItemProjects = reverse
    }
    /// UI callers await readiness here, never poll or replay their business command.
    func mutateWhenReady(_ change: @escaping (inout Workspace) throws -> Void) async -> Bool {
        let context = messageContextVersion
        while saving || loading {
            let waiter = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled { continuation.resume() }
                    else { writeWaiters[waiter] = continuation }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.writeWaiters.removeValue(forKey: waiter)?.resume() }
            }
            guard !Task.isCancelled, context == messageContextVersion else { return false }
        }
        guard !Task.isCancelled, context == messageContextVersion else { return false }
        return await mutate(change)
    }
    private func resumeWriteWaiters() {
        let waiters = writeWaiters; writeWaiters = [:]
        for continuation in waiters.values { continuation.resume() }
    }
    func mutate(allowWhileLoading: Bool = false, background: Bool = false, _ change: (inout Workspace) throws -> Void) async -> Bool {
        let messageContext = messageContextVersion
        guard !saving, !loading || allowWhileLoading, !Task.isCancelled else { return false }
        saving = true
        defer { finishWrite() }
        do {
            var candidate = workspace
            try change(&candidate)
            guard !Task.isCancelled else { return false }
            try await commit(candidate)
            serviceIssues["默认时间未能保存"] = nil
            return true
        } catch {
            let message = userMessage(for: error)
            if background { serviceIssues["默认时间未能保存"] = message }
            else { reportFailure("修改未保存", message: message, context: messageContext) }
            return false
        }
    }
    func mutateProjectTemplate(_ mutation: ProjectTemplateMutation) async -> String? {
        let messageContext = messageContextVersion
        guard !saving, !loading, !Task.isCancelled else { return nil }
        saving = true
        defer { finishWrite() }
        let snapshot = workspace, sourceVersion = revision, timestamp = Date()
        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                try mutation.prepare(in: snapshot, now: timestamp)
            }.value
            guard !Task.isCancelled else { return nil }
            guard revision == sourceVersion else { throw CoreError.blocked("项目内容已变化，请重新查看预览后保存。") }
            try await commit(prepared.workspace)
            return prepared.id
        } catch {
            reportFailure("修改未保存", message: userMessage(for: error), context: messageContext)
            return nil
        }
    }
    /// Saves locally, publishes the result and schedules a folder sync. Callers hold `saving`.
    private func commit(_ value: Workspace) async throws {
        guard let store else { throw CoreError.invalid("本机保存服务尚未准备好。草稿仍保留，请重新打开 app。") }
        var value = value
        try value.applyDefaultRemainingEstimates(now: Date())
        let document = try await store.save(workspace: value, basedOn: documentVersion)
        await publish(document)
        scheduleSync()
    }
    private func userMessage(for error: Error) -> String {
        if case CoreError.cycle(let path) = error {
            let names = path.map { key -> String in
                let id = ["item:", "node:", "blocker:"].first(where: { key.hasPrefix($0) }).map { String(key.dropFirst($0.count)) } ?? key
                return item(id)?.name ?? workspace.nodes.first { $0.id == id }?.name ?? workspace.blockers.first { $0.id == id }?.name ?? id
            }
            return "这条关系会形成循环：" + names.joined(separator: " → ") + "。请调整其中一个前置，草稿仍保留。"
        }
        if case CoreError.blocked(let message) = error, message.hasPrefix("item: ") {
            let id = String(message.dropFirst("item: ".count))
            return "\(item(id)?.name ?? "这项工作")还有前置条件或成果复核未处理，请到工作详情检查。"
        }
        return error.localizedDescription
    }
    private func finishWrite() {
        saving = false
        resumeWriteWaiters()
    }
    func refresh(background: Bool = true) async {
        #if DEBUG
        if isIntegrationTest { return }
        #endif
        let messageContext = messageContextVersion
        ensureCalendarBridge()
        if preferences.calendarEnabled {
            if preferences.syncedCalendarSelection != nil {
                let available = await calendarReader.read(from: Date(), to: Date(), selectedIDs: [])
                preferences.resolveCalendarSelection(in: available.calendars)
                preferences.save(defaults: syncDefaults)
            }
            externalCalendarSnapshot = await calendarReader.read(from: Calendar.current.startOfDay(for: Date()), to: horizon(from: Date()), selectedIDs: preferences.selectedCalendarIDs, excludingCalendarID: calendarBridge?.boundCalendarID)
        } else {
            // Keep authorized calendar identities available even when occupancy is disabled.
            externalCalendarSnapshot = await calendarReader.read(from: Date(), to: Date(), selectedIDs: [])
            if externalCalendarSnapshot.authorized { preferences.resolveCalendarSelection(in: externalCalendarSnapshot.calendars) }
        }
        await calendarBridge?.refresh()
        updateCalendarIntegrationSnapshot()
        if !saving, store != nil, !workspace.defaultEstimateItemIDs.isEmpty {
            if await mutate(allowWhileLoading: true, background: true, { _ in }) {
                serviceIssues["默认时间未能保存"] = nil
                return
            }
        }
        if background && isRefreshing { return }
        refreshGeneration += 1
        if !background || snapshot == nil { isRefreshing = true }
        let generation = refreshGeneration
        defer { if generation == refreshGeneration { isRefreshing = false } }
        now = Date()
        let requestRevision = revision
        let requestContext = planningContextRevision
        let date = now
        let input = await planningInput(date: date)
        guard generation == refreshGeneration, revision == requestRevision, planningContextRevision == requestContext else { return }
        visibleCapacitySlots = input.input.slots
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try Engine.plan(workspace: input.workspace, input: input.input)
            }.value
            guard revision == requestRevision, generation == refreshGeneration, planningContextRevision == requestContext else { return }
            planning = result
            snapshot = result.legacy
            calculationUpdatedAt = date
            calculationIsStale = false
            serviceIssues["排期未能更新"] = nil
            await updateNotices(using: result)
            await scheduleReminders()
        } catch {
            guard revision == requestRevision, generation == refreshGeneration, planningContextRevision == requestContext else { return }
            calculationIsStale = true
            let message = "\(error.localizedDescription) 请检查相关设置后下拉刷新。已有工作记录保留。"
            serviceIssues["排期未能更新"] = message
            if !background { reportFailure("排期未能更新", message: message, context: messageContext) }
        }
    }
    func trial(itemID: String, minutes: Int) async -> TrialResult? {
        let messageContext = messageContextVersion
        let version = sourceVersion
        let date = Date()
        let input = await calculationInput(date: date)
        do {
            var result = try await Task.detached(priority: .userInitiated) {
                try Engine.trial(workspace: input.workspace, selections: [TrialSelection(itemID: itemID, minutes: minutes)], slots: input.slots, now: date)
            }.value
            guard sourceVersion == version else { return nil }
            markMissingCalendar(&result.snapshot)
            return result
        } catch {
            guard sourceVersion == version else { return nil }
            reportFailure("试算未完成", message: "\(error.localizedDescription) 请调整试算内容后重试。", context: messageContext)
            return nil
        }
    }
    private func markMissingCalendar(_ result: inout EngineSnapshot) {
        var reasons: [String] = []
        if preferences.demoCapacityStart == nil {
        if !preferences.hasDeclaredWorkSchedule { reasons.append("工作时段尚未保存，请到设置调整并保存。") }
        if !preferences.calendarEnabled {
            reasons.append("尚未启用日历，目前只按手动工作时段计算空档。")
        } else if !calendar.authorized {
            reasons.append("日历读取未授权或已撤权，外部占用尚未计入。")
        }
        if !calendar.missingCalendarIDs.isEmpty { reasons.append("部分所选日历来源在本设备不可用，不能假定该来源完全空闲。") }
        if let fetched = calendar.fetchedAt, Date().timeIntervalSince(fetched) > 300 { reasons.append("日历数据已过时，当前结果未完成最新占用核对。") }
        if calendar.events.contains(where: { event in
            let rule = preferences.rule(for: event.calendarID)
            return (event.allDay && rule.allDay == .uncertain) || (!event.availabilityKnown && rule.unknownAvailability == .uncertain)
        }) { reasons.append("所选来源存在未确认的全天或忙闲规则，已保守计入占用；请在设置确认。") }
        }
        if let bridge = calendarBridge, bridge.enabled {
            if !bridge.pausedBlockIDs.isEmpty { reasons.append("Apple Calendar 时间块尚未核实，待确认时间块不参与条件性未来进展。") }
            if !bridge.status.authorized { reasons.append("Apple Calendar 双向同步权限不可用，外部占用未核实。") }
            if bridge.status.phase == .unavailable { reasons.append("绑定的 Cubic 日历暂不可用，当前安排尚未完成核对。") }
        }
        guard !reasons.isEmpty else { return }
        for reason in reasons { result.risks.append(Risk(kind: .insufficientInformation, message: reason)) }
        if result.feasibility == .feasible { result.feasibility = .undetermined }
        for i in result.projects.indices where result.projects[i].feasibility == .feasible { result.projects[i].feasibility = .undetermined }
    }
    func savePreferences(_ value: UserPreferences) async -> Bool {
        let messageContext = messageContextVersion
        guard !saving, !loading else { reportStatus("正在保存，请稍后再保存设置。", context: messageContext); return false }
        saving = true
        defer { finishWrite() }
        do {
            try value.validate()
            var candidate = value
            candidate.workScheduleConfigured = true
            candidate.workTimeZoneID = value.workTimeZoneID ?? TimeZone.current.identifier
            candidate.demoCapacityStart = nil
            guard let store else { throw CoreError.invalid("本机保存服务尚未准备好，请稍后再保存设置。") }
            let document = try await store.save(preferences: candidate.syncValues(calendars: calendar.calendars))
            preferences = candidate
            preferences.save(defaults: syncDefaults)
            await publish(document)
            scheduleSync()
            revision += 1
            await scheduleReminders()
            await refresh()
            return true
        } catch { reportFailure("设置未保存", message: error.localizedDescription, context: messageContext); return false }
    }
    func enableCalendar() async {
        let messageContext = messageContextVersion
        do {
            let allowed = try await calendarReader.requestAccess()
            if allowed {
                calendar = await calendarReader.read(from: Date(), to: horizon(from: Date()), selectedIDs: preferences.selectedCalendarIDs ?? [])
            } else { reportStatus("未获得日历权限，仍可使用手动设置的工作时段。", context: messageContext) }
        } catch { reportFailure("日历权限未能开启", message: error.localizedDescription, context: messageContext) }
    }
    func enableReminders() async {
        let messageContext = messageContextVersion
        do {
            if !(try await reminders.enable()) { reportStatus("提醒权限未开启，可在系统设置中调整。", context: messageContext) }
        } catch { reportFailure("提醒权限未能开启", message: error.localizedDescription, context: messageContext) }
    }
    private func updateNotices(using planning: PlanningSnapshot) async {
        let value = workspace, date = Date(), expectedRevision = revision
        let changes = await Task.detached { RiskNoticeEngine.changes(workspace: value, planning: planning, now: date) }.value
        guard expectedRevision == revision else { return }
        if !changes.isEmpty && !saving {
            saving = true
            defer { finishWrite() }
            do {
                var candidate = workspace
                for notice in changes { candidate.history.append(try RiskNoticeEngine.event(notice, at: date)) }
                try await commit(candidate)
                serviceIssues["提醒记录未能更新"] = nil
            } catch { serviceIssues["提醒记录未能更新"] = "\(error.localizedDescription) 下次刷新会重试。" }
        }
        await refreshStoredNotices()
    }
    func markNoticeRead(_ id: String) async {
        guard var notice = notices.first(where: { $0.id == id }) else { return }
        notice.isRead = true; notice.snoozedUntil = nil; notice.changedAt = Date()
        await saveNotice(notice)
    }
    func snoozeNotice(_ id: String, until date: Date) async {
        guard var notice = notices.first(where: { $0.id == id }), !notice.isResolved else { return }
        notice.snoozedUntil = date; notice.changedAt = Date()
        await saveNotice(notice)
    }
    private func saveNotice(_ notice: RiskNotice) async {
        _ = await mutate { $0.history.append(try RiskNoticeEngine.event(notice, at: notice.changedAt)) }
        // A persisted acknowledgement must cancel its alert even if planning fails.
        await refreshStoredNotices()
        await scheduleReminders()
    }
    private func refreshStoredNotices() async {
        #if DEBUG
        if isIntegrationTest { return }
        #endif
        noticeRefreshGeneration += 1
        let generation = noticeRefreshGeneration
        let current = workspace
        let stored = await Task.detached { RiskNoticeEngine.stored(in: current) }.value
        guard generation == noticeRefreshGeneration else { return }
        notices = stored
    }
    private func scheduleReminders() async {
        #if DEBUG
        if isIntegrationTest { return }
        #endif
        let requests = preferences.remindersEnabled ? notices.compactMap { notice -> FollowUpReminder? in
            guard preferences.allowsReminder(kind: notice.kind), let date = notice.nextNotificationDate, !notice.isResolved else { return nil }
            return FollowUpReminder(id: notice.id, title: "\(NoticeCopy.title(notice)) · \(NoticeCopy.summary(notice))", date: date, noticeID: notice.id)
        } : []
        do { try await reminders.replace(requests); serviceIssues["通知提醒未能更新"] = nil }
        catch { serviceIssues["通知提醒未能更新"] = "\(error.localizedDescription) 稍后刷新会重试；App 内的待处理事项仍可查看。" }
    }
    func planningTrial(itemID: String, minutes: Int?, start: Date? = nil, counterfactual: Bool = false, reportErrors: Bool = true) async -> PlanningTrialResult? {
        let messageContext = messageContextVersion
        let version = sourceVersion
        let input = await planningInput(date: Date())
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try Engine.trial(workspace: input.workspace,
                                 request: PlanningTrialRequest(itemID: itemID, minutes: minutes, start: start, counterfactual: counterfactual), input: input.input)
            }.value
            guard result.source.input.revision.workspace == String(revision), result.source.input.revision.capacity == sourceVersion else {
                if reportErrors { reportFailure("请重新查看试算", message: "数据在计算期间发生变化，请查看刷新后的试算再确认。", context: messageContext) }
                return nil
            }
            return result
        } catch {
            guard sourceVersion == version else { return nil }
            if reportErrors { reportFailure("试算未完成", message: error.localizedDescription, context: messageContext) }
            return nil
        }
    }
    func chooseNextAction(itemID: String?, note: String = "") async -> Bool {
        let ids = itemID.map { [$0] } ?? []
        let version = sourceVersion
        let context = ChoiceContext(date: Date(), displayedItems: ids.compactMap { item($0) }, projects: workspace.projects, dataVersion: version)
        return await mutate { workspace in
            let now = Date()
            try workspace.chooseNextAction(itemID: itemID, now: now, displayedItemIDs: ids, dataVersion: version, note: note)
            if let choiceID = workspace.currentNextAction?.id {
                workspace.history.append(HistoryEvent(date: now, kind: .choiceRecorded, objectID: choiceID,
                                                      note: "当时查看的可选工作", detail: String(decoding: try JSONCoding.encode(context), as: UTF8.self)))
            }
        }
    }
    @ObservationIgnored private var storedChoiceConfirmation: PlanningChoiceConfirmation?
    private var choiceConfirmation: PlanningChoiceConfirmation {
        if let storedChoiceConfirmation { return storedChoiceConfirmation }
        let operation = PlanningChoiceConfirmation(
        calculate: { [weak self] request in
            await self?.planningTrial(itemID: request.itemID, minutes: request.minutes, start: request.start,
                                      counterfactual: request.counterfactual, reportErrors: false)
        },
        sourceIsCurrent: { [weak self] result in
            guard let self else { return false }
            return result.source.input.revision.workspace == String(self.revision) &&
                result.source.input.revision.capacity == self.sourceVersion
        },
        commit: { [weak self] result, note in
            guard let self else { throw CancellationError() }
            try await self.commitPlanningChoice(result, note: note)
        })
        storedChoiceConfirmation = operation
        return operation
    }

    func confirmDisplayedTrial(presentationID: UUID, displayed: PlanningTrialResult, request: PlanningTrialRequest,
                              note: String, isCurrent: @escaping @MainActor () -> Bool) async -> PlanningChoiceConfirmation.Outcome {
        let context = messageContextVersion
        let outcome = await choiceConfirmation.confirm(presentationID: presentationID, displayed: displayed,
                                                       request: request, note: note, isCurrent: isCurrent)
        if case .unavailable(let message?) = outcome, isCurrent() {
            reportFailure("确认未完成", message: message, context: context)
        }
        return outcome
    }
    private func commitPlanningChoice(_ result: PlanningTrialResult, note: String) async throws {
        let scenario = result.scenario ?? result.baseline
        let savedTrial = result.request.minutes.map { minutes in
            TrialResult(selections: [TrialSelection(itemID: result.request.itemID, minutes: minutes)], allocations: result.allocations,
                        unallocatedMinutes: result.unallocatedMinutes ?? 0, snapshot: scenario.legacy)
        }
        let ids = Array(Set([result.request.itemID] + result.impacts.flatMap(\.itemIDs))).sorted()
        let version = sourceVersion
        guard result.source.input.revision.workspace == String(revision), result.source.input.revision.capacity == sourceVersion else {
            throw CoreError.blocked("源数据刚刚发生变化，请查看刷新后的影响再确认。")
        }
        guard !saving, !loading, !Task.isCancelled else { throw CoreError.blocked("正在保存，请稍后重试。") }
        saving = true
        defer { finishWrite() }
        var candidate = workspace
        try recordChoice(&candidate)
        guard !Task.isCancelled else { throw CancellationError() }
        try await commit(candidate)

        func recordChoice(_ workspace: inout Workspace) throws {
            let now = Date()
            try workspace.chooseNextAction(itemID: result.request.itemID, now: now, trial: savedTrial,
                                           displayedItemIDs: ids, dataVersion: version, impactWasVerified: savedTrial != nil, note: note)
            if let id = workspace.currentNextAction?.id {
                workspace.history.append(HistoryEvent(date: now, kind: .choiceRecorded, objectID: id,
                                                      note: "当时的试算条件与结果", detail: String(decoding: try JSONCoding.encode(result), as: UTF8.self)))
            }
        }
    }
    private func planningInput(date: Date) async -> (workspace: Workspace, input: PlanningInput) {
        var original = workspace
        original.timeBlocks?.removeAll { calendarBridge?.pausedBlockIDs.contains($0.id) == true }
        let settings = preferences, calendarValue = calendar
        let issues = capacityIssues()
        let version = sourceVersion
        let workspaceRevision = String(revision)
        let value = await Task.detached(priority: .userInitiated) { [original, settings, calendarValue, date] in
            Self.buildCalculationInput(workspace: original, preferences: settings, calendar: calendarValue, date: date)
        }.value
        let input = PlanningInput(slots: value.slots, now: date, horizonEnd: Self.planningHorizon(workspace: original, date: date),
                                  revision: PlanningRevision(workspace: workspaceRevision, capacity: version,
                                                             calendar: calendarValue.fetchedAt.map { String($0.timeIntervalSince1970) } ?? "unavailable", time: version),
                                  options: PlanningOptions(capacityVerified: issues.isEmpty, capacityNote: issues.isEmpty ? nil : issues.joined(separator: " ")))
        return (value.workspace, input)
    }
    func saveTimeBlock(_ block: WorkTimeBlock) async -> Bool {
        guard !saving, !loading else { return false }
        let version = sourceVersion
        let value = await planningInput(date: Date())
        guard version == sourceVersion else {
            reportFailure("时间块未保存", message: "工作或日历刚刚更新，请重新放置。")
            return false
        }
        return await mutate { try $0.setTimeBlock(block, slots: value.input.slots, busy: value.input.busy, now: Date()) }
    }
    func ensureCalendarBridge(eventStore: (any CalendarBridgeIO)? = nil) {
        guard calendarBridge == nil else { return }
        calendarBridgeGeneration += 1
        let generation = calendarBridgeGeneration
        calendarBridge = CalendarBridge(workspaceID: Self.calendarBridgeID, defaults: syncDefaults,
            context: { [weak self] in
                guard let self, self.calendarBridgeGeneration == generation else { return CalendarBridgeContext(workspace: .empty, slots: [], externalBusy: [], capacityVerified: false) }
                return await self.calendarIntegrationContext()
            }, applyExternal: { [weak self] block, expected, eventID in
                guard let self, self.calendarBridgeGeneration == generation else { throw CoreError.invalid("日历连接已重置，请重新核对。") }
                try await self.applyCalendarTimeBlock(block, expected: expected, excludingEventID: eventID)
            }, removeBlock: { [weak self] id in
                guard let self, self.calendarBridgeGeneration == generation else { throw CoreError.invalid("日历连接已重置，请重新核对。") }
                guard !self.saving, !self.loading else { throw CoreError.invalid("正在保存，请稍后重试。") }
                guard await self.mutate({ try $0.removeTimeBlock(id: id, now: Date()) }) else {
                    throw CoreError.invalid(self.errorMessage ?? "时间块未能保存，请重试。")
                }
            }, isContextCurrent: { [weak self] sourceRevision in
                guard let self, self.calendarBridgeGeneration == generation else { return false }
                return self.calendarIntegrationSourceVersion == sourceRevision
            }, eventStore: eventStore ?? CalendarBridgeStore())
        #if DEBUG
        if isIntegrationTest { return }
        #endif
        if !Self.workCalendarQAMode { calendarBridge?.start() }
    }
    private func calendarIntegrationContext() async -> CalendarBridgeContext {
        let original = workspace, settings = preferences
        var external = externalCalendarSnapshot
        external.events.removeAll { $0.calendarID == calendarBridge?.boundCalendarID }
        let version = calendarIntegrationSourceVersion, generation = calendarBridgeGeneration
        let slots = await Task.detached(priority: .userInitiated) { [original, settings, external] in
            Self.buildCalculationInput(workspace: original, preferences: settings, calendar: external, date: Date()).slots
        }.value
        return CalendarBridgeContext(workspace: original, slots: slots, externalBusy: [],
            capacityVerified: version == calendarIntegrationSourceVersion && generation == calendarBridgeGeneration && calendarStorageReady && (settings.hasDeclaredWorkSchedule || settings.demoCapacityStart != nil) &&
                (!settings.calendarEnabled || (external.authorized && external.missingCalendarIDs.isEmpty && external.fetchedAt.map { Date().timeIntervalSince($0) < 300 } == true)),
            storageReady: calendarStorageReady, sourceRevision: version)
    }
    private func applyCalendarTimeBlock(_ block: WorkTimeBlock, expected: WorkTimeBlock?, excludingEventID: String?) async throws {
        guard !saving, !loading else { throw CoreError.invalid("正在保存，请稍后重试。") }
        let generation = calendarBridgeGeneration
        let current = workspace.timeBlocks?.first { $0.id == block.id }
        if current == block { return } // The same fact may already have arrived through data sync.
        guard current == expected else { throw CoreError.invalid("Cubic 时间块也已修改，请刷新后确认双方时间。") }
        let context = await calendarIntegrationContext()
        guard !saving, generation == calendarBridgeGeneration, (workspace.timeBlocks?.first { $0.id == block.id }) == expected else {
            throw CoreError.invalid("工作刚刚更新，请重新核对后再接受。")
        }
        guard context.capacityVerified else { throw CoreError.invalid("日历容量尚未核实，请先检查工作时段和日历权限。") }
        let otherBusy = (calendarBridge?.validationBusyEvents ?? []).filter { $0.id != "cubic.bridge.\(excludingEventID ?? "")" }
            .map { BusyInterval(start: $0.start, end: $0.end) }
        var candidate = workspace
        try candidate.setTimeBlock(block, slots: context.slots, busy: context.externalBusy + otherBusy, now: Date())
        saving = true
        defer { finishWrite() }
        try await commit(candidate)
    }
    private func updateCalendarIntegrationSnapshot() {
        var value = externalCalendarSnapshot
        value.events.removeAll { $0.calendarID == calendarBridge?.boundCalendarID }
        if let bridge = calendarBridge, bridge.enabled {
            value.events += bridge.busyEvents
            value.authorized = bridge.status.authorized && (!preferences.calendarEnabled || value.authorized)
            if !preferences.calendarEnabled { value.fetchedAt = bridge.status.lastReconciledAt }
            serviceIssues["Apple Calendar 需要检查"] = bridge.status.phase == .needsPermission || bridge.status.phase == .unavailable ? bridge.status.message : nil
        } else { serviceIssues["Apple Calendar 需要检查"] = nil }
        if calendar != value { calendar = value }
    }
    func refreshCalendarBridge() async {
        ensureCalendarBridge()
        await refresh()
    }
    private func capacityIssues() -> [String] {
        var result = EngineSnapshot(availableActions: [], itemStates: [], risks: [], projects: [], capacityMinutes: 0, feasibility: .undetermined)
        markMissingCalendar(&result)
        return result.risks.map(\.message)
    }
    /// Applies a saved or downloaded document to the published state.
    private func publish(_ document: WorkspaceDocument) async {
        documentVersion = document.version
        let historyChanged = workspace.history != document.workspace.history
        var preferencesChanged = false
        do {
            let updated = try preferences.applyingSyncValues(document.preferences, calendars: calendar.calendars)
            if updated != preferences {
                preferences = updated
                preferences.save(defaults: syncDefaults)
                preferencesChanged = true
            }
            serviceIssues["同步设置需要检查"] = nil
        } catch { serviceIssues["同步设置需要检查"] = "收到的设置无法使用，请到设置检查后重新保存。\(error.localizedDescription)" }
        guard workspace != document.workspace || preferencesChanged else { return }
        workspace = document.workspace
        revision += 1
        calculationIsStale = true
        if historyChanged || preferencesChanged {
            await refreshStoredNotices()
            await scheduleReminders()
        }
        Task { await refresh() }
    }
    /// Polls the sync folder while the app is active.
    func startSync() {
        syncLoop?.cancel()
        guard fileSyncConnection != nil else { syncState = SyncState(); return }
        #if DEBUG
        if isIntegrationTest { return }
        #endif
        syncLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshSync()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
    func stopSync() { syncLoop?.cancel(); syncLoop = nil }
    private func scheduleSync() {
        guard fileSyncConnection != nil else { return }
        syncState.phase = .pending
        Task { await refreshSync() }
    }
    func refreshSync() async {
        guard let store, let connection = fileSyncConnection else { return }
        guard !syncing else { syncAgain = true; return }
        syncing = true
        defer { syncing = false }
        repeat {
            syncAgain = false
            do {
                let outcome = try await SyncFolder.withAccess(connection) { try await store.sync(folder: $0) }
                switch outcome {
                case .waitingForDownload:
                    syncState.phase = .waiting
                    continue
                case .downloaded, .conflict(keptThisDevice: false, _):
                    await publish(await store.document)
                default: break
                }
                if case .conflict(_, let backupName) = outcome {
                    syncState.message = "两台设备都修改过数据，已保留较新的版本。另一份保存为同步目录中的 \(backupName)。"
                } else if syncState.phase == .failed {
                    syncState.message = nil
                }
                syncState.phase = .synced
                syncState.lastSyncedAt = Date()
            } catch {
                syncState.phase = .failed
                syncState.message = error.localizedDescription
            }
        } while syncAgain
    }
    func inspectSyncDirectory(_ url: URL) -> FileSyncDirectoryInspection? {
        do { return try SyncFolder.inspect(url) }
        catch { reportFailure("同步目录未能读取", message: error.localizedDescription); return nil }
    }
    func connectSyncDirectory(_ inspection: FileSyncDirectoryInspection, start: FolderSyncStart) async {
        do {
            guard let store else { throw CoreError.invalid("本机保存服务尚未准备好。") }
            let connection = try SyncFolder.connection(for: inspection.directory)
            let outcome = try await SyncFolder.withAccess(connection) { try await store.connect(folder: $0, start: start) }
            syncDefaults.set(try JSONEncoder().encode(connection), forKey: "cubic.sync.folder")
            if outcome == .downloaded { await publish(await store.document) }
            syncState = SyncState(phase: .synced, lastSyncedAt: Date())
            startSync()
        } catch { reportFailure("同步目录未能连接", message: error.localizedDescription) }
    }
    func disconnectSync() async {
        stopSync()
        do { try await store?.disconnect() }
        catch { reportFailure("同步未能断开", message: error.localizedDescription); return }
        syncDefaults.removeObject(forKey: "cubic.sync.folder")
        syncState = SyncState()
    }
    private var businessNames: [String: String] {
        if cachedBusinessNames == nil {
            var pairs = workspace.items.map { ($0.id, $0.name) }
            pairs.append(contentsOf: workspace.nodes.map { ($0.id, $0.name) })
            pairs.append(contentsOf: workspace.projects.map { ($0.id, $0.name) })
            pairs.append(contentsOf: workspace.blockers.map { ($0.id, $0.name) })
            pairs.append(contentsOf: workspace.acceptances.map { ($0.id, $0.name) })
            var names = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
            for dependency in workspace.dependencies {
                names["dependency:" + dependency.id] = "前置关系：" + (names[dependency.source.id] ?? "原记录") + " → " + (names[dependency.targetItemID] ?? "原记录")
            }
            cachedBusinessNames = names
        }
        return cachedBusinessNames ?? [:]
    }
    func planningReferenceName(_ reference: String) -> String {
        PlanningCopy.referenceName(reference, names: businessNames)
    }
    func missingPlanningInformation(itemIDs: [String], projectIDs: [String], conditionIDs: [String] = []) -> [PlanningUnknown] {
        guard let planning else { return [] }
        let projects = Set(projectIDs).union(itemIDs.compactMap(item).flatMap { relatedProjectIDs(for: $0) })
        var ids = Set(itemIDs).union(projects)
        // Required project work includes transitive prerequisites and shared references.
        for project in projects {
            ids.formUnion(projectItemIDs(project).filter { item($0)?.required == true })
        }
        ids.formUnion(workspace.nodes.filter { $0.required && projects.contains($0.projectID) }.map(\.id))
        let itemNodeIDs = workspace.items.filter { ids.contains($0.id) }.compactMap(\.nodeID)
        ids.formUnion(itemNodeIDs)
        ids.formUnion(workspace.acceptances.filter { $0.isActive && $0.required && ids.contains($0.subject.id) }.map(\.id))
        let conditions = Set(conditionIDs).union(planning.projects.filter { projects.contains($0.projectID) }.flatMap(\.conditionIDs))
        return PlanningDisplay.relatedUnknowns(planning.unknowns, objectIDs: ids,
            conditions: planning.conditions.filter { conditions.contains($0.id) })
    }
    func businessIssue(_ issue: String) -> String {
        let names = businessNames
        // Completion diagnostics separate object IDs with this delimiter, including nested nodes.
        return issue.components(separatedBy: ": ").map { names[$0] ?? $0 }.joined(separator: "：")
    }
    /// A backup is the whole document: workspace plus synced settings.
    func exportBackup() async -> Data? {
        let messageContext = messageContextVersion
        do {
            guard !saving, let store else { throw CoreError.invalid("暂时无法导出备份，请稍后重试。") }
            let document = await store.document
            return try await Task.detached {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                return try encoder.encode(document)
            }.value
        } catch { reportFailure("备份未能导出", message: error.localizedDescription, context: messageContext); return nil }
    }
    /// Replaces the current data with the backup. The replaced data reaches other devices as an ordinary edit.
    func importBackup(_ data: Data) async -> Bool {
        let messageContext = messageContextVersion
        guard !saving, let store else { return false }
        saving = true
        defer { finishWrite() }
        do {
            let backup = try await Task.detached {
                let backup = try JSONDecoder().decode(WorkspaceDocument.self, from: data)
                try backup.workspace.validate()
                return backup
            }.value
            await publish(try await store.save(workspace: backup.workspace, preferences: backup.preferences))
            scheduleSync()
            reportStatus("备份已恢复。", context: messageContext)
            return true
        } catch {
            reportFailure("备份未能导入", message: "原数据未改变。\(error.localizedDescription)", context: messageContext)
            return false
        }
    }
    func renewDemoWindow() async {
        guard preferences.demoCapacityStart != nil else { return }
        let date = Date()
        if preferences.demoScenarioVersion == 2 {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = preferences.workTimeZone
            let today = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: date)!
            let start = date <= today ? today : calendar.date(byAdding: .day, value: 1, to: today)!
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start))!
            let end = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: tomorrow)!
            let zone = preferences.workTimeZone.identifier
            let changed = await mutate { workspace in
                for id in ["project-a", "project-b", "project-c"] where workspace.projects.contains(where: { $0.id == id }) {
                    try workspace.setProjectDeadline(id: id, deadline: id == "project-b" ? start.addingTimeInterval(120 * 60) : end, timeZoneID: zone, now: date)
                }
            }
            if changed { preferences.demoCapacityStart = start; preferences.save(); await refresh() }
        } else {
            let changed = await mutate { workspace in
                for id in ["project-a", "project-b", "project-c"] where workspace.projects.contains(where: { $0.id == id }) {
                    try workspace.setProjectDeadline(id: id, deadline: date.addingTimeInterval(90 * 60), timeZoneID: nil, now: date)
                }
            }
            if changed { preferences.demoCapacityStart = date; preferences.save(); await refresh() }
        }
    }
    func resetWorkspace() async -> Bool {
        let success = await mutate { try $0.archiveCurrentWorkspace(now: Date()) }
        if success { preferences.demoCapacityStart = nil; preferences.save(); await refresh() }
        return success
    }
    private func horizon(from date: Date) -> Date { Self.planningHorizon(workspace: workspace, date: date) }
    nonisolated private static func planningHorizon(workspace: Workspace, date: Date) -> Date {
        let defaultEnd = date.addingTimeInterval(30 * 86400)
        let latest = workspace.projects.compactMap(\.deadline).max() ?? defaultEnd
        return min(max(defaultEnd, latest.addingTimeInterval(86400)), date.addingTimeInterval(366 * 86400))
    }
    private func calculationInput(date: Date) async -> (workspace: Workspace, slots: [CapacitySlot]) {
        var value = workspace
        value.timeBlocks?.removeAll { calendarBridge?.pausedBlockIDs.contains($0.id) == true }
        let settings = preferences, calendarValue = calendar
        return await Task.detached(priority: .userInitiated) { [value, settings, calendarValue, date] in
            Self.buildCalculationInput(workspace: value, preferences: settings, calendar: calendarValue, date: date)
        }.value
    }
    nonisolated private static func buildCalculationInput(workspace: Workspace, preferences: UserPreferences, calendar: CalendarSnapshot, date: Date) -> (workspace: Workspace, slots: [CapacitySlot]) {
        if let start = preferences.demoCapacityStart {
            if preferences.demoScenarioVersion == 2 {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = preferences.workTimeZone
                let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start))!
                let secondStart = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: tomorrow)!
                let raw = [CapacitySlot(start: start, end: start.addingTimeInterval(120 * 60)),
                           CapacitySlot(start: secondStart, end: secondStart.addingTimeInterval(120 * 60))]
                return (workspace, raw.filter { $0.end > date }.map { CapacitySlot(start: max(date, $0.start), end: $0.end, energy: $0.energy) })
            }
            let end = start.addingTimeInterval(90 * 60)
            return (workspace, date < end ? [CapacitySlot(start: max(start, date), end: end)] : [])
        }
        guard preferences.hasDeclaredWorkSchedule else { return (workspace, []) }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = preferences.workTimeZone
        let end = planningHorizon(workspace: workspace, date: date)
        var day = cal.startOfDay(for: date)
        var slots: [CapacitySlot] = []
        let busy = calendar.events.filter { event in
            let rule = preferences.rule(for: event.calendarID)
            if event.allDay && rule.allDay == .ignore { return false }
            if !event.availabilityKnown && rule.unknownAvailability == .ignore { return false }
            return true
        }.sorted { $0.start < $1.start }
        let overrides = Dictionary(uniqueKeysWithValues: (preferences.dayOverrides ?? []).map { ($0.id, $0) })
        while day < end {
            guard let nextDay = cal.date(byAdding: .day, value: 1, to: day) else { break }
            let override = overrides[preferences.dateKey(day)]
            let dayBusy = busy.filter { $0.end > day && $0.start < nextDay }
            let canWork = override.map { !$0.unavailable } ?? (preferences.workWeekends || !cal.isDateInWeekend(day))
            if canWork {
                let periods = override?.periods ?? preferences.effectiveWorkPeriods
                for period in periods {
                    guard let rawStart = cal.date(bySettingHour: period.startMinute / 60, minute: period.startMinute % 60, second: 0, of: day),
                          let rawEnd = period.endMinute == 1440 ? nextDay : cal.date(bySettingHour: period.endMinute / 60, minute: period.endMinute % 60, second: 0, of: day) else { continue }
                    let dayEnd = min(rawEnd, end)
                    var cursor = max(rawStart, date)
                    let energy = Energy(rawValue: period.energy) ?? .normal
                    for event in dayBusy where event.end > cursor && event.start < dayEnd {
                        if event.start > cursor { slots.append(CapacitySlot(start: cursor, end: min(event.start, dayEnd), energy: energy)) }
                        cursor = max(cursor, event.end)
                        if cursor >= dayEnd { break }
                    }
                    if cursor < dayEnd { slots.append(CapacitySlot(start: cursor, end: dayEnd, energy: energy)) }
                }
            }
            day = nextDay
        }
        // Sweep declared periods in O(n log n); no all-slots scan for every boundary.
        var deltas: [Date: [Int]] = [:]
        for slot in slots {
            var begin = deltas[slot.start] ?? [0, 0, 0]
            var finish = deltas[slot.end] ?? [0, 0, 0]
            begin[slot.energy.rank] += 1; finish[slot.energy.rank] -= 1
            deltas[slot.start] = begin; deltas[slot.end] = finish
        }
        let boundaries = deltas.keys.sorted()
        var counts = [0, 0, 0], unique: [CapacitySlot] = []
        for (start, finish) in zip(boundaries, boundaries.dropFirst()) {
            if let delta = deltas[start] { for rank in 0...2 { counts[rank] += delta[rank] } }
            guard let rank = (0...2).reversed().first(where: { counts[$0] > 0 }) else { continue }
            let energy: Energy = rank == 2 ? .high : rank == 1 ? .normal : .low
            if let index = unique.indices.last, unique[index].end == start, unique[index].energy == energy {
                unique[index].end = finish
            } else { unique.append(CapacitySlot(start: start, end: finish, energy: energy)) }
        }
        slots = unique
        return (workspace, slots)
    }
}
