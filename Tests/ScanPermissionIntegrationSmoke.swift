import AppKit
import Darwin

@MainActor
struct ScanPermissionIntegrationSmoke {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }
    @MainActor private final class Decision {
        var shown = false
        var error: Error?
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(description: message) }
    }

    private static func views(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { views($0) }
    }

    private static func scan(_ url: URL) async throws -> ScanResult {
        var completed: ScanResult?
        for try await result in DiskScanner().scan(ScanRequest(url: url, sizeMode: .logical)) where result.isComplete { completed = result }
        guard let completed else { throw Failure(description: "No completed baseline scan") }
        return completed
    }

    private static func row(_ url: URL, in outline: NSOutlineView) throws -> Int {
        guard let row = (0..<outline.numberOfRows).first(where: { (outline.item(atRow: $0) as? DiskNode)?.url == url }) else {
            throw Failure(description: "Missing baseline row: \(url.path)")
        }
        return row
    }

    private static func beginScan(
        _ url: URL, continueScan: Bool, deniedPath: URL,
        controller: InventoryWindowController, map: TreemapView, baseline: DiskIndex
    ) async throws {
        let decision = Decision()
        let window = controller.window!
        let token = NotificationCenter.default.addObserver(forName: NSWindow.willBeginSheetNotification, object: window, queue: .main) { _ in
            Task { @MainActor in
                guard !decision.shown, let sheet = window.attachedSheet, let content = sheet.contentView else { return }
                let buttons = views(content).compactMap { $0 as? NSButton }
                guard buttons.contains(where: { $0.accessibilityIdentifier() == "permission.continue" }) else { return }
                do {
                    decision.shown = true
                    try check(map.root?.index === baseline, "Inventory traversal replaced the completed document before permission choice")
                    let text = views(content).compactMap { view -> String? in
                        if let field = view as? NSTextField { return field.stringValue }
                        return (view as? NSTextView)?.string
                    }.joined(separator: "\n")
                    try check(text.contains(deniedPath.path), "Permission summary omitted the actual in-scope denied path")
                    let identifier = continueScan ? "permission.continue" : "permission.cancel"
                    guard let button = buttons.first(where: { $0.accessibilityIdentifier() == identifier }) else {
                        throw Failure(description: "Missing permission decision button: \(identifier)")
                    }
                    button.performClick(nil)
                } catch {
                    decision.error = error
                    window.endSheet(sheet, returnCode: .abort)
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        controller.scan(url)
        guard let task = Mirror(reflecting: controller).children.first(where: { $0.label == "scanTask" })?.value as? Task<Void, Never> else {
            throw Failure(description: "Scan did not create its preflight task")
        }
        await task.value
        if let error = decision.error { throw error }
        try check(decision.shown, "Real denied-directory preflight skipped the upfront permission decision")
    }

    private static func checkProgressSizing(_ baseline: ScanResult) async throws {
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.orderFront(nil)
        defer { parent.close() }
        let progress = ScanProgressController()
        progress.beginCheckingAccess(on: parent, url: baseline.request.url)
        defer { progress.finish() }
        guard let panel = progress.window, let content = panel.contentView,
              let path = views(content).compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityIdentifier() == "scanPath" }),
              let statistics = views(content).compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityIdentifier() == "scanProgressStatistics" }),
              let volumeUsage = views(content).compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityIdentifier() == "scanVolumeUsage" }),
              let cancel = views(content).compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityIdentifier() == "cancelScan" }) else {
            throw Failure(description: "Missing real scan progress sheet controls")
        }
        content.layoutSubtreeIfNeeded()
        let size = panel.frame.size
        let parentFrame = parent.frame
        let pathHeight = path.frame.height
        let longURL = URL(fileURLWithPath: "/" + Array(repeating: String(repeating: "directory-", count: 18), count: 5).joined(separator: "/"))
        for checkingAccess in [true, false] {
            if !checkingAccess { progress.beginReading() }
            for url in [longURL, baseline.request.url, longURL] {
                if checkingAccess {
                    progress.checkingAccess(ScanPermissionTarget(url: url, kind: .documents))
                } else {
                    progress.update(ScanResult(root: baseline.root, skippedCount: 123,
                        request: baseline.request, isComplete: false, currentPath: url.path,
                        typeStatistics: baseline.typeStatistics))
                }
                await withCheckedContinuation { continuation in
                    DispatchQueue.main.async { continuation.resume() }
                }
                content.layoutSubtreeIfNeeded()
                panel.displayIfNeeded()
                try check(panel.frame.size == size && parent.frame == parentFrame, "Progress path resized the sheet or its parent")
                try check(content.fittingSize.width <= content.bounds.width, "Progress path increased the dialog's fitting width")
                try check(path.stringValue == url.path && path.frame.height == pathHeight, "Progress path lost its full value or wrapped")
                if !checkingAccess {
                    try check(statistics.stringValue.contains("123"), "Progress omitted the skipped-file count")
                    try check(volumeUsage.stringValue.isEmpty, "Subfolder progress invented whole-volume used capacity")
                }
                try check(content.bounds.contains(cancel.frame), "Long progress path pushed Cancel outside the sheet")
            }
        }
        if let argument = CommandLine.arguments.dropFirst().first {
            let output = URL(fileURLWithPath: argument).deletingLastPathComponent().appendingPathComponent("scan-progress-long-path.png")
            content.wantsLayer = true
            content.effectiveAppearance.performAsCurrentDrawingAppearance {
                content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            content.displayIfNeeded()
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                throw Failure(description: "Cannot capture scan progress sheet")
            }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw Failure(description: "Cannot encode scan progress sheet")
            }
            try png.write(to: output)
        }
        print("PASS: real progress sheet retains its size and parent geometry through long/short permission and scan paths; single-line path and Cancel stay in bounds")
    }

    static func run(root: URL) async throws {
        let manager = FileManager.default
        let baselineRoot = root.appendingPathComponent("Completed", isDirectory: true)
        let branch = baselineRoot.appendingPathComponent("Keep/Expanded", isDirectory: true)
        let selected = branch.appendingPathComponent("selected.bin")
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let documents = home.appendingPathComponent("Documents", isDirectory: true)
        let readable = home.appendingPathComponent("Other", isDirectory: true)
        try manager.createDirectory(at: branch, withIntermediateDirectories: true)
        try manager.createDirectory(at: documents, withIntermediateDirectories: true)
        try manager.createDirectory(at: readable, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 37).write(to: selected)
        try Data(repeating: 2, count: 41).write(to: documents.appendingPathComponent("private.bin"))
        try Data(repeating: 3, count: 73).write(to: readable.appendingPathComponent("visible.bin"))
        try check(chmod(documents.path, 0) == 0, "Cannot restrict the isolated Documents fixture")
        defer { chmod(documents.path, S_IRWXU) }

        let baseline = try await scan(baselineRoot)
        try await checkProgressSizing(baseline)
        let controller = InventoryWindowController(permissions: ScanPermissionService(homeDirectory: home))
        controller.showWindow(nil)
        defer { controller.window?.close() }
        controller.present(baseline)
        let content = controller.window!.contentView!
        guard let outline = views(content).compactMap({ $0 as? NSOutlineView }).first,
              let map = views(content).compactMap({ $0 as? TreemapView }).first else {
            throw Failure(description: "Missing actual document views")
        }
        let keep = baselineRoot.appendingPathComponent("Keep")
        outline.expandItem(outline.item(atRow: try row(keep, in: outline)))
        outline.expandItem(outline.item(atRow: try row(branch, in: outline)))
        outline.selectRowIndexes(IndexSet(integer: try row(selected, in: outline)), byExtendingSelection: false)
        let selectedRow = outline.selectedRow
        let beforeViewport = outline.visibleRect.origin

        try await beginScan(home, continueScan: false, deniedPath: documents, controller: controller, map: map, baseline: baseline.root.index)
        try check(map.root?.index === baseline.root.index, "Cancelling permission preflight discarded the completed map")
        try check(outline.isItemExpanded(outline.item(atRow: try row(keep, in: outline))) && outline.isItemExpanded(outline.item(atRow: try row(branch, in: outline))), "Cancelling permission preflight collapsed the existing tree")
        try check(outline.selectedRow == selectedRow && (outline.item(atRow: selectedRow) as? DiskNode)?.url == selected, "Cancelling permission preflight changed selection")
        try check(outline.visibleRect.origin == beforeViewport, "Cancelling permission preflight moved the viewport")
        let rescan = NSMenuItem(title: "", action: #selector(InventoryWindowController.rescan), keyEquivalent: "")
        try check(controller.validateMenuItem(rescan), "Cancelled permission preflight left scan actions busy")

        try await beginScan(home, continueScan: true, deniedPath: documents, controller: controller, map: map, baseline: baseline.root.index)
        guard let newRoot = map.root else { throw Failure(description: "Confirmed permission choice did not produce inventory") }
        try check(newRoot.url == home && newRoot.scanStatus == .partial, "Continuing did not scan the requested scope as partial")
        try check(newRoot.logicalSize == 73 && newRoot.fileCount == 1, "Available scan counted denied contents or lost readable files")
        try check(newRoot.index.find(url: documents)?.scanStatus == .unreadable, "Denied directory vanished after continuing")
        try check(newRoot.index.find(url: readable.appendingPathComponent("visible.bin"))?.logicalSize == 73, "Readable sibling was not scanned after explicit continuation")
        print("PASS: real scoped permission preflight precedes inventory; Cancel preserves completed map/tree/selection/viewport; explicit Continue produces honest partial inventory and keeps readable siblings")
    }
}
