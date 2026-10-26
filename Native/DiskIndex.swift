import Foundation

/// Immutable parent/child arena; only the scan root owns a full filesystem URL.
final class DiskIndex: Sendable {
    struct Entry: Sendable {
        var logicalSize: Int64
        var allocatedSize: Int64
        var fileCount: Int
        var parent: Int32
        var name: UInt32
        var childStart: Int32 = 0
        var childCount: Int32 = 0
        var histogramStart: Int32 = 0
        var histogramCount: Int32 = 0
        var kind: UInt32 = 0
        var flags: UInt8 = 0
        /// Failure observed here, excluding partial status inherited from descendants.
        var ownScanStatus: ScanEntryStatus = .complete

        var isDirectory: Bool { flags & 1 != 0 }
        var isAggregate: Bool { flags & 2 != 0 }
        var isPackage: Bool { flags & 4 != 0 }

        var scanStatus: ScanEntryStatus {
            get { ScanEntryStatus(rawValue: flags >> 3) ?? .complete }
            set { flags = (flags & 7) | (newValue.rawValue << 3) }
        }

        func size(in mode: DiskSizeMode) -> Int64 {
            mode.size(logical: logicalSize, allocated: allocatedSize)
        }
    }

    struct Bin: Sendable {
        var logicalSize: Int64
        var allocatedSize: Int64
        var count: Int
        let kind: UInt32
        let sizeRange: UInt8

        func size(in mode: DiskSizeMode) -> Int64 {
            mode.size(logical: logicalSize, allocated: allocatedSize)
        }

        static func range(for logicalSize: Int64) -> UInt8 {
            logicalSize == 0 ? 0 : UInt8(64 - UInt64(logicalSize).leadingZeroBitCount)
        }
    }

    let rootURL: URL
    let sizeMode: DiskSizeMode
    let kinds: [DiskFileKind]
    let volumeSpace: VolumeSpaceSnapshot?
    private let entries: [Entry]
    private let names: [String]
    private let childLinks: [Int]
    private let histograms: [Bin]
    private let progressTotals: ScanTypeAccumulator?
    private let hardLinks: [Int: HardLinkRecord]

    init(
        rootURL: URL, sizeMode: DiskSizeMode = .physical, kinds: [DiskFileKind],
        entries: [Entry], names: [String], childLinks: [Int], histograms: [Bin],
        progressTotals: ScanTypeAccumulator? = nil, hardLinks: [Int: HardLinkRecord] = [:],
        volumeSpace: VolumeSpaceSnapshot? = nil
    ) {
        self.rootURL = rootURL
        self.sizeMode = sizeMode
        self.kinds = kinds
        self.entries = entries
        self.names = names
        self.childLinks = childLinks
        self.histograms = histograms
        self.progressTotals = progressTotals
        self.hardLinks = hardLinks
        self.volumeSpace = volumeSpace
    }

    var root: DiskNode { node(at: 0) }

    func node(at id: Int) -> DiskNode { DiskNode(index: self, id: id) }
    func size(of id: Int) -> Int64 { entries[id].size(in: sizeMode) }
    func size(of bin: Bin) -> Int64 { bin.size(in: sizeMode) }
    func kind(at id: UInt32) -> DiskFileKind { kinds[Int(id)] }
    func entry(at id: Int) -> Entry { entries[id] }
    func name(of id: Int) -> String { names[Int(entries[id].name)] }
    func hardLink(at id: Int) -> HardLinkRecord? { hardLinks[id] }

    var unavailableEntryCount: Int {
        entries.reduce(0) { $0 + ($1.ownScanStatus == .complete ? 0 : 1) }
    }

    func childIDs(of id: Int) -> ArraySlice<Int> {
        let entry = entries[id]
        let start = Int(entry.childStart)
        return childLinks[start..<(start + Int(entry.childCount))]
    }

    func bins(of id: Int) -> ArraySlice<Bin> {
        let entry = entries[id]
        let start = Int(entry.histogramStart)
        return histograms[start..<(start + Int(entry.histogramCount))]
    }

    func url(of id: Int) -> URL {
        if entries[id].isAggregate { return url(of: Int(entries[id].parent)) }
        var components: [String] = []
        var current = id
        while current != 0 {
            components.append(name(of: current))
            current = Int(entries[current].parent)
        }
        var url = rootURL
        for component in components.reversed() { url.appendPathComponent(component) }
        return url
    }

    func statistics(for id: Int) -> [FileTypeStat] {
        collectStatistics(for: id, showPackageContents: true)
    }

    /// Like the original itemIsNode: a viewport root package always exposes its children.
    func presentationStatistics(for id: Int, showPackageContents: Bool = false) -> [FileTypeStat] {
        collectStatistics(for: id, showPackageContents: showPackageContents)
    }

    private func collectStatistics(for id: Int, showPackageContents: Bool) -> [FileTypeStat] {
        if id == 0, let progressTotals { return progressTotals.statistics(kinds: kinds, sizeMode: sizeMode) }
        var totals = ScanTypeAccumulator()
        var current: Int? = id
        var ancestors: [ArraySlice<Int>.Iterator] = []
        while let nodeID = current {
            let entry = entries[nodeID]
            if entry.isAggregate {
                for bin in bins(of: nodeID) {
                    totals.add(logicalSize: bin.logicalSize, allocatedSize: bin.allocatedSize, count: bin.count, kind: bin.kind)
                }
            } else if entry.isDirectory && (showPackageContents || !entry.isPackage || nodeID == id) {
                if entry.childCount > 0 {
                    var children = childIDs(of: nodeID).makeIterator()
                    current = children.next()
                    ancestors.append(children)
                    continue
                }
            } else {
                // Collapsed packages keep their presentation identity; unknown placeholders
                // must not fabricate a file merely because a pathname was retained.
                let count = entry.isDirectory
                    ? (entry.scanStatus == .complete || entry.fileCount > 0 ? 1 : 0)
                    : entry.fileCount
                if count > 0 {
                    totals.add(logicalSize: entry.logicalSize, allocatedSize: entry.allocatedSize, count: count, kind: entry.kind)
                }
            }
            current = nil
            while !ancestors.isEmpty {
                if let next = ancestors[ancestors.count - 1].next() {
                    current = next
                    break
                }
                ancestors.removeLast()
            }
        }
        return totals.statistics(kinds: kinds, sizeMode: sizeMode)
    }

    /// Shares immutable metadata and both measures; only child ordering is rebuilt.
    func withSizeMode(_ mode: DiskSizeMode) -> DiskIndex {
        guard mode != sizeMode else { return self }
        var links = childLinks
        Self.sortChildren(&links, entries: entries, names: names, sizeMode: mode)
        return DiskIndex(
            rootURL: rootURL, sizeMode: mode, kinds: kinds, entries: entries, names: names,
            childLinks: links, histograms: histograms, progressTotals: progressTotals,
            hardLinks: hardLinks, volumeSpace: volumeSpace
        )
    }

    /// Replaces the volume sample without copying or rebuilding immutable arena storage.
    func withVolumeSpace(_ snapshot: VolumeSpaceSnapshot?) -> DiskIndex {
        DiskIndex(
            rootURL: rootURL, sizeMode: sizeMode, kinds: kinds, entries: entries, names: names,
            childLinks: childLinks, histograms: histograms, progressTotals: progressTotals,
            hardLinks: hardLinks, volumeSpace: snapshot
        )
    }

    static func sortChildren(_ links: inout [Int], entries: [Entry], names: [String], sizeMode: DiskSizeMode) {
        links.withUnsafeMutableBufferPointer { buffer in
            for entry in entries where entry.childCount > 1 {
                let start = Int(entry.childStart)
                let end = start + Int(entry.childCount)
                var children = UnsafeMutableBufferPointer(rebasing: buffer[start..<end])
                children.sort {
                    let left = entries[$0]
                    let right = entries[$1]
                    let leftSize = left.size(in: sizeMode)
                    let rightSize = right.size(in: sizeMode)
                    return leftSize == rightSize
                        ? names[Int(left.name)].compare(names[Int(right.name)], options: [.numeric, .caseInsensitive]) == .orderedDescending
                        : leftSize > rightSize
                }
            }
        }
    }

    /// Removes dot components without Foundation's physical-to-visible /private aliases.
    static func lexicalURL(_ url: URL) -> URL {
        var components: [String] = []
        for component in url.pathComponents where component != "/" && component != "." {
            if component == ".." {
                if !components.isEmpty { components.removeLast() }
            } else {
                components.append(component)
            }
        }
        return URL(fileURLWithPath: "/" + components.joined(separator: "/"), isDirectory: url.hasDirectoryPath)
    }

    /// Maps independent alias spellings into this arena, preferring its actual stored path.
    private func arenaURL(for url: URL) -> URL? {
        let lexical = Self.lexicalURL(url)
        let root = Self.lexicalURL(rootURL)
        if let existing = find(url: lexical) { return existing.url }
        if lexical.path != "/", let parent = find(url: lexical.deletingLastPathComponent()) {
            return parent.url.appendingPathComponent(lexical.lastPathComponent)
        }
        if lexical.pathComponents.starts(with: root.pathComponents) { return lexical }
        let canonical = url.standardizedFileURL.pathComponents
        let canonicalRoot = rootURL.standardizedFileURL.pathComponents
        guard canonical.starts(with: canonicalRoot) else { return nil }
        var mapped = root
        for component in canonical.dropFirst(canonicalRoot.count) { mapped.appendPathComponent(component) }
        return mapped
    }

    func find(url: URL, aggregate: Bool = false) -> DiskNode? {
        let components = Self.lexicalURL(url).pathComponents
        let rootComponents = Self.lexicalURL(rootURL).pathComponents
        if let node = find(components: components, rootComponents: rootComponents, aggregate: aggregate) { return node }
        let canonical = url.standardizedFileURL.pathComponents
        let canonicalRoot = rootURL.standardizedFileURL.pathComponents
        if canonical != components || canonicalRoot != rootComponents,
           let node = find(components: canonical, rootComponents: canonicalRoot, aggregate: aggregate) {
            return node
        }
        // These visible macOS roots are symlinks and intentionally absent from a
        // whole-root arena. Independent scans may nevertheless use their spelling.
        if canonical.count > 1,
           canonical[1] == "var" || canonical[1] == "tmp" || canonical[1] == "etc" {
            let physical = URL(fileURLWithPath: "/private/" + canonical.dropFirst().joined(separator: "/"))
            if physical.standardizedFileURL.pathComponents == canonical {
                return find(components: physical.pathComponents, rootComponents: rootComponents, aggregate: aggregate)
            }
        }
        return nil
    }

    private func find(components: [String], rootComponents: [String], aggregate: Bool) -> DiskNode? {
        guard components.starts(with: rootComponents) else { return nil }
        var current = 0
        for component in components.dropFirst(rootComponents.count) {
            guard let child = childIDs(of: current).first(where: {
                !entries[$0].isAggregate && name(of: $0) == component
            }) else { return nil }
            current = child
        }
        if aggregate {
            guard let group = childIDs(of: current).first(where: { entries[$0].isAggregate }) else { return nil }
            current = group
        }
        return node(at: current)
    }

    /// Rebuilds the remaining arena, including pooled names, without filesystem I/O.
    func removingSubtree(at id: Int) -> DiskIndex {
        guard id > 0, entries.indices.contains(id) else { return self }
        return rebuilding(excluding: id)
    }

    /// A drilled small file may be represented only by its parent's histogram.
    func removingItem(at url: URL, logicalSize: Int64, allocatedSize: Int64, kindIdentifier: String) -> DiskIndex {
        if let node = find(url: url) { return removingSubtree(at: node.id) }
        guard logicalSize >= 0, logicalSize < ScanFileSelection.smallFileByteLimit, allocatedSize >= 0,
              let kind = kinds.firstIndex(where: { $0.identifier == kindIdentifier }),
              let group = find(url: url.deletingLastPathComponent(), aggregate: true) else { return self }
        var remaining = Array(bins(of: group.id))
        let range = Bin.range(for: logicalSize)
        guard let position = remaining.firstIndex(where: { $0.kind == UInt32(kind) && $0.sizeRange == range }),
              remaining[position].count > 0, remaining[position].logicalSize >= logicalSize,
              remaining[position].allocatedSize >= allocatedSize else { return self }
        remaining[position].logicalSize -= logicalSize
        remaining[position].allocatedSize -= allocatedSize
        remaining[position].count -= 1
        remaining.removeAll { $0.count == 0 }
        if remaining.isEmpty { return rebuilding(excluding: group.id) }
        return rebuilding(excluding: nil, replacingHistogramAt: group.id, with: remaining)
    }

    /// An inode first observed with multiple links may alias an anonymous old aggregate.
    func requiresFullRescan(at url: URL, replacement: DiskIndex) -> Bool {
        guard let target = arenaURL(for: url) else { return false }
        let rootParts = Self.lexicalURL(rootURL).pathComponents
        let targetParts = target.pathComponents
        guard targetParts.count > rootParts.count, targetParts.starts(with: rootParts),
              root.fileCount > (find(url: url)?.fileCount ?? 0) else { return false }
        let knownIdentities = Set(hardLinks.values.map(\.identity))
        return replacement.hardLinks.values.contains { !knownIdentities.contains($0.identity) }
    }

    /// Replaces one scanned directory without observing any unaffected filesystem paths.
    func grafting(at url: URL, replacement: DiskIndex) -> DiskIndex {
        let lexicalTarget = Self.lexicalURL(url)
        let targetParts = lexicalTarget.pathComponents
        let rootParts = Self.lexicalURL(rootURL).pathComponents
        guard replacement.rootURL.standardizedFileURL.path == lexicalTarget.standardizedFileURL.path else { return self }
        if rootParts.starts(with: targetParts)
            || rootURL.standardizedFileURL.pathComponents.starts(with: lexicalTarget.standardizedFileURL.pathComponents) {
            guard let surviving = replacement.find(url: rootURL) else {
                return replacement.withSizeMode(sizeMode)
            }
            return replacement.copyingSubtree(at: surviving.id, sizeMode: sizeMode, rootURL: rootURL)
        }
        guard let target = arenaURL(for: lexicalTarget),
              let parent = find(url: target.deletingLastPathComponent()) else { return self }
        let excluded = find(url: target)?.id
        let builder = DiskIndexBuilder(rootURL: rootURL, sizeMode: sizeMode, kinds: kinds)
        let freshLinks = replacement.hardLinkIDs()
        var remapping = [Int](repeating: -1, count: entries.count)
        for id in entries.indices {
            if id == excluded { continue }
            let oldParent = Int(entries[id].parent)
            if oldParent >= 0, remapping[oldParent] < 0 { continue }
            remapping[id] = appendEntry(
                at: id, to: builder, parent: oldParent < 0 ? -1 : remapping[oldParent],
                freshIndex: replacement, freshLinks: freshLinks
            )
        }
        replacement.appendSubtree(
            at: 0, to: builder, parent: remapping[parent.id],
            rootName: excluded.map { name(of: $0) } ?? target.lastPathComponent
        )
        return builder.finish(volumeSpace: volumeSpace)
    }

    /// Projects a retained directory scope from a larger fresh recursive scan.
    func copyingSubtree(at id: Int, sizeMode: DiskSizeMode, rootURL: URL? = nil) -> DiskIndex {
        let builder = DiskIndexBuilder(rootURL: rootURL ?? url(of: id), sizeMode: sizeMode, kinds: kinds)
        appendSubtree(at: id, to: builder, parent: -1)
        return builder.finish(volumeSpace: id == 0 ? volumeSpace : nil)
    }

    /// Projects direct ordinary small files when the recursive scan retains their names.
    func smallFileProjection(at id: Int, sizeMode: DiskSizeMode) -> DiskIndex {
        let builder = DiskIndexBuilder(rootURL: url(of: id), sizeMode: sizeMode, kinds: kinds)
        let entry = entries[id]
        let root = builder.append(
            parent: -1, name: name(of: id), isDirectory: true,
            kind: entry.kind, isPackage: entry.isPackage, scanStatus: entry.ownScanStatus
        )
        for child in childIDs(of: id) {
            let childEntry = entries[child]
            if !childEntry.isDirectory, childEntry.scanStatus != .complete {
                builder.markIncomplete(root, status: .partial)
            } else if !childEntry.isDirectory, hardLinks[child] == nil,
                      childEntry.logicalSize < ScanFileSelection.smallFileByteLimit {
                _ = appendEntry(at: child, to: builder, parent: root)
            }
        }
        return builder.finish()
    }

    private func hardLinkIDs() -> [FileIdentity: Int] {
        var ids: [FileIdentity: Int] = [:]
        for (id, record) in hardLinks {
            ids[record.identity] = min(ids[record.identity] ?? id, id)
        }
        return ids
    }

    private func appendSubtree(at root: Int, to builder: DiskIndexBuilder, parent: Int, rootName: String? = nil) {
        var remapping = [Int](repeating: -1, count: entries.count)
        for id in root..<entries.count {
            let oldParent = Int(entries[id].parent)
            if id != root, oldParent < 0 || remapping[oldParent] < 0 { continue }
            remapping[id] = appendEntry(
                at: id, to: builder, parent: id == root ? parent : remapping[oldParent],
                name: id == root ? rootName : nil
            )
        }
    }

    private func appendEntry(
        at id: Int, to builder: DiskIndexBuilder, parent: Int, name: String? = nil,
        freshIndex: DiskIndex? = nil, freshLinks: [FileIdentity: Int] = [:]
    ) -> Int {
        let entry = entries[id]
        let record = hardLinks[id]
        let fresh = record.flatMap { freshLinks[$0.identity] }
        let source = fresh == nil ? self : (freshIndex ?? self)
        let sourceEntry = fresh.map { source.entry(at: $0) } ?? entry
        let sourceRecord = fresh.flatMap { source.hardLink(at: $0) } ?? record
        let kind = source.kind(at: sourceEntry.kind)
        let kindID = builder.internKind(identifier: kind.identifier, fallbackName: kind.name)
        let mappedBins = bins(of: id).map { bin in
            let binKind = self.kind(at: bin.kind)
            return Bin(
                logicalSize: bin.logicalSize, allocatedSize: bin.allocatedSize, count: bin.count,
                kind: builder.internKind(identifier: binKind.identifier, fallbackName: binKind.name),
                sizeRange: bin.sizeRange
            )
        }
        return builder.append(
            parent: parent, name: name ?? self.name(of: id),
            logicalSize: sourceRecord?.logicalSize ?? entry.logicalSize,
            allocatedSize: sourceRecord?.allocatedSize ?? entry.allocatedSize,
            fileCount: entry.fileCount, isDirectory: entry.isDirectory, kind: kindID,
            isPackage: sourceEntry.isPackage, isAggregate: entry.isAggregate, bins: mappedBins,
            scanStatus: sourceEntry.ownScanStatus, hardLink: record?.identity
        )
    }

    private func rebuilding(excluding excluded: Int?, replacingHistogramAt replacement: Int? = nil, with replacementBins: [Bin] = []) -> DiskIndex {
        let builder = DiskIndexBuilder(rootURL: rootURL, sizeMode: sizeMode, kinds: kinds)
        var remapping = [Int](repeating: -1, count: entries.count)
        for id in entries.indices {
            let entry = entries[id]
            if id == excluded { continue }
            let parent = Int(entry.parent)
            if parent >= 0, remapping[parent] < 0 { continue }
            let bins = id == replacement ? replacementBins : Array(bins(of: id))
            let hardLink = hardLinks[id]
            let logicalSize = entry.isAggregate ? bins.reduce(Int64(0)) { $0 + $1.logicalSize } : hardLink?.logicalSize ?? entry.logicalSize
            let allocatedSize = entry.isAggregate ? bins.reduce(Int64(0)) { $0 + $1.allocatedSize } : hardLink?.allocatedSize ?? entry.allocatedSize
            let count = entry.isAggregate ? bins.reduce(0) { $0 + $1.count } : entry.fileCount
            remapping[id] = builder.append(
                parent: parent < 0 ? -1 : remapping[parent], name: name(of: id),
                logicalSize: logicalSize, allocatedSize: allocatedSize, fileCount: count,
                isDirectory: entry.isDirectory, kind: entry.kind, isPackage: entry.isPackage,
                isAggregate: entry.isAggregate, bins: bins, scanStatus: entry.ownScanStatus,
                hardLink: hardLink?.identity
            )
        }
        return builder.finish(volumeSpace: volumeSpace)
    }
}
