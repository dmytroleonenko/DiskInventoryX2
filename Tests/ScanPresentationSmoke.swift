import AppKit
import Darwin

@MainActor
struct ScanPresentationSmoke {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    private static func views(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { views($0) }
    }

    private static func field(_ identifier: String, in controller: InventoryWindowController) throws -> NSTextField {
        guard let content = controller.window?.contentView,
              let field = views(content).compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityIdentifier() == identifier }) else {
            throw Failure(description: "Missing actual AppKit field: \(identifier)")
        }
        return field
    }

    private static func row(_ url: URL, in outline: NSOutlineView) throws -> Int {
        guard let row = (0..<outline.numberOfRows).first(where: { (outline.item(atRow: $0) as? DiskNode)?.url == url }) else {
            throw Failure(description: "Missing AppKit outline row: \(url.path)")
        }
        return row
    }

    private static func select(_ url: URL, in outline: NSOutlineView) throws {
        outline.selectRowIndexes(IndexSet(integer: try row(url, in: outline)), byExtendingSelection: false)
    }

    private static func rowText(_ url: URL, column: Int, in outline: NSOutlineView) throws -> (String, String) {
        let row = try row(url, in: outline)
        outline.scrollRowToVisible(row)
        guard let view = outline.view(atColumn: column, row: row, makeIfNecessary: true) else {
            throw Failure(description: "AppKit did not create a row view")
        }
        let fields = views(view).compactMap { $0 as? NSTextField }
        return (fields.map(\.stringValue).joined(separator: " "), view.toolTip ?? fields.first?.toolTip ?? "")
    }

    private static func result(_ index: DiskIndex) -> ScanResult {
        ScanResult(root: index.root, skippedCount: 0, request: ScanRequest(url: index.rootURL, sizeMode: index.sizeMode), isComplete: true, currentPath: nil, typeStatistics: index.presentationStatistics(for: 0))
    }

    static func run(root: URL) async throws {
        let manager = FileManager.default
        let fixture = root.appendingPathComponent("scan-presentation-fixture", isDirectory: true)
        let denied = fixture.appendingPathComponent("denied", isDirectory: true)
        let empty = fixture.appendingPathComponent("empty", isDirectory: true)
        let payload = fixture.appendingPathComponent("payload.bin")
        let alias = fixture.appendingPathComponent("payload-alias.bin")
        try manager.createDirectory(at: denied, withIntermediateDirectories: true)
        try manager.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 1_100_000).write(to: payload)
        try manager.linkItem(at: payload, to: alias)
        try Data(repeating: 9, count: 101).write(to: denied.appendingPathComponent("hidden.bin"))
        defer {
            _ = chmod(denied.path, 0o700)
            try? manager.removeItem(at: fixture)
        }
        try check(chmod(denied.path, 0) == 0, "Could not deny fixture directory access")
        var completed: ScanResult?
        for try await value in DiskScanner().scan(ScanRequest(url: fixture, sizeMode: .logical)) where value.isComplete { completed = value }
        guard let scanned = completed, let deniedNode = scanned.root.index.find(url: denied),
              let emptyNode = scanned.root.index.find(url: empty) else {
            throw Failure(description: "Real denied-directory scan omitted its placeholder or empty sibling")
        }
        try check(deniedNode.scanStatus == .unreadable, "chmod-denied directory must remain unreadable, not empty (run as a non-root user)")
        try check(emptyNode.scanStatus == .complete && emptyNode.size == 0, "Real empty directory should remain complete and empty")
        try check(scanned.root.scanStatus == .partial, "Unreadable descendant must mark the real scan partial")

        let controller = InventoryWindowController(permissions: ScanPermissionService())
        controller.showWindow(nil)
        defer { controller.window?.close() }
        guard let content = controller.window?.contentView,
              let outline = views(content).compactMap({ $0 as? NSOutlineView }).first,
              let map = views(content).compactMap({ $0 as? TreemapView }).first else {
            throw Failure(description: "Missing real outline or treemap")
        }
        let delete = NSMenuItem(title: "", action: #selector(InventoryWindowController.deletePermanently), keyEquivalent: "")
        let zoom = NSMenuItem(title: "", action: #selector(InventoryWindowController.zoomSelection), keyEquivalent: "")
        controller.present(scanned)
        let info = try field("itemInformation", in: controller)
        let footer = try field("volumeSpaceSummary", in: controller)
        let deniedSize = try rowText(denied, column: 1, in: outline)
        let emptySize = try rowText(empty, column: 1, in: outline)
        try check(deniedSize.0 == String(localized: "entry.unavailable", defaultValue: "Unavailable") && deniedSize.0 != emptySize.0, "Actual unreadable row masqueraded as an empty size")
        try check(deniedSize.1.contains(String(localized: "entry.unreadable", defaultValue: "Unreadable")), "Unreadable row tooltip omitted its status")
        try select(denied, in: outline)
        try check(info.stringValue.contains(String(localized: "entry.unreadable", defaultValue: "Unreadable")), "Selected unreadable details omitted status")
        try check(!controller.validateMenuItem(delete) && !controller.validateMenuItem(zoom), "Unreadable item enabled deletion or empty zoom")
        map.onHover?(deniedNode)
        try check(map.toolTip?.contains(String(localized: "entry.unreadable", defaultValue: "Unreadable")) == true, "Hovered unreadable details omitted tooltip")
        try select(empty, in: outline)
        try check(controller.validateMenuItem(delete), "Complete empty directory lost normal deletion behavior")

        let linkedNodes = [payload, alias].compactMap { scanned.root.index.find(url: $0) }
        guard let shared = linkedNodes.first(where: { node in
            guard let record = node.index.hardLink(at: node.id) else { return false }
            return record.ownerID != node.id
        }), let record = scanned.root.index.hardLink(at: shared.id) else {
            throw Failure(description: "Real hard links did not retain a visible shared alias")
        }
        try select(shared.url, in: outline)
        let sharedSize = try rowText(shared.url, column: 1, in: outline)
        try check(sharedSize.0 == String(localized: "entry.countedElsewhere", defaultValue: "Already counted"), "Shared alias looked like an empty file")
        try check(info.stringValue.contains(scanned.root.index.url(of: record.ownerID).path), "Shared alias omitted owner path")
        try check(info.toolTip?.contains(ByteCountFormatter.string(fromByteCount: record.logicalSize, countStyle: .file)) == true, "Shared alias omitted original logical size")
        try check(info.toolTip?.contains(ByteCountFormatter.string(fromByteCount: record.allocatedSize, countStyle: .file)) == true, "Shared alias omitted original allocation")
        try check(controller.validateMenuItem(delete), "Complete shared alias lost normal deletion behavior")

        let mounted = fixture.appendingPathComponent("mounted-placeholder", isDirectory: true)
        try manager.createDirectory(at: mounted, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 1_100_000).write(to: mounted.appendingPathComponent("mounted.bin"))
        let states: [(String, ScanEntryStatus, String)] = [
            ("partial", .partial, String(localized: "entry.partial", defaultValue: "Partial scan")),
            ("unreadable", .unreadable, String(localized: "entry.unreadable", defaultValue: "Unreadable")),
            ("cloud", .cloudOnly, String(localized: "entry.cloudOnly", defaultValue: "Cloud only")),
            ("automount", .automount, String(localized: "entry.automount", defaultValue: "Automount not opened")),
            ("mounted-placeholder", .otherVolume, String(localized: "entry.otherVolume", defaultValue: "Other mounted volume — scan separately"))
        ]
        let builder = DiskIndexBuilder(rootURL: fixture)
        builder.append(parent: -1, name: fixture.lastPathComponent, isDirectory: true)
        let zoomID = builder.append(parent: 0, name: "zoomable", isDirectory: true)
        builder.append(parent: zoomID, name: "inside.bin", logicalSize: 9_000_000, allocatedSize: 100_000, fileCount: 1, isDirectory: false)
        builder.append(parent: 0, name: "outside.bin", logicalSize: 4_000_000, allocatedSize: 150_000, fileCount: 1, isDirectory: false)
        for (name, state, _) in states { builder.append(parent: 0, name: name, isDirectory: true, scanStatus: state) }
        let snapshot = VolumeSpaceSnapshot(volumeURL: fixture, capacityBytes: 1_000_000, freeBytes: 300_000)
        let index = builder.finish(volumeSpace: snapshot)
        controller.present(result(index))
        for (name, state, label) in states {
            let url = fixture.appendingPathComponent(name)
            try select(url, in: outline)
            let nameRow = try rowText(url, column: 0, in: outline)
            let sizeRow = try rowText(url, column: 1, in: outline)
            try check(nameRow.0.contains(label) && nameRow.1.contains(label), "Actual row or tooltip omitted \(state)")
            try check(info.stringValue.contains(label) && !controller.validateMenuItem(delete), "Selected \(state) omitted status or enabled deletion")
            if state == .partial {
                try check(sizeRow.0.contains(String.localizedStringWithFormat(String(localized: "entry.lowerBound", defaultValue: "At least %@"), ByteCountFormatter.string(fromByteCount: 0, countStyle: .file))), "Partial zero was not identified as a lower bound")
            } else {
                try check(sizeRow.0 == String(localized: "entry.unavailable", defaultValue: "Unavailable"), "Placeholder presented fake zero bytes")
            }
            if state == .automount || state == .cloudOnly {
                try check(!controller.validateMenuItem(zoom), "Cloud/automount placeholder enabled zoom")
                controller.zoomSelection()
                try check(map.root?.index === index, "Direct zoom opened cloud/automount placeholder")
            }
            if state == .otherVolume { try check(controller.validateMenuItem(zoom), "Mounted placeholder without children cannot be explicitly scanned") }
            map.onHover?(index.find(url: url))
            try check(info.stringValue.contains(label) && map.toolTip?.contains(label) == true, "Hovered \(state) details omitted status")
        }

        let positive = String.localizedStringWithFormat(
            String(localized: "space.unaccounted", defaultValue: "Full scan allocated %@ • Not accounted by scan %@"),
            ByteCountFormatter.string(fromByteCount: 250_000, countStyle: .file), ByteCountFormatter.string(fromByteCount: 450_000, countStyle: .file)
        )
        try check(footer.stringValue.contains(positive), "Footer did not show independently computed positive residual")
        try check(footer.stringValue.contains(ByteCountFormatter.string(fromByteCount: 700_000, countStyle: .file)), "Footer omitted volume used bytes")
        let originalFooter = footer.stringValue
        try select(fixture.appendingPathComponent("zoomable"), in: outline)
        controller.zoomSelection()
        try check(map.root?.id == zoomID && footer.stringValue == originalFooter, "Zoom narrowed full-scan allocated accounting")
        controller.togglePhysicalSizes()
        try await awaitTask("presentationTask", in: controller)
        try check(map.root?.index.sizeMode == .logical && footer.stringValue == originalFooter, "Logical mode replaced full-scan allocated accounting")
        try select(fixture.appendingPathComponent("zoomable/inside.bin"), in: outline)
        map.onHover?(map.root?.index.find(url: fixture.appendingPathComponent("zoomable/inside.bin")))
        try check(footer.stringValue == originalFooter, "Selection/hover replaced the persistent footer")
        controller.zoomOut()
        try check(footer.stringValue == originalFooter, "Zoom-out changed full-scan accounting")

        let excessIndex = index.withVolumeSpace(VolumeSpaceSnapshot(volumeURL: fixture, capacityBytes: 1_000_000, freeBytes: 900_000))
        controller.present(result(excessIndex))
        let excess = String.localizedStringWithFormat(
            String(localized: "space.excess", defaultValue: "Full scan allocated %@ • Allocation exceeds volume used by %@ (shared blocks / accounting scope)"),
            ByteCountFormatter.string(fromByteCount: 250_000, countStyle: .file), ByteCountFormatter.string(fromByteCount: 150_000, countStyle: .file)
        )
        try check(footer.stringValue.contains(excess) && !footer.stringValue.contains(positive), "Footer hid excess allocation or invented negative snapshot bytes")
        let excessFooter = footer.stringValue
        try select(fixture.appendingPathComponent("zoomable"), in: outline)
        controller.zoomSelection()
        controller.togglePhysicalSizes()
        try await awaitTask("presentationTask", in: controller)
        try select(fixture.appendingPathComponent("zoomable/inside.bin"), in: outline)
        try check(footer.stringValue == excessFooter && map.root?.index.sizeMode == .logical, "Excess summary changed under zoom/mode/selection")
        controller.zoomOut()
        controller.present(result(index.withVolumeSpace(nil)))
        try check(footer.stringValue == String(localized: "space.unavailable", defaultValue: "Volume space snapshot unavailable; unaccounted space cannot be determined."), "Missing snapshot invented volume totals")
        controller.present(result(index))
        try select(mounted, in: outline)
        controller.zoomSelection()
        try await awaitTask("scanTask", in: controller)
        try check(map.root?.url == mounted && map.root?.scanStatus == .complete && map.root?.logicalSize == 1_100_000, "Explicit mounted-placeholder zoom did not perform a real separate scan")
        controller.zoomOut()
        try check(map.root?.index === index && footer.stringValue == originalFooter, "Separate volume zoom-out lost the previous tree or footer")
        try select(fixture.appendingPathComponent("unreadable"), in: outline)
        if let outputPath = CommandLine.arguments.dropFirst().first {
            let screenshot = URL(fileURLWithPath: outputPath).deletingLastPathComponent().appendingPathComponent("scan-presentation.png")
            // Content-view caching has no window backdrop for vibrant label drawing.
            content.wantsLayer = true
            content.effectiveAppearance.performAsCurrentDrawingAppearance {
                content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw Failure(description: "Cannot capture actual AppKit surface") }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure(description: "Cannot encode AppKit surface screenshot") }
            try manager.createDirectory(at: screenshot.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: screenshot)
            print("Scan presentation screenshot: \(screenshot.path)")
        }
        print("PASS: real denied-directory and hardlink scan surfaces; every availability state; deletion/zoom guards; full-scan positive/excess volume accounting across zoom, mode and selection")
    }

    private static func awaitTask(_ name: String, in controller: InventoryWindowController) async throws {
        guard let task = Mirror(reflecting: controller).children.first(where: { $0.label == name })?.value as? Task<Void, Never> else {
            throw Failure(description: "Controller did not start \(name)")
        }
        await task.value
    }
}
