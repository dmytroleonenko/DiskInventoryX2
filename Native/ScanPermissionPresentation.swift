import Foundation

/// Presentation describes the probed location, not a claim about its TCC authorization.
struct ScanPermissionPresentation {
    static func category(_ kind: ScanPermissionTarget.Kind) -> String {
        switch kind {
        case .selectedRoot: String(localized: "permissions.category.selectedRoot", defaultValue: "Selected folder or volume")
        case .documents: String(localized: "permissions.category.documents", defaultValue: "Documents")
        case .desktop: String(localized: "permissions.category.desktop", defaultValue: "Desktop")
        case .downloads: String(localized: "permissions.category.downloads", defaultValue: "Downloads")
        case .photos: String(localized: "permissions.category.photos", defaultValue: "Photo library files")
        case .contacts: String(localized: "permissions.category.contacts", defaultValue: "Contact files")
        case .calendars: String(localized: "permissions.category.calendars", defaultValue: "Calendar files")
        case .reminders: String(localized: "permissions.category.reminders", defaultValue: "Reminder files")
        case .mediaLibrary: String(localized: "permissions.category.mediaLibrary", defaultValue: "Media library files")
        case .cloudStorage: String(localized: "permissions.category.cloudStorage", defaultValue: "Cloud and file provider folders")
        case .applicationData: String(localized: "permissions.category.applicationData", defaultValue: "Other applications’ data")
        case .applicationBundles: String(localized: "permissions.category.applicationBundles", defaultValue: "Application bundles")
        case .fullDiskAccess: String(localized: "permissions.category.fullDiskAccess", defaultValue: "Protected application files")
        }
    }

    static func settingsURL(for report: ScanPermissionReport) -> URL {
        let pane = report.denied.contains { $0.target.kind == .fullDiskAccess }
            ? "Privacy_AllFiles" : "Privacy"
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane)!
    }
}
