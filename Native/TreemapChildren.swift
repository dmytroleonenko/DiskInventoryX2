import Foundation

/// A merge view over arena children and histogram representatives; real children are not copied.
struct TreemapChildren {
    struct Item {
        let id: Int
        let kind: UInt32
        let size: Int64
        let synthetic: Bool
    }

    private struct Representative {
        let item: Item
        var position: Int = 0
        let ordinal: Int
    }

    private let index: DiskIndex
    private let children: ArraySlice<Int>
    private let aggregateOffset: Int?
    private var representatives: [Representative] = []

    init(index: DiskIndex, parent: Int, rect: NSRect, scale: CGFloat) {
        self.index = index
        let children = index.childIDs(of: parent)
        self.children = children
        aggregateOffset = children.firstIndex(where: { index.entry(at: $0).isAggregate }).map { $0 - children.startIndex }
        guard let aggregateOffset else { return }
        let aggregate = children[children.startIndex + aggregateOffset]
        let bins = index.bins(of: aggregate)
        let totalSize = index.size(of: aggregate)
        let totalCount = bins.reduce(0) { $0 + $1.count }
        let budget = min(totalCount, max(bins.count, Int(rect.width * rect.height / max(1, 4 * scale * scale))))
        let extra = max(0, budget - bins.count)
        for bin in bins where bin.count > 0 {
            let bytes = index.size(of: bin)
            let fraction = totalSize > 0 ? Double(bytes) / Double(totalSize) : Double(bin.count) / Double(max(1, totalCount))
            let count = min(bin.count, 1 + Int(Double(extra) * fraction))
            // Each logarithmic bucket conserves its exact selected-mode bytes and kind.
            // Varied representatives avoid an ordered equal-size type grid.
            var factors: [Double] = []
            factors.reserveCapacity(count)
            for ordinal in 0..<count {
                let phase = (UInt64(ordinal) &* 2_654_435_761 &+ UInt64(bin.kind) &* 97 &+ UInt64(bin.sizeRange) &* 193) % 1024
                factors.append(0.75 + Double(phase) / 2048)
            }
            let factorTotal = factors.reduce(0, +)
            var remaining = bytes
            for ordinal in 0..<count {
                let size = ordinal == count - 1 ? remaining : min(remaining, Int64(Double(bytes) * factors[ordinal] / factorTotal))
                remaining -= size
                representatives.append(Representative(
                    item: Item(id: aggregate, kind: bin.kind, size: size, synthetic: true),
                    ordinal: representatives.count
                ))
            }
        }
        representatives.sort {
            if $0.item.size != $1.item.size { return $0.item.size > $1.item.size }
            // Mix equal-size kinds rather than producing contiguous palette bands.
            let first = UInt64($0.ordinal) &* 2_654_435_761
            let second = UInt64($1.ordinal) &* 2_654_435_761
            return (first % 4_294_967_291) < (second % 4_294_967_291)
        }
        for representative in representatives.indices {
            let size = representatives[representative].item.size
            var low = 0
            var high = realCount
            while low < high {
                let middle = (low + high) / 2
                if index.size(of: realID(at: middle)) >= size { low = middle + 1 } else { high = middle }
            }
            representatives[representative].position = low + representative
        }
    }

    private var realCount: Int { children.count - (aggregateOffset == nil ? 0 : 1) }
    var count: Int { realCount + representatives.count }

    private func realID(at position: Int) -> Int {
        let offset = position + ((aggregateOffset.map { position >= $0 }) == true ? 1 : 0)
        return children[children.startIndex + offset]
    }

    func item(at position: Int) -> Item {
        var low = 0
        var high = representatives.count
        while low < high {
            let middle = (low + high) / 2
            if representatives[middle].position < position { low = middle + 1 } else { high = middle }
        }
        if low < representatives.count, representatives[low].position == position { return representatives[low].item }
        let id = realID(at: position - low)
        return Item(id: id, kind: index.entry(at: id).kind, size: index.size(of: id), synthetic: false)
    }
}
