import Foundation

/// Original file measures and the single charged name for a retained filesystem identity.
struct HardLinkRecord: Sendable {
    let identity: FileIdentity
    let logicalSize: Int64
    let allocatedSize: Int64
    let ownerID: Int
}
