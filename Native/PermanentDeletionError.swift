import Foundation

enum PermanentDeletionError: LocalizedError {
    case protectedLocation
    case changedItem
    case nestedVolume

    var errorDescription: String? {
        switch self {
        case .protectedLocation:
            String(localized: "delete.protected", defaultValue: "System service paths, the scan root, mounted volumes and synthetic groups cannot be deleted.")
        case .changedItem:
            String(localized: "delete.changed", defaultValue: "The selected item changed since confirmation. Rescan before deleting it.")
        case .nestedVolume:
            String(localized: "delete.nestedVolume", defaultValue: "This folder contains another mounted filesystem. Unmount it before deleting the folder.")
        }
    }
}
