import AppKit

@MainActor
final class InventoryWindowController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
    private let outline = InventoryOutlineView()
    private let kinds = NSTableView()
    private let map = TreemapView()
    private let status: CopyablePathField
    private let itemInformation: CopyablePathField
    private let volumeSpaceSummary = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private var documentToolbar: InventoryToolbar?
    private let kindsPanel = NSScrollView()
    // Keep the original external drawer; replacing it with an inset pane changes map geometry.
    private let kindsDrawer = NSDrawer(contentSize: NSSize(width: 330, height: 400), preferredEdge: .minX)
    private let scanner = DiskScanner()
    private let permissions: any ScanPermissionsPreparing
    private let permissionPrompt = ScanPermissionPromptController()
    private let deletionService = PermanentDeletionService()
    private let refreshService = SelectionRefreshService()
    private let progress = ScanProgressController()
    private var scanTask: Task<Void, Never>?
    private var deletionTask: Task<Void, Never>?
    private var presentationTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var volumePicker: VolumePickerController?
    private var root: DiskNode?
    private var selected: DiskNode?
    private var visibleResult: ScanResult?
    private var completedResult: ScanResult?
    private var navigationHistory: [ScanResult] = []
    private var completedHistory: [ScanResult] = []
    private var outlineNodes: [Int: DiskNode] = [:]
    private var typeRows: [FileTypeStat] = []
    private var scanGeneration = 0
    private var pendingRequest: ScanRequest?
    private var synchronizing = false
    private var showPackageContents = false
    private var sizeMode: DiskSizeMode = .physical
    private var showKinds = true

    init(permissions: any ScanPermissionsPreparing, pasteboard: NSPasteboard = .general) {
        self.permissions = permissions
        status = CopyablePathField(pasteboard: pasteboard)
        itemInformation = CopyablePathField(pasteboard: pasteboard)
        let window = InventoryWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = String(localized: "ui.appName", defaultValue: "Disk Inventory X2")
        window.minSize = NSSize(width: 1000, height: 480)
        super.init(window: window)
        window.center()
        let content = NSView()
        window.contentView = content
        let toolbar = InventoryToolbar(target: self)
        documentToolbar = toolbar
        window.toolbarStyle = .expanded
        window.toolbar = toolbar.toolbar
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thick
        split.autosaveName = "NativeDocumentSplit"
        let nameColumn = NSTableColumn(identifier: .init("name"))
        nameColumn.title = String(localized: "ui.name", defaultValue: "Name")
        nameColumn.width = 520
        let sizeColumn = NSTableColumn(identifier: .init("size"))
        sizeColumn.title = String(localized: "ui.size", defaultValue: "Size")
        sizeColumn.width = 150
        sizeColumn.minWidth = 120
        sizeColumn.maxWidth = 180
        sizeColumn.resizingMask = []
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.addTableColumn(nameColumn)
        outline.addTableColumn(sizeColumn)
        outline.outlineTableColumn = nameColumn
        outline.delegate = self
        outline.dataSource = self
        outline.style = .plain
        outline.rowHeight = NSFont.systemFontSize + 4
        outline.intercellSpacing = NSSize(width: 3, height: 2)
        outline.indentationPerLevel = 14
        outline.usesAlternatingRowBackgroundColors = false
        outline.setAccessibilityIdentifier("fileTree")
        outline.menu = selectionMenu()
        let left = NSScrollView()
        left.documentView = outline
        left.borderType = .bezelBorder
        left.hasVerticalScroller = true
        left.hasHorizontalScroller = true
        let colorColumn = NSTableColumn(identifier: .init("color"))
        colorColumn.title = String(localized: "ui.color", defaultValue: "Color")
        colorColumn.width = 35
        colorColumn.minWidth = 35
        colorColumn.maxWidth = 35
        colorColumn.resizingMask = []
        let kindColumn = NSTableColumn(identifier: .init("kind"))
        kindColumn.title = String(localized: "ui.kind", defaultValue: "Kind")
        kindColumn.width = 136
        kindColumn.minWidth = 90
        kindColumn.resizingMask = .autoresizingMask
        let bytesColumn = NSTableColumn(identifier: .init("bytes"))
        bytesColumn.title = String(localized: "ui.size", defaultValue: "Size")
        bytesColumn.width = 75
        bytesColumn.minWidth = 70
        bytesColumn.maxWidth = 95
        bytesColumn.resizingMask = []
        let countColumn = NSTableColumn(identifier: .init("count"))
        countColumn.title = String(localized: "ui.files", defaultValue: "Files")
        countColumn.width = 55
        countColumn.minWidth = 55
        countColumn.maxWidth = 55
        countColumn.resizingMask = []
        kinds.addTableColumn(colorColumn)
        kinds.addTableColumn(kindColumn)
        kinds.addTableColumn(bytesColumn)
        kinds.addTableColumn(countColumn)
        kinds.columnAutoresizingStyle = .sequentialColumnAutoresizingStyle
        kinds.dataSource = self
        kinds.delegate = self
        kinds.style = .plain
        kinds.autoresizingMask = [.width]
        kinds.rowHeight = NSFont.systemFontSize + 4
        kinds.intercellSpacing = NSSize(width: 3, height: 2)
        kinds.usesAlternatingRowBackgroundColors = false
        kinds.setAccessibilityIdentifier("fileKinds")
        kindsPanel.documentView = kinds
        kindsPanel.hasVerticalScroller = true
        kindsPanel.borderType = .bezelBorder
        kindsDrawer.parentWindow = window
        kindsDrawer.contentView = kindsPanel
        kindsDrawer.minContentSize = NSSize(width: 330, height: 50)
        kindsDrawer.maxContentSize = NSSize(width: 1000, height: 2000)
        kindsDrawer.trailingOffset = 15
        kindsDrawer.open()
        split.addArrangedSubview(left)
        split.addArrangedSubview(map)
        let document = split
        for label in [status, itemInformation] {
            label.font = .systemFont(ofSize: 11)
            label.lineBreakMode = .byTruncatingMiddle
        }
        status.font = .systemFont(ofSize: NSFont.systemFontSize)
        itemInformation.ordinaryTextColor = .secondaryLabelColor
        status.setAccessibilityIdentifier("selectionStatus")
        itemInformation.setAccessibilityIdentifier("itemInformation")
        volumeSpaceSummary.setAccessibilityIdentifier("volumeSpaceSummary")
        volumeSpaceSummary.font = .systemFont(ofSize: 11)
        volumeSpaceSummary.textColor = .secondaryLabelColor
        volumeSpaceSummary.toolTip = ScanEntryPresentation.volumeExplanation
        volumeSpaceSummary.maximumNumberOfLines = 0
        volumeSpaceSummary.setContentCompressionResistancePriority(.required, for: .vertical)
        status.display(String(localized: "ui.choose", defaultValue: "Choose a folder or volume to scan."))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for view in [document, status, itemInformation, volumeSpaceSummary, spinner] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            document.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            document.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            document.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -5),
            left.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            map.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            status.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: spinner.leadingAnchor, constant: -8),
            status.bottomAnchor.constraint(equalTo: itemInformation.topAnchor, constant: -6),
            itemInformation.leadingAnchor.constraint(equalTo: status.leadingAnchor),
            itemInformation.trailingAnchor.constraint(equalTo: status.trailingAnchor),
            itemInformation.bottomAnchor.constraint(equalTo: volumeSpaceSummary.topAnchor, constant: -8),
            volumeSpaceSummary.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            volumeSpaceSummary.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            volumeSpaceSummary.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            spinner.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            spinner.centerYAnchor.constraint(equalTo: status.centerYAnchor)
        ])
        content.layoutSubtreeIfNeeded()
        split.setPosition(split.bounds.width * 0.60, ofDividerAt: 0)
        map.onSelect = { [weak self] node in self?.selectFromMap(node) }
        map.onHover = { [weak self] node in self?.showInformation(for: node) }
        map.menu = selectionMenu()
        progress.onCancel = { [weak self] in self?.cancelScan() }
        window.onPermanentDelete = { [weak self] in self?.deletePermanently() }
        window.onMoveToTrash = { [weak self] in self?.moveToTrash() }
        updateActions()
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }


    private func selectionMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [
            (String(localized: "ui.zoomIn", defaultValue: "Zoom In"), #selector(zoomSelection)),
            (String(localized: "ui.selectParent", defaultValue: "Select Parent"), #selector(selectParent)),
            (String(localized: "ui.reveal", defaultValue: "Reveal in Finder"), #selector(reveal)),
            (String(localized: "refresh.selection", defaultValue: "Refresh Selection"), #selector(refreshSelection)),
            (String(localized: "trash.menu", defaultValue: "Move to Trash"), #selector(moveToTrash)),
            (String(localized: "delete.menu", defaultValue: "Delete Permanently…"), #selector(deletePermanently))
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    private var isBusy: Bool { pendingRequest != nil || deletionTask != nil || presentationTask != nil || refreshTask != nil }

    @objc func openFolder() {
        guard !isBusy, let window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "ui.scan", defaultValue: "Scan")
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.scan(url) }
        }
    }

    @objc func openVolume() {
        guard !isBusy, let window, window.attachedSheet == nil else { return }
        if volumePicker == nil {
            let picker = VolumePickerController()
            picker.onScan = { [weak self] url in self?.scan(url) }
            volumePicker = picker
        }
        volumePicker?.begin(on: window)
    }

    func scan(_ url: URL) {
        guard !isBusy else { return }
        navigationHistory.removeAll()
        startScan(ScanRequest(url: url, sizeMode: sizeMode))
    }

    private func startScan(_ request: ScanRequest, refreshing directory: URL? = nil) {
        let retainedResults = navigationHistory + (visibleResult.map { [$0] } ?? [])
        scanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        pendingRequest = request
        if let window { progress.beginCheckingAccess(on: window, url: request.url) }
        updateActions()
        scanTask = Task { [weak self, scanner, permissions] in
            do {
                var permissionReport: ScanPermissionReport?
                for try await event in permissions.prepare(request) {
                    try Task.checkCancellation()
                    guard let self, self.scanGeneration == generation else { return }
                    switch event {
                    case .checking(let target): self.progress.checkingAccess(target)
                    case .finished(let report): permissionReport = report
                    }
                }
                try Task.checkCancellation()
                guard let self, self.scanGeneration == generation else { return }
                guard let permissionReport else {
                    throw CocoaError(.fileReadUnknown, userInfo: [
                        NSURLErrorKey: request.url,
                        NSLocalizedDescriptionKey: String(localized: "permission.incomplete", defaultValue: "The access check did not finish. The scan was not started.")
                    ])
                }
                if !permissionReport.denied.isEmpty {
                    self.progress.finish()
                    guard let window = self.window else { self.restoreCompleted(); return }
                    let shouldScan = await self.permissionPrompt.confirm(permissionReport, on: window)
                    try Task.checkCancellation()
                    guard self.scanGeneration == generation else { return }
                    guard shouldScan else { self.restoreCompleted(); return }
                    self.progress.begin(on: window, url: request.url)
                } else {
                    self.progress.beginReading()
                }
                for try await result in scanner.scan(request) {
                    try Task.checkCancellation()
                    guard self.scanGeneration == generation else { return }
                    if let directory, result.isComplete {
                        var details: [URL: DiskIndex] = [:]
                        let refresh = IndexRefresh(url: directory, replacement: result.root.index)
                        let plan = await Task.detached(priority: .userInitiated) {
                            (refresh.requiresFullRescan(for: retainedResults), refresh.detailRequests(for: retainedResults))
                        }.value
                        try Task.checkCancellation()
                        guard self.scanGeneration == generation else { return }
                        if plan.0, let fullRequest = retainedResults.first?.request {
                            self.navigationHistory.removeAll()
                            self.startScan(fullRequest)
                            self.status.display(String(localized: "refresh.fullScan", defaultValue: "New hardlinks cross the cached scan boundary; refreshing the full scan to keep totals correct."))
                            return
                        }
                        for detailRequest in plan.1 {
                            for try await detail in scanner.scan(detailRequest) {
                                try Task.checkCancellation()
                                guard self.scanGeneration == generation else { return }
                                if detail.isComplete { details[detailRequest.url] = detail.root.index }
                                else { self.progress.update(detail) }
                            }
                        }
                        let detailReplacements = details
                        let updated = await Task.detached(priority: .userInitiated) {
                            IndexRefresh(url: directory, replacement: result.root.index, detailReplacements: detailReplacements).apply(to: retainedResults)
                        }.value
                        try Task.checkCancellation()
                        guard self.scanGeneration == generation else { return }
                        self.applyUpdatedResults(updated)
                    } else {
                        self.present(result)
                    }
                }
            } catch is CancellationError {
                // The action replacing/cancelling the scan owns restoration.
            } catch {
                guard let self, self.scanGeneration == generation, !Task.isCancelled else { return }
                self.restoreCompleted()
                self.status.display(String(localized: "overview.failed", defaultValue: "Scan failed") + ": " + error.localizedDescription)
                if let window = self.window { await NSAlert(error: error).beginSheetModal(for: window) }
            }
        }
    }

    /// Incomplete results are progress messages, never drawable document snapshots.
    func present(_ result: ScanResult) {
        guard result.isComplete else { progress.update(result); return }
        progress.finish()
        let previousURL = selected?.url
        let previousAggregate = selected?.isAggregate ?? false
        outlineNodes.removeAll()
        visibleResult = result
        root = result.root
        sizeMode = result.root.index.sizeMode
        map.showPackageContents = showPackageContents
        map.root = result.root
        typeRows = result.root.index.presentationStatistics(for: result.root.id, showPackageContents: showPackageContents)
        synchronizing = true
        outline.reloadData()
        kinds.reloadData()
        outline.deselectAll(nil)
        kinds.deselectAll(nil)
        synchronizing = false
        selected = nil
        map.selectedNode = nil
        map.highlightedKindID = nil
        if let previousURL, let match = result.root.index.find(url: previousURL, aggregate: previousAggregate), isInView(match) {
            select(match, revealTree: true)
        }
        let values = try? result.request.url.resourceValues(forKeys: [.localizedNameKey])
        let title = values?.localizedName ?? result.root.name
        window?.title = "\(title) (\(ScanEntryPresentation.size(result.root)))"
        window?.subtitle = ""
        completedResult = result
        completedHistory = navigationHistory
        pendingRequest = nil
        scanTask = nil
        spinner.stopAnimation(nil)
        volumeSpaceSummary.stringValue = ScanEntryPresentation.volumeSummary(result.root.index)
        volumeSpaceSummary.toolTip = result.root.index.rootURL.path + "\n" + ScanEntryPresentation.volumeExplanation
        showInformation(for: nil)
        updateActions()
    }

    private func isInView(_ node: DiskNode) -> Bool {
        guard let root, node.index === root.index else { return false }
        var current: DiskNode? = node
        while let item = current {
            if item.id == root.id { return true }
            current = item.parent
        }
        return false
    }

    private func restoreCompleted() {
        progress.finish()
        pendingRequest = nil
        scanTask = nil
        navigationHistory = completedHistory
        if let completedResult {
            if visibleResult?.root.index !== completedResult.root.index || visibleResult?.root.id != completedResult.root.id {
                present(completedResult)
            } else { showInformation(for: nil) }
        } else { clearResults() }
        updateActions()
    }

    private func selectFromMap(_ node: DiskNode) {
        guard isInView(node) else { return }
        // AppKit retains expansions below collapsed parents. Fresh UI identities
        // discard that hidden state; the filesystem index and map stay unchanged.
        synchronizing = true
        outlineNodes.removeAll(keepingCapacity: true)
        outline.reloadData()
        select(node, revealTree: true)
    }

    private func select(_ node: DiskNode?, revealTree: Bool) {
        selected = node
        map.selectedNode = node
        map.highlightedKindID = nil
        synchronizing = true
        defer { synchronizing = false; updateActions() }
        if let node {
            if revealTree, let root {
                var ancestors: [DiskNode] = []
                var parent = node.parent
                while let item = parent, item.id != root.id {
                    ancestors.append(item)
                    parent = item.parent
                }
                for ancestor in ancestors.reversed() { outline.expandItem(stableOutlineNode(ancestor)) }
                let row = outline.row(forItem: stableOutlineNode(node))
                if row >= 0 {
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    outline.scrollRowToVisible(row)
                } else { outline.deselectAll(nil) }
            }
            if (!node.isDirectory || node.isPackage && !showPackageContents), !node.isAggregate,
               let row = typeRows.firstIndex(where: { $0.name == node.index.kind(at: node.fileKindID).name }) {
                kinds.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                kinds.scrollRowToVisible(row)
            } else { kinds.deselectAll(nil) }
        } else {
            outline.deselectAll(nil)
            kinds.deselectAll(nil)
        }
        showInformation(for: node)
    }

    private func showInformation(for hovered: DiskNode?) {
        guard let result = visibleResult else { return }
        if let node = hovered ?? selected {
            let details = ScanEntryPresentation.tooltip(node)
            status.display(node.url.path, path: node.url, details: details)
            itemInformation.display(ScanEntryPresentation.details(node), details: details)
            map.toolTip = details
        } else {
            status.display(String.localizedStringWithFormat(
                String(localized: "overview.statistics", defaultValue: "%@ • %lld files • %lld skipped"),
                ScanEntryPresentation.size(result.root), Int64(result.root.fileCount), Int64(result.skippedCount)
            ), details: ScanEntryPresentation.tooltip(result.root))
            itemInformation.display(result.request.url.path, path: result.request.url, details: ScanEntryPresentation.tooltip(result.root))
            map.toolTip = nil
        }
    }

    @objc func refreshSelection() {
        guard !isBusy, window?.attachedSheet == nil, let node = selected,
              !node.isAggregate, node.scanStatus != .automount, node.scanStatus != .cloudOnly,
              node.scanStatus != .otherVolume, !SystemPathPolicy().excludes(node.url) else { return }
        refreshItem(at: node.url, scanRoot: node.index.rootURL)
    }

    private func refreshItem(at url: URL, scanRoot: URL) {
        spinner.startAnimation(nil)
        refreshTask = Task { [weak self, refreshService] in
            guard let self else { return }
            defer { self.refreshTask = nil; self.spinner.stopAnimation(nil); self.updateActions() }
            do {
                let directory = try await refreshService.directory(for: url, scanRoot: scanRoot)
                try Task.checkCancellation()
                self.startScan(ScanRequest(url: directory, sizeMode: self.sizeMode), refreshing: directory)
            } catch {
                if let window = self.window { await NSAlert(error: error).beginSheetModal(for: window) }
            }
        }
        updateActions()
    }

    @objc func rescan() {
        guard !isBusy else { return }
        if let request = navigationHistory.first?.request ?? visibleResult?.request {
            navigationHistory.removeAll()
            startScan(request)
        } else { openVolume() }
    }

    @objc func cancelScan() {
        guard pendingRequest != nil else { return }
        scanTask?.cancel()
        scanGeneration += 1
        restoreCompleted()
        status.display(String(localized: "overview.cancelledEmpty", defaultValue: "Scan cancelled."))
    }

    @objc func zoomSelection() {
        guard !isBusy, let node = selected, let current = visibleResult, node.id != root?.id,
              ScanEntryPresentation.canZoom(node) else { return }
        if node.scanStatus == .otherVolume {
            navigationHistory.append(current)
            startScan(ScanRequest(url: node.url, sizeMode: sizeMode))
        } else if let request = node.groupRequest {
            navigationHistory.append(current)
            startScan(request)
        } else if node.isDirectory {
            navigationHistory.append(current)
            selected = nil
            present(ScanResult(root: node, skippedCount: current.skippedCount, request: ScanRequest(url: node.url, sizeMode: sizeMode), isComplete: true, currentPath: nil, typeStatistics: node.index.presentationStatistics(for: node.id, showPackageContents: showPackageContents)))
        }
    }

    @objc func zoomOut() {
        guard !isBusy, let result = navigationHistory.popLast() else { return }
        let previousURL = root?.url
        selected = nil
        present(result)
        if let previousURL, let node = result.root.index.find(url: previousURL) { select(node, revealTree: true) }
    }

    @objc func selectParent() {
        guard !isBusy, let node = selected, let parent = node.parent, parent.id != root?.id else { return }
        select(parent, revealTree: true)
    }

    @objc func reveal() {
        if let selected { NSWorkspace.shared.activateFileViewerSelecting([selected.url]) }
    }

    @objc func toggleKinds() {
        showKinds.toggle()
        if showKinds { kindsDrawer.open() } else { kindsDrawer.close() }
        updateActions()
    }

    @objc func togglePackageContents() {
        guard !isBusy else { return }
        showPackageContents.toggle()
        if let result = visibleResult { selected = nil; present(result) }
    }

    @objc func togglePhysicalSizes() {
        guard !isBusy, let visibleResult else { return }
        let mode: DiskSizeMode = sizeMode == .physical ? .logical : .physical
        let results = navigationHistory + [visibleResult]
        spinner.startAnimation(nil)
        presentationTask = Task { [weak self] in
            let updated = await Task.detached(priority: .userInitiated) {
                Self.changingSizeMode(of: results, to: mode)
            }.value
            guard let self else { return }
            self.navigationHistory = Array(updated.dropLast())
            if let result = updated.last { self.present(result) }
            self.presentationTask = nil
            self.updateActions()
        }
        updateActions()
    }

    nonisolated private static func changingSizeMode(of results: [ScanResult], to mode: DiskSizeMode) -> [ScanResult] {
        var changed: [ObjectIdentifier: DiskIndex] = [:]
        return results.map { result in
            let key = ObjectIdentifier(result.root.index)
            let index = changed[key] ?? result.root.index.withSizeMode(mode)
            changed[key] = index
            let root = index.find(url: result.root.url, aggregate: result.root.isAggregate) ?? index.root
            return ScanResult(root: root, skippedCount: result.skippedCount, request: ScanRequest(url: result.request.url, fileSelection: result.request.fileSelection, sizeMode: mode, retainedFileNames: result.request.retainedFileNames), isComplete: true, currentPath: nil, typeStatistics: index.presentationStatistics(for: root.id))
        }
    }

    private func updateActions() {
        documentToolbar?.update(
            canZoomIn: !isBusy && selected.map { ScanEntryPresentation.canZoom($0) && $0.id != root?.id } == true,
            canZoomOut: !isBusy && !navigationHistory.isEmpty,
            showingKinds: showKinds
        )
    }

    private var canDeleteSelection: Bool {
        guard !isBusy, window?.attachedSheet == nil, let selected, let root,
              selected.index === root.index, !selected.isAggregate, selected.scanStatus == .complete,
              selected.id != root.id, selected.id != 0,
              !SystemPathPolicy().excludes(selected.url) else { return false }
        return true
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(deletePermanently): return canDeleteSelection
        case #selector(moveToTrash): return canDeleteSelection
        case #selector(refreshSelection):
            return !isBusy && window?.attachedSheet == nil && selected.map {
                !$0.isAggregate && $0.scanStatus != .automount && $0.scanStatus != .cloudOnly
                    && $0.scanStatus != .otherVolume && !SystemPathPolicy().excludes($0.url)
            } == true
        case #selector(zoomSelection): return documentToolbar?.zoomIn.isEnabled == true
        case #selector(zoomOut): return documentToolbar?.zoomOut.isEnabled == true
        case #selector(reveal): return !isBusy && selected != nil
        case #selector(selectParent): return !isBusy && selected?.parent != nil && selected?.parent?.id != root?.id
        case #selector(togglePackageContents): menuItem.state = showPackageContents ? .on : .off; return !isBusy && root != nil
        case #selector(togglePhysicalSizes): menuItem.state = sizeMode == .physical ? .on : .off; return !isBusy && root != nil
        case #selector(toggleKinds):
            menuItem.title = showKinds
                ? String(localized: "ui.hideKinds", defaultValue: "Hide File Kind Statistics")
                : String(localized: "ui.showKinds", defaultValue: "Show File Kind Statistics")
            return true
        default: return !isBusy
        }
    }

    @objc func deletePermanently() { removeSelection(permanently: true) }

    @objc func moveToTrash() { removeSelection(permanently: false) }

    private func removeSelection(permanently: Bool) {
        guard canDeleteSelection, let node = selected, let result = visibleResult, let window else { NSSound.beep(); return }
        let results = navigationHistory + [result]
        let mutation = IndexDeletion(url: node.url, logicalSize: node.logicalSize, allocatedSize: node.allocatedSize, kindIdentifier: node.kindIdentifier)
        deletionTask = Task { [weak self, deletionService] in
            guard let self else { return }
            defer { self.deletionTask = nil; self.updateActions() }
            let target: PermanentDeletionTarget
            do { target = try await deletionService.prepare(url: node.url, scanRoot: node.index.rootURL) }
            catch { await NSAlert(error: error).beginSheetModal(for: window); return }
            if permanently {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = String.localizedStringWithFormat(String(localized: "delete.title", defaultValue: "Delete “%@” permanently?"), node.name)
                alert.informativeText = String.localizedStringWithFormat(String(localized: "delete.warning", defaultValue: "%@\n\nThis bypasses the Trash and cannot be undone. If this is a folder, all its contents will be deleted."), target.url.path)
                alert.addButton(withTitle: String(localized: "delete.cancel", defaultValue: "Cancel"))
                let delete = alert.addButton(withTitle: String(localized: "delete.confirm", defaultValue: "Delete Permanently"))
                delete.hasDestructiveAction = true
                guard await alert.beginSheetModal(for: window) == .alertSecondButtonReturn else { return }
            }
            self.spinner.startAnimation(nil)
            self.status.display((permanently
                ? String(localized: "delete.progress", defaultValue: "Deleting permanently…")
                : String(localized: "trash.progress", defaultValue: "Moving to Trash…")) + " — " + target.url.path)
            do {
                let destination: URL?
                if permanently { destination = nil }
                else { destination = try await deletionService.trash(target) }
                let updated = try await Task.detached(priority: .userInitiated) {
                    if permanently { try await deletionService.remove(target) }
                    return mutation.apply(to: results)
                }.value
                self.applyUpdatedResults(updated)
                self.status.display((permanently
                    ? String(localized: "delete.done", defaultValue: "Deleted permanently; map and index updated.")
                    : String(localized: "trash.done", defaultValue: "Moved to Trash; map and index updated.")) + " — " + self.format(self.root?.size ?? 0))
                if let destination, let index = updated.first(where: { ScanPermissionScope.contains($0.root.index.rootURL, destination) })?.root.index {
                    let directory = await Task.detached(priority: .userInitiated) {
                        let scope = ScanPermissionScope(request: ScanRequest(url: index.rootURL))
                        var candidate = scope.target(for: destination.deletingLastPathComponent(), kind: .selectedRoot)?.url ?? index.rootURL
                        while index.find(url: candidate) == nil && candidate.pathComponents.count > index.rootURL.pathComponents.count {
                            candidate.deleteLastPathComponent()
                        }
                        return candidate
                    }.value
                    self.deletionTask = nil
                    self.startScan(ScanRequest(url: directory, sizeMode: self.sizeMode), refreshing: directory)
                }
            } catch {
                if !permanently {
                    self.spinner.stopAnimation(nil)
                    await NSAlert(error: error).beginSheetModal(for: window)
                    self.deletionTask = nil
                    self.refreshItem(at: target.url, scanRoot: node.index.rootURL)
                    return
                }
                let request = results.first?.request ?? result.request
                self.scanGeneration += 1
                self.navigationHistory.removeAll()
                self.completedHistory.removeAll()
                self.completedResult = nil
                self.clearResults()
                self.spinner.stopAnimation(nil)
                await NSAlert(error: error).beginSheetModal(for: window)
                self.deletionTask = nil
                self.startScan(request)
            }
        }
        updateActions()
    }

    private func applyUpdatedResults(_ results: [ScanResult]) {
        guard let current = results.last else { return }
        let state = visibleResult.map {
            OutlineViewState(outline: outline, loadedItems: outlineNodes.values, root: $0.root, selected: selected)
        }
        navigationHistory = Array(results.dropLast())
        selected = nil
        present(current)
        if let state {
            synchronizing = true
            let selection = state.restore(in: outline, root: current.root) { stableOutlineNode($0) }
            synchronizing = false
            select(selection, revealTree: false)
        }
    }

    private func clearResults() {
        visibleResult = nil
        root = nil
        selected = nil
        map.root = nil
        outlineNodes.removeAll()
        synchronizing = true
        outline.reloadData()
        typeRows.removeAll()
        kinds.reloadData()
        synchronizing = false
        status.display(String(localized: "ui.choose", defaultValue: "Choose a folder or volume to scan."))
        itemInformation.display("")
        map.toolTip = nil
        volumeSpaceSummary.stringValue = ""
    }

    private func stableOutlineNode(_ node: DiskNode) -> DiskNode {
        if let cached = outlineNodes[node.id] { return cached }
        outlineNodes[node.id] = node
        return node
    }

    private func format(_ size: Int64) -> String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? DiskNode ?? root else { return 0 }
        if node.isPackage, node.id != root?.id, !showPackageContents { return 0 }
        return node.index.childIDs(of: node.id).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let node = (item as? DiskNode) ?? root!
        let ids = node.index.childIDs(of: node.id)
        return stableOutlineNode(node.index.node(at: ids[ids.startIndex + index]))
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        let node = item as! DiskNode
        return node.isDirectory && !node.isAggregate && (!node.isPackage || showPackageContents) && !node.index.childIDs(of: node.id).isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let node = item as! DiskNode
        let isSize = tableColumn?.identifier.rawValue == "size"
        let cell = NSTextField(labelWithString: isSize ? ScanEntryPresentation.size(node) : ScanEntryPresentation.name(node))
        cell.lineBreakMode = .byTruncatingMiddle
        cell.font = .systemFont(ofSize: NSFont.systemFontSize)
        cell.toolTip = ScanEntryPresentation.tooltip(node)
        if node.scanStatus != .complete || ScanEntryPresentation.isSharedAlias(node) { cell.textColor = .secondaryLabelColor }
        if isSize { cell.alignment = .right; return cell }
        let symbol = node.scanStatus != .complete ? "exclamationmark.triangle" : node.isAggregate ? "square.stack.3d.up" : (node.isPackage ? "app.fill" : node.isDirectory ? "folder.fill" : "doc")
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.contentTintColor = node.isDirectory && !node.isPackage ? .systemBlue : .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16)])
        let stack = NSStackView(views: [icon, cell])
        stack.spacing = 4
        stack.toolTip = ScanEntryPresentation.tooltip(node)
        return stack
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !synchronizing else { return }
        select(outline.item(atRow: outline.selectedRow) as? DiskNode, revealTree: false)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !synchronizing else { return }
        let row = kinds.selectedRow
        map.highlightedKindID = row >= 0 ? typeRows[row].kindID : nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { typeRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = typeRows[row]
        let identifier = NSUserInterfaceItemIdentifier("kind-\(tableColumn?.identifier.rawValue ?? "")")
        if tableColumn?.identifier.rawValue == "color" {
            let swatch = tableView.makeView(withIdentifier: identifier, owner: self) as? KindSwatchView ?? KindSwatchView()
            swatch.identifier = identifier
            swatch.color = map.color(for: item.kindID)
            return swatch
        }
        let isSize = tableColumn?.identifier.rawValue == "bytes"
        let isCount = tableColumn?.identifier.rawValue == "count"
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField ?? NSTextField(labelWithString: "")
        cell.identifier = identifier
        cell.stringValue = isSize ? format(item.size) : isCount ? item.count.formatted() : item.name
        cell.font = .systemFont(ofSize: NSFont.systemFontSize)
        cell.lineBreakMode = .byTruncatingTail
        cell.alignment = isSize || isCount ? .right : .left
        cell.toolTip = String.localizedStringWithFormat(String(localized: "ui.kindCount", defaultValue: "%@ • %lld files"), item.name, Int64(item.count))
        return cell
    }
}
