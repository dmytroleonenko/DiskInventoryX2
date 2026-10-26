import AppKit
import Darwin

@MainActor
struct ScanPermissionPromptSmoke {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    @MainActor private final class Interaction {
        var shown = false
        var error: Error?
        var openedURLs: [URL] = []
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(description: message) }
    }

    private static func views(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { views($0) }
    }

    private static func field(_ identifier: String, in sheet: NSWindow) throws -> NSTextField {
        guard let content = sheet.contentView,
              let field = views(content).compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityIdentifier() == identifier }) else {
            throw Failure(description: "Missing actual progress field: \(identifier)")
        }
        return field
    }

    private static func capture(_ content: NSView) throws {
        guard let outputPath = CommandLine.arguments.dropFirst().first else { return }
        let screenshot = URL(fileURLWithPath: outputPath).deletingLastPathComponent().appendingPathComponent("permission-preflight.png")
        // Vibrant labels need an opaque backing when cached without the window backdrop.
        content.wantsLayer = true
        content.effectiveAppearance.performAsCurrentDrawingAppearance {
            content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            throw Failure(description: "Cannot capture permission sheet")
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure(description: "Cannot encode permission sheet screenshot")
        }
        try FileManager.default.createDirectory(at: screenshot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: screenshot)
        print("Permission preflight screenshot: \(screenshot.path)")
    }

    private static func respond(
        _ report: ScanPermissionReport, on window: NSWindow, button identifier: String,
        outsidePath: String, screenshot: Bool = false
    ) async throws -> (Bool, [URL]) {
        let interaction = Interaction()
        let controller = ScanPermissionPromptController(openSettings: { url in
            interaction.openedURLs.append(url)
            return true
        })
        // AppKit posts this before attachment; the actor turn resumes after beginSheet returns.
        let token = NotificationCenter.default.addObserver(forName: NSWindow.willBeginSheetNotification, object: window, queue: .main) { _ in
            Task { @MainActor in
                do {
                    guard let sheet = window.attachedSheet, let content = sheet.contentView else {
                        throw Failure(description: "Missing actual permission summary sheet")
                    }
                    let descendants = views(content)
                    let buttons = descendants.compactMap { $0 as? NSButton }
                    guard let cancel = buttons.first(where: { $0.accessibilityIdentifier() == "permission.cancel" }),
                          let selected = buttons.first(where: { $0.accessibilityIdentifier() == identifier }),
                          let paths = descendants.compactMap({ $0 as? NSTextView }).first(where: { $0.accessibilityIdentifier() == "permissionDeniedPaths" }) else {
                        throw Failure(description: "Missing permission buttons or real denied-path view")
                    }
                    try check(sheet.defaultButtonCell === cancel.cell, "Permission summary must default to Cancel")
                    for denial in report.denied {
                        try check(paths.string.contains(denial.target.url.path), "Permission summary omitted a real denied path")
                        try check(paths.string.contains(ScanPermissionPresentation.category(denial.target.kind)), "Permission summary omitted a denied category")
                        try check(paths.string.contains(denial.code == EACCES ? "EACCES" : "EPERM"), "Permission summary omitted the actual filesystem error")
                    }
                    try check(!paths.string.contains(outsidePath), "Permission summary included a location outside this scan")
                    if screenshot { try capture(content) }
                    interaction.shown = true
                    selected.performClick(nil)
                } catch {
                    interaction.error = error
                    if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort) }
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let result = await controller.confirm(report, on: window)
        if let error = interaction.error { throw error }
        try check(interaction.shown, "Permission decision bypassed actual AppKit summary")
        return (result, interaction.openedURLs)
    }

    static func run(root: URL) async throws {
        let manager = FileManager.default
        let fixture = root.appendingPathComponent("permission-prompt-fixture", isDirectory: true)
        let selectedRoot = fixture.appendingPathComponent("Selected", isDirectory: true)
        let denied = selectedRoot.appendingPathComponent("Documents", isDirectory: true)
        let outside = fixture.appendingPathComponent("Outside", isDirectory: true)
        try manager.createDirectory(at: denied, withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            _ = chmod(denied.path, 0o700)
            try? manager.removeItem(at: fixture)
        }
        try check(chmod(denied.path, 0) == 0, "Cannot restrict permission-summary fixture")
        errno = 0
        if let directory = opendir(denied.path) {
            closedir(directory)
            throw Failure(description: "Fixture must actually deny access; run as a non-root user")
        }
        let actualError = errno
        try check(actualError == EACCES || actualError == EPERM, "Fixture did not produce a real access denial")
        let report = ScanPermissionReport(checkedCount: 2, denied: [
            ScanPermissionDenial(target: ScanPermissionTarget(url: denied, kind: .documents), code: actualError)
        ])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 780), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = String(localized: "ui.appName", defaultValue: "Disk Inventory X2")
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        let cancelled = try await respond(report, on: window, button: "permission.cancel", outsidePath: outside.path, screenshot: true)
        try check(!cancelled.0 && cancelled.1.isEmpty, "Cancel continued scanning or opened settings")
        let available = try await respond(report, on: window, button: "permission.continue", outsidePath: outside.path)
        try check(available.0 && available.1.isEmpty, "Explicit Scan Available Files did not continue independently of settings")
        let settings = try await respond(report, on: window, button: "permission.openSettings", outsidePath: outside.path)
        try check(!settings.0 && settings.1.map(\.absoluteString) == ["x-apple.systempreferences:com.apple.preference.security?Privacy"], "Privacy settings must abort this scan and navigate to Privacy & Security")
        // A controlled category exercises the FDA navigation without touching actual protected folders or grants.
        let protectedReport = ScanPermissionReport(checkedCount: 1, denied: [
            ScanPermissionDenial(target: ScanPermissionTarget(url: denied, kind: .fullDiskAccess), code: EPERM)
        ])
        let fullDisk = try await respond(protectedReport, on: window, button: "permission.openSettings", outsidePath: outside.path)
        try check(!fullDisk.0 && fullDisk.1.map(\.absoluteString) == ["x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"], "Protected-file settings must abort this scan and select Full Disk Access")

        let progress = ScanProgressController()
        progress.beginCheckingAccess(on: window, url: selectedRoot)
        defer { progress.finish() }
        guard let sheet = window.attachedSheet else {
            throw Failure(description: "Missing actual checking-access progress sheet")
        }
        try check(try field("scanPath", in: sheet).stringValue == selectedRoot.path, "Initial checking scope omitted the selected root")
        progress.checkingAccess(report.denied[0].target)
        try check(try field("scanPath", in: sheet).stringValue == denied.path, "Checking phase omitted the current actual probe path")
        try check(try field("scanProgressStatistics", in: sheet).stringValue.contains(ScanPermissionPresentation.category(.documents)), "Checking phase omitted the protected category")
        progress.beginReading()
        try check(window.attachedSheet === sheet, "Allowed preflight replaced the existing progress sheet")
        try check(try field("scanPath", in: sheet).stringValue == selectedRoot.path, "beginReading did not restore the selected root path")
        progress.beginCheckingAccess(on: window, url: selectedRoot)
        progress.checkingAccess(report.denied[0].target)
        progress.begin(on: window, url: selectedRoot)
        try check(try field("scanPath", in: sheet).stringValue == selectedRoot.path && (try field("scanProgressStatistics", in: sheet)).stringValue.isEmpty, "Normal begin retained stale probe state")
        print("PASS: actual AppKit permission summary; explicit continue and default Cancel; scoped denied paths; manual Privacy/FDA navigation aborts; metadata-check path/category and reading reset")
    }
}
