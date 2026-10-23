import Foundation
import EventKit
import Observation
import CubicCore

struct CalendarBridgeContext: Sendable {
    var workspace: Workspace
    var slots: [CapacitySlot]
    var externalBusy: [BusyInterval]
    var capacityVerified = true
    var storageReady = true
    var sourceRevision = ""
}

struct CalendarBridgeSource: Identifiable, Sendable {
    let id: String
    let title: String
    let kind: String
    var displayName: String { "\(title) · \(kind)" }
}

struct CalendarBridgeCalendar: Identifiable, Sendable {
    let id: String
    let title: String
    let sourceID: String
    let sourceName: String
    var containsCubicEvents: Bool = false
}

struct CalendarBridgeEvent: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let blockID: String?
    let busy: Bool
    let recurring: Bool
    var fingerprint: CalendarBlockFingerprint { .init(start: start, end: end) }
}

struct CalendarDivergence: Identifiable, Sendable {
    var id: String { blockID }
    let blockID: String
    let itemID: String
    let reason: String
    let cubicStart: Date
    let cubicEnd: Date
    let events: [CalendarBridgeEvent]
    let detectedAt: Date
}

enum CalendarBridgePhase: String, Sendable {
    case disabled, needsPermission, needsCalendar, ready, pending, divergence, unavailable
}

struct CalendarBridgeStatus: Sendable {
    var phase: CalendarBridgePhase = .disabled
    var authorized = false
    var calendarTitle: String?
    var sourceName: String?
    var lastReconciledAt: Date?
    var pendingCount = 0
    var divergenceCount = 0
    var unlinkedCount = 0
    var message: String?
}

struct CalendarBlockFingerprint: Codable, Sendable, Equatable {
    let start: Date
    let end: Date
    init(start: Date, end: Date) { self.start = start; self.end = end }
    init(_ block: WorkTimeBlock) { self.init(start: block.start, end: block.end) }
}

private struct CalendarEventCache: Codable, Sendable {
    var itemID: String?
    var localEventIdentifier: String?
    var lastSyncedFingerprint: CalendarBlockFingerprint?
    var lastExportedFingerprint: CalendarBlockFingerprint?
    var lastObservedFingerprint: CalendarBlockFingerprint?
    var lastSuccessfulWriteAt: Date?
}

private struct CalendarBridgeCache: Codable, Sendable {
    var enabled = false
    var localCalendarIdentifier: String?
    var sourceDescriptor: String?
    var lastResolvedAt: Date?
    var events: [String: CalendarEventCache] = [:]
}

private enum CalendarBridgeError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { message } else { nil } }
}

/// Only the SDK I/O boundary is replaceable. Reconciliation and device-local ownership remain in CalendarBridge.
protocol CalendarBridgeIO: Sendable {
    func requestAccess() async throws -> Bool
    func catalog(discover: Bool) async -> (authorized: Bool, calendars: [CalendarBridgeCalendar], sources: [CalendarBridgeSource])
    func resolveCalendar(_ id: String) async throws -> CalendarBridgeCalendar
    func createCalendar(sourceID: String) async throws -> String
    func read(calendarID: String, from: Date, to: Date, cachedIDs: [String]) async throws -> [CalendarBridgeEvent]
    func refetch(eventID: String, calendarID: String) async throws -> CalendarBridgeEvent
    func write(block: WorkTimeBlock, calendarID: String, existing: CalendarBridgeEvent?, title: String) async throws -> CalendarBridgeEvent
    func remove(eventID: String, calendarID: String, expectedBlockID: String) async throws
}

/// EventKit identifiers and reconciliation baselines are device-local. Only the URL marker is portable.
/// Domain callbacks must save through AppModel, never write workspace storage directly.
@MainActor @Observable final class CalendarBridge {
    private(set) var status = CalendarBridgeStatus()
    private(set) var calendars: [CalendarBridgeCalendar] = []
    private(set) var sources: [CalendarBridgeSource] = []
    private(set) var divergences: [CalendarDivergence] = []
    private(set) var unlinkedEvents: [CalendarBridgeEvent] = []
    private(set) var busyEvents: [BusyEvent] = []
    @ObservationIgnored private(set) var validationBusyEvents: [BusyEvent] = []
    private(set) var pausedBlockIDs: Set<String> = []
    private(set) var pendingBlockIDs: Set<String> = []
    var boundCalendarID: String? { cache.enabled ? cache.localCalendarIdentifier : nil }
    var enabled: Bool { cache.enabled }
    @ObservationIgnored private let eventStore: any CalendarBridgeIO
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cacheKey: String
    @ObservationIgnored private var cache: CalendarBridgeCache
    @ObservationIgnored private let context: @MainActor () async -> CalendarBridgeContext
    @ObservationIgnored private let applyExternal: @MainActor (WorkTimeBlock, WorkTimeBlock?, String?) async throws -> Void
    @ObservationIgnored private let removeBlock: @MainActor (String) async throws -> Void
    @ObservationIgnored private let isContextCurrent: @MainActor (String) -> Bool
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshRequested = false
    @ObservationIgnored private var configurationGeneration = 0
    @ObservationIgnored private var interactionActive = false
    @ObservationIgnored private var interactionWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var invalidated = false

    init(workspaceID: String = "cubic.primary", defaults: UserDefaults = .standard,
         context: @escaping @MainActor () async -> CalendarBridgeContext,
         applyExternal: @escaping @MainActor (WorkTimeBlock, WorkTimeBlock?, String?) async throws -> Void,
         removeBlock: @escaping @MainActor (String) async throws -> Void,
         isContextCurrent: @escaping @MainActor (String) -> Bool = { _ in true },
         eventStore: any CalendarBridgeIO = CalendarBridgeStore()) {
        self.eventStore = eventStore
        self.defaults = defaults
        cacheKey = "cubic.calendarBridge.\(workspaceID).deviceLocal.v1"
        cache = defaults.data(forKey: cacheKey).flatMap { try? JSONDecoder().decode(CalendarBridgeCache.self, from: $0) } ?? CalendarBridgeCache()
        self.context = context; self.applyExternal = applyExternal; self.removeBlock = removeBlock
        self.isContextCurrent = isContextCurrent
        status.phase = cache.enabled ? .needsCalendar : .disabled
    }

    func start() {
        guard !invalidated, observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }

    func stop() {
        timer?.cancel(); timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// Terminal lifecycle boundary; no further I/O is issued afterwards. Background stop() is reversible.
    func invalidate() {
        invalidated = true; configurationGeneration += 1
        stop()
        let waiters = interactionWaiters; interactionWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func ensureActive() throws {
        guard !invalidated else { throw CalendarBridgeError.invalid("同步数据已切换，请返回当前数据重新操作。") }
    }

    private func contextIsCurrent(_ input: CalendarBridgeContext) -> Bool {
        !invalidated && isContextCurrent(input.sourceRevision)
    }

    private func ensureCurrent(_ input: CalendarBridgeContext) throws {
        try ensureActive()
        guard contextIsCurrent(input) else {
            refreshRequested = true
            throw CalendarBridgeError.invalid("Cubic 工作或日历条件刚刚变化，请刷新后重试。")
        }
    }

    private func ensureWritable(_ input: CalendarBridgeContext) throws {
        try ensureCurrent(input)
        guard input.storageReady else {
            throw CalendarBridgeError.invalid("Cubic 权威数据尚未就绪，Apple Calendar 写入已暂停；请等待加载完成或修复本机保存问题。")
        }
    }

    @discardableResult func requestAccess() async throws -> Bool {
        try ensureActive()
        let granted = try await eventStore.requestAccess()
        try ensureActive()
        await refresh()
        return granted
    }

    func bind(calendarID: String) async throws {
        try ensureActive()
        let value = try await eventStore.resolveCalendar(calendarID)
        try ensureActive()
        configurationGeneration += 1
        if cache.localCalendarIdentifier != calendarID { cache.events = [:] }
        cache.enabled = true; cache.localCalendarIdentifier = calendarID
        cache.sourceDescriptor = value.sourceName
        persist(); await refresh()
    }

    func create(sourceID: String) async throws {
        try ensureActive()
        let calendarID = try await eventStore.createCalendar(sourceID: sourceID)
        try ensureActive()
        try await bind(calendarID: calendarID)
    }

    func disable() {
        guard !invalidated else { return }
        configurationGeneration += 1
        cache.enabled = false; persist()
        divergences = []; unlinkedEvents = []; busyEvents = []; pausedBlockIDs = []; pendingBlockIDs = []
        validationBusyEvents = []
        status = CalendarBridgeStatus()
    }

    /// Coalesce notifications and domain-save refreshes; a callback can request another pass without reentrancy.
    func refresh() async {
        guard !invalidated else { return }
        if refreshing || interactionActive { refreshRequested = true; return }
        refreshing = true
        defer {
            refreshing = false
            if !interactionWaiters.isEmpty {
                interactionActive = true
                interactionWaiters.removeFirst().resume()
            }
        }
        repeat {
            refreshRequested = false
            await reconcile()
        } while !invalidated && refreshRequested && interactionWaiters.isEmpty && !Task.isCancelled
    }

    private func beginInteraction() async throws {
        try ensureActive()
        if refreshing || interactionActive { await withCheckedContinuation { interactionWaiters.append($0) } }
        else { interactionActive = true }
        try ensureActive()
    }

    private func endInteraction() {
        if !interactionWaiters.isEmpty { interactionWaiters.removeFirst().resume() }
        else {
            interactionActive = false
            Task { @MainActor [weak self] in await self?.refresh() }
        }
    }

    private func reconcile() async {
        guard !invalidated else { return }
        let generation = configurationGeneration
        let input = await context()
        guard contextIsCurrent(input), generation == configurationGeneration else { refreshRequested = true; return }
        let catalog = await eventStore.catalog(discover: cache.localCalendarIdentifier == nil)
        guard contextIsCurrent(input), generation == configurationGeneration else { refreshRequested = true; return }
        calendars = catalog.calendars; sources = catalog.sources
        status.authorized = catalog.authorized
        guard cache.enabled else { status.phase = .disabled; return }
        let blocks = input.workspace.timeBlocks ?? []
        guard catalog.authorized else {
            pauseAll(blocks, phase: .needsPermission, message: "Apple Calendar 完整访问权限不可用；工作数据保留，日历占用无法核实。")
            return
        }
        guard let calendarID = cache.localCalendarIdentifier, let calendar = calendars.first(where: { $0.id == calendarID }) else {
            pauseAll(blocks, phase: .unavailable, message: "Cubic 日历已不可用。请选择重新创建、绑定其他日历或关闭同步。")
            return
        }
        status.calendarTitle = calendar.title; status.sourceName = calendar.sourceName
        let now = Date()
        // Query in annual pieces (EventKit limits predicate ranges). Cached IDs additionally find moved events.
        let lower = min(blocks.map(\.start).min() ?? now, now.addingTimeInterval(-366 * 86_400))
        let upper = max(blocks.map(\.end).max() ?? now, now.addingTimeInterval(2 * 366 * 86_400))
        let events: [CalendarBridgeEvent]
        do {
            events = try await eventStore.read(calendarID: calendarID, from: lower, to: upper,
                                               cachedIDs: cache.events.values.compactMap(\.localEventIdentifier))
        } catch {
            pauseAll(blocks, phase: .unavailable, message: error.localizedDescription); return
        }
        guard contextIsCurrent(input), generation == configurationGeneration else { refreshRequested = true; return }
        guard input.storageReady else {
            // Workspace data is not loaded yet. Never infer Calendar deletions from it;
            // all actual Events remain busy until it is available.
            pauseAll(blocks, phase: .unavailable, message: "Cubic 权威数据尚未就绪，Apple Calendar 写入已暂停；现有日历事件保留。")
            busyEvents = events.filter(\.busy).map { BusyEvent(id: "cubic.bridge.\($0.id)", title: $0.title,
                                                             start: $0.start, end: $0.end, allDay: $0.allDay, calendarID: calendarID) }
            validationBusyEvents = busyEvents
            return
        }
        cache.lastResolvedAt = now
        var grouped: [String: [CalendarBridgeEvent]] = [:]
        for event in events { if let id = event.blockID { grouped[id, default: []].append(event) } }
        let blockIDs = Set(blocks.map(\.id))
        let blockByID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        var currentIssues = (try? input.workspace.calendarTimeBlockIssues(slots: input.slots, busy: input.externalBusy, now: now)) ??
            Dictionary(uniqueKeysWithValues: blocks.filter { $0.end > now }.map { ($0.id, "工作时间容量无法核实，请刷新后重新确认。") })
        if !input.capacityVerified {
            for block in blocks where block.end > now { currentIssues[block.id] = "当前工作时段或外部日历容量尚未核实，请刷新后重新确认。" }
        }
        var possibleBusy = events.filter { event in
            guard let id = event.blockID, let block = blockByID[id] else { return true }
            return (grouped[id]?.count ?? 0) > 1 || event.fingerprint != CalendarBlockFingerprint(block) || currentIssues[id] != nil
        }
        // Invalid mapped events also occupy real capacity and can invalidate an otherwise valid equal mapping.
        var pendingAssociationOwners: [String: String] = [:]
        for (id, record) in cache.events where blockIDs.contains(id) && record.lastSyncedFingerprint == nil {
            if let identifier = record.localEventIdentifier { pendingAssociationOwners[identifier] = id }
        }
        var unlinkedBusy: [BusyInterval] = [], mappedBusy: [String: [BusyInterval]] = [:]
        for event in possibleBusy where event.busy {
            let interval = BusyInterval(start: event.start, end: event.end)
            if let owner = event.blockID ?? pendingAssociationOwners[event.id] { mappedBusy[owner, default: []].append(interval) }
            else { unlinkedBusy.append(interval) }
        }
        let occupiedIssues = (try? input.workspace.calendarTimeBlockIssues(slots: input.slots, busy: input.externalBusy + unlinkedBusy,
                                                                           mappedBusy: mappedBusy, now: now)) ?? [:]
        for (id, reason) in occupiedIssues where currentIssues[id] == nil { currentIssues[id] = reason }
        let busyIDs = Set(possibleBusy.map(\.id))
        possibleBusy += events.filter { event in !busyIDs.contains(event.id) && event.blockID.map { currentIssues[$0] != nil } == true }
        // Publish fresh candidates before domain callbacks so validation can exclude only its own event.
        validationBusyEvents = possibleBusy.filter(\.busy).map { BusyEvent(id: "cubic.bridge.\($0.id)", title: $0.title,
                                                               start: $0.start, end: $0.end, allDay: $0.allDay, calendarID: calendarID) }
        var failures: [CalendarDivergence] = []
        var pending = 0
        var pendingIDs: Set<String> = []
        var errorMessage: String?
        var busy: [CalendarBridgeEvent] = events.filter { $0.blockID == nil || !blockIDs.contains($0.blockID!) }
        var unlinked = busy
        for block in blocks {
            guard contextIsCurrent(input), generation == configurationGeneration else { refreshRequested = true; return }
            let matches = grouped[block.id] ?? []
            let baseline = cache.events[block.id]?.lastSyncedFingerprint
            let domain = CalendarBlockFingerprint(block)
            var reason: String?
            if matches.count > 1 { reason = "同一时间块有多个 Apple Calendar 事件，请保留一个事件后重新核对。" }
            else if let event = matches.first {
                if event.allDay || event.recurring { reason = "全天或重复事件不能自动成为 Cubic 工作时间块，请改为单次具体时段。" }
                else if event.fingerprint == domain {
                    if let issue = currentIssues[block.id] { reason = issue }
                    else { remember(blockID: block.id, itemID: block.itemID, event: event, fingerprint: domain) }
                } else if let baseline {
                    let domainChanged = domain != baseline
                    let eventChanged = event.fingerprint != baseline
                    if domainChanged && eventChanged { reason = "Cubic 与 Apple Calendar 同时修改了这个时间块，请明确选择要保留的时间。" }
                    else if domainChanged {
                        if let issue = currentIssues[block.id] { reason = issue }
                        else {
                            do { try await export(block, calendarID: calendarID, existing: event, title: itemTitle(block, workspace: input.workspace), contextInput: input) }
                            catch { pending += 1; pendingIDs.insert(block.id); busy.append(contentsOf: matches); errorMessage = error.localizedDescription }
                        }
                    } else {
                        do { try await importEvent(event, block: block, input: input) }
                        catch { reason = error.localizedDescription }
                    }
                } else {
                    reason = "Apple Calendar 与 Cubic 时间不同，当前设备没有共同核对基线，请确认要接受或恢复的时间。"
                }
            } else if cache.events[block.id]?.lastSyncedFingerprint != nil {
                reason = "Apple Calendar 中的对应事件已删除或暂时不可见；Cubic 时间块保留，等待确认。"
            } else {
                // Historical Cubic blocks are not newly published as calendar reservations.
                if block.end <= now { continue }
                if let issue = currentIssues[block.id] { reason = issue }
                else {
                    // An association whose marker write failed still owns the original local Event ID.
                    let pendingAssociation = cache.events[block.id]?.localEventIdentifier.flatMap { id in events.first { $0.id == id && $0.blockID == nil } }
                    do { try await export(block, calendarID: calendarID, existing: pendingAssociation, title: itemTitle(block, workspace: input.workspace), contextInput: input)
                        if let pendingAssociation { busy.removeAll { $0.id == pendingAssociation.id }; unlinked.removeAll { $0.id == pendingAssociation.id } }
                    }
                    catch { pending += 1; pendingIDs.insert(block.id); errorMessage = error.localizedDescription }
                }
            }
            if let reason {
                failures.append(CalendarDivergence(blockID: block.id, itemID: block.itemID, reason: reason,
                                                   cubicStart: block.start, cubicEnd: block.end, events: matches,
                                                   detectedAt: divergences.first(where: { $0.blockID == block.id })?.detectedAt ?? now))
                busy.append(contentsOf: matches)
            }
        }
        // Only a previously mapped local block can justify deleting an Event. Unknown markers await data sync.
        for id in Array(cache.events.keys) where !blockIDs.contains(id) {
            guard contextIsCurrent(input), generation == configurationGeneration else { refreshRequested = true; return }
            do {
                for event in grouped[id] ?? [] {
                    guard contextIsCurrent(input), generation == configurationGeneration else { refreshRequested = true; return }
                    try await eventStore.remove(eventID: event.id, calendarID: calendarID, expectedBlockID: id)
                    guard contextIsCurrent(input), generation == configurationGeneration else { refreshRequested = true; return }
                }
                cache.events.removeValue(forKey: id)
                busy.removeAll { $0.blockID == id }
                unlinked.removeAll { $0.blockID == id }
            } catch { pending += 1; errorMessage = error.localizedDescription }
        }
        guard contextIsCurrent(input), generation == configurationGeneration else { refreshRequested = true; return }
        divergences = failures
        unlinkedEvents = unlinked
        pausedBlockIDs = Set(failures.map(\.blockID)).union(pendingIDs)
        pendingBlockIDs = pendingIDs
        busyEvents = busy.filter(\.busy).map { BusyEvent(id: "cubic.bridge.\($0.id)", title: $0.title, start: $0.start, end: $0.end,
                                                       allDay: $0.allDay, calendarID: calendarID) }
        validationBusyEvents = busyEvents
        status.phase = failures.isEmpty ? (pending == 0 ? .ready : .pending) : .divergence
        status.pendingCount = pending; status.divergenceCount = failures.count
        status.unlinkedCount = unlinkedEvents.count; status.message = errorMessage
        status.lastReconciledAt = now
        persist()
    }

    private func pauseAll(_ blocks: [WorkTimeBlock], phase: CalendarBridgePhase, message: String) {
        status.phase = phase; status.message = message
        pausedBlockIDs = Set(blocks.map(\.id)); busyEvents = []
        validationBusyEvents = []
        pendingBlockIDs = Set(blocks.map(\.id))
        status.pendingCount = blocks.count
        // Do not claim stale EventKit objects describe current busy time.
        divergences = []; unlinkedEvents = []
        status.divergenceCount = 0; status.unlinkedCount = 0
    }

    private func itemTitle(_ block: WorkTimeBlock, workspace: Workspace) -> String {
        workspace.items.first(where: { $0.id == block.itemID })?.name ?? "Cubic 工作时间块"
    }

    private func importEvent(_ event: CalendarBridgeEvent, block: WorkTimeBlock, input: CalendarBridgeContext) async throws {
        try ensureWritable(input)
        let generation = configurationGeneration
        guard input.capacityVerified else { throw CalendarBridgeError.invalid("外部日历占用尚未核实，请刷新日历后再接受修改。") }
        guard !event.allDay, !event.recurring else { throw CalendarBridgeError.invalid("请选择单次、非全天事件。") }
        let proposed = WorkTimeBlock(id: block.id, itemID: block.itemID, start: event.start, end: event.end)
        var draft = input.workspace
        let bridgeBusy = validationBusyEvents.filter { $0.id != "cubic.bridge.\(event.id)" }.map { BusyInterval(start: $0.start, end: $0.end) }
        try draft.setTimeBlock(proposed, slots: input.slots, busy: input.externalBusy + bridgeBusy, now: Date())
        try await applyExternal(proposed, block, event.id)
        try ensureActive()
        guard generation == configurationGeneration else { throw CalendarBridgeError.invalid("绑定日历已变化，请重新核对。") }
        let committedInput = await context()
        try ensureWritable(committedInput)
        guard generation == configurationGeneration,
              committedInput.workspace.timeBlocks?.first(where: { $0.id == block.id }) == proposed else {
            throw CalendarBridgeError.invalid("Cubic 时间块刚刚变化，请刷新后核对日历时间。")
        }
        remember(blockID: block.id, itemID: block.itemID, event: event, fingerprint: event.fingerprint)
    }

    private func export(_ block: WorkTimeBlock, calendarID: String, existing: CalendarBridgeEvent?, title: String,
                        contextInput: CalendarBridgeContext) async throws {
        try ensureWritable(contextInput)
        let generation = configurationGeneration
        let event = try await eventStore.write(block: block, calendarID: calendarID, existing: existing, title: title)
        try ensureActive()
        guard generation == configurationGeneration, boundCalendarID == calendarID else { throw CalendarBridgeError.invalid("绑定日历已变化，请重新核对。") }
        let fingerprint = CalendarBlockFingerprint(block)
        guard event.fingerprint == fingerprint else { throw CalendarBridgeError.invalid("Apple Calendar 未确认时间块写入，请稍后重试。") }
        remember(blockID: block.id, itemID: block.itemID, event: event, fingerprint: fingerprint)
        cache.events[block.id]?.lastExportedFingerprint = fingerprint
        cache.events[block.id]?.lastSuccessfulWriteAt = Date()
        persist()
        // A domain change during an already-issued SDK save cannot undo that save. Preserve its local
        // ownership receipt so the fresh pass can delete a now-removed block's Event instead of orphaning it.
        try ensureWritable(contextInput)
    }

    private func remember(blockID: String, itemID: String, event: CalendarBridgeEvent, fingerprint: CalendarBlockFingerprint) {
        var record = cache.events[blockID] ?? CalendarEventCache()
        record.itemID = itemID
        record.localEventIdentifier = event.id; record.lastSyncedFingerprint = fingerprint
        record.lastObservedFingerprint = event.fingerprint; cache.events[blockID] = record
    }

    func accept(blockID: String) async throws {
        try await beginInteraction()
        defer { endInteraction() }
        guard let divergence = divergences.first(where: { $0.blockID == blockID }), divergence.events.count == 1 else {
            throw CalendarBridgeError.invalid("请选择一个有效的 Apple Calendar 事件。")
        }
        let input = await context()
        try ensureWritable(input)
        guard let block = input.workspace.timeBlocks?.first(where: { $0.id == blockID }), let calendarID = boundCalendarID else { throw CalendarBridgeError.invalid("时间块或绑定日历已不可用。") }
        let event = try await eventStore.refetch(eventID: divergence.events[0].id, calendarID: calendarID)
        try ensureWritable(input)
        try await importEvent(event, block: block, input: input)
        persist(); await refresh()
    }

    func restore(blockID: String) async throws {
        try await beginInteraction()
        defer { endInteraction() }
        let input = await context()
        try ensureWritable(input)
        guard let block = input.workspace.timeBlocks?.first(where: { $0.id == blockID }), let calendarID = boundCalendarID else { throw CalendarBridgeError.invalid("时间块或绑定日历已不可用。") }
        let events = try await readCurrentEvents(input: input, calendarID: calendarID)
        let index = eventIndex(events)
        try await restore(block, input: input, calendarID: calendarID, index: index)
        await refresh()
    }

    func cancel(blockID: String) async throws {
        try await beginInteraction()
        defer { endInteraction() }
        let input = await context()
        try ensureWritable(input)
        try await removeBlock(blockID)
        let committedInput = await context()
        try ensureWritable(committedInput)
        await refresh()
    }

    func associate(eventID: String, itemID: String) async throws {
        try await beginInteraction()
        defer { endInteraction() }
        guard let calendarID = boundCalendarID else { throw CalendarBridgeError.invalid("请先绑定 Cubic 日历。") }
        let event = try await eventStore.refetch(eventID: eventID, calendarID: calendarID)
        try ensureActive()
        guard event.blockID == nil else { throw CalendarBridgeError.invalid("此事件已有 Cubic 标记，请先等待数据同步，不要创建重复时间块。") }
        let input = await context()
        try ensureWritable(input)
        let block = WorkTimeBlock(itemID: itemID, start: event.start, end: event.end)
        guard input.capacityVerified, !event.allDay, !event.recurring else { throw CalendarBridgeError.invalid("请先核实日历占用；只支持单次、非全天事件。") }
        var draft = input.workspace
        let otherBusy = validationBusyEvents.filter { $0.id != "cubic.bridge.\(event.id)" }.map { BusyInterval(start: $0.start, end: $0.end) }
        try draft.setTimeBlock(block, slots: input.slots, busy: input.externalBusy + otherBusy, now: Date())
        // A failed save removes only this local association intent.
        cache.events[block.id] = CalendarEventCache(itemID: itemID, localEventIdentifier: event.id)
        persist()
        do { try await applyExternal(block, nil, event.id) }
        catch { cache.events[block.id] = nil; persist(); throw error }
        try ensureActive()
        let committedInput = await context()
        try ensureWritable(committedInput)
        guard committedInput.workspace.timeBlocks?.first(where: { $0.id == block.id }) == block else {
            throw CalendarBridgeError.invalid("Cubic 时间块刚刚变化，请刷新后核对原日历事件。")
        }
        do { try await export(block, calendarID: calendarID, existing: event, title: itemTitle(block, workspace: committedInput.workspace), contextInput: committedInput) }
        catch { status.phase = .pending; status.message = error.localizedDescription; status.pendingCount += 1; throw error }
        await refresh()
    }

    func republish() async throws {
        try await beginInteraction()
        defer { endInteraction() }
        let input = await context()
        try ensureWritable(input)
        guard let calendarID = boundCalendarID else { throw CalendarBridgeError.invalid("请先绑定 Cubic 日历。") }
        // One batch scan reconstructs marker mappings, including ready events with no divergence row.
        let events = try await readCurrentEvents(input: input, calendarID: calendarID)
        let index = eventIndex(events)
        for block in input.workspace.timeBlocks ?? [] where block.end > Date() {
            try await restore(block, input: input, calendarID: calendarID, index: index)
        }
        await refresh()
    }

    private func readCurrentEvents(input: CalendarBridgeContext, calendarID: String) async throws -> [CalendarBridgeEvent] {
        try ensureWritable(input)
        let now = Date(), blocks = input.workspace.timeBlocks ?? []
        let lower = min(blocks.map(\.start).min() ?? now, now.addingTimeInterval(-366 * 86_400))
        let upper = max(blocks.map(\.end).max() ?? now, now.addingTimeInterval(2 * 366 * 86_400))
        let events = try await eventStore.read(calendarID: calendarID, from: lower, to: upper,
                                               cachedIDs: cache.events.values.compactMap(\.localEventIdentifier))
        try ensureWritable(input)
        return events
    }

    private func eventIndex(_ events: [CalendarBridgeEvent]) -> (blocks: [String: [CalendarBridgeEvent]], localIDs: [String: CalendarBridgeEvent]) {
        (Dictionary(grouping: events.filter { $0.blockID != nil }, by: { $0.blockID! }),
         Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) }))
    }

    private func restore(_ block: WorkTimeBlock, input: CalendarBridgeContext, calendarID: String,
                         index: (blocks: [String: [CalendarBridgeEvent]], localIDs: [String: CalendarBridgeEvent])) async throws {
        try ensureWritable(input)
        let matches = index.blocks[block.id] ?? []
        guard matches.count <= 1 else { throw CalendarBridgeError.invalid("请先在 Apple Calendar 删除重复事件，保留一个事件后再恢复。") }
        let pendingAssociation = cache.events[block.id]?.localEventIdentifier.flatMap { identifier in
            index.localIDs[identifier].flatMap { $0.blockID == nil ? $0 : nil }
        }
        try await export(block, calendarID: calendarID, existing: matches.first ?? pendingAssociation,
                         title: itemTitle(block, workspace: input.workspace), contextInput: input)
    }

    private func persist() { if let data = try? JSONEncoder().encode(cache) { defaults.set(data, forKey: cacheKey) } }
}

/// The SDK's synchronous scans and writes stay off MainActor and all EK objects stay inside this actor.
actor CalendarBridgeStore: CalendarBridgeIO {
    private let store = EKEventStore()

    func requestAccess() async throws -> Bool { try await store.requestFullAccessToEvents() }

    func catalog(discover: Bool) -> (authorized: Bool, calendars: [CalendarBridgeCalendar], sources: [CalendarBridgeSource]) {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return (false, [], []) }
        store.reset()
        let calendars = store.calendars(for: .event).filter(\.allowsContentModifications).map { calendar in
            var containsMarkers = false
            if discover {
                let now = Date()
                let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-366 * 86_400),
                                                         end: now.addingTimeInterval(2 * 366 * 86_400), calendars: [calendar])
                containsMarkers = store.events(matching: predicate).contains { Self.marker($0.url) != nil }
            }
            return CalendarBridgeCalendar(id: calendar.calendarIdentifier, title: calendar.title, sourceID: calendar.source.sourceIdentifier,
                                          sourceName: calendar.source.title, containsCubicEvents: containsMarkers)
        }
        let sources = store.sources.filter { ![EKSourceType.birthdays, .subscribed].contains($0.sourceType) }.map {
            CalendarBridgeSource(id: $0.sourceIdentifier, title: $0.title, kind: sourceKind($0.sourceType))
        }
        return (true, calendars, sources)
    }

    private func sourceKind(_ type: EKSourceType) -> String {
        switch type {
        case .local: return "此设备本地"
        case .calDAV: return "CalDAV / iCloud"
        case .exchange: return "Exchange"
        case .mobileMe: return "iCloud"
        default: return "Calendar account"
        }
    }

    func resolveCalendar(_ id: String) throws -> CalendarBridgeCalendar {
        let calendar = try writableCalendar(id)
        return CalendarBridgeCalendar(id: id, title: calendar.title, sourceID: calendar.source.sourceIdentifier, sourceName: calendar.source.title)
    }

    func createCalendar(sourceID: String) throws -> String {
        try requireAccess()
        guard let source = store.sources.first(where: { $0.sourceIdentifier == sourceID }), ![EKSourceType.birthdays, .subscribed].contains(source.sourceType) else { throw CalendarBridgeError.invalid("此 Calendar account 不支持创建日历，请选择其他来源。") }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = "Cubic"; calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        return calendar.calendarIdentifier
    }

    func read(calendarID: String, from: Date, to: Date, cachedIDs: [String]) throws -> [CalendarBridgeEvent] {
        let calendar = try writableCalendar(calendarID)
        var result: [String: CalendarBridgeEvent] = [:]
        var start = from
        while start < to {
            let end = min(start.addingTimeInterval(366 * 86_400), to)
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])
            for event in store.events(matching: predicate) { if let value = snapshot(event) { result[value.id] = value } }
            start = end
        }
        for id in cachedIDs {
            if let event = store.event(withIdentifier: id), event.calendar.calendarIdentifier == calendarID,
               let value = snapshot(event) { result[value.id] = value }
        }
        return result.values.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }

    func refetch(eventID: String, calendarID: String) throws -> CalendarBridgeEvent {
        _ = try writableCalendar(calendarID)
        guard let event = store.event(withIdentifier: eventID), event.calendar.calendarIdentifier == calendarID,
              let value = snapshot(event) else { throw CalendarBridgeError.invalid("事件已变化或不可见，请刷新后重试。") }
        return value
    }

    func write(block: WorkTimeBlock, calendarID: String, existing: CalendarBridgeEvent?, title: String) throws -> CalendarBridgeEvent {
        let calendar = try writableCalendar(calendarID)
        let event: EKEvent
        if let existing {
            guard let found = store.event(withIdentifier: existing.id), found.calendar.calendarIdentifier == calendarID else { throw CalendarBridgeError.invalid("原事件已不可见，请刷新后确认恢复。") }
            guard snapshot(found) == existing else { throw CalendarBridgeError.invalid("Apple Calendar 事件刚刚变化，请刷新后重新核对。") }
            let mappedID = Self.marker(found.url)
            guard mappedID == nil || mappedID == block.id else { throw CalendarBridgeError.invalid("事件身份发生变化，请重新核对关联。") }
            guard !found.hasRecurrenceRules else { throw CalendarBridgeError.invalid("重复事件不能作为单个 Cubic 时间块。") }
            event = found
        } else { event = EKEvent(eventStore: store); event.calendar = calendar }
        event.title = title; event.startDate = block.start; event.endDate = block.end; event.isAllDay = false
        var components = URLComponents()
        components.scheme = "cubic"; components.host = "time-block"; components.path = "/\(block.id)"
        guard let url = components.url else { throw CalendarBridgeError.invalid("时间块身份无法编码。") }
        event.url = url
        try store.save(event, span: .thisEvent, commit: true)
        guard let identifier = event.eventIdentifier else { throw CalendarBridgeError.invalid("Apple Calendar 未返回已保存事件的身份。") }
        return try refetch(eventID: identifier, calendarID: calendarID)
    }

    func remove(eventID: String, calendarID: String, expectedBlockID: String) throws {
        _ = try writableCalendar(calendarID)
        guard let event = store.event(withIdentifier: eventID) else { return }
        guard event.calendar.calendarIdentifier == calendarID, Self.marker(event.url) == expectedBlockID else { throw CalendarBridgeError.invalid("事件关联已改变，未删除其他日历事件。") }
        guard !event.hasRecurrenceRules else { throw CalendarBridgeError.invalid("事件已变为重复系列，请在 Apple Calendar 中处理。") }
        try store.remove(event, span: .thisEvent, commit: true)
    }

    private func requireAccess() throws {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw CalendarBridgeError.invalid("需要 Apple Calendar 完整访问权限。") }
    }

    private func writableCalendar(_ id: String) throws -> EKCalendar {
        try requireAccess()
        guard let value = store.calendar(withIdentifier: id), value.allowsContentModifications else { throw CalendarBridgeError.invalid("绑定的 Cubic 日历已删除、只读或不可用，请重新选择日历。") }
        return value
    }

    private func snapshot(_ event: EKEvent) -> CalendarBridgeEvent? {
        guard let id = event.eventIdentifier, let start = event.startDate, let end = event.endDate else { return nil }
        return CalendarBridgeEvent(id: id, title: event.title ?? "日历占用", start: start, end: end, allDay: event.isAllDay,
                                   blockID: Self.marker(event.url), busy: event.availability != .free && event.status != .canceled,
                                   recurring: event.hasRecurrenceRules)
    }

    private static func marker(_ url: URL?) -> String? {
        guard let url, url.scheme?.lowercased() == "cubic", url.host?.lowercased() == "time-block",
              url.query == nil, url.fragment == nil else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 1, !parts[0].isEmpty else { return nil }
        return String(parts[0])
    }
}
