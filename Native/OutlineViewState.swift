import AppKit

/// Keeps only expanded UI items and viewport anchors, not a second filesystem tree.
@MainActor
struct OutlineViewState {
    private struct Item {
        let url: URL
        let aggregate: Bool

        init(_ node: DiskNode) {
            url = node.url
            aggregate = node.isAggregate
        }

        func resolve(in index: DiskIndex) -> DiskNode? {
            index.find(url: url, aggregate: aggregate)
        }
    }

    private let expanded: [Item]
    private let selectionCandidates: [Item]
    private let selectedRow: Int
    private let anchors: [(item: Item, offset: CGFloat)]
    private let origin: NSPoint

    init(outline: NSOutlineView, loadedItems: some Sequence<DiskNode>, root: DiskNode, selected: DiskNode?) {
        var expandedRows: [(row: Int, item: Item)] = []
        for node in loadedItems where node.isDirectory && outline.isItemExpanded(node) {
            let row = outline.row(forItem: node)
            if row >= 0 { expandedRows.append((row, Item(node))) }
        }
        // Visible row order puts expanded ancestors before their children.
        expanded = expandedRows.sorted { $0.row < $1.row }.map { $0.item }

        var candidates: [Item] = []
        if let selected {
            candidates.append(Item(selected))
            var parent = selected.parent
            while let node = parent, node.id != root.id {
                candidates.append(Item(node))
                parent = node.parent
            }
        }
        selectionCandidates = candidates
        selectedRow = outline.selectedRow
        origin = outline.visibleRect.origin

        var visibleAnchors: [(item: Item, offset: CGFloat)] = []
        let visibleRows = outline.rows(in: outline.visibleRect)
        if visibleRows.location != NSNotFound {
            for row in visibleRows.location..<min(NSMaxRange(visibleRows), outline.numberOfRows) {
                if let node = outline.item(atRow: row) as? DiskNode {
                    visibleAnchors.append((Item(node), outline.rect(ofRow: row).minY - origin.y))
                }
            }
        }
        anchors = visibleAnchors
    }

    /// Resolves paths into the rebuilt index because deletion can renumber every retained ID.
    func restore(in outline: NSOutlineView, root: DiskNode, item: (DiskNode) -> DiskNode) -> DiskNode? {
        for saved in expanded {
            guard let node = saved.resolve(in: root.index) else { continue }
            outline.expandItem(item(node))
        }

        var selection: DiskNode?
        for candidate in selectionCandidates {
            if let node = candidate.resolve(in: root.index) {
                selection = item(node)
                break
            }
        }
        if selection == nil, selectedRow >= 0, outline.numberOfRows > 0 {
            selection = outline.item(atRow: min(selectedRow, outline.numberOfRows - 1)) as? DiskNode
        }
        let row = selection.map { outline.row(forItem: $0) } ?? -1
        if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        else { outline.deselectAll(nil) }
        outline.layoutSubtreeIfNeeded()

        if let scroll = outline.enclosingScrollView {
            var restoredOrigin = origin
            var restoredAnchor = false
            for anchor in anchors {
                guard let node = anchor.item.resolve(in: root.index) else { continue }
                let anchorRow = outline.row(forItem: item(node))
                guard anchorRow >= 0 else { continue }
                restoredOrigin.y = outline.rect(ofRow: anchorRow).minY - anchor.offset
                restoredAnchor = true
                break
            }
            if !restoredAnchor, row >= 0 { restoredOrigin.y = outline.rect(ofRow: row).minY }
            let clip = scroll.contentView
            var bounds = clip.bounds
            bounds.origin = restoredOrigin
            clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
            scroll.reflectScrolledClipView(clip)
        }
        return selection
    }
}
