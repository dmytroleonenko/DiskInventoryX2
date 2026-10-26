import Foundation

/// Whether byte totals are complete, a lower bound, or unavailable for this entry.
enum ScanEntryStatus: UInt8, Sendable {
    case complete
    case partial
    case unreadable
    case cloudOnly
    case automount
    case otherVolume
}
