import AppKit

@MainActor
struct SystemPathPolicySmoke {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    static func run(root: URL) async throws {
        let manager = FileManager.default
        let policy = SystemPathPolicy()
        let names = [".nofollow", ".resolve", ".vol", ".file"]
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        for name in names {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 17).write(to: directory.appendingPathComponent("payload.bin"))
        }
        try Data(repeating: 2, count: 23).write(to: root.appendingPathComponent(".ordinary"))

        // Inspect only immediate root entries; never recursively scan a system namespace.
        let systemRoot = URL(fileURLWithPath: "/", isDirectory: true)
        let entries = try manager.contentsOfDirectory(at: systemRoot, includingPropertiesForKeys: nil)
        let excluded = Set(entries.filter { policy.excludes($0) }.map { $0.lastPathComponent })
        let expected = Set(entries.map { $0.lastPathComponent }).intersection(names)
        try check(excluded == expected, "Root policy excluded unrelated entries")
        for path in ["/.nofollow-backup", "/.resolve.txt", "/Volumes/Disk/.vol", "/Users/Shared/.file", "/Users/Shared/.nofollow/child"] {
            try check(!policy.excludes(URL(fileURLWithPath: path)), "Overbroad system path exclusion: \(path)")
        }
        let blockedPaths = names.map { "/" + $0 } + [
            "/.nofollow" + root.path,
            "/.resolve/1" + root.path,
            "/.vol/123/456", "/.file/namespace-entry",
            "/.nofollow/../Users", "/.resolve/1/../Users"
        ]
        let service = PermanentDeletionService()
        for path in blockedPaths {
            let url = URL(fileURLWithPath: path)
            try check(policy.excludes(url), "System namespace alias was not excluded: \(path)")
            try await rejectScan(url)
            do {
                _ = try await service.prepare(url: url, scanRoot: systemRoot)
                throw Failure(description: "Deletion preparation allowed a system namespace: \(path)")
            } catch PermanentDeletionError.protectedLocation {
                // This must be rejected by application policy, not SIP or access failures.
            }
            let target = PermanentDeletionTarget(url: url, device: 0, inode: 0, isDirectory: true)
            do {
                // Zero identity also prevents filesystem removal if the policy regresses.
                try await service.remove(target)
                throw Failure(description: "Deletion accepted a system namespace target: \(path)")
            } catch PermanentDeletionError.protectedLocation {
            }
        }
        let escaped = URL(string: "file:///%2Enofollow/Users")!
        try await rejectScan(escaped)
        do {
            _ = try await service.prepare(url: root.appendingPathComponent(".ordinary"), scanRoot: URL(fileURLWithPath: "/.nofollow" + root.path))
            throw Failure(description: "Deletion allowed a reserved scan-root alias")
        } catch PermanentDeletionError.protectedLocation {
        }

        // Ordinary hidden names retain their real bytes/counts and are still deletable.
        var completed: ScanResult?
        for try await result in DiskScanner().scan(ScanRequest(url: root, sizeMode: .logical)) where result.isComplete { completed = result }
        guard let result = completed else { throw Failure(description: "No ordinary-folder scan result") }
        try check(result.root.size == 91 && result.root.fileCount == 5 && result.skippedCount == 0, "Ordinary hidden files lost bytes/counts")
        for name in names {
            let directory = root.appendingPathComponent(name)
            let node = result.root.index.find(url: directory)
            try check(node?.isDirectory == true && node?.size == 17 && node?.fileCount == 1, "Nested \(name) was hidden from the real scan")
            var direct: ScanResult?
            for try await value in DiskScanner().scan(ScanRequest(url: directory, sizeMode: .logical)) where value.isComplete { direct = value }
            try check(direct?.root.size == 17 && direct?.root.fileCount == 1, "Direct scan incorrectly rejected nested \(name)")
        }
        let ordinaryNamedDirectory = root.appendingPathComponent(".nofollow")
        let target = try await service.prepare(url: ordinaryNamedDirectory, scanRoot: root)
        try await service.remove(target)
        try check(!manager.fileExists(atPath: ordinaryNamedDirectory.path), "Ordinary nested .nofollow could not be removed")
        try check(manager.fileExists(atPath: root.appendingPathComponent(".resolve/payload.bin").path), "Deletion affected an unrelated hidden folder")
        try verifyOldIndexDeletionMenus()
        print("PASS: system root entries/aliases rejected before scan or deletion; unrelated hidden names and nested .nofollow/.resolve/.vol/.file retain bytes and remain usable; stale-index delete menus disabled")
    }

    private static func rejectScan(_ url: URL) async throws {
        var published = 0
        do {
            for try await _ in DiskScanner().scan(ScanRequest(url: url)) { published += 1 }
            throw Failure(description: "Scanner accepted a system namespace: \(url.absoluteString)")
        } catch let error as CocoaError {
            try check(error.code == .fileReadNoPermission && published == 0, "Blocked root was accessed or published as a usable scan: \(url.absoluteString)")
        }
    }

    private static func views(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { views($0) }
    }

    private static func verifyOldIndexDeletionMenus() throws {
        // Represents an already scanned tree from before this exclusion was introduced.
        let rootURL = URL(fileURLWithPath: "/", isDirectory: true)
        let builder = DiskIndexBuilder(rootURL: rootURL)
        builder.append(parent: -1, name: "/", isDirectory: true)
        for name in [".nofollow", ".resolve", ".vol", ".file"] {
            builder.append(parent: 0, name: name, isDirectory: name != ".file")
        }
        let parent = builder.append(parent: 0, name: "Users", isDirectory: true)
        builder.append(parent: parent, name: ".nofollow", isDirectory: true)
        let index = builder.finish()
        let controller = InventoryWindowController(permissions: ScanPermissionService())
        controller.showWindow(nil)
        defer { controller.window?.close() }
        controller.present(ScanResult(root: index.root, skippedCount: 0, request: ScanRequest(url: rootURL), isComplete: true, currentPath: nil, typeStatistics: index.presentationStatistics(for: 0)))
        let outline = views(controller.window!.contentView!).compactMap { $0 as? NSOutlineView }.first!
        let menu = NSMenuItem(title: "", action: #selector(InventoryWindowController.deletePermanently), keyEquivalent: "")
        for row in 0..<outline.numberOfRows {
            guard let node = outline.item(atRow: row) as? DiskNode else { continue }
            if ["/.nofollow", "/.resolve", "/.vol", "/.file"].contains(node.url.path) {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                try check(!controller.validateMenuItem(menu), "A system root entry remained deletable in an old index")
            }
        }
        let parentRow = (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? DiskNode)?.name == "Users" }!
        outline.expandItem(outline.item(atRow: parentRow))
        let childRow = (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? DiskNode)?.url.path == "/Users/.nofollow" }!
        outline.selectRowIndexes(IndexSet(integer: childRow), byExtendingSelection: false)
        try check(controller.validateMenuItem(menu), "An ordinary nested name was disabled in the UI")
    }
}
