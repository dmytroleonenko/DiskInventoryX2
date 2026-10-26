import AppKit

/// A metadata label becomes a copy action only while it displays a real path.
@MainActor
final class CopyablePathField: NSTextField {
    private let pasteboard: NSPasteboard
    private var content = ""
    private var path: String?
    var ordinaryTextColor: NSColor = .labelColor

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
    }

    required init?(coder: NSCoder) { fatalError("Use init(pasteboard:)") }

    func display(_ text: String, path url: URL? = nil, details: String? = nil) {
        let newPath = url?.path
        if let newPath {
            let help = String(localized: "path.copy.help", defaultValue: "Click to copy the full path")
            toolTip = [help, details ?? newPath].joined(separator: "\n\n")
        } else {
            toolTip = details
        }
        guard text != content || newPath != path else { return }
        content = text
        path = newPath
        render(copyResult: nil)
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if path != nil { addCursorRect(visibleRect, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        guard path != nil else { super.mouseDown(with: event); return }
        _ = copyPath()
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        path == nil ? .staticText : .button
    }

    override func accessibilityLabel() -> String? { stringValue }
    override func accessibilityHelp() -> String? { toolTip }
    override func accessibilityPerformPress() -> Bool { copyPath() }

    private func copyPath() -> Bool {
        guard let path else { return false }
        pasteboard.clearContents()
        let copied = pasteboard.setString(path, forType: .string)
        render(copyResult: copied)
        NSAccessibility.post(element: self, notification: .valueChanged)
        return copied
    }

    private func render(copyResult: Bool?) {
        let text: String
        let color: NSColor
        switch copyResult {
        case true?:
            text = String.localizedStringWithFormat(String(localized: "path.copy.done", defaultValue: "Copied — %@"), content)
            color = .systemGreen
        case false?:
            text = String.localizedStringWithFormat(String(localized: "path.copy.failed", defaultValue: "Couldn’t copy — %@"), content)
            color = .systemRed
        case nil:
            text = content
            color = path == nil ? ordinaryTextColor : .linkColor
        }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: color
        ]
        if path != nil { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        attributedStringValue = NSAttributedString(string: text, attributes: attributes)
    }
}
