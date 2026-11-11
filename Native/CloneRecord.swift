import Foundation

/// Original per-name measures and the charged clone extent group for one retained name.
///
/// Full APFS clones share data-fork allocation while keeping distinct logical sizes.
/// The first member of an extent group owns the shared data bytes; every later member
/// keeps its own independently allocated resource-fork bytes.
struct CloneRecord: Sendable {
    let identity: CloneFileMetadata.Identity
    /// The name's own logical size; clones never share logical bytes.
    let logicalSize: Int64
    /// The name's total allocation, including independently allocated resource forks.
    let allocatedSize: Int64
    /// Data-fork allocation shared with the other members of this extent group.
    let sharedDataAllocatedSize: Int64
    let ownerID: Int
}

/// Mirrors the builder's clone charging so streamed progress totals agree with the finished arena.
struct CloneChargeLedger {
    private var owners: Set<CloneFileMetadata.Identity> = []

    /// Returns the allocation charged to this occurrence.
    mutating func charge(
        allocatedSize: Int64, sharedDataAllocatedSize: Int64,
        identity: CloneFileMetadata.Identity?
    ) -> Int64 {
        guard allocatedSize > 0, let identity else { return allocatedSize }
        let shared = Self.sharedBytes(allocatedSize: allocatedSize, dataAllocatedSize: sharedDataAllocatedSize)
        if owners.contains(identity) { return allocatedSize - shared }
        owners.insert(identity)
        return allocatedSize
    }

    /// Only the recognized data-fork portion can be shared; resource forks stay independent.
    static func sharedBytes(allocatedSize: Int64, dataAllocatedSize: Int64) -> Int64 {
        guard allocatedSize > 0, dataAllocatedSize > 0 else { return 0 }
        return min(allocatedSize, dataAllocatedSize)
    }
}
