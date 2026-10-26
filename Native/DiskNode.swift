import Foundation

/// Lightweight immutable identity into a shared compact arena.
final class DiskNode: Sendable {
    let index: DiskIndex
    let id: Int

    init(index: DiskIndex, id: Int) {
        self.index = index
        self.id = id
    }

    var url: URL { index.url(of: id) }
    var name: String {
        guard isAggregate else { return index.name(of: id) }
        return String.localizedStringWithFormat(
            NSLocalizedString("Small files (<1 MB, %lld files)", comment: "Grouped immediate files smaller than one decimal megabyte"),
            Int64(fileCount)
        )
    }
    var size: Int64 { index.size(of: id) }
    var logicalSize: Int64 { index.entry(at: id).logicalSize }
    var allocatedSize: Int64 { index.entry(at: id).allocatedSize }
    var isPackage: Bool { index.entry(at: id).isPackage }
    var isDirectory: Bool { index.entry(at: id).isDirectory }
    var scanStatus: ScanEntryStatus { index.entry(at: id).scanStatus }
    var children: [DiskNode] { index.childIDs(of: id).map { index.node(at: $0) } }
    var fileCount: Int { index.entry(at: id).fileCount }
    var fileKindID: UInt32 { index.entry(at: id).kind }
    var kindIdentifier: String { index.kind(at: fileKindID).identifier }
    var groupRequest: ScanRequest? {
        guard isAggregate else { return nil }
        let parentID = Int(index.entry(at: id).parent)
        guard parentID >= 0 else { return nil }
        var retainedNames: Set<String> = []
        for sibling in index.childIDs(of: parentID) {
            let entry = index.entry(at: sibling)
            if !entry.isDirectory && !entry.isAggregate {
                retainedNames.insert(index.name(of: sibling))
            }
        }
        return ScanRequest(
            url: url, fileSelection: .smallFilesOnly, sizeMode: index.sizeMode,
            retainedFileNames: retainedNames
        )
    }
    var isAggregate: Bool { index.entry(at: id).isAggregate }
    var parent: DiskNode? {
        let parent = Int(index.entry(at: id).parent)
        return parent >= 0 ? index.node(at: parent) : nil
    }
    var mosaicBins: [ScanMosaicBin] {
        index.bins(of: id).map {
            ScanMosaicBin(size: index.size(of: $0), logicalSize: $0.logicalSize, allocatedSize: $0.allocatedSize, count: $0.count, kindID: $0.kind)
        }
    }
}
