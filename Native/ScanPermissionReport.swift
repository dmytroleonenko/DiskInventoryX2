import Foundation

struct ScanPermissionReport: Sendable, Equatable {
    let checkedCount: Int
    let denied: [ScanPermissionDenial]
}
