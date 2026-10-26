/// The stored measure used for ordering, layout, and statistics.
enum DiskSizeMode: Sendable, Equatable {
    case physical
    case logical

    func size(logical: Int64, allocated: Int64) -> Int64 {
        switch self {
        case .physical: allocated
        case .logical: logical
        }
    }
}
