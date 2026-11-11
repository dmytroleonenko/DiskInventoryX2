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

    private static func cloneFile(_ source: URL, _ destination: URL) throws {
        let status = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return Int32(-1) }
                return clonefile(sourcePath, destinationPath, 0)
            }
        }
        guard status == 0 else {
            throw Failure(description: "clonefile failed for \(destination.path): errno \(errno)")
        }
    }

    private static func cloneScenario(root: URL) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let full = root.appendingPathComponent("Full")
        try manager.createDirectory(at: full, withIntermediateDirectories: true)

        let source = full.appendingPathComponent("source.bin")
        try Data(repeating: 0xa5, count: 1_048_576).write(to: source)
        let sourceMeasures = try measures(source)
        try check(sourceMeasures.allocated >= 1_048_576, "Clone fixture data fork was not allocated")

        let hard = full.appendingPathComponent("hard.bin")
        try manager.linkItem(at: source, to: hard)
        let cloned = full.appendingPathComponent("clone.bin")
        try cloneFile(source, cloned)
        let cloneMeasures = try measures(cloned)
        try check(cloneMeasures.allocated == sourceMeasures.allocated, "APFS clone did not expose equivalent allocated blocks")
        try check(CloneFileMetadata.read(at: cloned)?.isFullClone == true, "Full clone metadata was not recognized")

        let partial = full.appendingPathComponent("partial.bin")
        try cloneFile(source, partial)
        let partialHandle = try FileHandle(forWritingTo: partial)
        _ = try partialHandle.seek(toOffset: 512 * 1024)
        try partialHandle.write(contentsOf: Data([0x00]))
        try partialHandle.synchronize()
        try partialHandle.close()
        let partialMeasures = try measures(partial)
        if let partialMetadata = CloneFileMetadata.read(at: partial) {
            try check(!partialMetadata.isFullClone, "A partially diverged clone reported a full-clone identity")
        }

        let grouped = full.appendingPathComponent("Grouped")
        try manager.createDirectory(at: grouped, withIntermediateDirectories: true)
        for number in 0..<60 {
            try Data(repeating: UInt8(number + 1), count: 256).write(to: grouped.appendingPathComponent("ordinary-\(number).bin"))
        }
        let smallSource = grouped.appendingPathComponent("small-source.bin")
        try Data(repeating: 0x11, count: 512).write(to: smallSource)
        let smallClone = grouped.appendingPathComponent("small-clone.bin")
        try cloneFile(smallSource, smallClone)
        let smallMeasures = try measures(smallSource)
        let ordinaryMeasures = try measures(grouped.appendingPathComponent("ordinary-0.bin"))
        try check(smallMeasures.allocated > 0, "Small clone fixture was not allocated")

        let expectedLogical = sourceMeasures.logical + cloneMeasures.logical + partialMeasures.logical
            + ordinaryMeasures.logical * 60 + smallMeasures.logical * 2
        let expectedAllocated = sourceMeasures.allocated + partialMeasures.allocated
            + ordinaryMeasures.allocated * 60 + smallMeasures.allocated

        var result = try await scan(root)
        var index = result.root.index
        let sourceNode = try node(source, in: index)
        let hardNode = try node(hard, in: index)
        let cloneNode = try node(cloned, in: index)
        let partialNode = try node(partial, in: index)
        guard let sourceLink = index.hardLink(at: sourceNode.id),
              let hardLink = index.hardLink(at: hardNode.id) else {
            throw Failure(description: "Clone fixture hard links lost their metadata")
        }
        try check(sourceLink.identity == hardLink.identity, "Hard links do not share filesystem identity")
        try check(sourceLink.ownerID == hardLink.ownerID && sourceLink.ownerID == min(sourceNode.id, hardNode.id), "Hard links must charge one owner")
        try check(sourceNode.logicalSize + hardNode.logicalSize == sourceMeasures.logical, "Hard links must charge one logical name")
        guard let sourceClone = index.clone(at: sourceNode.id),
              let cloneRecord = index.clone(at: cloneNode.id) else {
            throw Failure(description: "Full clones lost their extent group metadata")
        }
        try check(sourceClone.identity == cloneRecord.identity, "Full clones do not share extent identity")
        try check(sourceClone.ownerID == cloneRecord.ownerID, "Clone members disagree about the shared owner")
        let cloneMembers = [sourceNode, hardNode, cloneNode]
        try check(cloneMembers.contains { $0.id == sourceClone.ownerID && $0.allocatedSize == sourceMeasures.allocated }, "One clone member must own the data fork")
        try check(cloneMembers.filter { $0.allocatedSize == 0 }.count == 2, "Nonowning clone members must keep only independent allocation")
        try check(cloneNode.logicalSize == cloneMeasures.logical, "A clone lost its per-name logical size")
        try check(index.clone(at: partialNode.id) == nil, "A partial clone was treated as a full clone")
        try check(partialNode.allocatedSize == partialMeasures.allocated, "A partial clone was deduplicated")

        let groupedNode = try node(grouped, in: index)
        let groups = groupedNode.children.filter(\.isAggregate)
        try check(groups.count == 1 && groups[0].fileCount == 60, "Clone names were absorbed by the small-file aggregate")
        try check(groupedNode.children.count == 3, "Small clones must stay individually addressable")
        let smallSourceNode = try node(smallSource, in: index)
        let smallCloneNode = try node(smallClone, in: index)
        guard let smallSourceRecord = index.clone(at: smallSourceNode.id),
              let smallCloneRecord = index.clone(at: smallCloneNode.id) else {
            throw Failure(description: "Grouped small clones lost their extent identity")
        }
        try check(smallSourceRecord.identity == smallCloneRecord.identity, "Small clones do not share extent identity")
        try check(smallSourceNode.id == smallSourceRecord.ownerID || smallCloneNode.id == smallSourceRecord.ownerID, "Small clone owner is not a group member")
        try check([smallSourceNode, smallCloneNode].filter { $0.allocatedSize == smallMeasures.allocated }.count == 1, "Small clones must charge one data fork")
        try check(smallSourceNode.logicalSize == smallMeasures.logical && smallCloneNode.logicalSize == smallMeasures.logical, "Small clones lost per-name logical sizes")
        try check(index.clone(at: groups[0].id) == nil, "The ordinary aggregate acquired clone metadata")
        try conserved(index, logical: expectedLogical, allocated: expectedAllocated, count: 66)
        let physical = index.withSizeMode(.physical)
        try check(physical.clone(at: cloneNode.id)?.ownerID == cloneRecord.ownerID, "Size toggle lost clone ownership")
        let sampled = index.withVolumeSpace(VolumeSpaceSnapshot(volumeURL: root, capacityBytes: 100_000_000, freeBytes: 50_000_000))
        try check(sampled.clone(at: cloneNode.id)?.ownerID == cloneRecord.ownerID, "Volume sample lost clone ownership")

        result = try await remove(cloned, from: [result])[0]
        index = result.root.index
        try check(index.find(url: cloned) == nil, "Deleted clone retained its name")
        let survivorSource = try node(source, in: index)
        let survivorHard = try node(hard, in: index)
        let survivorGroup = [survivorSource, survivorHard]
        guard let survivorLink = index.hardLink(at: survivorSource.id),
              let survivorHardLink = index.hardLink(at: survivorHard.id) else {
            throw Failure(description: "Surviving hard links lost their metadata")
        }
        try check(survivorLink.ownerID == survivorHardLink.ownerID && survivorLink.identity == survivorHardLink.identity, "Hard-link ownership broke after clone deletion")
        try check(survivorGroup.reduce(Int64(0)) { $0 + $1.logicalSize } == sourceMeasures.logical, "Surviving hard links lost their logical charge")
        try check(survivorGroup.filter { $0.allocatedSize == sourceMeasures.allocated }.count == 1, "Clone deletion changed the retained data-fork charge")
        guard let survivingClone = survivorGroup.compactMap({ index.clone(at: $0.id) }).first else {
            throw Failure(description: "Surviving hard links lost their clone record")
        }
        try check(survivorGroup.contains { $0.id == survivingClone.ownerID && $0.allocatedSize == sourceMeasures.allocated }, "The surviving clone owner lost the data-fork charge")
        try conserved(index, logical: expectedLogical - cloneMeasures.logical, allocated: expectedAllocated, count: 65)

        result = try await remove(source, from: [result])[0]
        index = result.root.index
        let lastHard = try node(hard, in: index)
        try check(lastHard.logicalSize == sourceMeasures.logical && lastHard.allocatedSize == sourceMeasures.allocated, "The surviving hard link did not take over both measures")
        guard let promoted = index.clone(at: lastHard.id) else {
            throw Failure(description: "The surviving hard link lost its clone record")
        }
        try check(promoted.ownerID == lastHard.id && promoted.identity == sourceClone.identity, "The surviving hard link was not promoted to clone owner")
        try check(promoted.logicalSize == sourceMeasures.logical && promoted.allocatedSize == sourceMeasures.allocated, "Promotion lost the original measures")
        try conserved(index, logical: expectedLogical - cloneMeasures.logical, allocated: expectedAllocated, count: 64)

        result = try await remove(hard, from: [result])[0]
        index = result.root.index
        try check(index.find(url: hard) == nil, "The last clone-group name survived deletion")
        try conserved(index, logical: expectedLogical - sourceMeasures.logical - cloneMeasures.logical, allocated: expectedAllocated - sourceMeasures.allocated, count: 63)
    }

    private static func cloneRefresh(root: URL) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceDirectory = root.appendingPathComponent("Source")
        let targetDirectory = root.appendingPathComponent("Target")
        let outsideDirectory = root.appendingPathComponent("Outside")
        for directory in [sourceDirectory, targetDirectory, outsideDirectory] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let owner = sourceDirectory.appendingPathComponent("owner.bin")
        try Data(repeating: 0x3c, count: 1_048_576).write(to: owner)
        let ownerMeasures = try measures(owner)
        let member = targetDirectory.appendingPathComponent("member.bin")
        try cloneFile(owner, member)
        let memberMeasures = try measures(member)
        guard let ownerMetadata = CloneFileMetadata.read(at: owner), ownerMetadata.isFullClone,
              let memberMetadata = CloneFileMetadata.read(at: member), memberMetadata.isFullClone else {
            throw Failure(description: "Full clones were not recognized before scanning")
        }
        try check(ownerMetadata.identity == memberMetadata.identity, "Full clones do not share extent identity before scanning")

        let initial = try await scan(root)
        let initialOwner = try node(owner, in: initial.root.index)
        let initialMember = try node(member, in: initial.root.index)
        guard let initialOwnerRecord = initial.root.index.clone(at: initialOwner.id),
              let initialMemberRecord = initial.root.index.clone(at: initialMember.id) else {
            throw Failure(description: "Initial clone scan lost extent identity")
        }
        try check(initialOwnerRecord.identity == initialMemberRecord.identity, "Initial clone scan split an extent group")
        try conserved(initial.root.index, logical: ownerMeasures.logical * 2, allocated: ownerMeasures.allocated, count: 2)

        let targetScan = try await scan(targetDirectory)
        let knownRefresh = IndexRefresh(url: targetDirectory, replacement: targetScan.root.index)
        try check(!knownRefresh.requiresFullRescan(for: [initial]), "A known clone identity forced a full rescan")
        var results = knownRefresh.apply(to: [initial])
        var index = results[0].root.index
        let ownerNode = try node(owner, in: index)
        let memberNode = try node(member, in: index)
        guard let ownerRecord = index.clone(at: ownerNode.id),
              let memberRecord = index.clone(at: memberNode.id) else {
            throw Failure(description: "Grafted clone lost its extent identity")
        }
        try check(ownerRecord.identity == memberRecord.identity, "Grafted clone members disagree about identity")
        try check(ownerRecord.ownerID == ownerNode.id && memberRecord.ownerID == ownerNode.id, "Graft did not retain the outside owner")
        try check(ownerNode.allocatedSize == ownerMeasures.allocated && memberNode.allocatedSize == 0, "Graft did not deduplicate the clone data fork")
        try check(memberNode.logicalSize == memberMeasures.logical, "Graft changed a clone's logical size")
        try conserved(index, logical: ownerMeasures.logical * 2, allocated: ownerMeasures.allocated, count: 2)

        let lateSource = outsideDirectory.appendingPathComponent("late-source.bin")
        try Data(repeating: 0x71, count: 65_536).write(to: lateSource)
        let lateMeasures = try measures(lateSource)
        let lateClone = targetDirectory.appendingPathComponent("late-clone.bin")
        try cloneFile(lateSource, lateClone)
        let ambiguousScan = try await scan(targetDirectory)
        let ambiguous = IndexRefresh(url: targetDirectory, replacement: ambiguousScan.root.index)
        try check(ambiguous.requiresFullRescan(for: results), "An unknown clone identity did not force a conservative rescan")
        let wholeScan = try await scan(root)
        let wholeRefresh = IndexRefresh(url: root, replacement: wholeScan.root.index)
        try check(!wholeRefresh.requiresFullRescan(for: results), "A whole-root replacement unnecessarily forced another scan")
        results = wholeRefresh.apply(to: results)
        index = results[0].root.index
        let lateSourceNode = try node(lateSource, in: index)
        let lateCloneNode = try node(lateClone, in: index)
        guard let lateSourceRecord = index.clone(at: lateSourceNode.id),
              let lateCloneRecord = index.clone(at: lateCloneNode.id) else {
            throw Failure(description: "Whole-root refresh lost the late clone identity")
        }
        try check(lateSourceRecord.identity == lateCloneRecord.identity, "Whole-root refresh did not rejoin the late clone group")
        try check([lateSourceNode.id, lateCloneNode.id].contains(lateSourceRecord.ownerID), "Late clone owner is not a group member")
        try conserved(
            index, logical: ownerMeasures.logical * 2 + lateMeasures.logical * 2,
            allocated: ownerMeasures.allocated + lateMeasures.allocated, count: 4
        )

        let partial = targetDirectory.appendingPathComponent("partial.bin")
        try cloneFile(owner, partial)
        let partialHandle = try FileHandle(forWritingTo: partial)
        _ = try partialHandle.seek(toOffset: 4096)
        try partialHandle.write(contentsOf: Data([0x00]))
        try partialHandle.synchronize()
        try partialHandle.close()
        let partialMeasures = try measures(partial)
        if let partialMetadata = CloneFileMetadata.read(at: partial) {
            try check(!partialMetadata.isFullClone, "A partially diverged clone reported a full-clone identity during refresh")
        }
        let partialScan = try await scan(targetDirectory)
        let partialRefresh = IndexRefresh(url: targetDirectory, replacement: partialScan.root.index)
        try check(!partialRefresh.requiresFullRescan(for: results), "An unknown partial clone forced a rescan")
        results = partialRefresh.apply(to: results)
        index = results[0].root.index
        let partialNode = try node(partial, in: index)
        try check(index.clone(at: partialNode.id) == nil && partialNode.allocatedSize == partialMeasures.allocated, "Refresh deduplicated a partial clone")
        try conserved(
            index, logical: ownerMeasures.logical * 2 + lateMeasures.logical * 2 + partialMeasures.logical,
            allocated: ownerMeasures.allocated + lateMeasures.allocated + partialMeasures.allocated, count: 5
        )
    }

    private static func unsharedDeletion(root: URL) throws {
        let builder = DiskIndexBuilder(rootURL: root)
        let rootID = builder.append(parent: -1, name: root.lastPathComponent, isDirectory: true)
        let first = builder.append(parent: rootID, name: "first", isDirectory: true)
        let removed = builder.append(parent: first, name: "removed", isDirectory: true)
        builder.append(parent: removed, name: "file", logicalSize: 30, allocatedSize: 40, fileCount: 1, isDirectory: false)
        builder.append(parent: removed, name: "unreadable", isDirectory: true, scanStatus: .unreadable)
        builder.append(parent: first, name: "kept", logicalSize: 10, allocatedSize: 20, fileCount: 1, isDirectory: false)
        let second = builder.append(parent: rootID, name: "second", isDirectory: true)
        builder.append(parent: second, name: "file", logicalSize: 20, allocatedSize: 30, fileCount: 1, isDirectory: false)
        let original = builder.finish()
        let updated = original.removingSubtree(at: removed)
        try check(original.root.logicalSize == 60 && original.root.scanStatus == .partial, "Deletion mutated the original snapshot")
        try conserved(original, logical: 60, allocated: 90, count: 3)
        try conserved(updated, logical: 30, allocated: 50, count: 2)
        try check(updated.find(url: root.appendingPathComponent("first"))?.id == first, "Retained node ID changed")
        try check(Array(updated.childIDs(of: first)).count == 1, "Deleted child link remains reachable")
        try check(updated.root.logicalSize == 30 && updated.root.allocatedSize == 50 && updated.root.fileCount == 2, "Deletion did not update ancestor totals")
        try check(updated.root.scanStatus == .complete && updated.unavailableEntryCount == 0, "Deletion retained an unavailable descendant")
        try check(updated.find(url: root.appendingPathComponent("first/removed")) == nil, "Deleted subtree remains reachable")
        try check(updated.childIDs(of: rootID).first == second, "Deletion did not reorder changed ancestors")
        let secondDeletion = updated.removingSubtree(at: second)
        try check(secondDeletion.root.logicalSize == 10 && updated.root.logicalSize == 30, "Repeated deletion mutated a snapshot or lost totals")
        let copied = updated.copyingSubtree(at: rootID, sizeMode: .logical)
        try check(copied.root.logicalSize == 30 && copied.find(url: root.appendingPathComponent("first/removed")) == nil, "Subtree copy resurrected deleted entries")
    }

    private static func sharedDeletionAfterTombstone(root: URL, ownerInside: Bool) throws {
        let builder = DiskIndexBuilder(rootURL: root)
        let top = builder.append(parent: -1, name: root.lastPathComponent, isDirectory: true)
        let inside = builder.append(parent: top, name: "inside", isDirectory: true)
        let outside = builder.append(parent: top, name: "outside", isDirectory: true)
        let noise = builder.append(parent: top, name: "noise", logicalSize: 1, allocatedSize: 1, fileCount: 1, isDirectory: false)
        let link = FileIdentity(device: 1, inode: 42)
        let clone = CloneFileMetadata.Identity(device: 1, stream: 43)
        for parent in ownerInside ? [inside, outside] : [outside, inside] {
            builder.append(parent: parent, name: "link", logicalSize: 10, allocatedSize: 80, fileCount: 1, isDirectory: false, hardLink: link)
            builder.append(parent: parent, name: "clone", logicalSize: 10, allocatedSize: 80, fileCount: 1, isDirectory: false, cloneIdentity: clone, cloneDataAllocatedSize: 60)
        }
        let original = builder.finish()
        let withoutNoise = original.removingSubtree(at: noise)
        let result = withoutNoise.removingSubtree(at: inside)
        try conserved(original, logical: 31, allocated: 181, count: 5)
        try conserved(withoutNoise, logical: 30, allocated: 180, count: 4)
        try conserved(result, logical: 20, allocated: 160, count: 2)
        try check(result.find(url: root.appendingPathComponent("noise")) == nil, "Rebuild resurrected a tombstone")
        try check(result.find(url: root.appendingPathComponent("inside")) == nil, "Shared subtree survived deletion")
        let remainingLink = try node(root.appendingPathComponent("outside/link"), in: result)
        let remainingClone = try node(root.appendingPathComponent("outside/clone"), in: result)
        try check(result.hardLink(at: remainingLink.id)?.ownerID == remainingLink.id, "Hardlink ownership was not retained or transferred")
        try check(result.clone(at: remainingClone.id)?.ownerID == remainingClone.id, "Clone ownership was not retained or transferred")
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
        try unsharedDeletion(root: root.appendingPathComponent("Unshared"))
        for ownerInside in [false, true] {
            try sharedDeletionAfterTombstone(root: root.appendingPathComponent("Shared-\(ownerInside)"), ownerInside: ownerInside)
        }
        try await cloneScenario(root: root.appendingPathComponent("Clones"))
        try await cloneRefresh(root: root.appendingPathComponent("CloneRefresh"))
        print("PASS: hardlink names and single-owner bytes; owning/nonowning file and directory deletion; surviving promotion and last link; logical/physical and kind conservation; ordinary aggregation/detail deletion; retained status and volume snapshots; full/partial APFS clone data-fork dedup, per-name logical sizes, grouped small clones, clone-owner promotion, and conservative refresh")
    }
}
