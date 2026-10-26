import Foundation
import UniformTypeIdentifiers

/// Confined to a scan or detached rebuild; immutable storage is transferred at finish.
final class DiskIndexBuilder {
    let rootURL: URL
    let sizeMode: DiskSizeMode
    private(set) var kinds: [DiskFileKind]
    private var kindIDs: [String: UInt32]
    private var entries: [DiskIndex.Entry] = []
    private var names: [String] = []
    private var nameIDs: [String: UInt32] = [:]
    private var histograms: [DiskIndex.Bin] = []
    private var hardLinks: [Int: HardLinkRecord] = [:]
    private var hardLinkOwners: [FileIdentity: Int] = [:]

    init(rootURL: URL, sizeMode: DiskSizeMode = .physical, kinds: [DiskFileKind] = [.data]) {
        self.rootURL = rootURL
        self.sizeMode = sizeMode
        self.kinds = kinds
        kindIDs = Dictionary(uniqueKeysWithValues: kinds.enumerated().map { ($0.element.identifier, UInt32($0.offset)) })
    }

    /// Resolves the system description only on the first occurrence of a UTI.
    func internKind(identifier: String, fallbackName: String?) -> UInt32 {
        if let id = kindIDs[identifier] { return id }
        let id = UInt32(kinds.count)
        let name = UTType(identifier)?.localizedDescription ?? fallbackName ?? identifier
        kinds.append(DiskFileKind(identifier: identifier, name: name))
        kindIDs[identifier] = id
        return id
    }

    @discardableResult
    func append(
        parent: Int, name: String, logicalSize: Int64 = 0, allocatedSize: Int64 = 0,
        fileCount: Int = 0, isDirectory: Bool, kind: UInt32 = 0,
        isPackage: Bool = false, isAggregate: Bool = false, bins: [DiskIndex.Bin] = [],
        scanStatus: ScanEntryStatus = .complete, hardLink: FileIdentity? = nil
    ) -> Int {
        let nameID: UInt32
        if let existing = nameIDs[name] {
            nameID = existing
        } else {
            nameID = UInt32(names.count)
            nameIDs[name] = nameID
            names.append(name)
        }
        let id = entries.count
        var chargedLogicalSize = logicalSize
        var chargedAllocatedSize = allocatedSize
        if let hardLink {
            precondition(!isDirectory && !isAggregate && bins.isEmpty)
            let owner: Int
            if let existing = hardLinkOwners[hardLink] {
                owner = existing
                chargedLogicalSize = 0
                chargedAllocatedSize = 0
            } else {
                owner = id
                hardLinkOwners[hardLink] = id
            }
            hardLinks[id] = HardLinkRecord(
                identity: hardLink, logicalSize: logicalSize, allocatedSize: allocatedSize, ownerID: owner
            )
        }
        entries.append(DiskIndex.Entry(
            logicalSize: chargedLogicalSize, allocatedSize: chargedAllocatedSize,
            fileCount: hardLink == nil ? fileCount : 1,
            parent: Int32(parent), name: nameID,
            histogramStart: Int32(histograms.count), histogramCount: Int32(bins.count),
            kind: kind, flags: (isDirectory ? 1 : 0) | (isAggregate ? 2 : 0) | (isPackage ? 4 : 0) | (scanStatus.rawValue << 3),
            ownScanStatus: scanStatus
        ))
        histograms.append(contentsOf: bins)
        return id
    }

    /// Keeps an entry's concrete failure reason when an ancestor-level partial mark arrives.
    func markIncomplete(_ id: Int, status: ScanEntryStatus) {
        guard status != .complete else { return }
        let previous = entries[id].scanStatus
        if previous == .complete || previous == .partial {
            entries[id].scanStatus = status
        }
        let own = entries[id].ownScanStatus
        if own == .complete || own == .partial {
            entries[id].ownScanStatus = status
        }
    }

    func finish(volumeSpace: VolumeSpaceSnapshot? = nil) -> DiskIndex {
        // Parents always precede descendants, so one reverse pass folds both measures.
        for id in entries.indices where entries[id].isDirectory && !entries[id].isAggregate {
            entries[id].logicalSize = 0
            entries[id].allocatedSize = 0
            entries[id].fileCount = 0
        }
        for id in entries.indices.reversed() {
            let parent = Int(entries[id].parent)
            guard parent >= 0 else { continue }
            entries[parent].logicalSize += entries[id].logicalSize
            entries[parent].allocatedSize += entries[id].allocatedSize
            entries[parent].fileCount += entries[id].fileCount
            entries[parent].childCount += 1
            if entries[id].scanStatus != .complete {
                let previous = entries[parent].scanStatus
                if previous == .complete { entries[parent].scanStatus = .partial }
            }
        }
        var offset = 0
        for id in entries.indices {
            entries[id].childStart = Int32(offset)
            offset += Int(entries[id].childCount)
        }
        var links = [Int](repeating: 0, count: offset)
        var nextOffsets = entries.map { Int($0.childStart) }
        for id in entries.indices {
            let parent = Int(entries[id].parent)
            guard parent >= 0 else { continue }
            links[nextOffsets[parent]] = id
            nextOffsets[parent] += 1
        }
        DiskIndex.sortChildren(&links, entries: entries, names: names, sizeMode: sizeMode)
        return DiskIndex(
            rootURL: rootURL, sizeMode: sizeMode, kinds: kinds,
            entries: entries, names: names, childLinks: links, histograms: histograms,
            hardLinks: hardLinks, volumeSpace: volumeSpace
        )
    }
}
