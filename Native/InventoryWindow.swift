import AppKit

@MainActor
final class InventoryWindow: NSWindow {
    var onPermanentDelete: (() -> Void)?
    var onMoveToTrash: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.shift, .command, .control, .option])
        if event.type == .keyDown, event.keyCode == 51 || event.keyCode == 117,
           !event.isARepeat, attachedSheet == nil, !(firstResponder is NSTextView) {
            if modifiers == .shift, let onPermanentDelete {
                onPermanentDelete()
                return
            }
            if modifiers == .command, let onMoveToTrash {
                onMoveToTrash()
                return
            }
        }
        super.sendEvent(event)
    }
}
