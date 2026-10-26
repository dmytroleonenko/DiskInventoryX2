import Foundation

/// An actual EACCES/EPERM result, not a guess at global TCC authorization state.
struct ScanPermissionDenial: Sendable, Equatable {
    let target: ScanPermissionTarget
    let code: Int32
}
