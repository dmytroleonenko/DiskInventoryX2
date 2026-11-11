import AppKit

/// Scanning reports progress here; incomplete indexes never reach the document views.
@MainActor
final class ScanProgressController: NSWindowController {
    private let heading = NSTextField(labelWithString: String(localized: "scan.reading", defaultValue: "Reading folder contents…"))
    private let currentPath = NSTextField(labelWithString: "")
    private let statistics = NSTextField(labelWithString: "")
    private let volumeUsage = NSTextField(labelWithString: "")
    private let indicator = NSProgressIndicator()
    private var scanURL: URL?
    private var volumeSpace: VolumeSpaceSnapshot?
    private var volumeSpaceSampled = false
    var onCancel: (() -> Void)?

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 190), styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = String(localized: "scan.title", defaultValue: "Scanning")
        let content = NSView()
        panel.contentView = content
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.setAccessibilityIdentifier("scanPhase")
        currentPath.font = .systemFont(ofSize: 11)
        currentPath.lineBreakMode = .byTruncatingMiddle
        currentPath.maximumNumberOfLines = 1
        currentPath.cell?.usesSingleLineMode = true
        currentPath.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        currentPath.setAccessibilityIdentifier("scanPath")
        statistics.font = .systemFont(ofSize: 11)
        statistics.textColor = .secondaryLabelColor
        statistics.lineBreakMode = .byWordWrapping
        statistics.maximumNumberOfLines = 3
        statistics.setAccessibilityIdentifier("scanProgressStatistics")
        volumeUsage.font = .systemFont(ofSize: 11)
        volumeUsage.textColor = .secondaryLabelColor
        volumeUsage.lineBreakMode = .byTruncatingTail
        volumeUsage.maximumNumberOfLines = 1
        volumeUsage.cell?.usesSingleLineMode = true
        volumeUsage.setAccessibilityIdentifier("scanVolumeUsage")
        indicator.style = .bar
        indicator.isIndeterminate = true
        let cancel = NSButton(title: String(localized: "delete.cancel", defaultValue: "Cancel"), target: self, action: #selector(cancelScan))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.setAccessibilityIdentifier("cancelScan")
        for view in [heading, currentPath, statistics, volumeUsage, indicator, cancel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            // Progress text must fit the dialog, not resize it as paths change.
            content.widthAnchor.constraint(equalToConstant: 560),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            currentPath.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            currentPath.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            currentPath.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 9),
            indicator.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            indicator.trailingAnchor.constraint(equalTo: currentPath.trailingAnchor),
            indicator.topAnchor.constraint(equalTo: currentPath.bottomAnchor, constant: 12),
            statistics.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            statistics.topAnchor.constraint(equalTo: indicator.bottomAnchor, constant: 12),
            statistics.trailingAnchor.constraint(lessThanOrEqualTo: cancel.leadingAnchor, constant: -12),
            volumeUsage.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            volumeUsage.trailingAnchor.constraint(equalTo: currentPath.trailingAnchor),
            volumeUsage.topAnchor.constraint(equalTo: statistics.bottomAnchor, constant: 6),
            volumeUsage.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -12),
            cancel.trailingAnchor.constraint(equalTo: currentPath.trailingAnchor),
            cancel.centerYAnchor.constraint(equalTo: statistics.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }

    func begin(on parent: NSWindow, url: URL) {
        volumeSpace = nil
        volumeSpaceSampled = false
        volumeUsage.stringValue = ""
        scanURL = url
        beginReading()
        indicator.startAnimation(nil)
        guard let window, window.sheetParent == nil else { return }
        parent.beginSheet(window)
    }

    func beginCheckingAccess(on parent: NSWindow, url: URL) {
        volumeSpace = nil
        volumeSpaceSampled = false
        volumeUsage.stringValue = ""
        scanURL = url
        heading.stringValue = String(localized: "permissions.checking", defaultValue: "Checking filesystem access…")
        currentPath.stringValue = url.path
        statistics.stringValue = String(localized: "permissions.checking.scope", defaultValue: "Selected scope only • names, types and sizes • no file contents or cloud downloads")
        indicator.startAnimation(nil)
        guard let window, window.sheetParent == nil else { return }
        parent.beginSheet(window)
    }

    func checkingAccess(_ target: ScanPermissionTarget) {
        currentPath.stringValue = target.url.path
        statistics.stringValue = String.localizedStringWithFormat(
            String(localized: "permissions.checking.category", defaultValue: "%@ • metadata access only"),
            ScanPermissionPresentation.category(target.kind)
        )
    }

    func beginReading() {
        heading.stringValue = String(localized: "scan.reading", defaultValue: "Reading folder contents…")
        currentPath.stringValue = scanURL?.path ?? ""
        statistics.stringValue = String(localized: "scan.progress.note", defaultValue: "Progress counts are scanned attribution, not disk used.")
        showVolumeUsage()
    }

    func update(_ result: ScanResult) {
        currentPath.stringValue = result.currentPath ?? result.request.url.path
        let progress = String.localizedStringWithFormat(
            String(localized: "scan.progress", defaultValue: "%lld files • scanned allocation estimate %@ • %lld skipped"),
            Int64(result.root.fileCount), ScanEntryPresentation.bytes(result.root.allocatedSize), Int64(result.skippedCount)
        )
        statistics.stringValue = progress + "\n" + String(localized: "scan.progress.note", defaultValue: "Progress counts are scanned attribution, not disk used.")
    }

    /// One filesystem metadata sample per scan start; progress updates never resample.
    private func showVolumeUsage() {
        if !volumeSpaceSampled, let scanURL {
            volumeSpaceSampled = true
            volumeSpace = VolumeSpaceReader().read(at: scanURL)
        }
        guard let volumeSpace else {
            volumeUsage.stringValue = ""
            return
        }
        volumeUsage.stringValue = ScanEntryPresentation.progressVolumeUsage(volumeSpace)
    }

    func finish() {
        indicator.stopAnimation(nil)
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        window?.orderOut(nil)
    }

    @objc private func cancelScan() { onCancel?() }
}
