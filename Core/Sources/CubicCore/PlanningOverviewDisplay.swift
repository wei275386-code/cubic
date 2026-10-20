import Foundation

extension PlanningDisplay {
    public struct OverviewRiskGroup: Identifiable, Sendable {
        public let id: [String]
        public var risks: [Risk]
        public var primary: Risk { risks.max { ($0.shortageMinutes ?? 0) < ($1.shortageMinutes ?? 0) }! }
    }
    /// Group the same affected work into one diagnosis; every original risk/proof remains in the drill-down.
    /// Keys deliberately exclude capture time and changing minute counts so a refresh preserves row identity.
    public static func overviewRisks(_ risks: [Risk]) -> [OverviewRiskGroup] {
        var groups: [OverviewRiskGroup] = [], indices: [[String]: Int] = [:]
        for risk in risks {
            let topic: String
            switch risk.kind {
            case .provenCapacityShortfall, .sharedResourceConflict, .energyConstraint, .continuousConstraint:
                topic = risk.shortageMinutes == nil && risk.kind == .provenCapacityShortfall ? "date" : "time"
            default: topic = risk.kind.rawValue + ":" + risk.message
            }
            let key = [topic, risk.projectID ?? ""] + Set(risk.itemIDs).sorted()
            if let index = indices[key] { groups[index].risks.append(risk) }
            else { indices[key] = groups.count; groups.append(OverviewRiskGroup(id: key, risks: [risk])) }
        }
        return groups
    }
    public static func overviewUnknowns(_ unknowns: [PlanningUnknown]) -> [PlanningUnknown] {
        var rows: [PlanningUnknown] = [], indices: [String: Int] = [:], messages: [String: Set<String>] = [:]
        for unknown in unknowns {
            guard messages[unknown.objectID, default: []].insert(unknown.message).inserted else { continue }
            if let index = indices[unknown.objectID] { rows[index].message += "\n" + unknown.message }
            else { indices[unknown.objectID] = rows.count; rows.append(unknown) }
        }
        return rows
    }
}
