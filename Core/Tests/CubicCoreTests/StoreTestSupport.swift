import Foundation
@testable import CubicCore

/// Encodes `workspace` the way WorkspaceStore writes it to disk, then decodes it again.
func persistedCopy(_ workspace: Workspace) throws -> Workspace {
    let document = WorkspaceDocument(workspace: workspace, deviceID: "test")
    let decoded = try JSONCoding.decode(WorkspaceDocument.self, from: JSONCoding.encode(document)).workspace
    try decoded.validate()
    return decoded
}
