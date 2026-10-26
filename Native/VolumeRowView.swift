import AppKit

@MainActor
final class VolumeRowView: NSTableCellView {
    private var volume: DiskVolume?
    private var maximumCapacity: Int64 = 0
    private var icon: NSImage?
    private var nameText = NSAttributedString()
    private var formatText = NSAttributedString()
    private var capacityText = NSAttributedString()
    private var usedText = NSAttributedString()
    private var freeText = NSAttributedString()

    override var isFlipped: Bool { true }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    func configure(with volume: DiskVolume, maximumCapacity: Int64) {
        if self.volume?.url != volume.url { icon = NSWorkspace.shared.icon(forFile: volume.url.path) }
        self.volume = volume
        self.maximumCapacity = maximumCapacity
        toolTip = volume.url.path + (volume.isStartup ? " — " + String(localized: "volumes.startup", defaultValue: "Startup Disk") : "")
        nameText = text(volume.name, bold: true, size: 13)
        formatText = text(volume.formatDescription ?? "—", size: 11)
        capacityText = text(String(localized: "volumes.capacity", defaultValue: "Capacity") + ": " + bytes(volume.totalCapacity), bold: true, alignRight: true)
        usedText = text(String(localized: "volumes.used", defaultValue: "Used") + ": " + bytes(volume.usedCapacity), alignRight: true)
        freeText = text(String(localized: "volumes.free", defaultValue: "Free") + ": " + bytes(volume.availableCapacity), alignRight: true)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel([nameText.string, formatText.string, capacityText.string, usedText.string, freeText.string, volume.url.path].joined(separator: ", "))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let volume else { return }
        icon?.draw(in: NSRect(x: 8, y: (bounds.height - 28) / 2, width: 28, height: 28), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let metricsX: CGFloat = 202
        let metricsWidth: CGFloat = 128
        nameText.draw(in: NSRect(x: 50, y: 5, width: metricsX - 58, height: 18))
        formatText.draw(in: NSRect(x: 54, y: 24, width: metricsX - 62, height: 16))
        capacityText.draw(in: NSRect(x: metricsX, y: 2, width: metricsWidth, height: 14))
        usedText.draw(in: NSRect(x: metricsX, y: 16, width: metricsWidth, height: 14))
        freeText.draw(in: NSRect(x: metricsX, y: 30, width: metricsWidth, height: 14))
        guard let capacity = volume.totalCapacity, capacity > 0,
              let usedFraction = volume.usedFraction, maximumCapacity > 0 else { return }
        let barX = metricsX + metricsWidth + 20
        let availableWidth = max(0, bounds.width - barX - 16)
        // Preserve the original's capacity comparison, with a 20% minimum for small volumes.
        let capacityScale = max(0.2, min(1, Double(capacity) / Double(maximumCapacity)))
        let track = NSRect(x: barX, y: (bounds.height - 6) / 2, width: availableWidth * capacityScale, height: 6)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        if usedFraction > 0 {
            var filled = track
            filled.size.width *= usedFraction
            NSColor.secondaryLabelColor.setFill()
            NSBezierPath(roundedRect: filled, xRadius: 3, yRadius: 3).fill()
        }
    }

    private func bytes(_ value: Int64?) -> String {
        value.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
    }

    private func text(_ value: String, bold: Bool = false, size: CGFloat = 11, alignRight: Bool = false) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = alignRight ? .right : .left
        return NSAttributedString(string: value, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style
        ])
    }
}
