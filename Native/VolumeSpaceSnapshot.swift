import Foundation

/// Filesystem capacity at scan completion, not an attribution to APFS snapshots.
struct VolumeSpaceSnapshot: Sendable, Equatable {
    let volumeURL: URL
    let capacityBytes: Int64
    let freeBytes: Int64

    var usedBytes: Int64 { capacityBytes - freeBytes }
}
