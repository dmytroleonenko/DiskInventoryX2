import Foundation

struct DiskVolume: Sendable {
    let url: URL
    let name: String
    let formatDescription: String?
    let totalCapacity: Int64?
    let availableCapacity: Int64?

    // Matches the original: occupied space in the shared capacity, not this APFS member's allocation.
    var usedCapacity: Int64? {
        guard let totalCapacity, let availableCapacity else { return nil }
        return max(0, totalCapacity - availableCapacity)
    }

    var usedFraction: Double? {
        guard let totalCapacity, totalCapacity > 0, let usedCapacity else { return nil }
        return min(1, Double(usedCapacity) / Double(totalCapacity))
    }

    var isStartup: Bool { url.standardizedFileURL.path == "/" }
}
