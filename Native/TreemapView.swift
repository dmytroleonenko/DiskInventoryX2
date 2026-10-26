import AppKit

@MainActor
final class TreemapView: NSView {
    var root: DiskNode? {
        didSet {
            if !sameNode(root, oldValue) { selectedNode = nil }
            reservePalette()
            refreshHighlightedKinds()
            invalidateLayout()
        }
    }
    var selectedNode: DiskNode? {
        didSet {
            guard !sameNode(selectedNode, oldValue) else { return }
            selectionRects = nil
            needsDisplay = true
        }
    }
    var highlightedKindID: UInt32? {
        didSet {
            guard highlightedKindID != oldValue else { return }
            refreshHighlightedKinds()
            needsDisplay = true
        }
    }
    var showPackageContents = false {
        didSet {
            guard showPackageContents != oldValue else { return }
            paletteIndex = nil
            reservePalette()
            invalidateLayout()
        }
    }
    var onSelect: ((DiskNode) -> Void)?
    var onOpen: ((DiskNode) -> Void)?
    var onHover: ((DiskNode?) -> Void)?
    private var highlightedKinds: Set<UInt32> = []

    /// Only resolvable leaves retain geometry, never paths or per-file model wrappers.
    private struct Cell {
        let id: Int32
        let kind: UInt32
        let x: Int32
        let y: Int32
        let width: Int32
        let height: Int32

        init(id: Int, kind: UInt32, rect: NSRect) {
            self.id = Int32(id)
            self.kind = kind
            x = Int32(rect.minX)
            y = Int32(rect.minY)
            width = Int32(rect.width)
            height = Int32(rect.height)
        }

        var rect: NSRect { NSRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height)) }
    }

    private struct Work {
        let id: Int
        let rect: NSRect
        let surface: OriginalCushionSurface
        let height: Float
        let syntheticKind: UInt32?
    }

    private var cells: [Cell] = []
    private var raster: NSImage?
    private var laidOutSize: NSSize?
    private var selectionRects: [NSRect]?
    private var palette = FilePalette()
    private var paletteIndex: DiskIndex?
    private var hoverTrackingArea: NSTrackingArea?
    private var hoveredNode: DiskNode?
    private var scale: CGFloat { window?.backingScaleFactor ?? 1 }
    private let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func color(for kindID: UInt32) -> NSColor {
        guard let root else { return .gray }
        reservePalette()
        return palette.color(for: root.index.kind(at: kindID).name)
    }

    private func reservePalette() {
        guard let root else {
            paletteIndex = nil
            return
        }
        guard paletteIndex !== root.index else { return }
        palette.reserve(
            statistics: root.index.presentationStatistics(for: 0, showPackageContents: showPackageContents),
            in: root.index
        )
        paletteIndex = root.index
    }

    private func refreshHighlightedKinds() {
        guard let root, let highlightedKindID, Int(highlightedKindID) < root.index.kinds.count else {
            highlightedKinds.removeAll()
            return
        }
        let name = root.index.kind(at: highlightedKindID).name
        highlightedKinds = Set(root.index.kinds.enumerated().compactMap {
            $0.element.name == name ? UInt32($0.offset) : nil
        })
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { invalidateLayout() }
    }

    override func setBoundsSize(_ newSize: NSSize) {
        let changed = bounds.size != newSize
        super.setBoundsSize(newSize)
        if changed { invalidateLayout() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        invalidateLayout()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(tracking)
        hoverTrackingArea = tracking
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        ensureRaster()
        guard let node = node(at: convert(event.locationInWindow, from: nil)) else { return }
        selectedNode = node
        onSelect?(node)
        if event.clickCount == 2 { onOpen?(node) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        ensureRaster()
        if let node = node(at: convert(event.locationInWindow, from: nil)) {
            selectedNode = node
            onSelect?(node)
            window?.makeFirstResponder(self)
        }
        return super.menu(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        clearHover()
    }

    override func draw(_ dirtyRect: NSRect) {
        ensureRaster()
        guard let raster else {
            NSColor.black.setFill()
            dirtyRect.fill()
            return
        }
        raster.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        if !highlightedKinds.isEmpty, let context = NSGraphicsContext.current?.cgContext {
            context.setStrokeColor(NSColor.yellow.cgColor)
            context.setLineWidth(2)
            for cell in cells where highlightedKinds.contains(cell.kind) {
                let rect = viewRect(cell.rect)
                if rect.intersects(dirtyRect) { context.stroke(rect) }
            }
        }
        if selectionRects == nil { selectionRects = selectedRects() }
        NSColor.yellow.setStroke()
        for rect in selectionRects ?? [] where rect.intersects(dirtyRect) {
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 2
            path.stroke()
        }
    }


    private func invalidateLayout() {
        raster = nil
        laidOutSize = nil
        cells.removeAll()
        selectionRects = nil
        clearHover()
        needsDisplay = true
    }

    private func clearHover() {
        guard hoveredNode != nil else { return }
        hoveredNode = nil
        toolTip = nil
        onHover?(nil)
    }

    private func updateHover(at point: NSPoint) {
        ensureRaster()
        let current = node(at: point)
        guard !sameNode(current, hoveredNode) else { return }
        hoveredNode = current
        if let current {
            toolTip = current.name + "\n" + current.url.path + "\n" + sizeFormatter.string(fromByteCount: current.size)
        } else {
            toolTip = nil
        }
        onHover?(current)
    }

    private func sameNode(_ first: DiskNode?, _ second: DiskNode?) -> Bool {
        switch (first, second) {
        case (nil, nil): true
        case let (first?, second?): first.index === second.index && first.id == second.id
        default: false
        }
    }

    private var backingSize: NSSize {
        NSSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
    }

    private func ensureRaster() {
        let size = backingSize
        guard laidOutSize != size else { return }
        laidOutSize = size
        cells.removeAll(keepingCapacity: true)
        guard let root, size.width > 0, size.height > 0,
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
              ), let pixels = bitmap.bitmapData else { return }
        pixels.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        var colors: [UInt32: NSColor] = [:]
        var work = [Work(id: root.id, rect: NSRect(origin: .zero, size: size), surface: OriginalCushionSurface(), height: 0.5, syntheticKind: nil)]
        while let next = work.popLast() {
            // Match TMVItem's point-sized cutoff, not an arbitrary tile-count cap.
            guard next.rect.width >= scale, next.rect.height >= scale else { continue }
            let surface = next.id == root.id && next.syntheticKind == nil
                ? next.surface : next.surface.addingRidge(in: next.rect, heightFactor: next.height)
            let entry = root.index.entry(at: next.id)
            let isNode = next.syntheticKind == nil && entry.isDirectory
                && (next.id == root.id || !entry.isPackage || showPackageContents)
            if isNode {
                let children = TreemapChildren(index: root.index, parent: next.id, rect: next.rect, scale: scale)
                let childHeight: Float = next.height * 0.9
                OriginalTreemapLayout.layout(
                    count: children.count, totalWeight: root.index.size(of: next.id), in: next.rect,
                    weight: { children.item(at: $0).size }
                ) { child, rect in
                    guard rect.width >= scale, rect.height >= scale else { return }
                    let item = children.item(at: child)
                    work.append(Work(id: item.id, rect: rect, surface: surface, height: childHeight, syntheticKind: item.synthetic ? item.kind : nil))
                }
            } else if !entry.isAggregate || next.syntheticKind != nil {
                let kind = next.syntheticKind ?? entry.kind
                let color: NSColor
                if let cached = colors[kind] { color = cached } else {
                    color = self.color(for: kind)
                    colors[kind] = color
                }
                OriginalCushionRenderer.render(rect: next.rect, surface: surface, color: color, into: bitmap)
                cells.append(Cell(id: next.id, kind: kind, rect: next.rect))
            }
        }
        bitmap.size = bounds.size
        let tagged = window?.colorSpace.flatMap { bitmap.retagging(with: $0) } ?? bitmap
        let image = NSImage(size: bounds.size)
        image.addRepresentation(tagged)
        raster = image
    }

    private func viewRect(_ rect: NSRect) -> NSRect {
        NSRect(x: bounds.minX + rect.minX / scale, y: bounds.minY + rect.minY / scale,
               width: rect.width / scale, height: rect.height / scale)
    }

    private func node(at point: NSPoint) -> DiskNode? {
        guard let root, bounds.contains(point) else { return nil }
        let x = (point.x - bounds.minX) * scale
        let y = (point.y - bounds.minY) * scale
        guard let cell = cells.first(where: {
            x >= CGFloat($0.x) && x < CGFloat($0.x + $0.width)
                && y >= CGFloat($0.y) && y < CGFloat($0.y + $0.height)
        }) else { return nil }
        return root.index.node(at: Int(cell.id))
    }

    private func selectedRects() -> [NSRect] {
        guard let selectedNode, let root, selectedNode.index === root.index else { return [] }
        // Members have no individual identity: frame their containing directory,
        // not tens of thousands of invented, individually selectable file cells.
        let item = selectedNode.isAggregate ? selectedNode.parent ?? selectedNode : selectedNode
        var path: [Int] = []
        var current = item.id
        while current != root.id {
            path.append(current)
            let parent = Int(root.index.entry(at: current).parent)
            guard parent >= 0 else { return [] }
            current = parent
        }
        var rect = NSRect(origin: .zero, size: backingSize)
        current = root.id
        for target in path.reversed() {
            let entry = root.index.entry(at: current)
            guard rect.width >= scale, rect.height >= scale,
                  current == root.id || !entry.isPackage || showPackageContents else { return [] }
            let children = TreemapChildren(index: root.index, parent: current, rect: rect, scale: scale)
            var found: NSRect?
            OriginalTreemapLayout.layout(
                count: children.count, totalWeight: root.index.size(of: current), in: rect,
                weight: { children.item(at: $0).size }
            ) { child, childRect in
                if children.item(at: child).id == target { found = childRect }
            }
            guard let found else { return [] }
            rect = found
            current = target
        }
        guard rect.width >= scale, rect.height >= scale else { return [] }
        return [viewRect(rect)]
    }
}
