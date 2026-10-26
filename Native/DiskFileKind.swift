import Foundation
import UniformTypeIdentifiers

/// A system type shared by all matching entries in one index.
struct DiskFileKind: Sendable, Equatable {
    let identifier: String
    let name: String

    static let data = DiskFileKind(identifier: UTType.data.identifier, name: UTType.data.localizedDescription ?? UTType.data.identifier)
}
