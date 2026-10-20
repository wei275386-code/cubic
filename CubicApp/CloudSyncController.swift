import Foundation
import Observation
import CloudKit
import Network
import CubicCore
#if canImport(UIKit)
import UIKit
#endif

/// Root owns integration: keep this object alive, call start() on foreground and stop() on background.
/// onMerge must preserve disputed facts and feed pausedItemIDs to planning; it is never called across accounts.
@MainActor @Observable final class CloudSyncController {
    private(set) var status = SyncStatus()
    private(set) var projection: SyncMergeResult?
    private(set) var localError: String?
    @ObservationIgnored private let remoteEnabled: Bool
    @ObservationIgnored private let coordinator: SyncCoordinator
    @ObservationIgnored private var automaticTask: Task<Void, Never>?
    @ObservationIgnored private var directoryHintTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: (id: UUID, task: Task<SyncStatus, Never>)?
    @ObservationIgnored private var retired = false
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let onMerge: (@MainActor (SyncMergeResult) -> Void)?
    init(coordinator: SyncCoordinator, remoteEnabled: Bool = true, onMerge: (@MainActor (SyncMergeResult) -> Void)? = nil) {
        self.coordinator = coordinator; self.remoteEnabled = remoteEnabled; self.onMerge = onMerge
    }
    func start(intervalSeconds: TimeInterval = 60) {
        guard !retired else { return }
        stop()
        // Local and Release-blocked legacy bindings need no polling or network monitor.
        // Local writes and explicit refresh already publish journal status.
        guard remoteEnabled else { Task { await self.refresh() }; return }
        let interval = min(3600, max(30, intervalSeconds.isFinite ? intervalSeconds : 60))
        observers.append(NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.status.phase = .accountChanged
                self.status.message = "iCloud 账号发生变化，原账号 journal 保留；正在核对独立 workspace。"
                await self.refresh()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .cubicFileSyncDirectoryChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.directoryHintTask?.cancel()
                self.directoryHintTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
                    await self?.refresh()
                }
            }
        })
        if remoteEnabled {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                if path.status == .satisfied { Task { @MainActor [weak self] in await self?.refresh() } }
            }
            monitor.start(queue: DispatchQueue(label: "cubic.sync.network"))
            pathMonitor = monitor
        }
        #if canImport(UIKit)
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        })
        #endif
        automaticTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(self?.status.phase == .pending ? 2 : interval)) } catch { return }
            }
        }
    }
    func stop() {
        automaticTask?.cancel(); automaticTask = nil
        pathMonitor?.cancel(); pathMonitor = nil
        directoryHintTask?.cancel(); directoryHintTask = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }
    /// Finish the old transport before another controller writes to this journal.
    /// This also covers manual and post-save refreshes, not just the polling loop.
    func retire() async {
        retired = true
        stop()
        let task = refreshTask?.task
        task?.cancel()
        _ = await task?.value
        refreshTask = nil
    }
    func resumeAfterFailedSwitch() {
        retired = false
        start()
    }
    func refresh() async {
        guard !retired else { return }
        // Automatic polling retains the last meaningful status instead of flashing a transient row every minute.
        if remoteEnabled {
            let flight: (id: UUID, task: Task<SyncStatus, Never>)
            if let running = refreshTask { flight = running }
            else {
                flight = (UUID(), Task { [coordinator] in await coordinator.refresh() })
                refreshTask = flight
            }
            let updated = await flight.task.value
            guard !retired, refreshTask?.id == flight.id else { return }
            refreshTask = nil
            status = updated
        }
        else {
            status = (try? await coordinator.journal.syncStatus()) ?? SyncStatus()
            if status.conflicts.isEmpty { status.phase = .localOnly }
        }
        guard [.synced, .pending, .conflict].contains(status.phase) else { return }
        do {
            let value = try await coordinator.snapshot()
            projection = value; onMerge?(value)
        } catch { localError = String(describing: error) }
    }
    /// A local fact is already durable. Status/network failures cannot reclassify that save.
    @discardableResult func acceptLocalCommit(_ value: SyncMergeResult) async -> SyncMergeResult {
        // Fetch current canonical heads because a remote ingest may have raced the cache await.
        let current = (try? await coordinator.snapshot()) ?? value
        projection = current
        if let stored = try? await coordinator.journal.syncStatus() { status = stored }
        localError = nil
        Task { @MainActor [weak self] in await self?.refresh() }
        return current
    }
    func bindAccount(_ accountID: String) async throws {
        try await coordinator.bindAccount(accountID); await refresh()
    }
    @discardableResult func record(workspace: Workspace, currentChoiceID: String?, expectedHeads: [String]? = nil) async throws -> SyncMergeResult {
        do {
            let value = try await coordinator.record(workspace: workspace, currentChoiceID: currentChoiceID, expectedHeads: expectedHeads)
            projection = value; status = await coordinator.status(); localError = nil
            // Durable local save returns without waiting for networking. Autosync runs independently.
            Task { @MainActor [weak self] in await self?.refresh() }
            return value
        } catch {
            localError = String(describing: error)
            if expectedHeads != nil, let current = try? await coordinator.snapshot() {
                projection = current; status = await coordinator.status(); onMerge?(current)
            }
            throw error
        }
    }
    func resolve(conflictID: String, choosingRevisionID: String) async throws {
        let value = try await coordinator.resolve(conflictID: conflictID, choosingRevisionID: choosingRevisionID)
        projection = value; status = await coordinator.status(); onMerge?(value)
        Task { @MainActor [weak self] in await self?.refresh() }
    }
    @discardableResult func recordPreferences(_ values: [String: SyncValue]) async throws -> SyncMergeResult {
        do {
            let value = try await coordinator.recordPreferences(values)
            projection = value; status = await coordinator.status(); localError = nil
            Task { @MainActor [weak self] in await self?.refresh() }
            return value
        } catch { localError = String(describing: error); throw error }
    }
    func resolveCurrentChoice(conflictID: String, choosingChoiceID: String?) async throws {
        let value = try await coordinator.resolveCurrentChoice(conflictID: conflictID, choosingChoiceID: choosingChoiceID)
        projection = value; status = await coordinator.status(); onMerge?(value)
        Task { @MainActor [weak self] in await self?.refresh() }
    }
    func resolveRelationships(conflictID: String, removingDependencyIDs: Set<String>, removingWorkLinkIDs: Set<String> = []) async throws {
        let value = try await coordinator.resolveRelationships(conflictID: conflictID, removingDependencyIDs: removingDependencyIDs, removingWorkLinkIDs: removingWorkLinkIDs)
        projection = value; status = await coordinator.status(); onMerge?(value)
        Task { @MainActor [weak self] in await self?.refresh() }
    }
    func resolveDeletion(conflictID: String, archive: Bool = false) async throws {
        let value = try await coordinator.resolveDeletion(conflictID: conflictID, archive: archive)
        projection = value; status = await coordinator.status(); onMerge?(value)
        Task { @MainActor [weak self] in await self?.refresh() }
    }
    func resolveInvariant(conflictID: String, workspace: Workspace) async throws {
        let value = try await coordinator.resolveInvariant(conflictID: conflictID, workspace: workspace)
        projection = value; status = await coordinator.status(); onMerge?(value)
        Task { @MainActor [weak self] in await self?.refresh() }
    }
    func resolveSemanticRecord(conflictID: String, choosingEntityID: String) async throws {
        let value = try await coordinator.resolveSemanticRecord(conflictID: conflictID, choosingEntityID: choosingEntityID)
        projection = value; status = await coordinator.status(); onMerge?(value)
        Task { @MainActor [weak self] in await self?.refresh() }
    }
    func exportArchive() async throws -> SyncArchive { try await coordinator.exportArchive() }
    @discardableResult func restoreArchive(_ archive: SyncArchive) async throws -> SyncMergeResult {
        let value = try await coordinator.restoreArchive(archive)
        projection = value; status = await coordinator.status(); onMerge?(value)
        Task { @MainActor [weak self] in await self?.refresh() }
        return value
    }
    /// Route only this container's silent CloudKit notifications here. A push is a refresh hint, never a business fact.
    func receivedRemoteNotification(_ userInfo: [AnyHashable: Any], containerID: String) async {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo), notification.containerIdentifier == containerID else { return }
        await refresh()
    }
}
