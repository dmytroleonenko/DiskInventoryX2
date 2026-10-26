import Foundation

/// Accumulates numeric kinds without retaining per-file type strings.
struct ScanTypeAccumulator: Sendable {
    private struct Total: Sendable {
        var logicalSize: Int64 = 0
        var allocatedSize: Int64 = 0
        var count = 0
    }

    private var totals: [UInt32: Total] = [:]
    private(set) var logicalSize: Int64 = 0
    private(set) var allocatedSize: Int64 = 0
    private(set) var fileCount = 0

    mutating func add(logicalSize: Int64, allocatedSize: Int64, count: Int = 1, kind: UInt32) {
        self.logicalSize += logicalSize
        self.allocatedSize += allocatedSize
        fileCount += count
        totals[kind, default: Total()].logicalSize += logicalSize
        totals[kind, default: Total()].allocatedSize += allocatedSize
        totals[kind, default: Total()].count += count
    }

    func statistics(kinds: [DiskFileKind], sizeMode: DiskSizeMode) -> [FileTypeStat] {
        var byName: [String: FileTypeStat] = [:]
        for (kind, total) in totals where total.count > 0 {
            let name = kinds[Int(kind)].name
            let size = sizeMode.size(logical: total.logicalSize, allocated: total.allocatedSize)
            if let previous = byName[name] {
                byName[name] = FileTypeStat(
                    kindID: min(previous.kindID, kind), name: name,
                    size: previous.size + size, count: previous.count + total.count
                )
            } else {
                byName[name] = FileTypeStat(kindID: kind, name: name, size: size, count: total.count)
            }
        }
        // FileSystemDoc keys statistics by the Finder kind name, not by the UTI.
        return byName.values.sorted {
            if $0.size != $1.size { return $0.size > $1.size }
            return $0.name.compare($1.name, options: .numeric) == .orderedAscending
        }
    }
}
