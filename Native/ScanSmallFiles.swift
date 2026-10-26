/// Keeps at most 50 component-name candidates per active directory.
struct ScanSmallFiles {
    struct Candidate {
        let name: String
        let logicalSize: Int64
        let allocatedSize: Int64
        let kind: UInt32
        let isPackage: Bool
    }

    private(set) var candidates: [Candidate] = []
    private(set) var logicalSize: Int64 = 0
    private(set) var allocatedSize: Int64 = 0
    private(set) var count = 0
    private var histogram: [UInt64: DiskIndex.Bin] = [:]

    var isGrouped: Bool { count > 50 }
    var bins: [DiskIndex.Bin] {
        histogram.keys.sorted().compactMap { histogram[$0] }
    }

    mutating func add(name: String, logicalSize: Int64, allocatedSize: Int64, kind: UInt32, isPackage: Bool) {
        self.logicalSize += logicalSize
        self.allocatedSize += allocatedSize
        count += 1
        if count <= 50 {
            candidates.append(Candidate(name: name, logicalSize: logicalSize, allocatedSize: allocatedSize, kind: kind, isPackage: isPackage))
            return
        }
        if count == 51 {
            for candidate in candidates {
                addBin(logicalSize: candidate.logicalSize, allocatedSize: candidate.allocatedSize, kind: candidate.kind)
            }
            candidates.removeAll(keepingCapacity: false)
        }
        addBin(logicalSize: logicalSize, allocatedSize: allocatedSize, kind: kind)
    }

    private mutating func addBin(logicalSize: Int64, allocatedSize: Int64, kind: UInt32) {
        let range = DiskIndex.Bin.range(for: logicalSize)
        let key = (UInt64(kind) << 8) | UInt64(range)
        if var bin = histogram[key] {
            bin.logicalSize += logicalSize
            bin.allocatedSize += allocatedSize
            bin.count += 1
            histogram[key] = bin
        } else {
            histogram[key] = DiskIndex.Bin(logicalSize: logicalSize, allocatedSize: allocatedSize, count: 1, kind: kind, sizeRange: range)
        }
    }
}
