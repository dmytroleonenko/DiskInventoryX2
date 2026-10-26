import AppKit

@MainActor
final class InventoryToolbar: NSObject, NSToolbarDelegate {
    let toolbar = NSToolbar(identifier: "NativeDocumentToolbar")
    let zoomIn = NSToolbarItem(itemIdentifier: .init("zoomIn"))
    let zoomOut = NSToolbarItem(itemIdentifier: .init("zoomOut"))
    let kinds = NSToolbarItem(itemIdentifier: .init("fileKinds"))

    init(target: InventoryWindowController) {
        super.init()
        configure(zoomIn, title: String(localized: "ui.zoomIn", defaultValue: "Zoom In"), symbol: "plus.magnifyingglass", target: target, action: #selector(InventoryWindowController.zoomSelection))
        configure(zoomOut, title: String(localized: "ui.zoomOut", defaultValue: "Zoom Out"), symbol: "minus.magnifyingglass", target: target, action: #selector(InventoryWindowController.zoomOut))
        configure(kinds, title: String(localized: "ui.hideKinds", defaultValue: "Hide File Kind Statistics"), symbol: "chart.bar", target: target, action: #selector(InventoryWindowController.toggleKinds))
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.sizeMode = .regular
    }

    func update(canZoomIn: Bool, canZoomOut: Bool, showingKinds: Bool) {
        zoomIn.isEnabled = canZoomIn
        zoomOut.isEnabled = canZoomOut
        let title = showingKinds
            ? String(localized: "ui.hideKinds", defaultValue: "Hide File Kind Statistics")
            : String(localized: "ui.showKinds", defaultValue: "Show File Kind Statistics")
        kinds.label = title
        kinds.paletteLabel = title
        kinds.toolTip = title
    }

    private func configure(_ item: NSToolbarItem, title: String, symbol: String, target: InventoryWindowController, action: Selector) {
        item.label = title
        item.paletteLabel = title
        item.toolTip = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.target = target
        item.action = action
        item.autovalidates = false
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [zoomIn.itemIdentifier, zoomOut.itemIdentifier, .flexibleSpace, kinds.itemIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case zoomIn.itemIdentifier: zoomIn
        case zoomOut.itemIdentifier: zoomOut
        case kinds.itemIdentifier: kinds
        default: nil
        }
    }
}
