import Foundation

extension PlanningDisplay {
    /// Default planning screens hide archived scope without changing demand or historical proofs.
    public struct PlanningVisibility: Sendable {
        public let projectIDs: Set<String>
        public let itemIDs: Set<String>
        public let objectIDs: Set<String>

        public init(workspace: Workspace, relatedProjectIDs: (WorkItem) -> Set<String>) {
            projectIDs = Set(workspace.projects.filter { !$0.archived }.map(\.id))
            let visibleProjects = projectIDs
            itemIDs = Set(workspace.items.filter { item in
                guard !item.archived && item.effectiveDisposition != .cancelled && !item.isPendingInboxOrganization else { return false }
                let projects = relatedProjectIDs(item)
                return projects.isEmpty || !projects.isDisjoint(with: visibleProjects)
            }.map(\.id))
            let visibleItems = itemIDs
            var nodes = Set(workspace.nodes.filter { !$0.archived && visibleProjects.contains($0.projectID) }.map(\.id))
            nodes.formUnion(workspace.items.filter { visibleItems.contains($0.id) }.compactMap(\.nodeID))
            for dependency in workspace.dependencies where dependency.isActive && visibleItems.contains(dependency.targetItemID) {
                if case .node(let id) = dependency.source { nodes.insert(id) }
            }
            let links = (workspace.workLinks ?? []).filter { $0.removedAt == nil }
            // Shared node links can form a chain, including nodes with no direct members.
            var changed = true
            while changed {
                changed = false
                for link in links where visibleProjects.contains(link.projectID) || link.nodeID.map(nodes.contains) == true {
                    if case .node(let id) = link.source, nodes.insert(id).inserted { changed = true }
                }
            }
            nodes.subtract(workspace.nodes.filter(\.archived).map(\.id))
            var blockers = Set(workspace.nodes.filter { nodes.contains($0.id) }.flatMap { $0.blockerIDs ?? [] })
            for dependency in workspace.dependencies where dependency.isActive && visibleItems.contains(dependency.targetItemID) {
                if case .blocker(let id) = dependency.source { blockers.insert(id) }
            }
            blockers.subtract(workspace.blockers.filter { $0.isArchived == true }.map(\.id))
            var objects = visibleProjects.union(visibleItems).union(nodes).union(blockers)
            objects.formUnion(workspace.acceptances.filter { $0.isActive && objects.contains($0.subject.id) }.map(\.id))
            objects.insert("capacity")
            objectIDs = objects
        }

        public func unknowns(_ unknowns: [PlanningUnknown]) -> [PlanningUnknown] {
            unknowns.filter { objectIDs.contains($0.objectID) }
        }

        public func certificates(_ certificates: [PlanningCertificate]) -> [PlanningCertificate] {
            certificates.filter { proof in
                if proof.projectIDs.count == 1 { return projectIDs.contains(proof.projectIDs[0]) }
                if !proof.itemIDs.isEmpty { return !itemIDs.isDisjoint(with: proof.itemIDs) }
                return proof.projectIDs.isEmpty || !projectIDs.isDisjoint(with: proof.projectIDs)
            }
        }

        public func risks(_ risks: [Risk], certificates: [PlanningCertificate], unknowns: [PlanningUnknown]) -> [Risk] {
            let evidence = PlanningDisplay.certificatesByRisk(certificates)
            let hasVisibleUnknowns = !self.unknowns(unknowns).isEmpty
            let visible = risks.compactMap { risk -> Risk? in
                if let projectID = risk.projectID {
                    guard projectIDs.contains(projectID) else { return nil }
                } else if risk.kind == .insufficientInformation {
                    guard hasVisibleUnknowns else { return nil }
                } else if !risk.itemIDs.isEmpty {
                    guard !itemIDs.isDisjoint(with: risk.itemIDs) else { return nil }
                } else {
                    let projects = Set((evidence[PlanningDisplay.riskKey(risk)] ?? []).flatMap { $0.proofs.flatMap(\.projectIDs) })
                    guard projects.isEmpty ? !projectIDs.isEmpty || !itemIDs.isEmpty : !projectIDs.isDisjoint(with: projects) else { return nil }
                }
                var row = risk
                row.itemIDs = risk.itemIDs.filter(itemIDs.contains)
                return row
            }
            // Filter raw causes before taking the strongest lower bound for each visible row.
            return PlanningDisplay.risks(visible)
        }
    }
}
