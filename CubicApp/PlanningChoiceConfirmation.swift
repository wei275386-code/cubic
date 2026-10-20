import Foundation
import CubicCore

/// Compares the premises and results shown to the user at minute display precision.
/// Capture timestamps alone do not force a second confirmation; changed slots or effects do.
enum TrialConfirmationPolicy {
    static func requiresRedisplay(_ displayed: PlanningTrialResult, _ latest: PlanningTrialResult) -> Bool {
        guard let old = try? signature(displayed), let new = try? signature(latest) else { return true }
        return old != new
    }
    private struct Context: Encodable {
        var source: PlanningSource
        var request: PlanningTrialRequest
        var baselineProjects: [PlanningProjectAssessment]
        var scenarioProjects: [PlanningProjectAssessment]?
        var allocations: [TrialAllocation]
        var startPosition: Date?
        var estimatedCompletion: Date?
        var assumedRemainingMinutes: Int?
        var unallocatedMinutes: Int?
        var excessMinutes: Int?
        var impacts: [PlanningImpact]
        var conditions: [PlanningCondition]
        var conflicts: [PlanningCertificate]
    }
    private static func signature(_ result: PlanningTrialResult) throws -> SyncValue {
        var source = result.source
        source.input.now = Date(timeIntervalSince1970: 0)
        source.input.revision = PlanningRevision(workspace: "", capacity: "", calendar: "", time: "")
        let context = Context(source: source, request: result.request,
            baselineProjects: result.baseline.projects, scenarioProjects: result.scenario?.projects,
            allocations: result.allocations, startPosition: result.startPosition,
            estimatedCompletion: result.estimatedCompletion, assumedRemainingMinutes: result.assumedRemainingMinutes,
            unallocatedMinutes: result.unallocatedMinutes, excessMinutes: result.excessMinutes,
            impacts: result.impacts, conditions: result.conditions, conflicts: result.unresolvedConflicts)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        return normalized(try SyncCoding.decode(SyncValue.self, from: encoder.encode(context)))
    }
    private static let displayDates: Set<String> = ["start", "end", "startPosition", "estimatedCompletion", "beforeDate", "afterDate", "windowStart", "windowEnd", "expectedAt", "requiredReadyAt", "latestAllowedAt", "latestStart", "latestFinish", "horizonEnd"]
    private static func normalized(_ value: SyncValue, field: String = "", eventTimes: Bool = false) -> SyncValue {
        switch value {
        case .number(let number) where displayDates.contains(field) || eventTimes:
            return .number(floor(number / 60_000) * 60_000)
        case .number(let number) where field == "elapsedDelaySeconds":
            return .number(ceil(number / 60) * 60)
        case .object(let fields):
            // Certificates expose integer minutes; raw fractional proof seconds remain
            // in the saved latest result but must not force an invisible reconfirmation.
            let displayed = fields["shortageMinutes"] != nil && fields["capacityMinutes"] != nil
                ? fields.filter { !["capacitySeconds", "shortageSeconds", "demandSeconds"].contains($0.key) }
                : fields
            return .object(displayed.mapValuesWithKeys { key, value in
                normalized(value, field: key, eventTimes: field == "eventTimes")
            })
        case .array(let values): return .array(values.map { normalized($0, field: field) })
        default: return value
        }
    }
}

private extension Dictionary where Key == String, Value == SyncValue {
    func mapValuesWithKeys(_ transform: (String, SyncValue) -> SyncValue) -> [String: SyncValue] {
        reduce(into: [:]) { result, pair in result[pair.key] = transform(pair.key, pair.value) }
    }
}

/// One complete confirmation command, shared by production and operation tests.
/// Input and display state remain in the View. Only in-flight and unsettled operation identities live here.
@MainActor final class PlanningChoiceConfirmation {
    enum Outcome {
        case confirmed(WorkspaceCommitOutcome)
        case redisplay(PlanningTrialResult)
        case recoveryRequired(SyncLocalCommitFailure)
        case unavailable(String?)
    }
    private let calculate: @MainActor (PlanningTrialRequest) async -> PlanningTrialResult?
    private let sourceIsCurrent: @MainActor (PlanningTrialResult) -> Bool
    private let commit: @MainActor (PlanningTrialResult, String) async throws -> WorkspaceCommitOutcome
    private let recover: @MainActor (SyncLocalCommitReceipt) async throws -> WorkspaceCommitOutcome?
    private var inFlight: Set<UUID> = []
    private var unsettled: [UUID: SyncLocalCommitReceipt] = [:]
    private var completed: [UUID] = []

    init(calculate: @escaping @MainActor (PlanningTrialRequest) async -> PlanningTrialResult?,
         sourceIsCurrent: @escaping @MainActor (PlanningTrialResult) -> Bool,
         commit: @escaping @MainActor (PlanningTrialResult, String) async throws -> WorkspaceCommitOutcome,
         recover: @escaping @MainActor (SyncLocalCommitReceipt) async throws -> WorkspaceCommitOutcome?) {
        self.calculate = calculate; self.sourceIsCurrent = sourceIsCurrent
        self.commit = commit; self.recover = recover
    }

    func confirm(presentationID: UUID, displayed: PlanningTrialResult, request: PlanningTrialRequest,
                 note: String, isCurrent: @escaping @MainActor () -> Bool) async -> Outcome {
        guard !inFlight.contains(presentationID), !completed.contains(presentationID),
              !Task.isCancelled, isCurrent() else { return .unavailable(nil) }
        inFlight.insert(presentationID)
        defer { inFlight.remove(presentationID) }
        do {
            if let receipt = unsettled[presentationID] {
                // Finish the original choice even if its journal was recovered by a background refresh.
                guard let outcome = try await recover(receipt) else {
                    unsettled[presentationID] = nil
                    return .unavailable("已核实原选择未写入，请重新查看试算后确认。")
                }
                return settle(outcome, presentationID: presentationID)
            }
            guard displayed.request == request else { return .unavailable("试算输入已变化，请查看新结果。") }
            guard let latest = await calculate(request) else { return .unavailable(nil) }
            guard !Task.isCancelled, isCurrent(), sourceIsCurrent(latest) else { return .unavailable(nil) }
            let changed = await Task.detached(priority: .userInitiated) {
                TrialConfirmationPolicy.requiresRedisplay(displayed, latest)
            }.value
            guard !Task.isCancelled, isCurrent(), sourceIsCurrent(latest) else { return .unavailable(nil) }
            if changed { return .redisplay(latest) }
            // Linearization boundary: after issuing this commit, cancellation cannot undo a durable fact.
            let outcome = try await commit(latest, note)
            return settle(outcome, presentationID: presentationID)
        } catch { return .unavailable(error.localizedDescription) }
    }

    private func settle(_ outcome: WorkspaceCommitOutcome, presentationID: UUID) -> Outcome {
        switch outcome {
        case .committed:
            unsettled[presentationID] = nil
            completed.append(presentationID)
            if completed.count > 64 { completed.removeFirst() }
            return .confirmed(outcome)
        case .recoveryRequired(let failure):
            unsettled[presentationID] = failure.receipt
            return .recoveryRequired(failure)
        }
    }
}
