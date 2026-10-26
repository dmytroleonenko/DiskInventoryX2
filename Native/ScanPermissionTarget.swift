import Foundation

/// A read-only directory probe inside the selected traversal scope.
struct ScanPermissionTarget: Sendable, Equatable {
    enum Kind: Sendable, Hashable {
        case selectedRoot, documents, desktop, downloads, photos, contacts
        case calendars, reminders, mediaLibrary, cloudStorage
        case applicationData, applicationBundles, fullDiskAccess
    }

    let url: URL
    let kind: Kind
}
