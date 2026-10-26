import Foundation

/// Captures the confirmed filesystem identity, not just a potentially reused pathname.
struct PermanentDeletionTarget: Sendable {
    let url: URL
    let device: Int32
    let inode: UInt64
    let isDirectory: Bool
}
