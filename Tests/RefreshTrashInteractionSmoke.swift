import AppKit

@MainActor
struct RefreshTrashInteractionSmoke {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(description: message) }
    }
    private static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { views($0) } }
    private static func task(_ name: String, in controller: InventoryWindowController) -> Task<Void, Never>? {
        Mirror(reflecting: controller).children.first { $0.label == name }?.value as? Task<Void, Never>
    }
    private static func row(_ url: URL, in outline: NSOutlineView) throws -> Int {
        guard let row = (0..<outline.numberOfRows).first(where: { (outline.item(atRow: $0) as? DiskNode)?.url.path == url.path }) else {
            throw Failure(description: "Missing interaction row: \(url.path)")
        }
        return row
    }
    private static func select(_ url: URL, in outline: NSOutlineView) throws {
        outline.selectRowIndexes(IndexSet(integer: try row(url, in: outline)), byExtendingSelection: false)
    }
    private static func expand(_ url: URL, in outline: NSOutlineView) throws {
        outline.expandItem(outline.item(atRow: try row(url, in: outline)))
    }
    private static func write(_ url: URL, count: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: count).write(to: url)
    }
    private static func scan(_ url: URL) async throws -> ScanResult {
        var result: ScanResult?
        for try await value in DiskScanner().scan(ScanRequest(url: url, sizeMode: .logical)) where value.isComplete { result = value }
        guard let result else { throw Failure(description: "No completed interaction scan") }
        return result
    }
    private static func refresh(_ controller: InventoryWindowController, outline: NSOutlineView) async throws {
        guard let menu = outline.menu, let item = menu.items.first(where: { $0.action == #selector(InventoryWindowController.refreshSelection) }) else {
            throw Failure(description: "Tree context menu has no Refresh Selection")
        }
        try check(controller.validateMenuItem(item), "Refresh Selection is unavailable for the selected directory")
        menu.performActionForItem(at: menu.index(of: item))
        guard let planning = task("refreshTask", in: controller) else { throw Failure(description: "Context refresh did not start") }
        await planning.value
        while let scanning = task("scanTask", in: controller) { await scanning.value }
    }

    static func run(root: URL) async throws {
        let a = root.appendingPathComponent("A")
        let deep = a.appendingPathComponent("Deep")
        let b = root.appendingPathComponent("B")
        let old = deep.appendingPathComponent("old.bin")
        let outside = b.appendingPathComponent("outside.bin")
        let created = deep.appendingPathComponent("new.bin")
        try write(old, count: 21)
        try write(outside, count: 31)
        let controller = InventoryWindowController(permissions: ScanPermissionService())
        controller.showWindow(nil)
        defer { controller.window?.close() }
        controller.present(try await scan(root))
        guard let content = controller.window?.contentView,
              let outline = views(content).compactMap({ $0 as? NSOutlineView }).first,
              let map = views(content).compactMap({ $0 as? TreemapView }).first else { throw Failure(description: "Missing real document interaction views") }
        try expand(a, in: outline)
        try expand(deep, in: outline)
        try expand(b, in: outline)
        try select(a, in: outline)
        try FileManager.default.removeItem(at: old)
        try write(created, count: 71)
        try write(outside, count: 931)
        try await refresh(controller, outline: outline)
        try check(map.root?.url.path == root.path && map.root?.logicalSize == 102, "Scoped refresh replaced the document root or rescanned the unrelated sibling")
        try check(map.root?.index.find(url: old) == nil && map.root?.index.find(url: created)?.logicalSize == 71, "Scoped refresh kept removed content or omitted new content")
        try check(outline.isItemExpanded(outline.item(atRow: try row(deep, in: outline))) && outline.isItemExpanded(outline.item(atRow: try row(b, in: outline))), "Scoped refresh discarded unrelated or surviving expansion state")
        try check((outline.item(atRow: outline.selectedRow) as? DiskNode)?.url.path == a.path, "Scoped refresh changed surviving selection")

        // A refresh while zoomed must also update the cached parent before Zoom Out.
        controller.zoomSelection()
        try select(deep, in: outline)
        try write(created, count: 111)
        try await refresh(controller, outline: outline)
        try check(map.root?.url.path == a.path && map.root?.logicalSize == 111, "Refresh lost the zoomed view")
        controller.zoomOut()
        try check(map.root?.url.path == root.path && map.root?.logicalSize == 142, "Zoom Out restored stale pre-refresh parent totals")
        try expand(a, in: outline)
        try expand(deep, in: outline)
        try expand(b, in: outline)

        let trashName = "dix-ui-trash-\(UUID().uuidString).bin"
        let trashSource = a.appendingPathComponent(trashName)
        let payload = Data("owned trash fixture \(trashName)".utf8)
        try payload.write(to: trashSource)
        try select(a, in: outline)
        try await refresh(controller, outline: outline)
        try select(trashSource, in: outline)
        guard let trashItem = outline.menu?.items.first(where: { $0.action == #selector(InventoryWindowController.moveToTrash) }) else {
            throw Failure(description: "Tree context menu has no Move to Trash")
        }
        try check(controller.validateMenuItem(trashItem), "Move to Trash is disabled for an ordinary fixture file")
        // Resolve only this fixture's known Trash basename; never enumerate or empty Trash.
        let trashDirectory = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: trashSource, create: true)
        let destination = trashDirectory.appendingPathComponent(trashName)
        defer {
            if (try? Data(contentsOf: destination)) == payload { try? FileManager.default.removeItem(at: destination) }
        }
        let window = controller.window!
        window.makeFirstResponder(outline)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{8}", charactersIgnoringModifiers: "\u{8}", isARepeat: false, keyCode: 51)!
        window.sendEvent(event)
        guard let removing = task("deletionTask", in: controller) else { throw Failure(description: "Command–Delete did not start Trash") }
        await removing.value
        try check(!FileManager.default.fileExists(atPath: trashSource.path) && (try Data(contentsOf: destination)) == payload, "Command–Delete did not preserve bytes in actual Trash")
        try check(map.root?.index.find(url: trashSource) == nil && map.root?.logicalSize == 142, "Trash did not reconcile the map and ancestor totals")
        try check(outline.isItemExpanded(outline.item(atRow: try row(deep, in: outline))) && outline.isItemExpanded(outline.item(atRow: try row(b, in: outline))), "Trash collapsed surviving branches")
        try check((outline.item(atRow: outline.selectedRow) as? DiskNode)?.url.path == a.path, "Trash did not select the surviving parent")

        // Externally removed directories disappear on refresh, rather than becoming empty lies.
        try select(deep, in: outline)
        try FileManager.default.removeItem(at: deep)
        try await refresh(controller, outline: outline)
        try check(map.root?.index.find(url: deep) == nil && map.root?.logicalSize == 31, "Refresh of a disappeared directory did not reconcile its parent")
        // A formerly ordinary outside file has no cached inode identity. New cross-scope
        // links require a full refresh rather than counting the old file and new alias twice.
        let alias = a.appendingPathComponent("new-hardlink.bin")
        try FileManager.default.linkItem(at: outside, to: alias)
        try select(a, in: outline)
        try await refresh(controller, outline: outline)
        try check(map.root?.logicalSize == 931 && map.root?.fileCount == 2, "New cross-boundary hardlink did not trigger exact full-scan reconciliation")
        try check(map.root?.index.find(url: alias) != nil && map.root?.index.find(url: outside) != nil, "Hardlink fallback lost either name")
        print("PASS: real tree context refresh adds/removes/resizes only the scoped branch; zoom history and expansion/selection survive; actual Command–Delete moves bytes to Trash and updates map; disappeared directory refresh reconciles its parent")
    }
}
