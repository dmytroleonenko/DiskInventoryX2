import AppKit

@MainActor
final class InventoryApplication: NSObject, NSApplicationDelegate {
    private var controller: InventoryWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = InventoryWindowController(permissions: ScanPermissionService())
        self.controller = controller
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: String(localized: "ui.about", defaultValue: "About Disk Inventory X2"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "ui.quit", defaultValue: "Quit Disk Inventory X2"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, to: main)
        let file = NSMenu(title: String(localized: "ui.file", defaultValue: "File"))
        file.addItem(item(String(localized: "ui.open", defaultValue: "Open Folder…"), action: #selector(InventoryWindowController.openFolder), key: "o"))
        file.addItem(item(String(localized: "ui.volumes", defaultValue: "Volumes…"), action: #selector(InventoryWindowController.openVolume), key: "o", modifiers: [.command, .shift]))
        file.addItem(.separator())
        file.addItem(item(String(localized: "ui.rescan", defaultValue: "Rescan All"), action: #selector(InventoryWindowController.rescan), key: "r"))
        file.addItem(item(String(localized: "refresh.selection", defaultValue: "Refresh Selection"), action: #selector(InventoryWindowController.refreshSelection)))
        file.addItem(item(String(localized: "ui.reveal", defaultValue: "Reveal in Finder"), action: #selector(InventoryWindowController.reveal), key: "r", modifiers: [.command, .shift]))
        file.addItem(.separator())
        file.addItem(item(String(localized: "trash.menu", defaultValue: "Move to Trash"), action: #selector(InventoryWindowController.moveToTrash), key: "\u{8}", modifiers: [.command]))
        file.addItem(item(String(localized: "delete.menu", defaultValue: "Delete Permanently…"), action: #selector(InventoryWindowController.deletePermanently), key: "\u{8}", modifiers: [.shift]))
        file.addItem(withTitle: String(localized: "ui.close", defaultValue: "Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(file, to: main)
        let view = NSMenu(title: String(localized: "ui.view", defaultValue: "View"))
        view.addItem(item(String(localized: "ui.zoomIn", defaultValue: "Zoom In"), action: #selector(InventoryWindowController.zoomSelection), key: "+"))
        view.addItem(item(String(localized: "ui.zoomOut", defaultValue: "Zoom Out"), action: #selector(InventoryWindowController.zoomOut), key: "-"))
        view.addItem(item(String(localized: "ui.selectParent", defaultValue: "Select Parent"), action: #selector(InventoryWindowController.selectParent)))
        view.addItem(.separator())
        view.addItem(item(String(localized: "ui.packageContents", defaultValue: "Show Package Contents"), action: #selector(InventoryWindowController.togglePackageContents)))
        view.addItem(item(String(localized: "ui.physicalSizes", defaultValue: "Use Physical File Sizes"), action: #selector(InventoryWindowController.togglePhysicalSizes)))
        view.addItem(item(String(localized: "ui.fileKinds", defaultValue: "File Kind Statistics"), action: #selector(InventoryWindowController.toggleKinds)))
        add(view, to: main)
        NSApplication.shared.mainMenu = main
        controller.showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let path = ProcessInfo.processInfo.arguments.dropFirst().first {
            controller.scan(URL(fileURLWithPath: path))
        } else { controller.openVolume() }
    }

    private func item(_ title: String, action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = controller
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private func add(_ menu: NSMenu, to main: NSMenu) {
        let item = NSMenuItem()
        item.submenu = menu
        main.addItem(item)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.showWindow(nil)
        return true
    }
}

@main
struct InventoryMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = InventoryApplication()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
