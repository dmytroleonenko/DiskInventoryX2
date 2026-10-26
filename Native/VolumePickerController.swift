import AppKit

@MainActor
final class VolumePickerController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let table = NSTableView()
    private let scanButton = NSButton()
    private let hiddenButton = NSButton(checkboxWithTitle: String(localized: "volumes.hidden", defaultValue: "Show hidden system volumes"), target: nil, action: nil)
    private let message = NSTextField(wrappingLabelWithString: String(localized: "volumes.explanation", defaultValue: "Select the startup volume (/) to scan system files, Applications and Users together. Protected folders require Full Disk Access. Only mounted filesystems are listed; APFS containers and unmounted disks cannot be scanned."))
    private let catalog = VolumeCatalog()
    private var loadTask: Task<Void, Never>?
    private(set) var volumes: [DiskVolume] = []
    private var maximumCapacity: Int64 = 0
    var onScan: ((URL) -> Void)?

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 440), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        panel.title = String(localized: "volumes.title", defaultValue: "Select a volume")
        panel.minSize = NSSize(width: 780, height: 380)
        super.init(window: panel)
        panel.delegate = self
        let content = NSView()
        panel.contentView = content
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("volume"))
        column.width = 968
        column.minWidth = 700
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .fullWidth
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.usesAlternatingRowBackgroundColors = true
        table.intercellSpacing = .zero
        table.rowHeight = 48
        table.autoresizingMask = [.width]
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(scanSelected)
        table.setAccessibilityIdentifier("mountedVolumes")
        hiddenButton.target = self
        hiddenButton.action = #selector(reloadVolumes)
        let refresh = NSButton(title: String(localized: "volumes.refresh", defaultValue: "Refresh"), target: self, action: #selector(reloadVolumes))
        let cancel = NSButton(title: String(localized: "volumes.cancel", defaultValue: "Cancel"), target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        scanButton.title = String(localized: "volumes.scan", defaultValue: "Scan Volume")
        scanButton.target = self
        scanButton.action = #selector(scanSelected)
        scanButton.bezelStyle = .rounded
        scanButton.keyEquivalent = "\r"
        scanButton.isEnabled = false
        let buttons = NSStackView(views: [refresh, cancel, scanButton])
        buttons.spacing = 8
        message.font = .systemFont(ofSize: 12)
        message.textColor = .secondaryLabelColor
        for view in [scroll, hiddenButton, message, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 192),
            hiddenButton.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            hiddenButton.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            message.topAnchor.constraint(equalTo: hiddenButton.bottomAnchor, constant: 8),
            message.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            message.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            buttons.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 12),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }

    func begin(on parent: NSWindow) {
        guard let window, window.sheetParent == nil else { return }
        parent.beginSheet(window)
        reloadVolumes()
    }

    func windowDidResize(_ notification: Notification) {
        window?.contentView?.layoutSubtreeIfNeeded()
        fitVolumeColumn()
    }

    private func fitVolumeColumn() {
        guard let scroll = table.enclosingScrollView else { return }
        table.tableColumns.first?.width = scroll.contentSize.width
    }

    @objc private func reloadVolumes() {
        let previousURL = selectedVolume?.url
        loadTask?.cancel()
        let showHidden = hiddenButton.state == .on
        loadTask = Task { [weak self, catalog] in
            do {
                let volumes = try await catalog.volumes(showHidden: showHidden)
                try Task.checkCancellation()
                guard let self else { return }
                self.volumes = volumes
                self.maximumCapacity = volumes.compactMap(\.totalCapacity).max() ?? 0
                self.table.reloadData()
                self.window?.contentView?.layoutSubtreeIfNeeded()
                self.fitVolumeColumn()
                if !volumes.isEmpty {
                    let row = volumes.firstIndex { $0.url == previousURL } ?? 0
                    self.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
                self.scanButton.isEnabled = self.selectedVolume != nil
            } catch is CancellationError { } catch {
                guard let self, !Task.isCancelled else { return }
                self.volumes = []
                self.table.reloadData()
                self.scanButton.isEnabled = false
                self.message.stringValue = error.localizedDescription
            }
        }
    }

    private var selectedVolume: DiskVolume? {
        volumes.indices.contains(table.selectedRow) ? volumes[table.selectedRow] : nil
    }

    @objc private func scanSelected() {
        guard let selectedVolume else { return }
        finish()
        onScan?(selectedVolume.url)
    }
    @objc private func cancel() { finish() }
    private func finish() {
        loadTask?.cancel()
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        window?.orderOut(nil)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { volumes.count }
    func tableViewSelectionDidChange(_ notification: Notification) { scanButton.isEnabled = selectedVolume != nil }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("volumeRow")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? VolumeRowView ?? VolumeRowView()
        cell.identifier = identifier
        cell.configure(with: volumes[row], maximumCapacity: maximumCapacity)
        return cell
    }
}
