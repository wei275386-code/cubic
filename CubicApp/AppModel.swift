import SwiftUI
import CubicCore
import CryptoKit

private actor WorkspaceStore {
    private var repository: SQLiteWorkspaceRepository?
    private let url: URL
    init(url: URL) { self.url = url }
    func load(now: Date) throws -> (Workspace, Bool) {
        let first = !FileManager.default.fileExists(atPath: url.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let repo = try SQLiteWorkspaceRepository(url: url)
        repository = repo
        if first {
            // A new installation is ready to receive the user's real workspace.
            // Samples must never become local facts that a later binding uploads.
            try repo.save(.empty)
            return (.empty, true)
        }
        return (try repo.load(), false)
    }
    func save(_ workspace: Workspace) throws {
        guard let repository else { throw BackupError.unsupported }
        try repository.save(workspace)
    }
}
private struct AppBackup: Sendable {
    var schemaVersion = 2
    var workspace: Workspace
    var preferences: UserPreferences
    var syncArchive: SyncArchive?
}

private extension AppBackup {
    enum CodingKeys: String, CodingKey { case schemaVersion, workspace, preferences, syncArchive, syncArchiveDateEncoding }
}
extension AppBackup: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        workspace = try container.decode(Workspace.self, forKey: .workspace)
        preferences = try container.decode(UserPreferences.self, forKey: .preferences)
        let archiveEncoding = try container.decodeIfPresent(String.self, forKey: .syncArchiveDateEncoding)
        if archiveEncoding == "deferredToDate" {
            let value = try container.decode(SyncValue.self, forKey: .syncArchive)
            syncArchive = try SyncCoding.decode(SyncArchive.self, from: SyncCoding.encode(value))
        } else {
            guard archiveEncoding == nil else { throw BackupError.unsupported }
            // Earlier v1/v2 envelopes use the outer milliseconds strategy.
            syncArchive = try container.decodeIfPresent(SyncArchive.self, forKey: .syncArchive)
        }
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(workspace, forKey: .workspace)
        try container.encode(preferences, forKey: .preferences)
        if let syncArchive {
            // Preserve operation dates bit-for-bit in their canonical reference epoch.
            let value = try SyncCoding.decode(SyncValue.self, from: SyncCoding.encode(syncArchive))
            try container.encode(value, forKey: .syncArchive)
            try container.encode("deferredToDate", forKey: .syncArchiveDateEncoding)
        }
    }
}

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
    var cloudSync: CloudSyncController?
    var calendarBridge: CalendarBridge?
    private var calendarBridgePartition: String?
    private var calendarBridgeGeneration = 0
    private var syncControllerGeneration = 0
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
    private var calendarStorageReady: Bool { !loading && syncJournal != nil && syncStorageError == nil && pendingLocalSave == nil && canVerifyPlanning }
    private var calendarIntegrationSourceVersion: String {
        "\(revision):\(planningContextRevision):\(calendarPreferencesRevision):\(externalCalendarInputRevision):\(calendarBridgeGeneration):\(calendarBridge?.boundCalendarID ?? ""):\(calendarStorageReady)"
    }
    var syncStatus: SyncStatus { cloudSync?.status ?? SyncStatus(phase: syncStorageError == nil ? .localOnly : .failed,
        message: syncStorageError ?? "本地数据已保存，正在准备同步。") }
    private var syncProjection: SyncMergeResult?
    private var deferredSyncProjection: SyncMergeResult?
    private var workspaceSession: WorkspaceSession?
    private var pendingLocalSave: SyncLocalCommitFailure?
    private var recoveryBlockedHosts: Set<UUID> = []
    private var currentEditorHost: UUID? { modalMessageHosts.last ?? messagePages.last }
    @ObservationIgnored private var writeWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var syncJournal: SyncJournal?
    private static let cloudContainerID = "iCloud.local.liwei.Cubic"
    nonisolated private static var syncWorkspaceID: String { workCalendarQAMode ? "cubic.work-calendar.qa" : "cubic.primary" }
    #if DEBUG
    @ObservationIgnored private var testingDefaults: UserDefaults?
    @ObservationIgnored private var testingSyncRoot: URL?
    @ObservationIgnored private var isIntegrationTest = false
    #endif
    private var syncDefaults: UserDefaults {
        #if DEBUG
        if let testingDefaults { return testingDefaults }
        #endif
        return Self.workCalendarQAMode ? UserDefaults(suiteName: "cubic.work-calendar.qa.sync")! : .standard
    }
    private var activeSyncPartition: String?
    private var activeSyncKind = "local"
    var cloudKitLegacyBlocked: Bool { activeSyncKind == "cloudkit" && !ReleaseCapabilities.cloudKitEnabled }
    var syncTransportLabel: String { activeSyncKind == "file" ? "文件目录同步" : activeSyncKind == "cloudkit" ? "CloudKit" : "仅本机" }
    var fileSyncConnection: FileSyncConnection? {
        guard let data = syncDefaults.data(forKey: "cubic.sync.fileConnection") else { return nil }
        return try? JSONDecoder().decode(FileSyncConnection.self, from: data)
    }
    var syncDirectoryLabel: String? { activeSyncKind == "file" ? fileSyncConnection?.directoryLabel : nil }
    private var syncStorageError: String?
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
    var canVerifyPlanning: Bool { syncProjection?.planningIsValid != false }
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
    private let store: WorkspaceStore
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
            store = WorkspaceStore(url: qaDirectory.appendingPathComponent("work-calendar.sqlite"))
            preferences = syncDefaults.data(forKey: "cubic.preferences") == nil ? Self.workCalendarQAPreferences(now: Date()) : UserPreferences.load(defaults: syncDefaults)
        } else {
            store = WorkspaceStore(url: documents.appendingPathComponent("Cubic/workspace.sqlite"))
        }
    }
    #if DEBUG
    /// Isolated composition seam for testing the REAL AppModel adapter; never touches Documents or system services.
    init(testDirectory: URL, journal: SyncJournal, projection: SyncMergeResult, defaults: UserDefaults,
         beforeCacheSave: (@Sendable (Workspace) async throws -> Void)? = nil) async throws {
        store = WorkspaceStore(url: testDirectory.appendingPathComponent("workspace.sqlite"))
        testingDefaults = defaults; testingSyncRoot = testDirectory.appendingPathComponent("Sync")
        isIntegrationTest = true
        _ = try await store.load(now: Date())
        try await store.save(projection.planningWorkspace)
        workspace = projection.planningWorkspace; syncProjection = projection; syncJournal = journal
        workspaceSession = WorkspaceSession(journal: journal, cacheProjection: { [store] value in
            if let beforeCacheSave { try await beforeCacheSave(value) }
            try await store.save(value)
        })
        cloudSync = CloudSyncController(coordinator: SyncCoordinator(journal: journal, transport: LocalOnlySyncTransport()), remoteEnabled: false)
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
            let date = Date()
            let (storedValue, first) = try await store.load(now: date)
            let shouldSeedQA = Self.workCalendarQAMode && (Self.resetWorkCalendarQA || first)
            let value = shouldSeedQA ? Self.workCalendarQAWorkspace(now: date) : storedValue
            if Self.workCalendarQAMode, shouldSeedQA { try await store.save(value) }
            workspace = value
            if !Self.workCalendarQAMode, !first, preferences.acceptanceNoticeAcknowledged != true,
               value.needsAcceptanceReinterpretationNotice {
                acceptanceNotice = "验收规则已更新：没有添加验收条件的节点，在必需工作完成后即视为验收通过；以前标记为“非必需”的验收条件现在按必需处理。"
            }
            if !Self.workCalendarQAMode, preferences.workTimeZoneID == nil { preferences.workTimeZoneID = TimeZone.current.identifier; preferences.save() }
            if !Self.workCalendarQAMode, first {
                preferences.demoCapacityStart = nil
                preferences.demoScenarioVersion = nil
                preferences.workTimeZoneID = TimeZone.current.identifier
                preferences.save()
            }
            if Self.workCalendarQAMode { await prepareSync(accountID: nil, importLocal: true) } else { await prepareSync() }
            // Domain and journal are ready before Calendar imports and planning refresh.
            loading = false
            ensureCalendarBridge()
            await refresh()
        } catch { loadFailure = "无法读取本地数据：\(error.localizedDescription)" }
        loading = false
        resumeWriteWaiters()
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
        recoveryBlockedHosts.remove(id)
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
        recoveryBlockedHosts.remove(id)
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
        let context = messageContextVersion, session = workspaceSession?.id
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
            guard !Task.isCancelled, context == messageContextVersion,
                  session == nil || session == workspaceSession?.id else { return false }
        }
        guard !Task.isCancelled, context == messageContextVersion else { return false }
        return await mutate(change)
    }
    private func resumeWriteWaiters() {
        let waiters = writeWaiters; writeWaiters = [:]
        for continuation in waiters.values { continuation.resume() }
    }
    private var writeToken: WorkspaceWriteToken? {
        workspaceSession.map { WorkspaceWriteToken(sessionID: $0.id, heads: syncProjection?.heads ?? []) }
    }
    func mutate(allowWhileLoading: Bool = false, background: Bool = false, _ change: (inout Workspace) throws -> Void) async -> Bool {
        let messageContext = messageContextVersion
        guard !saving, !loading || allowWhileLoading, !Task.isCancelled else { return false }
        guard ![currentEditorHost].compactMap({ $0 }).contains(where: recoveryBlockedHosts.contains) else {
            if !background { reportFailure("请重新打开编辑页面", message: "原保存记录已恢复，请关闭此编辑页面后核对最新内容。", context: messageContext) }
            return false
        }
        guard pendingLocalSave == nil else {
            if !background { reportFailure("保存结果待核对", message: "原记录需要恢复核对，请在设置刷新同步。请勿重复提交。", context: messageContext) }
            return false
        }
        saving = true
        defer { finishWrite() }
        let token = writeToken
        do {
            var candidate = workspace
            try change(&candidate)
            guard !Task.isCancelled else { return false }
            let outcome = try await submitWorkspace(candidate, token: token)
            let committed = await publishLocalCommit(outcome, context: messageContext)
            if committed { serviceIssues["默认时间未能保存"] = nil }
            return committed
        } catch {
            let message = userMessage(for: error)
            if background { serviceIssues["默认时间未能保存"] = message }
            else { reportFailure("修改未保存", message: message, context: messageContext) }
            return false
        }
    }
    /// The base token is captured with the prepared workspace, before leaving MainActor.
    func mutateProjectTemplate(_ mutation: ProjectTemplateMutation) async -> String? {
        let messageContext = messageContextVersion
        guard !saving, !loading, pendingLocalSave == nil, !Task.isCancelled,
              ![currentEditorHost].compactMap({ $0 }).contains(where: recoveryBlockedHosts.contains) else { return nil }
        saving = true
        defer { finishWrite() }
        let snapshot = workspace, sourceVersion = revision, timestamp = Date(), token = writeToken
        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                try mutation.prepare(in: snapshot, now: timestamp)
            }.value
            guard !Task.isCancelled else { return nil }
            guard revision == sourceVersion else { throw CoreError.blocked("项目内容已变化，请重新查看预览后保存。") }
            let outcome = try await submitWorkspace(prepared.workspace, token: token)
            return await publishLocalCommit(outcome, context: messageContext) ? prepared.id : nil
        } catch {
            reportFailure("修改未保存", message: userMessage(for: error), context: messageContext)
            return nil
        }
    }
    private func submitWorkspace(_ value: Workspace, token: WorkspaceWriteToken?) async throws -> WorkspaceCommitOutcome {
        guard let workspaceSession, let token else { throw CoreError.invalid("本机保存服务尚未准备好。草稿仍保留，请重新打开 app。") }
        return try await workspaceSession.submit(value, basedOn: token)
    }
    @discardableResult private func publishLocalCommit(_ outcome: WorkspaceCommitOutcome, context: Int) async -> Bool {
        switch outcome {
        case .committed(let projection, let cacheIssue):
            pendingLocalSave = nil
            serviceIssues["保存结果待核对"] = nil
            serviceIssues["本机页面数据未能更新"] = cacheIssue
            let canonical = await cloudSync?.acceptLocalCommit(projection) ?? projection
            await publishCanonicalProjection(canonical, cacheAlreadySaved: canonical.heads == projection.heads)
            if !projection.planningIsValid {
                reportStatus("修改已记录，还有同步冲突需要处理。请到设置核对。", context: context)
            }
            return true
        case .recoveryRequired(let failure):
            recoveryBlockedHosts.formUnion([currentEditorHost].compactMap { $0 })
            pendingLocalSave = failure
            serviceIssues["保存结果待核对"] = failure.localizedDescription
            reportFailure("保存结果待核对", message: "请在设置刷新同步以恢复原记录。不要重复提交；草稿和原记录保留。", context: context)
            return false
        }
    }
    private func recoverPendingLocalSave() async {
        guard !saving, let failure = pendingLocalSave, let workspaceSession else { return }
        saving = true
        defer { finishWrite() }
        do {
            if let outcome = try await workspaceSession.recover(failure.receipt) {
                _ = await publishLocalCommit(outcome, context: messageContextVersion)
                if pendingLocalSave == nil {
                    // Retained editors must reopen: the original operation is complete, not a new save opportunity.
                    invalidateActionMessages()
                    reportStatus("原保存记录已恢复。请重新打开编辑页面，核对最新内容后再修改。", context: messageContextVersion)
                }
            } else {
                pendingLocalSave = nil; serviceIssues["保存结果待核对"] = nil
                recoveryBlockedHosts = []
                reportStatus("已核实原修改未写入，可以重新保存。", context: messageContextVersion)
            }
        } catch { serviceIssues["保存结果待核对"] = error.localizedDescription }
    }
    private func retainLocalRecovery(_ error: Error) -> Bool {
        guard let failure = error as? SyncLocalCommitFailure else { return false }
        pendingLocalSave = failure
        recoveryBlockedHosts.formUnion([currentEditorHost].compactMap { $0 })
        serviceIssues["保存结果待核对"] = failure.localizedDescription
        return true
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
    private func persistDurableProjection(_ value: Workspace) async {
        do { try await store.save(value); serviceIssues["本机页面数据未能更新"] = nil }
        catch { serviceIssues["本机页面数据未能更新"] = "修改已保存，当前页面暂未更新。请重新打开 app。" }
    }
    private func finishWrite() {
        saving = false
        resumeWriteWaiters()
        if let deferred = deferredSyncProjection {
            deferredSyncProjection = nil
            let generation = syncControllerGeneration
            Task {
                guard syncControllerGeneration == generation else { return }
                await applySyncProjection(deferred)
            }
        }
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
        guard syncProjection?.planningIsValid != false else { calculationIsStale = true; return }
        if !saving, syncJournal != nil, !workspace.defaultEstimateItemIDs.isEmpty {
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
        guard generation == refreshGeneration, revision == requestRevision, planningContextRevision == requestContext, canVerifyPlanning else { return }
        visibleCapacitySlots = input.input.slots
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try Engine.plan(workspace: input.workspace, input: input.input)
            }.value
            guard revision == requestRevision, generation == refreshGeneration, planningContextRevision == requestContext, canVerifyPlanning else { return }
            planning = result
            snapshot = result.legacy
            calculationUpdatedAt = date
            calculationIsStale = false
            serviceIssues["排期未能更新"] = nil
            await updateNotices(using: result)
            await scheduleReminders()
        } catch {
            guard revision == requestRevision, generation == refreshGeneration, planningContextRevision == requestContext, canVerifyPlanning else { return }
            calculationIsStale = true
            let message = "\(error.localizedDescription) 请检查相关设置后下拉刷新。已有工作记录保留。"
            serviceIssues["排期未能更新"] = message
            if !background { reportFailure("排期未能更新", message: message, context: messageContext) }
        }
    }
    func trial(itemID: String, minutes: Int) async -> TrialResult? {
        let messageContext = messageContextVersion
        guard canVerifyPlanning else { return nil }
        let version = sourceVersion
        let date = Date()
        let input = await calculationInput(date: date)
        do {
            var result = try await Task.detached(priority: .userInitiated) {
                try Engine.trial(workspace: input.workspace, selections: [TrialSelection(itemID: itemID, minutes: minutes)], slots: input.slots, now: date)
            }.value
            guard canVerifyPlanning, sourceVersion == version else { return nil }
            markMissingCalendar(&result.snapshot)
            return result
        } catch {
            guard canVerifyPlanning, sourceVersion == version else { return nil }
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
    func savePreferences(_ value: UserPreferences, comparedTo original: [String: SyncValue]? = nil) async -> Bool {
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
            let fields = try candidate.syncValues(calendars: calendar.calendars)
            // A remote update while the sheet is open must not be overwritten by untouched draft fields.
            let existing = Set(syncProjection?.preferences.keys.map { $0 } ?? []).union((syncProjection?.conflicts ?? []).flatMap(\.paths).filter { $0.collection == "@preferences" }.map(\.field))
            let patch = fields.filter { original?[$0.key] != $0.value || !existing.contains($0.key) }
            if let original, patch.contains(where: { field, edited in
                guard let current = syncProjection?.preferences[field] else { return false }
                return current != original[field] && current != edited
            }) { throw CoreError.invalid("这项设置刚被另一台设备更新。请重新打开设置，核对最新内容后再保存。") }
            guard let cloudSync else { throw CoreError.invalid("本机保存服务尚未准备好，请稍后再保存设置。") }
            let result = try await cloudSync.recordPreferences(patch)
            await publishCanonicalProjection(result)
            syncDefaults.set(true, forKey: "cubic.preferences.saved")
            revision += 1
            // Preference changes must cancel suppressed pending requests even when
            // structural conflicts prevent a new precise planning snapshot.
            await scheduleReminders()
            await refresh()
            return true
        } catch { let partial = retainLocalRecovery(error); reportFailure(partial ? "设置保存结果待核对" : "设置未保存", message: error.localizedDescription, context: messageContext); return false }
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
        let conflicts = syncProjection?.conflicts ?? []
        let changes = await Task.detached { RiskNoticeEngine.changes(workspace: value, planning: planning, now: date, conflicts: conflicts) }.value
        guard expectedRevision == revision else { return }
        if !changes.isEmpty && !saving {
            saving = true
            defer { finishWrite() }
            do {
                var candidate = workspace
                for notice in changes { candidate.history.append(try RiskNoticeEngine.event(notice, at: date)) }
                try candidate.validate()
                let committed = try await journalLocalWorkspace(candidate)
                workspace = committed
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
        // A persisted acknowledgement must cancel its alert even if planning
        // fails or the sync journal cannot produce a valid computation view.
        await refreshStoredNotices()
        await scheduleReminders()
    }
    private func refreshStoredNotices() async {
        #if DEBUG
        if isIntegrationTest { return }
        #endif
        noticeRefreshGeneration += 1
        let generation = noticeRefreshGeneration
        let current = syncProjection?.workspace ?? workspace
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
        guard syncProjection?.planningIsValid != false else {
            if reportErrors { reportFailure("试算未完成", message: "还有同步冲突未处理，暂时无法试算。请到设置处理同步冲突。", context: messageContext) }
            return nil
        }
        let input = await planningInput(date: Date())
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try Engine.trial(workspace: input.workspace,
                                 request: PlanningTrialRequest(itemID: itemID, minutes: minutes, start: start, counterfactual: counterfactual), input: input.input)
            }.value
            guard canVerifyPlanning, result.source.input.revision.workspace == String(revision), result.source.input.revision.capacity == sourceVersion else {
                if reportErrors { reportFailure("请重新查看试算", message: "数据在计算期间发生变化，请查看刷新后的试算再确认。", context: messageContext) }
                return nil
            }
            return result
        } catch {
            guard canVerifyPlanning, sourceVersion == version else { return nil }
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
                                                      note: "当时查看的可选工作", detail: String(decoding: try SyncCoding.encode(context), as: UTF8.self)))
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
            return self.canVerifyPlanning && result.source.input.revision.workspace == String(self.revision) &&
                result.source.input.revision.capacity == self.sourceVersion
        },
        commit: { [weak self] result, note in
            guard let self else { throw CancellationError() }
            return try await self.commitPlanningChoice(result, note: note)
        },
        recover: { [weak self] receipt in
            guard let self, let session = self.workspaceSession, !self.saving else { throw CoreError.blocked("正在保存，请稍后核对。") }
            self.saving = true
            defer { self.finishWrite() }
            let outcome = try await session.recover(receipt)
            if let outcome { _ = await self.publishLocalCommit(outcome, context: self.messageContextVersion) }
            return outcome
        })
        storedChoiceConfirmation = operation
        return operation
    }

    func confirmDisplayedTrial(presentationID: UUID, displayed: PlanningTrialResult, request: PlanningTrialRequest,
                              note: String, isCurrent: @escaping @MainActor () -> Bool) async -> PlanningChoiceConfirmation.Outcome {
        let context = messageContextVersion, sessionID = workspaceSession?.id, generation = syncControllerGeneration
        let outcome = await choiceConfirmation.confirm(presentationID: presentationID, displayed: displayed,
                                                       request: request, note: note, isCurrent: { [weak self] in
                                                           guard let self else { return false }
                                                           return self.workspaceSession?.id == sessionID && self.syncControllerGeneration == generation && isCurrent()
                                                       })
        if case .unavailable(let message?) = outcome, isCurrent() {
            reportFailure("确认未完成", message: message, context: context)
        }
        return outcome
    }
    private func commitPlanningChoice(_ result: PlanningTrialResult, note: String) async throws -> WorkspaceCommitOutcome {
        let scenario = result.scenario ?? result.baseline
        let savedTrial = result.request.minutes.map { minutes in
            TrialResult(selections: [TrialSelection(itemID: result.request.itemID, minutes: minutes)], allocations: result.allocations,
                        unallocatedMinutes: result.unallocatedMinutes ?? 0, snapshot: scenario.legacy)
        }
        let ids = Array(Set([result.request.itemID] + result.impacts.flatMap(\.itemIDs))).sorted()
        let version = sourceVersion
        guard canVerifyPlanning, result.source.input.revision.workspace == String(revision), result.source.input.revision.capacity == sourceVersion else {
            throw CoreError.blocked("源数据刚刚发生变化，请查看刷新后的影响再确认。")
        }
        guard !saving, !loading, pendingLocalSave == nil, !Task.isCancelled else {
            throw CoreError.blocked("正在保存或核对原保存记录，请稍后重试。")
        }
        saving = true
        defer { finishWrite() }
        let token = writeToken
        var candidate = workspace
        try recordChoice(&candidate)
        guard !Task.isCancelled else { throw CancellationError() }
        let outcome = try await submitWorkspace(candidate, token: token)
        _ = await publishLocalCommit(outcome, context: messageContextVersion)
        return outcome

        func recordChoice(_ workspace: inout Workspace) throws {
            let now = Date()
            try workspace.chooseNextAction(itemID: result.request.itemID, now: now, trial: savedTrial,
                                           displayedItemIDs: ids, dataVersion: version, impactWasVerified: savedTrial != nil, note: note)
            if let id = workspace.currentNextAction?.id {
                workspace.history.append(HistoryEvent(date: now, kind: .choiceRecorded, objectID: id,
                                                      note: "当时的试算条件与结果", detail: String(decoding: try SyncCoding.encode(result), as: UTF8.self)))
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
        let disputed = Array(syncProjection?.pausedItemIDs ?? [])
        let value = await Task.detached(priority: .userInitiated) { [original, settings, calendarValue, date] in
            Self.buildCalculationInput(workspace: original, preferences: settings, calendar: calendarValue, date: date)
        }.value
        let input = PlanningInput(slots: value.slots, now: date, horizonEnd: Self.planningHorizon(workspace: original, date: date),
                                  revision: PlanningRevision(workspace: workspaceRevision, capacity: version,
                                                             calendar: calendarValue.fetchedAt.map { String($0.timeIntervalSince1970) } ?? "unavailable", time: version),
                                  options: PlanningOptions(capacityVerified: issues.isEmpty, capacityNote: issues.isEmpty ? nil : issues.joined(separator: " "),
                                                           disputedItemIDs: disputed))
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
        let partition = activeSyncPartition ?? "local"
        guard calendarBridge == nil || calendarBridgePartition != partition else { return }
        calendarBridge?.invalidate()
        calendarBridgeGeneration += 1
        let generation = calendarBridgeGeneration
        calendarBridgePartition = partition
        calendarBridge = CalendarBridge(workspaceID: Self.syncWorkspaceID + "." + partition, defaults: syncDefaults,
            context: { [weak self] in
                guard let self, self.calendarBridgeGeneration == generation, (self.activeSyncPartition ?? "local") == partition else { return CalendarBridgeContext(workspace: .empty, slots: [], externalBusy: [], capacityVerified: false) }
                return await self.calendarIntegrationContext()
            }, applyExternal: { [weak self] block, expected, eventID in
                guard let self, self.calendarBridgeGeneration == generation, (self.activeSyncPartition ?? "local") == partition else { throw CoreError.invalid("同步数据已切换，请在当前数据中重新核对日历。") }
                try await self.applyCalendarTimeBlock(block, expected: expected, excludingEventID: eventID)
            }, removeBlock: { [weak self] id in
                guard let self, self.calendarBridgeGeneration == generation, (self.activeSyncPartition ?? "local") == partition else { throw CoreError.invalid("同步数据已切换，请在当前数据中重新核对日历。") }
                guard !self.saving, !self.loading else { throw CoreError.invalid("正在保存，请稍后重试。") }
                guard await self.mutate({ try $0.removeTimeBlock(id: id, now: Date()) }) else {
                    throw CoreError.invalid(self.errorMessage ?? "时间块未能保存，请重试。")
                }
            }, isContextCurrent: { [weak self] sourceRevision in
                guard let self, self.calendarBridgeGeneration == generation, (self.activeSyncPartition ?? "local") == partition else { return false }
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
            disputedItemIDs: syncProjection?.pausedItemIDs ?? [],
            capacityVerified: version == calendarIntegrationSourceVersion && generation == calendarBridgeGeneration && calendarStorageReady && canVerifyPlanning && (settings.hasDeclaredWorkSchedule || settings.demoCapacityStart != nil) &&
                (!settings.calendarEnabled || (external.authorized && external.missingCalendarIDs.isEmpty && external.fetchedAt.map { Date().timeIntervalSince($0) < 300 } == true)),
            storageReady: calendarStorageReady, sourceRevision: version)
    }
    private func applyCalendarTimeBlock(_ block: WorkTimeBlock, expected: WorkTimeBlock?, excludingEventID: String?) async throws {
        guard !saving, !loading else { throw CoreError.invalid("正在保存，请稍后重试。") }
        let generation = calendarBridgeGeneration, partition = activeSyncPartition
        let current = workspace.timeBlocks?.first { $0.id == block.id }
        if current == block { return } // The same fact may already have arrived through data sync.
        guard current == expected else { throw CoreError.invalid("Cubic 时间块也已修改，请刷新后确认双方时间。") }
        let context = await calendarIntegrationContext()
        guard !saving, generation == calendarBridgeGeneration, partition == activeSyncPartition, (workspace.timeBlocks?.first { $0.id == block.id }) == expected else {
            throw CoreError.invalid("工作刚刚更新，请重新核对后再接受。")
        }
        guard context.capacityVerified else { throw CoreError.invalid("日历容量尚未核实，请先检查工作时段和日历权限。") }
        let otherBusy = (calendarBridge?.validationBusyEvents ?? []).filter { $0.id != "cubic.bridge.\(excludingEventID ?? "")" }
            .map { BusyInterval(start: $0.start, end: $0.end) }
        var candidate = workspace
        try candidate.setTimeBlock(block, slots: context.slots, busy: context.externalBusy + otherBusy, now: Date())
        saving = true
        defer { finishWrite() }
        let committed = try await journalLocalWorkspace(candidate)
        workspace = committed; revision += 1; calculationIsStale = true
        Task { await refresh() }
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
    @discardableResult func prepareSync(accountID: String? = nil, importLocal: Bool = true, fileConnection: FileSyncConnection? = nil, transportKind: String? = nil) async -> Bool {
        // A saved legacy binding may reopen its original partition, but explicit
        // CloudKit association must fail before any journal/defaults mutation.
        if transportKind == "cloudkit", !ReleaseCapabilities.cloudKitEnabled {
            reportStatus(ReleaseCapabilities.cloudKitUnavailableMessage, context: messageContextVersion)
            return false
        }
        guard pendingLocalSave == nil else { statusMessage = "请先恢复原保存记录，再切换数据。"; return false }
        guard !saving else { statusMessage = "正在保存，请稍后再切换账号数据。"; return false }
        saving = true
        defer { finishWrite() }
        let previousController = cloudSync, previousJournal = syncJournal
        let previousPartition = activeSyncPartition, previousProjection = syncProjection
        let previousSession = workspaceSession, previousPendingSave = pendingLocalSave
        let previousKind = activeSyncKind, previousGeneration = syncControllerGeneration
        do {
            let defaults = syncDefaults
            let deviceID = defaults.string(forKey: "cubic.sync.deviceID") ?? UUID().uuidString
            defaults.set(deviceID, forKey: "cubic.sync.deviceID")
            let kind = transportKind ?? defaults.string(forKey: "cubic.sync.transport") ?? (defaults.string(forKey: "cubic.sync.activeAccount") == nil ? "local" : "cloudkit")
            let connection = fileConnection ?? self.fileSyncConnection
            let account = kind == "file" ? connection?.metadata.remoteBinding.rawValue : (accountID ?? defaults.string(forKey: "cubic.sync.activeAccount"))
            if kind == "cloudkit", !ReleaseCapabilities.cloudKitEnabled {
                guard accountID == nil, let account, account == defaults.string(forKey: "cubic.sync.activeAccount") else {
                    throw CoreError.invalid(ReleaseCapabilities.cloudKitUnavailableMessage)
                }
            }
            let remoteEnabled = kind == "file" || (kind == "cloudkit" && ReleaseCapabilities.cloudKitEnabled)
            if kind == "file", connection == nil { throw CoreError.invalid("同步目录授权不可用，请重新选择目录。") }
            let partition = account.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() } ?? "local"
            if activeSyncPartition == partition, activeSyncKind == kind, fileConnection == nil, let cloudSync, let syncJournal {
                await publishCanonicalProjection(try await syncJournal.snapshot())
                syncStorageError = nil
                cloudSync.start()
                return true
            }
            // Explicit association carries raw branches, not the isolated planning preview.
            let reusesJournal = activeSyncPartition == partition && syncJournal != nil
            let associationArchive = importLocal && !reusesJournal ? try await cloudSync?.exportArchive() : nil
            // Keep the source handles until the target is ready, including failed retries.
            await cloudSync?.retire()
            let root = URL.documentsDirectory.appendingPathComponent(Self.workCalendarQAMode ? "CubicQA/Sync" : "Cubic/Sync")
            #if DEBUG
            let directory = (testingSyncRoot ?? root).appendingPathComponent(partition)
            #else
            let directory = root.appendingPathComponent(partition)
            #endif
            let workspaceID = Self.syncWorkspaceID
            let journal: SyncJournal
            if reusesJournal, let existing = syncJournal {
                // Disconnecting or renewing a folder grant changes the transport,
                // not the local history. A second writer for this same directory
                // would fail its lease while the rollback controller owns it.
                journal = existing
            } else {
                journal = try await Task.detached(priority: .userInitiated) {
                    try SyncJournal(directory: directory, workspaceID: workspaceID, deviceID: deviceID)
                }.value
            }
            if let account { try await journal.bindAccount(account) }
            if let associationArchive {
                _ = try await journal.restoreArchive(associationArchive)
            } else if importLocal, !reusesJournal, workspace != .empty {
                // No domain facts exist on a fresh install. The first real edit
                // will create its revision; do not queue an empty bootstrap.
                _ = try await journal.bootstrap(workspace: workspace, currentChoiceID: workspace.currentChoiceID)
            }
            let adapter: any SyncTransport
            if kind == "file", let connection {
                adapter = FileProviderSyncTransport(access: SecurityScopedFileSyncAccess(connection: connection), workspaceID: Self.syncWorkspaceID, remoteBindingID: connection.metadata.remoteBinding, pageSize: 256)
            } else if kind == "cloudkit", ReleaseCapabilities.cloudKitEnabled {
                adapter = CloudSyncAdapter(containerID: Self.cloudContainerID, accountID: account ?? "unbound", workspaceID: Self.syncWorkspaceID)
            } else { adapter = LocalOnlySyncTransport() }
            let coordinator = SyncCoordinator(journal: journal, transport: adapter)
            // Migrate existing user settings once. Pull first so an existing remote setting wins over a local cache.
            if importLocal, preferences.hasDeclaredWorkSchedule || preferences.calendarEnabled || preferences.remindersEnabled || preferences.workWeekends || syncDefaults.bool(forKey: "cubic.preferences.saved") {
                func registeredPreferences(_ value: SyncMergeResult) -> Set<String> {
                    Set(value.preferences.keys).union(value.conflicts.flatMap(\.paths).filter { $0.collection == "@preferences" }.map(\.field))
                }
                let registered = registeredPreferences(try await journal.snapshot())
                let fields = try preferences.syncValues(calendars: calendar.calendars)
                if !Set(fields.keys).isSubset(of: registered) {
                    if remoteEnabled { _ = await coordinator.refresh() }
                    let existing = registeredPreferences(try await journal.snapshot())
                    let calendars = await calendarReader.read(from: Date(), to: Date(), selectedIDs: [])
                    let legacy = try preferences.syncValues(calendars: calendars.calendars).filter { !existing.contains($0.key) }
                    _ = try await coordinator.recordPreferences(legacy)
                }
            }
            let generation = syncControllerGeneration + 1
            let controller = CloudSyncController(coordinator: coordinator, remoteEnabled: remoteEnabled, onMerge: { [weak self] value in
                Task { @MainActor [weak self] in
                    guard let self, (self.activeSyncPartition ?? "local") == partition, self.syncControllerGeneration == generation else { return }
                    await self.applySyncProjection(value)
                }
            })
            workspaceSession = WorkspaceSession(journal: journal, cacheProjection: { [store] value in try await store.save(value) })
            pendingLocalSave = nil
            syncJournal = journal
            cloudSync = controller
            syncControllerGeneration = generation
            if calendarBridgePartition != partition {
                calendarBridge?.invalidate(); calendarBridge = nil; calendarBridgePartition = nil
            }
            activeSyncPartition = partition
            activeSyncKind = kind
            deferredSyncProjection = nil
            // An empty or blocker-only canonical workspace is still authoritative.
            let projection = try await journal.snapshot()
            if previousPartition != partition && !importLocal { preferences = UserPreferences() }
            await publishCanonicalProjection(projection)
            ensureCalendarBridge()
            syncStorageError = nil
            serviceIssues["本机记录未能打开"] = nil
            serviceIssues["账号数据未能切换"] = nil
            serviceIssues["CloudKit 发行支持边界"] = cloudKitLegacyBlocked ? ReleaseCapabilities.cloudKitUnavailableMessage : nil
            #if DEBUG
            if !isIntegrationTest, !Self.workCalendarQAMode || kind == "file" { controller.start() }
            #else
            controller.start()
            #endif
            return true
        } catch {
            await cloudSync?.retire()
            cloudSync = previousController; syncJournal = previousJournal
            workspaceSession = previousSession; pendingLocalSave = previousPendingSave
            activeSyncPartition = previousPartition; syncProjection = previousProjection; activeSyncKind = previousKind
            syncControllerGeneration = previousGeneration
            ensureCalendarBridge()
            deferredSyncProjection = nil
            if let previousController {
                previousController.resumeAfterFailedSwitch()
                syncStorageError = nil
                serviceIssues["账号数据未能切换"] = "原数据仍可使用。\(error.localizedDescription) 请在设置重新选择账号数据。"
            } else {
                syncStorageError = "本机保存服务未能打开，暂时无法保存修改。请重新打开 app 后重试；若仍失败，请到设置导出备份并联系支持。现有记录保留。"
                serviceIssues["本机记录未能打开"] = syncStorageError!
            }
            return false
        }
    }
    private func journalLocalWorkspace(_ value: Workspace, expectedHeads: [String]? = nil) async throws -> Workspace {
        guard let session = workspaceSession else { throw CoreError.invalid("本机保存服务尚未准备好。") }
        let token = WorkspaceWriteToken(sessionID: session.id, heads: expectedHeads ?? syncProjection?.heads ?? [])
        let outcome = try await session.submit(value, basedOn: token)
        switch outcome {
        case .committed(let result, let cacheIssue):
            serviceIssues["本机页面数据未能更新"] = cacheIssue
            let canonical = await cloudSync?.acceptLocalCommit(result) ?? result
            await publishCanonicalProjection(canonical, cacheAlreadySaved: canonical.heads == result.heads)
            guard canonical.planningIsValid else { throw WorkspaceCommittedProjectionUnavailable() }
            return canonical.planningWorkspace
        case .recoveryRequired(let failure):
            recoveryBlockedHosts.formUnion([currentEditorHost].compactMap { $0 })
            pendingLocalSave = failure
            serviceIssues["保存结果待核对"] = failure.localizedDescription
            throw failure
        }
    }
    private func applySyncProjection(_ value: SyncMergeResult) async {
        guard cloudSync?.projection?.heads == value.heads || cloudSync?.projection == nil else { return }
        if saving { deferredSyncProjection = value; return }
        saving = true
        defer { finishWrite() }
        await publishCanonicalProjection(value)
    }
    func publishCanonicalProjection(_ value: SyncMergeResult, cacheAlreadySaved: Bool = false) async {
        let noticeHistoryChanged = syncProjection?.workspace.history != value.workspace.history
        var reminderPreferencesChanged = false
        let contextChanged = syncProjection?.heads != value.heads || syncProjection?.pausedItemIDs != value.pausedItemIDs || syncProjection?.planningIsValid != value.planningIsValid
        if contextChanged { planningContextRevision += 1 }
        syncProjection = value
        do {
            let updated = try preferences.applyingSyncValues(value.preferences, calendars: calendar.calendars)
            if preferences != updated {
                reminderPreferencesChanged = true
                preferences = updated
                preferences.save(defaults: syncDefaults)
                revision += 1; calculationIsStale = true
                Task { await refresh() }
            }
            serviceIssues["同步设置需要检查"] = nil
        } catch { serviceIssues["同步设置需要检查"] = "收到的设置无法使用，请到设置检查同步冲突。\(error.localizedDescription)" }
        // Notification state lives in factual history and does not require a
        // successful planning projection, including remote read/snooze edits.
        if noticeHistoryChanged || reminderPreferencesChanged {
            await refreshStoredNotices()
            await scheduleReminders()
        }
        guard syncProjection?.heads == value.heads else { return }
        guard value.planningIsValid else {
            calculationIsStale = true
            isRefreshing = false
            planning = nil
            // SyncSettingsSection presents the conflict persistently; a remote merge must not interrupt navigation.
            return
        }
        let projected = value.planningWorkspace
        guard workspace != projected || contextChanged else { return }
        if workspace != projected {
            if !cacheAlreadySaved { await persistDurableProjection(projected) }
            workspace = projected
        }
        revision += 1
        calculationIsStale = true
        Task { await refresh() }
    }
    func refreshSync() async { await recoverPendingLocalSave(); await cloudSync?.refresh() }
    func connectCloudAccount(importLocal: Bool) async {
        let messageContext = messageContextVersion
        guard ReleaseCapabilities.cloudKitEnabled else { reportStatus(ReleaseCapabilities.cloudKitUnavailableMessage, context: messageContext); return }
        let probe = CloudSyncAdapter(containerID: Self.cloudContainerID, accountID: "probe", workspaceID: Self.syncWorkspaceID)
        do {
            switch try await probe.availability() {
            case .requiresSigning: reportStatus("当前安装的版本暂不支持 CloudKit 同步，可以继续使用本机数据或选择 iCloud Drive 同步目录。", context: messageContext)
            case .requiresAccount: reportStatus("请在系统设置检查 iCloud 登录状态和使用权限，再重试。", context: messageContext)
            case .available(let account):
                // Explicit partition switch; never bind an old account's journal to a new identity.
                guard await prepareSync(accountID: account, importLocal: importLocal, transportKind: "cloudkit") else { return }
                syncDefaults.set(account, forKey: "cubic.sync.activeAccount")
                syncDefaults.set("cloudkit", forKey: "cubic.sync.transport")
                await refreshSync()
                if let projection = cloudSync?.projection { await applySyncProjection(projection) }
            }
        } catch { reportFailure("iCloud 未能连接", message: "暂时无法连接 iCloud，请稍后重试。", context: messageContext) }
    }
    func inspectFileSyncDirectory(_ url: URL) async -> FileSyncDirectoryInspection? {
        do {
            return try await Task.detached(priority: .userInitiated) {
                try FileSyncDirectoryManager.inspect(directory: url, workspaceID: Self.syncWorkspaceID)
            }.value
        } catch { reportFailure("同步目录未能读取", message: error.localizedDescription); return nil }
    }
    func connectFileSyncDirectory(_ inspection: FileSyncDirectoryInspection, importLocal: Bool) async {
        do {
            let connection: FileSyncConnection
            if let existing = inspection.connection { connection = existing }
            else {
                connection = try await Task.detached(priority: .userInitiated) {
                    try FileSyncDirectoryManager.create(directory: inspection.directory, workspaceID: Self.syncWorkspaceID)
                }.value
            }
            let encoded = try JSONEncoder().encode(connection)
            guard await prepareSync(importLocal: importLocal, fileConnection: connection, transportKind: "file") else { return }
            let defaults = syncDefaults
            defaults.set(encoded, forKey: "cubic.sync.fileConnection")
            defaults.set(connection.metadata.remoteBinding.rawValue, forKey: "cubic.sync.activeAccount")
            defaults.set("file", forKey: "cubic.sync.transport")
            await refreshSync()
        } catch { reportFailure("文件同步未能连接", message: error.localizedDescription) }
    }
    func disconnectRemoteSync() async {
        guard await prepareSync(importLocal: false, transportKind: "local") else { return }
        syncDefaults.set("local", forKey: "cubic.sync.transport")
        await refreshSync()
    }
    func resolveSyncConflict(_ conflict: SyncConflict, revisionID: String?, removingDependencyIDs: Set<String>) async {
        let messageContext = messageContextVersion
        do {
            if conflict.kind == .dependencyCycle {
                let links = Set(conflict.paths.filter { $0.collection == "workLinks" }.map(\.entityID))
                try await cloudSync?.resolveRelationships(conflictID: conflict.id,
                    removingDependencyIDs: removingDependencyIDs.subtracting(links), removingWorkLinkIDs: removingDependencyIDs.intersection(links))
            } else if let revisionID {
                try await cloudSync?.resolve(conflictID: conflict.id, choosingRevisionID: revisionID)
            }
            if let projection = cloudSync?.projection { await applySyncProjection(projection) }
        } catch { _ = retainLocalRecovery(error); reportFailure("同步冲突未能处理", message: "冲突尚未处理完成，原记录已保留。\(error.localizedDescription)", context: messageContext) }
    }
    func syncRevision(id: String) async -> SyncRevision? { await syncJournal?.revision(id: id) }
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
    func syncRecordSummary(collection: String, id: String) -> String {
        let raw = syncProjection?.workspace ?? workspace
        func name(_ id: String) -> String { raw.items.first { $0.id == id }?.name ?? raw.nodes.first { $0.id == id }?.name ?? raw.blockers.first { $0.id == id }?.name ?? raw.projects.first { $0.id == id }?.name ?? "原记录" }
        switch collection {
        case "projectTemplates":
            if let template = raw.projectTemplate(id: id) {
                return "项目模板：\(template.title)\n\(template.payload?.project.name ?? "内容暂不可用")"
            }
        case "@preferences": return "Cubic 设置"
        case "workSessions":
            if let record = raw.workSessions.first(where: { $0.id == id }) {
                return "\(name(record.itemID))\n第 \(record.round ?? 1) 轮 · 投入 \(minutesLabel(record.actualMinutes))\n\((record.recordedAt ?? record.end).formatted(date: .abbreviated, time: .shortened))"
            }
        case "estimateRevisions":
            if let record = raw.estimateRevisions?.first(where: { $0.id == id }) {
                return "\(name(record.itemID)) · 第 \(record.round) 轮\n估计 \(minutesLabel(record.minutes))\n\(record.date.formatted(date: .abbreviated, time: .shortened))\n\(record.note)"
            }
        case "history":
            if let record = raw.history.first(where: { $0.id == id }) {
                return "\(name(record.objectID)) · \(ProjectUI.historyLabel(record.kind))\n原值 \(minutesLabel(record.previousMinutes)) → 记录值 \(minutesLabel(record.minutes))\n\(record.date.formatted(date: .abbreviated, time: .shortened))"
            }
        case "workRounds":
            if let record = raw.workRounds?.first(where: { $0.id == id }) {
                return "\(name(record.itemID))\n第 \(record.round) 轮\n首次估计 \(minutesLabel(record.initialMinutes)) · 开工前估计 \(minutesLabel(record.preStartMinutes))\n\(record.completedAt.map { "完成于 " + $0.formatted(date: .abbreviated, time: .shortened) } ?? record.startedAt.map { "开始于 " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "本轮未记录开始时间")"
            }
        case "blockerRounds":
            if let record = raw.blockerRounds?.first(where: { $0.id == id }) {
                return "\(name(record.blockerID)) · 第 \(record.round) 轮\n\(record.triggeredAt.map { "发起 " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "未记录开始时间")\n\(record.resolvedAt.map { "解除 " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "等待尚未结束")"
            }
        case "dependencies":
            if let dependency = raw.dependencies.first(where: { $0.id == id }) { return "\(name(dependency.source.id)) → \(name(dependency.targetItemID))" }
        case "workLinks":
            if let link = raw.workLinks?.first(where: { $0.id == id }) { return "\(name(link.source.id)) → \(name(link.nodeID ?? link.projectID))" }
        default: return name(id)
        }
        return "版本 \(id.prefix(8))；原记录保留"
    }
    func resolveSyncDeletion(_ conflict: SyncConflict, archive: Bool) async {
        let messageContext = messageContextVersion
        do {
            try await cloudSync?.resolveDeletion(conflictID: conflict.id, archive: archive)
            if let value = cloudSync?.projection { await applySyncProjection(value) }
        } catch { _ = retainLocalRecovery(error); reportFailure("关联冲突未能处理", message: "关联冲突尚未处理完成，原记录已保留。\(error.localizedDescription)", context: messageContext) }
    }
    func resolveSyncRecord(_ conflict: SyncConflict, entityID: String) async {
        let messageContext = messageContextVersion
        do {
            try await cloudSync?.resolveSemanticRecord(conflictID: conflict.id, choosingEntityID: entityID)
            if let value = cloudSync?.projection { await applySyncProjection(value) }
        } catch { _ = retainLocalRecovery(error); reportFailure("历史版本未能选定", message: "尚未选定历史版本，原记录已保留。\(error.localizedDescription)", context: messageContext) }
    }
    func resolveSyncReview(_ conflict: SyncConflict, outcome: ReviewOutcome) async {
        let messageContext = messageContextVersion
        guard let projected = syncProjection?.planningWorkspace else { return }
        do {
            var candidate = projected
            for id in conflict.affectedItemIDs {
                guard let item = candidate.items.first(where: { $0.id == id }), item.needsReview else { continue }
                try candidate.reviewItem(id: id, outcome: outcome, now: Date(), note: "人工处理并发前置变化")
            }
            try await cloudSync?.resolveInvariant(conflictID: conflict.id, workspace: candidate)
            if let value = cloudSync?.projection { await applySyncProjection(value) }
        } catch { _ = retainLocalRecovery(error); reportFailure("复核未完成", message: "复核尚未完成，原记录已保留。\(error.localizedDescription)", context: messageContext) }
    }
    func exportBackup() async -> Data? {
        let messageContext = messageContextVersion
        do {
            guard !saving, let cloudSync else { throw CoreError.invalid("暂时无法导出完整备份，请稍后重试。") }
            let original = workspace, settings = preferences
            let archive = try await cloudSync.exportArchive()
            guard !saving, original == workspace else { throw CoreError.invalid("导出期间数据发生变化，请重新导出最新备份。") }
            let copy = AppBackup(workspace: original, preferences: settings, syncArchive: archive)
            let data = try await Task.detached {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .millisecondsSince1970
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                return try encoder.encode(copy)
            }.value
            guard data.count <= 64 * 1024 * 1024 else { throw BackupError.tooLarge }
            return data
        } catch { reportFailure("备份未能导出", message: error.localizedDescription, context: messageContext); return nil }
    }
    func importBackup(_ data: Data) async -> Bool {
        let messageContext = messageContextVersion
        guard !saving, pendingLocalSave == nil else { return false }
        saving = true
        defer { finishWrite() }
        var factsImported = false
        do {
            guard data.count <= 64 * 1024 * 1024 else { throw BackupError.tooLarge }
            let backup = try await Task.detached {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
                let backup = try decoder.decode(AppBackup.self, from: data)
                guard (1...2).contains(backup.schemaVersion), backup.schemaVersion != 2 || backup.syncArchive != nil else { throw BackupError.unsupported }
                try backup.workspace.validate(); try backup.preferences.validate()
                return backup
            }.value
            let committed: Workspace
            if let archive = backup.syncArchive {
                guard let cloudSync else { throw CoreError.invalid("暂时无法导入备份，请稍后重试。") }
                let result = try await cloudSync.restoreArchive(archive)
                guard result.planningIsValid else {
                    await publishCanonicalProjection(result)
                    throw CoreError.invalid("原数据已保留。还有同步冲突需要到设置处理，当前数据未被覆盖。")
                }
                syncProjection = result
                committed = result.planningWorkspace
            } else {
                committed = try await journalLocalWorkspace(backup.workspace)
            }
            factsImported = true
            await persistDurableProjection(committed)
            workspace = committed
            guard let cloudSync else { throw CoreError.invalid("本机保存服务尚未准备好。") }
            let preferenceResult = try await cloudSync.recordPreferences(backup.preferences.syncValues(calendars: calendar.calendars))
            await publishCanonicalProjection(preferenceResult)
            revision += 1
            await refresh()
            reportStatus(backup.syncArchive != nil ? "备份已合并。有不同版本的内容时，请到设置处理同步冲突。" : "旧版备份已导入。这个格式不包含完整的同步修改历史。", context: messageContext)
            return true
        } catch {
            let partial = retainLocalRecovery(error)
            let detail = partial ? "已有记录需要恢复核对，请勿重复导入。" : factsImported ? "备份事实已导入，偏好导入尚未完成。" : "尚未完成导入；已写入的恢复事实和原记录保留。"
            reportFailure("备份导入需核对", message: "\(detail) \(error.localizedDescription)", context: messageContext); return false
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
