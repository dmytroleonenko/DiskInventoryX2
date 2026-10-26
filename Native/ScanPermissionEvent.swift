import Foundation

/// Checking events precede blocking system consent; finished precedes inventory traversal.
enum ScanPermissionEvent: Sendable {
    case checking(ScanPermissionTarget)
    case finished(ScanPermissionReport)
}
