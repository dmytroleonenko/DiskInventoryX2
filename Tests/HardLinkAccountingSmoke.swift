import Foundation
import Darwin

/// Exercises charged ownership against real links, scanner arenas, and permanent deletion.
struct HardLinkAccountingSmoke {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    private static func scan(_ url: URL) async throws -> ScanResult {
        try await scan(ScanRequest(url: url))
    }

    private static func scan(_ request: ScanRequest) async throws -> ScanResult {
        var completed: ScanResult?
        for try await result in DiskScanner().scan(request) where result.isComplete {
            completed = result
        }
        guard let completed else { throw Failure(description: "No completed hardlink fixture scan") }
        return completed
    }

    private static func scanGroup(_ group: DiskNode) async throws -> ScanResult {
        guard let request = group.groupRequest else { throw Failure(description: "Aggregate has no real drill request") }
        return try await scan(request)
    }

    private static func node(_ url: URL, in index: DiskIndex) throws -> DiskNode {
        guard let node = index.find(url: url) else { throw Failure(description: "Missing retained name: \(url.path)") }
        return node
    }

    private static func measures(_ url: URL) throws -> (logical: Int64, allocated: Int64, links: UInt64) {
        var value = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &value)
        }
        guard result == 0 else { throw Failure(description: "Cannot stat hardlink fixture") }
        return (Int64(value.st_size), Int64(value.st_blocks) * 512, UInt64(value.st_nlink))
    }

    private static func conserved(_ index: DiskIndex, logical: Int64, allocated: Int64, count: Int) throws {
        try check(index.root.logicalSize == logical && index.root.allocatedSize == allocated, "Arena byte totals are not conserved")
        try check(index.root.fileCount == count, "Arena must count every retained filename")
        for mode in [DiskSizeMode.logical, .physical] {
            let changed = index.withSizeMode(mode)
            let statistics = changed.statistics(for: 0)
            try check(changed.root.size == (mode == .logical ? logical : allocated), "Size toggle lost a measure")
            try check(statistics.reduce(Int64(0)) { $0 + $1.size } == changed.root.size, "Kind bytes disagree with the arena")
            try check(statistics.reduce(0) { $0 + $1.count } == count, "Kind counts lost hardlink names")
            let presentation = changed.presentationStatistics(for: 0)
            try check(presentation.reduce(Int64(0)) { $0 + $1.size } == changed.root.size, "Presentation bytes disagree with the arena")
            try check(presentation.reduce(0) { $0 + $1.count } == count, "Presentation counts lost names")
        }
    }

    private static func remove(_ url: URL, from results: [ScanResult]) async throws -> [ScanResult] {
        guard let first = results.first else { throw Failure(description: "No deletion fixture result") }
        let item = try node(url, in: first.root.index)
        let mutation = IndexDeletion(url: url, logicalSize: item.logicalSize, allocatedSize: item.allocatedSize, kindIdentifier: item.kindIdentifier)
        let service = PermanentDeletionService()
        let target = try await service.prepare(url: url, scanRoot: first.root.index.rootURL)
        try await service.remove(target)
        try check(!FileManager.default.fileExists(atPath: url.path), "Deletion service retained a deleted name")
        return mutation.apply(to: results)
    }

    private static func scenario(root: URL, removeOwner: Bool, directory: Bool) async throws {
        let manager = FileManager.default
        let left = root.appendingPathComponent("Left")
        let right = root.appendingPathComponent("Right")
        for folder in [left, right] {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            for number in 0..<60 {
                try Data(repeating: UInt8(number + 1), count: 256).write(to: folder.appendingPathComponent("ordinary-\(number).bin"))
            }
        }
        let firstURL = left.appendingPathComponent("linked.bin")
        let secondURL = right.appendingPathComponent("alias.bin")
        try Data(repeating: 0x5a, count: 8192).write(to: firstURL)
        try manager.linkItem(at: firstURL, to: secondURL)
        let linked = try measures(firstURL)
        let ordinary = try measures(left.appendingPathComponent("ordinary-0.bin"))
        try check(linked.allocated > 0, "Hardlink fixture must have real allocated bytes")
        var result = try await scan(root)
        let index = result.root.index
        let first = try node(firstURL, in: index)
        let second = try node(secondURL, in: index)
        guard let firstRecord = index.hardLink(at: first.id), let secondRecord = index.hardLink(at: second.id) else {
            throw Failure(description: "Small hardlinks were aggregated or lost sparse metadata")
        }
        try check(firstRecord.identity == secondRecord.identity, "Aliases do not share filesystem identity")
        try check(firstRecord.ownerID == min(first.id, second.id) && secondRecord.ownerID == firstRecord.ownerID, "First arena member must own the charge")
        try check(firstRecord.logicalSize == linked.logical && secondRecord.logicalSize == linked.logical, "Original logical sizes were not retained")
        try check(firstRecord.allocatedSize == linked.allocated && secondRecord.allocatedSize == linked.allocated, "Original allocated sizes were not retained")
        let owner = index.node(at: firstRecord.ownerID)
        let alias = owner.id == first.id ? second : first
        try check(owner.logicalSize == linked.logical && owner.allocatedSize == linked.allocated, "Owner lost its charge")
        try check(alias.logicalSize == 0 && alias.allocatedSize == 0 && alias.fileCount == 1, "Nonowning alias must count its name, not its bytes")
        for folder in [left, right] {
            let parent = try node(folder, in: index)
            let groups = parent.children.filter(\.isAggregate)
            try check(groups.count == 1 && groups[0].fileCount == 60, "Ordinary small files must still aggregate alongside retained hardlinks")
            try check(index.hardLink(at: groups[0].id) == nil, "Ordinary aggregate acquired hardlink metadata")
            try check(parent.children.count == 2, "Hardlink must remain a real child beside the ordinary aggregate")
            let detail = try await scanGroup(groups[0])
            try check(detail.root.index.find(url: firstURL) == nil && detail.root.index.find(url: secondURL) == nil, "Aggregate drill reintroduced an individually retained hardlink")
            try conserved(detail.root.index, logical: ordinary.logical * 60, allocated: ordinary.allocated * 60, count: 60)
            for number in 0..<60 {
                let ordinaryURL = folder.appendingPathComponent("ordinary-\(number).bin")
                try check(detail.root.index.find(url: ordinaryURL) != nil, "Aggregate drill lost an ordinary member")
            }
        }
        try conserved(index, logical: linked.logical + ordinary.logical * 120, allocated: linked.allocated + ordinary.allocated * 120, count: 122)
        for mode in [DiskSizeMode.logical, .physical] {
            let changed = index.withSizeMode(mode)
            let changedAlias = try node(alias.url, in: changed)
            try check(changed.hardLink(at: changedAlias.id)?.ownerID == owner.id && changedAlias.logicalSize == 0, "Toggle changed hardlink ownership")
        }
        let direct = try await scan(alias.url)
        try conserved(direct.root.index, logical: linked.logical, allocated: linked.allocated, count: 1)

        let deleted = removeOwner ? owner : alias
        let survivorURL = removeOwner ? alias.url : owner.url
        let deletionURL = directory ? deleted.url.deletingLastPathComponent() : deleted.url
        let sampled = index.withSizeMode(removeOwner ? .logical : .physical)
            .withVolumeSpace(VolumeSpaceSnapshot(volumeURL: root, capacityBytes: 100_000_000, freeBytes: 50_000_000))
        result = ScanResult(root: sampled.root, skippedCount: result.skippedCount, request: ScanRequest(url: root, sizeMode: sampled.sizeMode), isComplete: result.isComplete, currentPath: result.currentPath, typeStatistics: sampled.presentationStatistics(for: 0))
        let survivorParent = try node(survivorURL.deletingLastPathComponent(), in: sampled)
        let zoomed = ScanResult(root: survivorParent, skippedCount: result.skippedCount, request: result.request, isComplete: result.isComplete, currentPath: result.currentPath, typeStatistics: sampled.presentationStatistics(for: survivorParent.id))
        let replaced = try await remove(deletionURL, from: [result, zoomed])
        result = replaced[0]
        try check(result.root.index === replaced[1].root.index, "Retained views of one arena must share a single rebuild")
        try check(replaced[1].root.url == survivorParent.url && result.isComplete, "Deletion changed retained scan scope or completion")
        try check(result.root.index.volumeSpace == nil, "Deletion must refresh an old volume sample, not estimate reclaimed bytes or retain stale data")
        let survivor = try node(survivorURL, in: result.root.index)
        guard let promoted = result.root.index.hardLink(at: survivor.id) else { throw Failure(description: "Surviving alias lost original metadata") }
        try check(promoted.ownerID == survivor.id && promoted.identity == firstRecord.identity, "Surviving alias was not promoted after deletion")
        try check(survivor.logicalSize == linked.logical && survivor.allocatedSize == linked.allocated, "Promotion did not restore both original measures")
        let ordinaryCount = directory ? 60 : 120
        try conserved(result.root.index, logical: linked.logical + ordinary.logical * Int64(ordinaryCount), allocated: linked.allocated + ordinary.allocated * Int64(ordinaryCount), count: ordinaryCount + 1)
        let survivingMeasures = try measures(survivorURL)
        try check(survivingMeasures.links == 1, "Internal alias deletion did not leave a single filesystem link")
        guard let survivingGroup = result.root.index.find(url: survivorURL.deletingLastPathComponent(), aggregate: true) else {
            throw Failure(description: "Surviving directory lost its ordinary aggregate")
        }
        let survivorDetail = try await scanGroup(survivingGroup)
        try check(survivorDetail.root.index.find(url: survivorURL) == nil, "An original hardlink survivor reentered the aggregate after its link count became one")
        try conserved(survivorDetail.root.index, logical: ordinary.logical * 60, allocated: ordinary.allocated * 60, count: 60)
        result = try await remove(survivorURL, from: [result])[0]
        try check(result.root.index.find(url: survivorURL) == nil, "Last-link deletion retained its name")
        try conserved(result.root.index, logical: ordinary.logical * Int64(ordinaryCount), allocated: ordinary.allocated * Int64(ordinaryCount), count: ordinaryCount)
        for parent in result.root.children {
            try check(result.root.index.hardLink(at: parent.id) == nil, "Last-link deletion retained stale directory metadata")
            for child in parent.children {
                try check(result.root.index.hardLink(at: child.id) == nil, "Last-link deletion retained stale sparse metadata")
            }
        }

        // A real ungrouped detail scan and its aggregate parent must reconcile independently.
        let ordinaryURL = survivorURL.deletingLastPathComponent().appendingPathComponent("ordinary-0.bin")
        guard let ordinaryGroup = result.root.index.find(url: ordinaryURL.deletingLastPathComponent(), aggregate: true) else {
            throw Failure(description: "Ordinary aggregate missing before detail deletion")
        }
        let detail = try await scanGroup(ordinaryGroup)
        let ordinaryNode = try node(ordinaryURL, in: detail.root.index)
        try check(detail.root.index.hardLink(at: ordinaryNode.id) == nil && !ordinaryNode.isAggregate, "Single-link detail changed representation")
        let mutation = IndexDeletion(url: ordinaryURL, logicalSize: ordinaryNode.logicalSize, allocatedSize: ordinaryNode.allocatedSize, kindIdentifier: ordinaryNode.kindIdentifier)
        let service = PermanentDeletionService()
        let target = try await service.prepare(url: ordinaryURL, scanRoot: root)
        try await service.remove(target)
        let reconciled = mutation.apply(to: [result, detail])
        try conserved(reconciled[0].root.index, logical: ordinary.logical * Int64(ordinaryCount - 1), allocated: ordinary.allocated * Int64(ordinaryCount - 1), count: ordinaryCount - 1)
        try conserved(reconciled[1].root.index, logical: ordinary.logical * 59, allocated: ordinary.allocated * 59, count: 59)
    }

    private static func retainedState(root: URL) throws {
        let builder = DiskIndexBuilder(rootURL: root)
        let rootID = builder.append(parent: -1, name: root.lastPathComponent, isDirectory: true)
        let partial = builder.append(parent: rootID, name: "Partial", isDirectory: true)
        let unavailable = builder.append(parent: partial, name: "Unreadable", isDirectory: true, scanStatus: .unreadable)
        builder.markIncomplete(partial, status: .partial)
        builder.markIncomplete(unavailable, status: .partial)
        let cloud = builder.append(parent: rootID, name: "Cloud", fileCount: 1, isDirectory: false, scanStatus: .cloudOnly)
        let automount = builder.append(parent: rootID, name: "Automount", isDirectory: true, scanStatus: .automount)
        let otherVolume = builder.append(parent: rootID, name: "OtherVolume", isDirectory: true, scanStatus: .otherVolume)
        for status in [ScanEntryStatus.unreadable, .cloudOnly, .automount, .otherVolume] {
            builder.append(parent: rootID, name: "Unknown-\(status.rawValue)", isDirectory: false, scanStatus: status)
            builder.append(parent: rootID, name: "Unknown-\(status.rawValue).app", isDirectory: true, isPackage: true, scanStatus: status)
        }
        let partialPackage = builder.append(parent: rootID, name: "Partial.app", isDirectory: true, isPackage: true, scanStatus: .partial)
        builder.append(parent: partialPackage, name: "Known.bin", logicalSize: 5, allocatedSize: 4096, fileCount: 1, isDirectory: false)
        builder.append(parent: rootID, name: "delete.bin", logicalSize: 10, allocatedSize: 4096, fileCount: 1, isDirectory: false)
        let snapshot = VolumeSpaceSnapshot(volumeURL: root, capacityBytes: 100_000, freeBytes: 40_000)
        let index = builder.finish(volumeSpace: snapshot)
        try check(index.root.scanStatus == .partial && index.node(at: partial).scanStatus == .partial, "Incomplete children did not propagate to ancestors")
        for (id, status) in [(unavailable, ScanEntryStatus.unreadable), (cloud, .cloudOnly), (automount, .automount), (otherVolume, .otherVolume)] {
            try check(index.node(at: id).scanStatus == status, "A concrete incomplete reason was erased")
        }
        let rebuilt = index.removingItem(at: root.appendingPathComponent("delete.bin"), logicalSize: 10, allocatedSize: 4096, kindIdentifier: index.kind(at: 0).identifier)
        for retained in [index, index.withSizeMode(.logical), rebuilt, rebuilt.withSizeMode(.logical)] {
            try check(retained.volumeSpace?.capacityBytes == snapshot.capacityBytes && retained.volumeSpace?.freeBytes == snapshot.freeBytes, "Snapshot was lost or changed by an arena-only operation")
            try check(retained.root.scanStatus == .partial, "Rebuild or toggle lost incomplete state")
            let unreadable = try node(root.appendingPathComponent("Partial/Unreadable"), in: retained)
            try check(unreadable.scanStatus == .unreadable, "Rebuild lost the concrete unavailable reason")
            try check(retained.statistics(for: 0).reduce(0) { $0 + $1.count } == retained.root.fileCount, "Unavailable leaf placeholders invented kind counts")
            try check(retained.presentationStatistics(for: 0).reduce(0) { $0 + $1.count } == retained.root.fileCount, "Unavailable package placeholders invented kind counts")
        }
    }

    static func run(root: URL) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        for removeOwner in [true, false] {
            for directory in [false, true] {
                try await scenario(root: root.appendingPathComponent("\(removeOwner)-\(directory)"), removeOwner: removeOwner, directory: directory)
            }
        }
        try retainedState(root: root.appendingPathComponent("State"))
        print("PASS: hardlink names and single-owner bytes; owning/nonowning file and directory deletion; surviving promotion and last link; logical/physical and kind conservation; ordinary aggregation/detail deletion; retained status and volume snapshots")
    }
}
