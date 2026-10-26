import Foundation

struct ScanResult: Sendable {
    let root: DiskNode
    /// Unreadable metadata/subtrees and deliberately excluded entries.
    let skippedCount: Int
    let request: ScanRequest
    /// Incomplete snapshots contain observed lower bounds, not estimates.
    let isComplete: Bool
    let currentPath: String?
    let typeStatistics: [FileTypeStat]
}
