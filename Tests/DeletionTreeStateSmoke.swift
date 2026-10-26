import AppKit

/// Runs the real AppKit deletion flow against an isolated temporary filesystem.
@main
struct DeletionTreeStateSmoke {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    @MainActor private final class Confirmation {
        var shown = false
        var error: Error?
    }

    @MainActor private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    @MainActor private static func views(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { views($0) }
    }

    private static func file(_ url: URL, size: UInt64) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard manager.createFile(atPath: url.path, contents: nil) else { throw Failure(description: "Cannot create fixture file") }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: size)
    }

    private static func scan(_ url: URL) async throws -> ScanResult {
        var result: ScanResult?
        for try await value in DiskScanner().scan(ScanRequest(url: url, sizeMode: .logical)) where value.isComplete { result = value }
        guard let result else { throw Failure(description: "No completed fixture scan") }
        return result
    }

    @MainActor private static func value<T>(_ name: String, from controller: InventoryWindowController, as type: T.Type) -> T? {
        Mirror(reflecting: controller).children.first { $0.label == name }?.value as? T
    }

    @MainActor private static func row(_ url: URL, in outline: NSOutlineView) throws -> Int {
        guard let row = (0..<outline.numberOfRows).first(where: {
            (outline.item(atRow: $0) as? DiskNode)?.url.path == url.path
        }) else { throw Failure(description: "Missing visible row: \(url.path)") }
        return row
    }

    @MainActor private static func select(_ url: URL, in outline: NSOutlineView) throws {
        outline.selectRowIndexes(IndexSet(integer: try row(url, in: outline)), byExtendingSelection: false)
    }

    @MainActor private static func expand(_ urls: [URL], in outline: NSOutlineView) throws {
        for url in urls { outline.expandItem(outline.item(atRow: try row(url, in: outline))) }
    }

    @MainActor private static func expanded(in outline: NSOutlineView) -> Set<String> {
        Set((0..<outline.numberOfRows).compactMap { row in
            guard let node = outline.item(atRow: row) as? DiskNode, outline.isItemExpanded(node) else { return nil }
            return node.url.path
        })
    }

    @MainActor private static func selected(in outline: NSOutlineView) -> URL? {
        (outline.item(atRow: outline.selectedRow) as? DiskNode)?.url
    }

    @MainActor private static func remove(
        _ url: URL, controller: InventoryWindowController, outline: NSOutlineView,
        confirm: Bool = true, keyCode: UInt16? = 51, selectAfterConfirmation: URL? = nil
    ) async throws {
        let window = controller.window!
        try select(url, in: outline)
        window.makeFirstResponder(outline)
        let confirmation = Confirmation()
        // The sheet notification precedes attachment; an actor turn waits for beginSheet to return.
        let token = NotificationCenter.default.addObserver(forName: NSWindow.willBeginSheetNotification, object: window, queue: .main) { _ in
            Task { @MainActor in
                do {
                    guard let sheet = window.attachedSheet, let content = sheet.contentView else { throw Failure(description: "Missing deletion confirmation sheet") }
                    let fields = views(content).compactMap { $0 as? NSTextField }
                    try check(fields.contains { $0.stringValue.contains(url.path) }, "Confirmation must show the selected real path")
                    let title = confirm
                        ? String(localized: "delete.confirm", defaultValue: "Delete Permanently")
                        : String(localized: "delete.cancel", defaultValue: "Cancel")
                    guard let button = views(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else { throw Failure(description: "Missing confirmation button") }
                    confirmation.shown = true
                    button.performClick(nil)
                    if let selectAfterConfirmation { try select(selectAfterConfirmation, in: outline) }
                } catch {
                    confirmation.error = error
                    window.endSheet(window.attachedSheet!, returnCode: .abort)
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        if let keyCode {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
                windowNumber: window.windowNumber, context: nil,
                characters: keyCode == 51 ? "\u{8}" : "\u{7f}", charactersIgnoringModifiers: "\u{8}",
                isARepeat: false, keyCode: keyCode
            )!
            window.sendEvent(event)
        } else {
            let item = NSMenuItem(title: "", action: #selector(InventoryWindowController.deletePermanently), keyEquivalent: "")
            try check(NSApplication.shared.sendAction(item.action!, to: controller, from: item), "Delete menu action not handled")
        }
        guard let task = value("deletionTask", from: controller, as: Task<Void, Never>.self) else { throw Failure(description: "Deletion action did not start") }
        await task.value
        if let error = confirmation.error { throw error }
        try check(confirmation.shown, "Deletion bypassed confirmation")
        controller.window?.contentView?.layoutSubtreeIfNeeded()
    }

    @MainActor private static func scenario(root fixture: URL) async throws {
        let main = fixture.appendingPathComponent("Main")
        let active = main.appendingPathComponent("Active")
        let removeDirectory = active.appendingPathComponent("DeleteMe")
        let keepA = active.appendingPathComponent("KeepA")
        let keepB = active.appendingPathComponent("KeepB")
        let other = main.appendingPathComponent("Other")
        let closed = main.appendingPathComponent("Closed")
        try file(removeDirectory.appendingPathComponent("Sub/payload.bin"), size: 8_000_000)
        try file(keepA.appendingPathComponent("Deep/a.bin"), size: 2_000_000)
        try file(keepB.appendingPathComponent("Deep/b.bin"), size: 3_000_000)
        try file(other.appendingPathComponent("Nested/payload.bin"), size: 9_000_000)
        try file(closed.appendingPathComponent("Nested/payload.bin"), size: 300_000)
        for i in 0..<45 {
            try file(main.appendingPathComponent(String(format: "Tail-%02d/payload.bin", i)), size: 10_000)
        }
        let controller = InventoryWindowController(permissions: ScanPermissionService())
        controller.showWindow(nil)
        let window = controller.window!
        window.setContentSize(NSSize(width: 1150, height: 480))
        controller.present(try await scan(main))
        let outline = views(window.contentView!).compactMap { $0 as? NSOutlineView }.first!
        let map = views(window.contentView!).compactMap { $0 as? TreemapView }.first!
        let branches = [active, removeDirectory, removeDirectory.appendingPathComponent("Sub"), keepA, keepA.appendingPathComponent("Deep"), keepB, keepB.appendingPathComponent("Deep"), other, other.appendingPathComponent("Nested")]
        try expand(branches, in: outline)
        let beforeExpanded = expanded(in: outline)
        let beforeSize = map.root!.size
        let beforeCount = map.root!.fileCount
        let beforeIndex = map.root!.index
        try await remove(removeDirectory, controller: controller, outline: outline, confirm: false)
        try check(expanded(in: outline) == beforeExpanded && map.root!.index === beforeIndex, "Cancel changed expansion or the completed index")
        try check(selected(in: outline)?.path == removeDirectory.path && FileManager.default.fileExists(atPath: removeDirectory.path), "Cancel changed selection or deleted files")

        // Anchor an unrelated row below the removed subtree, with a partially scrolled row.
        let anchor = keepB
        let clip = outline.enclosingScrollView!.contentView
        clip.scroll(to: NSPoint(x: 0, y: outline.rect(ofRow: try row(anchor, in: outline)).minY + 4))
        outline.enclosingScrollView!.reflectScrolledClipView(clip)
        let oldOffset = outline.rect(ofRow: try row(anchor, in: outline)).minY - outline.visibleRect.minY
        try await remove(removeDirectory, controller: controller, outline: outline)
        let expected = beforeExpanded.filter { !$0.hasPrefix(removeDirectory.path) }
        try check(expanded(in: outline) == expected, "Deleting an expanded directory collapsed surviving branches")
        try check(!FileManager.default.fileExists(atPath: removeDirectory.path), "Confirmed directory still exists")
        try check(map.root!.size == beforeSize - 8_000_000 && map.root!.fileCount == beforeCount - 1, "Deletion did not reconcile sizes/counts")
        try check(selected(in: outline)?.path == active.path, "Deleted selection did not fall back to its surviving parent")
        let newOffset = outline.rect(ofRow: try row(anchor, in: outline)).minY - outline.visibleRect.minY
        try check(abs(newOffset - oldOffset) < 0.5, "Viewport jumped after deletion and size-based sibling reordering")
        let closedItem = outline.item(atRow: try row(closed, in: outline))
        try check(!outline.isItemExpanded(closedItem), "A deliberately collapsed branch was expanded")
        if let path = CommandLine.arguments.dropFirst().first {
            let content = window.contentView!
            window.displayIfNeeded()
            let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        }

        // Keep a different surviving selection made after the confirmation closes.
        let keepAFile = keepA.appendingPathComponent("Deep/a.bin")
        let otherFile = other.appendingPathComponent("Nested/payload.bin")
        let expandedBeforeFile = expanded(in: outline)
        try await remove(keepAFile, controller: controller, outline: outline, keyCode: 117, selectAfterConfirmation: otherFile)
        try check(selected(in: outline)?.path == otherFile.path, "A surviving selection made during deletion was lost")
        let survivingExpected = expandedBeforeFile.subtracting([keepA.appendingPathComponent("Deep").path])
        try check(expanded(in: outline) == survivingExpected, "Forward Shift-Delete changed unrelated expansion state")

        // The same restoration path applies to deletion from a zoomed view and the menu.
        try select(active, in: outline)
        controller.zoomSelection()
        try expand([keepB, keepB.appendingPathComponent("Deep")], in: outline)
        let zoomedExpanded = expanded(in: outline)
        try await remove(keepB.appendingPathComponent("Deep/b.bin"), controller: controller, outline: outline, keyCode: nil)
        try check(map.root!.url.path == active.path, "Deletion changed the zoom scope")
        try check(expanded(in: outline) == zoomedExpanded.subtracting([keepB.appendingPathComponent("Deep").path]), "Menu deletion lost zoomed expansion state")
        try check(selected(in: outline)?.path == keepB.appendingPathComponent("Deep").path, "Last child deletion did not retain the now-empty parent selection")
        controller.zoomOut()
        try check(map.root!.url.path == main.path && map.root!.size == beforeSize - 13_000_000, "Zoom Out restored stale deletion totals")

        // Removing a direct child has no visible parent row; use the next surviving row.
        let single = fixture.appendingPathComponent("Single")
        let first = single.appendingPathComponent("First")
        let last = single.appendingPathComponent("Last")
        try file(first.appendingPathComponent("payload.bin"), size: 2000)
        try file(last.appendingPathComponent("payload.bin"), size: 1000)
        controller.present(try await scan(single))
        try await remove(first, controller: controller, outline: outline)
        try check(selected(in: outline)?.path == last.path && outline.numberOfRows == 1, "Direct child deletion did not select the next surviving row")
        try await remove(last, controller: controller, outline: outline)
        try check(outline.numberOfRows == 0 && outline.selectedRow == -1 && map.root!.size == 0, "Last root child deletion did not produce an empty tree")
        window.close()
        print("PASS: real Shift-Delete directory/file and menu deletion; surviving expanded branches and collapsed branches; viewport anchor after size reordering; parent/next-row selection; selection changed during deletion; Cancel; zoomed scope/history; empty tree")
    }

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("dix-tree-state-\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
                try await SystemPathPolicySmoke.run(root: fixture.appendingPathComponent("SystemPaths"))
                try await HardLinkAccountingSmoke.run(root: fixture.appendingPathComponent("HardLinks"))
                try await ScanSafetySmoke.run(root: fixture.appendingPathComponent("Safety"))
                try await ScanPresentationSmoke.run(root: fixture.appendingPathComponent("Presentation"))
                try await ScanPermissionScopeSmoke.run(root: fixture.appendingPathComponent("PermissionScope"))
                try await ScanPermissionPromptSmoke.run(root: fixture.appendingPathComponent("PermissionPrompt"))
                try await ScanPermissionIntegrationSmoke.run(root: fixture.appendingPathComponent("PermissionIntegration"))
                try await SelectionInteractionSmoke.run(root: fixture.appendingPathComponent("SelectionInteraction"))
                try await TrashServiceSmoke.run(root: fixture.appendingPathComponent("TrashService"))
                try await IndexRefreshSmoke.run(root: fixture.appendingPathComponent("IndexRefresh"))
                try await RefreshTrashInteractionSmoke.run(root: fixture.appendingPathComponent("RefreshTrashUI"))
                try await scenario(root: fixture)
                try FileManager.default.removeItem(at: fixture)
                exit(0)
            } catch {
                print("FAIL: \(error)")
                try? FileManager.default.removeItem(at: fixture)
                exit(1)
            }
        }
        app.run()
    }
}
