import AppKit

@MainActor
struct SelectionInteractionSmoke {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(description: message) }
    }

    private static func views(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { views($0) }
    }

    private static func file(_ url: URL, size: UInt64) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw Failure(description: "Cannot create selection fixture") }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: size)
    }

    private static func event(_ type: NSEvent.EventType, at point: NSPoint, in view: NSView) throws -> NSEvent {
        guard let window = view.window, let event = NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ) else { throw Failure(description: "Cannot create native pointer event") }
        return event
    }

    private static func click(_ view: NSView) throws {
        view.mouseDown(with: try event(.leftMouseDown, at: NSPoint(x: view.bounds.midX, y: view.bounds.midY), in: view))
    }

    private static func clickMap(_ url: URL, map: TreemapView) throws {
        // Find a real rendered tile through hover, without changing tree selection first.
        for y in 0..<32 {
            for x in 0..<32 {
                let point = NSPoint(x: map.bounds.width * (CGFloat(x) + 0.5) / 32, y: map.bounds.height * (CGFloat(y) + 0.5) / 32)
                map.mouseMoved(with: try event(.mouseMoved, at: point, in: map))
                if map.toolTip?.components(separatedBy: "\n").first == url.path {
                    map.mouseDown(with: try event(.leftMouseDown, at: point, in: map))
                    return
                }
            }
        }
        throw Failure(description: "No visible fixture tile for \(url.path)")
    }

    private static func row(_ url: URL, in outline: NSOutlineView) throws -> Int {
        guard let row = (0..<outline.numberOfRows).first(where: { (outline.item(atRow: $0) as? DiskNode)?.url.path == url.path }) else {
            throw Failure(description: "Missing visible fixture row: \(url.path)")
        }
        return row
    }

    private static func expand(_ urls: [URL], in outline: NSOutlineView) throws {
        for url in urls { outline.expandItem(outline.item(atRow: try row(url, in: outline))) }
    }

    private static func expanded(_ outline: NSOutlineView) -> Set<String> {
        Set((0..<outline.numberOfRows).compactMap {
            guard let node = outline.item(atRow: $0) as? DiskNode, outline.isItemExpanded(node) else { return nil }
            return node.url.path
        })
    }

    private static func selected(_ outline: NSOutlineView) -> DiskNode? {
        outline.item(atRow: outline.selectedRow) as? DiskNode
    }

    private static func capture(_ view: NSView) throws {
        guard let argument = CommandLine.arguments.dropFirst().first else { return }
        let url = URL(fileURLWithPath: argument).deletingLastPathComponent().appendingPathComponent("selection-interactions.png")
        view.wantsLayer = true
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure(description: "Cannot capture interaction surface") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure(description: "Cannot encode interaction surface") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
        print("Selection/copy screenshot: \(url.path)")
    }

    static func run(root: URL) async throws {
        let fixture = root.appendingPathComponent("Paths with пробелы # %", isDirectory: true)
        let a = fixture.appendingPathComponent("A")
        let aDeep = a.appendingPathComponent("Deep")
        let aExtra = a.appendingPathComponent("Extra")
        let firstFile = aDeep.appendingPathComponent("first café # %.bin")
        let b = fixture.appendingPathComponent("B")
        let bDeep = b.appendingPathComponent("Deep")
        let bHidden = bDeep.appendingPathComponent("Hidden")
        let secondFile = bDeep.appendingPathComponent("second.bin")
        let package = fixture.appendingPathComponent("Sample.app")
        let group = fixture.appendingPathComponent("Grouped")
        try file(firstFile, size: 24_000_000)
        try file(aExtra.appendingPathComponent("extra.bin"), size: 12_000_000)
        try file(secondFile, size: 24_000_000)
        try file(bHidden.appendingPathComponent("hidden.bin"), size: 12_000_000)
        try file(package.appendingPathComponent("Contents/payload.bin"), size: 24_000_000)
        for index in 0..<51 { try file(group.appendingPathComponent("small-\(index).bin"), size: 900_000) }
        var result: ScanResult?
        for try await value in DiskScanner().scan(ScanRequest(url: fixture, sizeMode: .logical)) where value.isComplete { result = value }
        guard let result else { throw Failure(description: "No completed selection fixture scan") }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let controller = InventoryWindowController(permissions: ScanPermissionService(), pasteboard: pasteboard)
        controller.showWindow(nil)
        defer { controller.window?.close() }
        controller.present(result)
        guard let content = controller.window?.contentView,
              let outline = views(content).compactMap({ $0 as? NSOutlineView }).first,
              let map = views(content).compactMap({ $0 as? TreemapView }).first,
              let status = views(content).compactMap({ $0 as? CopyablePathField }).first(where: { $0.accessibilityIdentifier() == "selectionStatus" }),
              let information = views(content).compactMap({ $0 as? CopyablePathField }).first(where: { $0.accessibilityIdentifier() == "itemInformation" }) else {
            throw Failure(description: "Missing actual document interaction views")
        }
        content.layoutSubtreeIfNeeded()
        pasteboard.setString("untouched", forType: .string)
        try click(status)
        try check(pasteboard.string(forType: .string) == "untouched", "Overview statistics acted like a path")
        try click(information)
        try check(pasteboard.string(forType: .string) == fixture.path, "Overview path did not copy its exact decoded filesystem path")
        try check(information.stringValue != fixture.path && information.stringValue.contains(fixture.path), "Successful copy left no inline confirmation or removed the displayed path")
        try click(information)
        try check(pasteboard.string(forType: .string) == fixture.path, "Repeated click copied the confirmation instead of the path")

        try expand([a, aDeep, aExtra, b, bDeep, bHidden], in: outline)
        outline.collapseItem(outline.item(atRow: try row(b, in: outline)))
        try clickMap(firstFile, map: map)
        try check(expanded(outline) == Set([a.path, aDeep.path]), "Map click retained unrelated expanded branches")
        try check(selected(outline)?.url.path == firstFile.path && outline.visibleRect.intersects(outline.rect(ofRow: outline.selectedRow)), "Map click did not select and reveal the real file row")
        try click(information)
        try check(pasteboard.string(forType: .string) == fixture.path && !information.accessibilityPerformPress(), "File details retained a stale overview-path copy action")
        try click(status)
        try check(pasteboard.string(forType: .string) == firstFile.path && status.stringValue != firstFile.path, "Selected path did not copy its full text with visible feedback")
        try check(status.accessibilityPerformPress() && pasteboard.string(forType: .string) == firstFile.path, "Accessible press copied stale text or feedback")

        try expand([b, bDeep], in: outline)
        try check(!outline.isItemExpanded(outline.item(atRow: try row(bHidden, in: outline))), "A previously hidden expansion survived the map reset")
        outline.selectRowIndexes(IndexSet(integer: try row(secondFile, in: outline)), byExtendingSelection: false)
        try check(expanded(outline).contains(aDeep.path), "Manual tree selection unexpectedly collapsed other branches")
        try clickMap(secondFile, map: map)
        try check(expanded(outline) == Set([b.path, bDeep.path]) && selected(outline)?.url.path == secondFile.path, "Second map selection did not focus its own ancestry")
        try check(status.stringValue == secondFile.path, "New path retained old copy confirmation")
        try expand([a, aDeep, aExtra], in: outline)
        try clickMap(secondFile, map: map)
        try check(expanded(outline) == Set([b.path, bDeep.path]), "Clicking the same map tile did not remove manually opened unrelated branches")
        try clickMap(package, map: map)
        try check(expanded(outline).isEmpty && selected(outline)?.isPackage == true, "Map package selection exposed its contents or retained unrelated branches")
        try clickMap(group, map: map)
        try check(expanded(outline) == Set([group.path]) && selected(outline)?.isAggregate == true, "Map aggregate selection did not reveal only its containing directory and group row")
        try click(status)
        try check(pasteboard.string(forType: .string) == group.path, "Synthetic group copied a nonexistent member path")

        try clickMap(firstFile, map: map)
        try click(status)
        try capture(content)
        print("PASS: actual path clicks and accessible press copy exact Unicode/space/percent paths with inline feedback; repeat/new-path/nonpath transitions; real map clicks focus only ancestry, clear hidden expansions, reveal selection, preserve manual tree behavior, and handle packages/aggregates")
    }
}
