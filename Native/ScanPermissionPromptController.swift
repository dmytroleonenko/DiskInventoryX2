import AppKit
import Darwin

/// Summarizes actual filesystem denials after macOS has finished its own consent prompts.
@MainActor
struct ScanPermissionPromptController {
    private let openSettings: @MainActor (URL) -> Bool

    init(openSettings: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.openSettings = openSettings
    }

    func confirm(_ report: ScanPermissionReport, on window: NSWindow) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "permissions.denied.title", defaultValue: "Some selected locations are unavailable")
        alert.informativeText = String(localized: "permissions.denied.explanation", defaultValue: "The locations below denied access. Continue with an incomplete scan, or change access in System Settings. This check reads directory metadata only, not file contents, and does not download cloud files.")

        let cancel = alert.addButton(withTitle: String(localized: "permissions.cancel", defaultValue: "Cancel"))
        cancel.setAccessibilityIdentifier("permission.cancel")
        let available = alert.addButton(withTitle: String(localized: "permissions.scanAvailable", defaultValue: "Scan Available Files"))
        available.setAccessibilityIdentifier("permission.continue")
        let settings = alert.addButton(withTitle: String(localized: "permissions.openSettings", defaultValue: "Open Privacy Settings"))
        settings.setAccessibilityIdentifier("permission.openSettings")

        let paths = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 150))
        paths.isEditable = false
        paths.isSelectable = true
        paths.isRichText = false
        paths.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        paths.textColor = .labelColor
        paths.backgroundColor = .textBackgroundColor
        paths.textContainerInset = NSSize(width: 8, height: 8)
        paths.autoresizingMask = [.width]
        paths.textContainer?.widthTracksTextView = true
        paths.setAccessibilityIdentifier("permissionDeniedPaths")
        paths.string = report.denied.map { denial in
            let reason = denial.code == EACCES
                ? String(localized: "permissions.error.accessDenied", defaultValue: "Access denied (EACCES)")
                : String(localized: "permissions.error.notPermitted", defaultValue: "Operation not permitted (EPERM)")
            return "\(ScanPermissionPresentation.category(denial.target.kind)) — \(reason)\n\(denial.target.url.path)"
        }.joined(separator: "\n\n")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 150))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = paths
        paths.isVerticallyResizable = true
        paths.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        let guidance = NSTextField(wrappingLabelWithString: String(localized: "permissions.settings.help", defaultValue: "macOS remembers previous decisions. Check Privacy & Security → Files and Folders or Full Disk Access; Disk Inventory X2 cannot grant Full Disk Access itself. Unix permissions can also deny access. Opening settings cancels this scan. After changing access, restart Disk Inventory X2 if required and scan again."))
        guidance.font = .systemFont(ofSize: 11)
        guidance.textColor = .secondaryLabelColor
        guidance.setAccessibilityIdentifier("permissionSettingsHelp")
        let accessory = NSStackView(views: [scroll, guidance])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 12
        scroll.widthAnchor.constraint(equalToConstant: 520).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
        guidance.widthAnchor.constraint(equalToConstant: 520).isActive = true
        accessory.setFrameSize(accessory.fittingSize)
        alert.accessoryView = accessory
        alert.layout()
        alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
        cancel.keyEquivalent = "\r"
        cancel.keyEquivalentModifierMask = []
        available.keyEquivalent = ""
        settings.keyEquivalent = ""

        switch await alert.beginSheetModal(for: window) {
        case .alertSecondButtonReturn:
            return true
        case .alertThirdButtonReturn:
            _ = openSettings(ScanPermissionPresentation.settingsURL(for: report))
            return false
        default:
            return false
        }
    }
}
