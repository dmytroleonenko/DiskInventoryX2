import Foundation
import Darwin

/// Real scanner fixtures plus deterministic arena failures exercise refresh without a full rescan.
struct IndexRefreshSmoke {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    private static func scan(_ request: ScanRequest) async throws -> ScanResult {
        var completed: ScanResult?
        for try await value in DiskScanner().scan(request) where value.isComplete { completed = value }
        guard let completed else { throw Failure(description: "Refresh fixture did not finish scanning") }
        return completed
    }

    private static func node(_ path: String, in index: DiskIndex) throws -> DiskNode {
        guard let value = index.find(url: index.rootURL.appendingPathComponent(path)) else {
            throw Failure(description: "Missing refresh fixture node: \(path)")
        }
        return value
    }

    private static func result(_ index: DiskIndex, root: DiskNode? = nil, selection: ScanFileSelection = .all) -> ScanResult {
        let root = root ?? index.root
        return ScanResult(
            root: root, skippedCount: index.unavailableEntryCount,
            request: ScanRequest(url: index.rootURL, fileSelection: selection, sizeMode: index.sizeMode),
            isComplete: true, currentPath: nil, typeStatistics: index.presentationStatistics(for: root.id)
        )
    }

    private static func conserved(_ index: DiskIndex, logical: Int64, count: Int) throws {
        try check(index.root.logicalSize == logical && index.root.fileCount == count, "Refreshed directory totals disagree")
        for mode in [DiskSizeMode.logical, .physical] {
            let changed = index.withSizeMode(mode)
            let statistics = changed.statistics(for: 0)
            try check(statistics.reduce(Int64(0)) { $0 + $1.size } == changed.root.size, "Refreshed kind bytes disagree with arena")
            try check(statistics.reduce(0) { $0 + $1.count } == count, "Refreshed kind counts disagree with arena")
        }
    }

    private static func subtreeAndHistory(root: URL) throws {
        let builder = DiskIndexBuilder(rootURL: root, sizeMode: .logical)
        let top = builder.append(parent: -1, name: root.lastPathComponent, isDirectory: true)
        let left = builder.append(parent: top, name: "Left", isDirectory: true)
        builder.append(parent: left, name: "resize.bin", logicalSize: 10, allocatedSize: 4096, fileCount: 1, isDirectory: false)
        let removed = builder.append(parent: left, name: "Removed", isDirectory: true)
        builder.append(parent: removed, name: "gone.bin", logicalSize: 20, allocatedSize: 4096, fileCount: 1, isDirectory: false)
        let right = builder.append(parent: top, name: "Right", isDirectory: true)
        builder.append(parent: right, name: "old.bin", logicalSize: 30, allocatedSize: 4096, fileCount: 1, isDirectory: false)
        let original = builder.finish(volumeSpace: VolumeSpaceSnapshot(volumeURL: root, capacityBytes: 100_000, freeBytes: 50_000))
        let fresh = DiskIndexBuilder(rootURL: root.appendingPathComponent("Left"))
        let freshRoot = fresh.append(parent: -1, name: "Left", isDirectory: true)
        let text = fresh.internKind(identifier: "public.plain-text", fallbackName: "Text")
        fresh.append(parent: freshRoot, name: "resize.bin", logicalSize: 100, allocatedSize: 8192, fileCount: 1, isDirectory: false)
        fresh.append(parent: freshRoot, name: "added.txt", logicalSize: 50, allocatedSize: 4096, fileCount: 1, isDirectory: false, kind: text)
        let replacement = fresh.finish()
        let views = [result(original), result(original, root: original.node(at: left)), result(original, root: original.node(at: removed)), result(original, root: original.node(at: right))]
        let refreshed = IndexRefresh(url: replacement.rootURL, replacement: replacement).apply(to: views)
        let index = refreshed[0].root.index
        try check(refreshed.allSatisfy { $0.root.index === index }, "History zoom snapshots rebuilt one arena more than once")
        try conserved(index, logical: 180, count: 3)
        try check(index.sizeMode == .logical, "Fresh physical scan changed retained size mode")
        let sibling = try node("Right/old.bin", in: index)
        try check(sibling.logicalSize == 30, "Untouched sibling metadata changed")
        try check(index.find(url: root.appendingPathComponent("Left/Removed")) == nil, "Deleted descendant survived graft")
        try check(refreshed[1].root.url == replacement.rootURL && refreshed[3].root.url == root.appendingPathComponent("Right"), "Surviving history roots lost their scope")
        try check(refreshed[2].root.id == 0, "Missing zoom descendant did not fall back to surviving arena root")
        try check(index.statistics(for: 0).contains { index.kind(at: $0.kindID).identifier == "public.plain-text" }, "Fresh kind IDs were not remapped")
        try check(index.volumeSpace == nil, "Refresh retained a fabricated stale volume sample")
        try check(original.root.logicalSize == 60, "Refresh mutated an old snapshot")
        let independent = result(original.copyingSubtree(at: left, sizeMode: .physical))
        let independentRefresh = IndexRefresh(url: root, replacement: index).apply(to: [independent])[0]
        try conserved(independentRefresh.root.index, logical: 150, count: 2)
        try check(independentRefresh.root.url == replacement.rootURL && independentRefresh.root.index.sizeMode == .physical, "Enclosing refresh lost an independent retained directory scope")
        let newDirectory = DiskIndexBuilder(rootURL: root.appendingPathComponent(".Trash"))
        let trash = newDirectory.append(parent: -1, name: ".Trash", isDirectory: true)
        newDirectory.append(parent: trash, name: "moved.bin", logicalSize: 5, allocatedSize: 4096, fileCount: 1, isDirectory: false)
        let inserted = original.grafting(at: newDirectory.rootURL, replacement: newDirectory.finish())
        try conserved(inserted, logical: 65, count: 4)
        try check(inserted.find(url: root.appendingPathComponent(".Trash/moved.bin")) != nil, "New direct directory could not be grafted into an existing parent")

        let newRoot = DiskIndexBuilder(rootURL: root)
        let newTop = newRoot.append(parent: -1, name: root.lastPathComponent, isDirectory: true)
        newRoot.append(parent: newTop, name: "entirely-new.bin", logicalSize: 7, allocatedSize: 4096, fileCount: 1, isDirectory: false)
        let whole = IndexRefresh(url: root, replacement: newRoot.finish()).apply(to: refreshed)
        try conserved(whole[0].root.index, logical: 7, count: 1)
        try check(whole.allSatisfy { $0.root.id == 0 }, "Root refresh kept removed history roots")
    }

    private static func hardLinks(root: URL) throws {
        let identity = FileIdentity(device: 1, inode: 42)
        let builder = DiskIndexBuilder(rootURL: root)
        let top = builder.append(parent: -1, name: root.lastPathComponent, isDirectory: true)
        let outside = builder.append(parent: top, name: "Outside", isDirectory: true)
        builder.append(parent: outside, name: "owner.bin", logicalSize: 8, allocatedSize: 4096, fileCount: 1, isDirectory: false, hardLink: identity)
        let inside = builder.append(parent: top, name: "Inside", isDirectory: true)
        builder.append(parent: inside, name: "removed-alias.bin", logicalSize: 8, allocatedSize: 4096, fileCount: 1, isDirectory: false, hardLink: identity)
        let original = builder.finish()
        let fresh = DiskIndexBuilder(rootURL: root.appendingPathComponent("Inside"))
        let topFresh = fresh.append(parent: -1, name: "Inside", isDirectory: true)
        let newKind = fresh.internKind(identifier: "public.plain-text", fallbackName: "Text")
        fresh.append(parent: topFresh, name: "added-alias.txt", logicalSize: 80, allocatedSize: 8192, fileCount: 1, isDirectory: false, kind: newKind, hardLink: identity)
        fresh.append(parent: topFresh, name: "second-alias.txt", logicalSize: 80, allocatedSize: 8192, fileCount: 1, isDirectory: false, kind: newKind, hardLink: identity)
        let index = original.grafting(at: fresh.rootURL, replacement: fresh.finish())
        try conserved(index, logical: 80, count: 3)
        let owner = try node("Outside/owner.bin", in: index)
        let alias = try node("Inside/added-alias.txt", in: index)
        try check(owner.logicalSize == 80 && owner.allocatedSize == 8192 && owner.kindIdentifier == "public.plain-text", "Stale outside owner did not adopt freshly observed inode metadata")
        try check(alias.logicalSize == 0 && alias.fileCount == 1, "Added cross-boundary alias acquired duplicate bytes")
        try check(index.hardLink(at: owner.id)?.ownerID == owner.id && index.hardLink(at: alias.id)?.ownerID == owner.id, "Cross-boundary hardlink ownership is incoherent")
        try check(index.find(url: root.appendingPathComponent("Inside/removed-alias.bin")) == nil, "Removed hardlink name survived refresh")

        let empty = DiskIndexBuilder(rootURL: root.appendingPathComponent("Outside"))
        empty.append(parent: -1, name: "Outside", isDirectory: true)
        let promoted = index.grafting(at: empty.rootURL, replacement: empty.finish())
        try conserved(promoted, logical: 80, count: 2)
        let names = [try node("Inside/added-alias.txt", in: promoted), try node("Inside/second-alias.txt", in: promoted)]
        try check(names.filter { $0.logicalSize == 80 && $0.allocatedSize == 8192 }.count == 1, "Removing outside owner did not promote exactly one retained alias")
    }

    private static func statusAndPackages(root: URL) throws {
        let builder = DiskIndexBuilder(rootURL: root)
        let top = builder.append(parent: -1, name: root.lastPathComponent, isDirectory: true)
        let packageKind = builder.internKind(identifier: "com.apple.application-bundle", fallbackName: "Application")
        let package = builder.append(parent: top, name: "Fixture.app", isDirectory: true, kind: packageKind, isPackage: true)
        builder.append(parent: package, name: "Unavailable", isDirectory: true, scanStatus: .unreadable)
        builder.append(parent: top, name: "Snapshot.bin", logicalSize: 9, allocatedSize: 4096, fileCount: 1, isDirectory: false)
        let original = builder.finish()
        try check(original.root.scanStatus == .partial, "Status fixture failed to inherit unavailable child")
        let fresh = DiskIndexBuilder(rootURL: root.appendingPathComponent("Fixture.app"))
        let kind = fresh.internKind(identifier: "com.apple.application-bundle", fallbackName: "Application")
        let freshRoot = fresh.append(parent: -1, name: "Fixture.app", isDirectory: true, kind: kind, isPackage: true)
        fresh.append(parent: freshRoot, name: "Ready.bin", logicalSize: 15, allocatedSize: 8192, fileCount: 1, isDirectory: false)
        let refreshed = IndexRefresh(url: fresh.rootURL, replacement: fresh.finish()).apply(to: [result(original), result(original, root: original.node(at: package))])
        let index = refreshed[0].root.index
        try check(index.root.scanStatus == .complete && refreshed[0].skippedCount == 0, "Recovered subtree left ancestor unavailable state behind")
        let app = try node("Fixture.app", in: index)
        try check(app.isPackage && app.scanStatus == .complete && refreshed[1].root.isPackage, "Package refresh lost package identity")
        try conserved(index, logical: 24, count: 2)
        try check(index.presentationStatistics(for: 0).contains { index.kind(at: $0.kindID).identifier == "com.apple.application-bundle" && $0.count == 1 }, "Collapsed package presentation lost its kind")
        try check(refreshed[1].typeStatistics.reduce(0) { $0 + $1.count } == 1, "Viewport package did not expose content statistics")

        let failed = DiskIndexBuilder(rootURL: fresh.rootURL)
        failed.append(parent: -1, name: "Fixture.app", isDirectory: true, kind: 0, isPackage: true, scanStatus: .cloudOnly)
        let unavailable = index.grafting(at: fresh.rootURL, replacement: failed.finish())
        let failedApp = try node("Fixture.app", in: unavailable)
        try check(failedApp.scanStatus == .cloudOnly && unavailable.root.scanStatus == .partial, "Fresh concrete unavailable reason did not propagate")
        try check(unavailable.presentationStatistics(for: 0).reduce(0) { $0 + $1.count } == 1, "Unavailable package fabricated a file")
    }

    private static func scannerAndDetails(root: URL) async throws {
        let manager = FileManager.default
        let left = root.appendingPathComponent("Left")
        let right = root.appendingPathComponent("Right")
        for directory in [left, right] { try manager.createDirectory(at: directory, withIntermediateDirectories: true) }
        for number in 0..<60 {
            try Data(repeating: 1, count: 10).write(to: left.appendingPathComponent("small-\(number).bin"))
        }
        let stable = right.appendingPathComponent("snapshot.bin")
        try Data(repeating: 2, count: 30).write(to: stable)
        let original = try await scan(ScanRequest(url: root))
        guard let group = original.root.index.find(url: left, aggregate: true), let drill = group.groupRequest else {
            throw Failure(description: "Refresh fixture did not create a real aggregate")
        }
        let detail = try await scan(drill)
        let selected = try node("small-0.bin", in: detail.root.index)
        let selectedView = result(detail.root.index, root: selected, selection: .smallFilesOnly)
        try manager.removeItem(at: selected.url)
        try Data(repeating: 3, count: 20).write(to: left.appendingPathComponent("small-1.bin"))
        try Data(repeating: 4, count: 40).write(to: left.appendingPathComponent("added.bin"))
        // Deliberately mutate an unselected sibling: its retained scan must remain snapshot-old.
        try Data(repeating: 5, count: 300).write(to: stable)
        let fresh = try await scan(ScanRequest(url: left))
        let refresh = IndexRefresh(url: left, replacement: fresh.root.index)
        let retained = [original, detail, selectedView]
        let requests = refresh.detailRequests(for: retained)
        try check(requests.count == 1 && requests[0].url.path == left.path && requests[0].fileSelection == .smallFilesOnly, "Detail rescans were not deduplicated and bounded to refresh scope: \(requests) for \(left.path)")
        var detailIndices: [URL: DiskIndex] = [:]
        for request in requests { detailIndices[request.url] = try await scan(request).root.index }
        let changed = IndexRefresh(url: left, replacement: fresh.root.index, detailReplacements: detailIndices).apply(to: retained)
        try conserved(changed[0].root.index, logical: 670, count: 61)
        try conserved(changed[1].root.index, logical: 640, count: 60)
        let oldSibling = try node("Right/snapshot.bin", in: changed[0].root.index)
        try check(oldSibling.logicalSize == 30, "Refresh traversed the untouched sibling")
        try check(changed[1].root.children.allSatisfy { !$0.isAggregate } && changed[1].request.fileSelection == .smallFilesOnly, "Detail refresh silently reintroduced aggregation")
        try check(changed[1].root.index === changed[2].root.index && changed[2].root.id == 0, "Removed selected detail descendant did not fall back within its rebuilt arena")
        try check(changed[1].root.index.find(url: selected.url) == nil, "Removed small-file detail name remained cached")
        let added = try node("added.bin", in: changed[1].root.index)
        try check(added.logicalSize == 40, "Added small-file detail was not refreshed")

        // Crossing back under the grouping threshold needs no name-bearing second scan.
        for number in 10..<60 { try manager.removeItem(at: left.appendingPathComponent("small-\(number).bin")) }
        let sparse = try await scan(ScanRequest(url: left))
        let sparseRefresh = IndexRefresh(url: left, replacement: sparse.root.index)
        try check(sparseRefresh.detailRequests(for: changed).isEmpty, "Ungrouped replacement unnecessarily requested another detail scan")
        let sparseResults = sparseRefresh.apply(to: changed)
        try conserved(sparseResults[1].root.index, logical: 140, count: 10)
        try check(sparseResults[1].request.fileSelection == .smallFilesOnly && sparseResults[1].root.children.allSatisfy { !$0.isAggregate }, "Ungrouped fresh names did not preserve detail mode")
    }

    private static func newlyLinkedOutsideFile(root: URL) async throws {
        let manager = FileManager.default
        for grouped in [false, true] {
            let directory = root.appendingPathComponent(grouped ? "Grouped" : "Individual")
            let inside = directory.appendingPathComponent("Inside")
            let outside = directory.appendingPathComponent("Outside")
            for folder in [inside, outside] {
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            let ordinary = outside.appendingPathComponent("formerly-ordinary.bin")
            try Data(repeating: 1, count: 8192).write(to: ordinary)
            if grouped {
                for number in 0..<60 {
                    try Data([2]).write(to: outside.appendingPathComponent("filler-\(number).bin"))
                }
            }
            let old = try await scan(ScanRequest(url: directory))
            try manager.linkItem(at: ordinary, to: inside.appendingPathComponent("new-alias.bin"))
            let fresh = try await scan(ScanRequest(url: inside))
            let refresh = IndexRefresh(url: inside, replacement: fresh.root.index)
            try check(refresh.requiresFullRescan(for: [old]), "New alias to an old ordinary or histogram member did not require an enclosing rescan")
            let whole = try await scan(ScanRequest(url: directory))
            let wholeRefresh = IndexRefresh(url: directory, replacement: whole.root.index)
            try check(!wholeRefresh.requiresFullRescan(for: [old]), "Whole-root replacement unnecessarily required another scan")
            let changed = wholeRefresh.apply(to: [old])[0]
            try conserved(changed.root.index, logical: grouped ? 8252 : 8192, count: grouped ? 62 : 2)
        }
    }

    private static func physicalPrivatePath() async throws {
        let manager = FileManager.default
        let physical = URL(fileURLWithPath: "/private/var/tmp", isDirectory: true)
            .appendingPathComponent("DiskInventoryX2-PhysicalRefresh-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: physical, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: physical) }
        for number in 0..<60 {
            try Data(repeating: 1, count: 10).write(to: physical.appendingPathComponent("small-\(number).bin"))
        }
        let ungrouped = physical.appendingPathComponent("Ungrouped", isDirectory: true)
        try manager.createDirectory(at: ungrouped, withIntermediateDirectories: false)
        try Data(repeating: 4, count: 7).write(to: ungrouped.appendingPathComponent("individual.bin"))
        let childDetail = try await scan(ScanRequest(url: ungrouped, fileSelection: .smallFilesOnly))
        let scanned = try await scan(ScanRequest(url: physical))
        guard let oldGroup = scanned.root.index.find(url: physical, aggregate: true),
              let oldRequest = oldGroup.groupRequest else {
            throw Failure(description: "Physical-path fixture did not create an aggregate")
        }
        let oldDetail = try await scan(oldRequest)

        // Construct only the physical branch; never enumerate the actual filesystem root.
        let filesystemRoot = URL(fileURLWithPath: "/", isDirectory: true)
        let builder = DiskIndexBuilder(rootURL: filesystemRoot)
        var directory = builder.append(parent: -1, name: "/", isDirectory: true)
        for component in physical.pathComponents.dropFirst() {
            directory = builder.append(parent: directory, name: component, isDirectory: true)
        }
        builder.append(
            parent: directory, name: "", logicalSize: 600, allocatedSize: oldGroup.allocatedSize,
            fileCount: 60, isDirectory: true, isAggregate: true,
            bins: [DiskIndex.Bin(logicalSize: 600, allocatedSize: oldGroup.allocatedSize, count: 60, kind: 0, sizeRange: DiskIndex.Bin.range(for: 10))]
        )
        let child = builder.append(parent: directory, name: "Ungrouped", isDirectory: true)
        builder.append(parent: child, name: "individual.bin", logicalSize: 7, allocatedSize: childDetail.root.allocatedSize, fileCount: 1, isDirectory: false)
        builder.append(parent: 0, name: "untouched.bin", logicalSize: 13, allocatedSize: 4096, fileCount: 1, isDirectory: false)
        let original = builder.finish()
        let lexical = URL(fileURLWithPath: physical.path + "/unused/../.", isDirectory: true)
        let plan = try await SelectionRefreshService().directory(for: lexical, scanRoot: filesystemRoot)
        try check(plan.path == physical.path, "Whole-root planner rewrote the real private/var branch to the var symlink")
        let before = original.find(url: lexical)
        try check(before?.id == directory, "Arena lookup did not prefer the actual lexical private/var branch")

        try manager.removeItem(at: physical.appendingPathComponent("small-0.bin"))
        try Data(repeating: 2, count: 20).write(to: physical.appendingPathComponent("small-1.bin"))
        try Data(repeating: 3, count: 40).write(to: physical.appendingPathComponent("added.bin"))
        let fresh = try await scan(ScanRequest(url: plan))
        let refresh = IndexRefresh(url: plan, replacement: fresh.root.index)
        let retained = [result(original), result(original, root: original.node(at: directory)), oldDetail, scanned, childDetail]
        try check(refresh.url.path == physical.path, "Refresh discarded the lexical graft target")
        try check(!refresh.requiresFullRescan(for: retained), "Alias spelling incorrectly required a full-root rescan")
        let detailRequests = refresh.detailRequests(for: retained)
        try check(detailRequests.count == 1, "Physical and canonical scopes did not overlap for retained detail")
        var details: [URL: DiskIndex] = [:]
        for request in detailRequests { details[request.url] = try await scan(request).root.index }
        let changed = IndexRefresh(url: plan, replacement: fresh.root.index, detailReplacements: details).apply(to: retained)
        try check(changed[0].root.url.path == "/" && changed[0].root.index === changed[1].root.index, "Physical graft replaced the whole-root arena or split its history")
        try conserved(changed[0].root.index, logical: 660, count: 62)
        try check(changed[1].root.url.path == physical.path && changed[1].root.logicalSize == 647, "Physical graft lost its stored path or retained stale bytes")
        let sibling = try node("untouched.bin", in: changed[0].root.index)
        try check(sibling.logicalSize == 13, "Physical graft changed unrelated snapshot metadata")
        let refreshedGroup = changed[0].root.index.find(url: physical, aggregate: true)
        try check(refreshedGroup?.logicalSize == 640, "Physical subtree histogram was not replaced")
        try conserved(changed[2].root.index, logical: 640, count: 60)
        try check(changed[2].request.fileSelection == .smallFilesOnly && changed[2].root.children.allSatisfy { !$0.isAggregate }, "Canonical detail scope did not remain an exact ungrouped view")
        try check(changed[2].root.index.find(url: physical.appendingPathComponent("small-0.bin")) == nil, "Physical-path detail retained a deleted member")
        try conserved(changed[3].root.index, logical: 647, count: 61)
        try check(changed[3].root.url.standardizedFileURL.path == scanned.root.url.standardizedFileURL.path, "Independent canonical directory scope lost its identity")
        guard let detailChild = changed[4].root.children.first,
              let physicalChild = changed[0].root.index.find(url: detailChild.url) else {
            throw Failure(description: "Canonical individual detail URL did not resolve to the real private branch")
        }
        try check(physicalChild.url.path == ungrouped.appendingPathComponent("individual.bin").path, "Reverse alias lookup invented a visible var branch")
        let deletion = IndexDeletion(
            url: detailChild.url, logicalSize: detailChild.logicalSize,
            allocatedSize: detailChild.allocatedSize, kindIdentifier: detailChild.kindIdentifier
        ).apply(to: changed)
        try conserved(deletion[0].root.index, logical: 653, count: 61)
        try check(deletion[4].root.fileCount == 0 && deletion[0].root.index.find(url: detailChild.url) == nil, "Canonical detail deletion did not reconcile the physical arena")
        guard let groupedChild = changed[2].root.index.find(url: physical.appendingPathComponent("added.bin")) else {
            throw Failure(description: "Fresh canonical detail lost its aggregate member")
        }
        let groupedDeletion = IndexDeletion(
            url: groupedChild.url, logicalSize: groupedChild.logicalSize,
            allocatedSize: groupedChild.allocatedSize, kindIdentifier: groupedChild.kindIdentifier
        ).apply(to: deletion)
        try conserved(groupedDeletion[0].root.index, logical: 613, count: 60)
        try conserved(groupedDeletion[2].root.index, logical: 600, count: 59)
    }

    private static func planning(root: URL) async throws {
        let manager = FileManager.default
        let folder = root.appendingPathComponent("Existing")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("file.bin")
        try Data([1]).write(to: file)
        let planner = SelectionRefreshService()
        let directoryPlan = try await planner.directory(for: folder, scanRoot: root)
        let filePlan = try await planner.directory(for: file, scanRoot: root)
        try check(directoryPlan.path == folder.path && filePlan.path == folder.path, "Refresh planner did not map directories and files correctly")
        let users = URL(fileURLWithPath: "/Users", isDirectory: true)
        let startupRoot = URL(fileURLWithPath: "/", isDirectory: true)
        if try ScanMountPolicy().statusForCandidate(at: users, scanRoot: startupRoot) == nil {
            let mergedPlan = try await planner.directory(for: users, scanRoot: startupRoot)
            try check(mergedPlan.path == users.path, "Refresh planner rejected a traversable startup firmlink path")
        }
        let removed = folder.appendingPathComponent("Removed/Descendant", isDirectory: true)
        let missingPlan = try await planner.directory(for: removed, scanRoot: root)
        try check(missingPlan.path == folder.path, "Missing descendant did not resolve to nearest existing parent")
        let before = try await scan(ScanRequest(url: root))
        let beforeFolder = try node("Existing", in: before.root.index)
        try manager.removeItem(at: folder)
        let missingParentPlan = try await planner.directory(for: file, scanRoot: root)
        try check(missingParentPlan.path == root.path, "Removed parent did not fall back to scan root")
        let fresh = try await scan(ScanRequest(url: missingParentPlan))
        let reconciled = IndexRefresh(url: missingParentPlan, replacement: fresh.root.index).apply(to: [before, result(before.root.index, root: beforeFolder)])
        try check(reconciled.allSatisfy { $0.root.id == 0 && $0.root.fileCount == 0 }, "Actual missing selected directory survived its parent rescan")
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-refresh")
        do {
            _ = try await planner.directory(for: outside, scanRoot: root)
            throw Failure(description: "Refresh planner escaped the scanned arena")
        } catch is Failure { throw Failure(description: "Refresh planner escaped the scanned arena") }
        catch { }
        let link = root.appendingPathComponent("Link")
        try manager.createSymbolicLink(at: link, withDestinationURL: root.deletingLastPathComponent())
        do {
            _ = try await planner.directory(for: link.appendingPathComponent("missing"), scanRoot: root)
            throw Failure(description: "Refresh planner followed a symlink ancestor")
        } catch is Failure { throw Failure(description: "Refresh planner followed a symlink ancestor") }
        catch { }
    }

    static func run(root: URL) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try subtreeAndHistory(root: root.appendingPathComponent("Arena"))
        try hardLinks(root: root.appendingPathComponent("Links"))
        try statusAndPackages(root: root.appendingPathComponent("Packages"))
        try await scannerAndDetails(root: root.appendingPathComponent("Scanner"))
        try await newlyLinkedOutsideFile(root: root.appendingPathComponent("NewLinks"))
        try await planning(root: root.appendingPathComponent("Planner"))
        try await physicalPrivatePath()
        print("PASS: subtree add/delete/resize; unchanged sibling snapshot; shared history and removed descendants; hardlink owner metadata/dedup/promotion; recovered and unavailable statuses; package kinds; aggregate/detail refresh and threshold change; bounded missing-target planning")
    }
}
