import AppKit

@MainActor
final class KindSwatchView: NSView {
    var color: NSColor = .gray {
        didSet {
            guard color != oldValue else { return }
            raster = nil
            needsDisplay = true
        }
    }
    private var raster: NSImage?

    override func setFrameSize(_ newSize: NSSize) {
        if frame.size != newSize { raster = nil }
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        raster = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if raster == nil {
            let scale = window?.backingScaleFactor ?? 1
            let rect = NSRect(x: 0, y: 0, width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
            guard rect.width > 0, rect.height > 0,
                  let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(rect.width), pixelsHigh: Int(rect.height),
                    bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                    colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
                  ) else { return }
            let surface = OriginalCushionSurface().addingRidge(in: rect, heightFactor: 0.5)
            OriginalCushionRenderer.render(rect: rect, surface: surface, color: color, into: bitmap)
            let image = NSImage(size: bounds.size)
            image.addRepresentation(bitmap)
            raster = image
        }
        raster?.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
    }
}
