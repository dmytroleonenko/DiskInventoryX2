import AppKit

@MainActor
final class InventoryOutlineView: NSOutlineView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        window?.makeFirstResponder(self)
        return super.menu(for: event)
    }
}
