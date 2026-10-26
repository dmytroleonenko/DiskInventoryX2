import Foundation

/// A deliberately shallow catalog, not an exhaustive list of Apple's private TCC paths.
struct ScanPermissionCatalog: Sendable {
    enum Discovery: Sendable, Equatable {
        case libraries, photos, media, providers, containers, groups, applications, homes

        func kind(for name: String) -> ScanPermissionTarget.Kind? {
            name.withCString { kind(for: UnsafeBufferPointer(start: $0, count: name.utf8.count)) }
        }

        /// Tests ASCII package suffixes before allocating a String for a directory entry.
        func kind(for name: UnsafeBufferPointer<CChar>) -> ScanPermissionTarget.Kind? {
            if name.count == 1 && name[0] == 46 { return nil }
            if name.count == 2 && name[0] == 46 && name[1] == 46 { return nil }
            func hasSuffix(_ suffix: StaticString) -> Bool {
                suffix.withUTF8Buffer { suffixBytes in
                    guard name.count >= suffixBytes.count else { return false }
                    let start = name.count - suffixBytes.count
                    for offset in suffixBytes.indices {
                        let byte = UInt8(bitPattern: name[start + offset])
                        let folded = byte >= 65 && byte <= 90 ? byte + 32 : byte
                        if folded != suffixBytes[offset] { return false }
                    }
                    return true
                }
            }
            func libraryKind() -> ScanPermissionTarget.Kind? {
                if hasSuffix(".photoslibrary") { return .photos }
                if hasSuffix(".app") { return .applicationBundles }
                if hasSuffix(".musiclibrary") || hasSuffix(".musiclibrarypackage")
                    || hasSuffix(".ituneslibrary") || hasSuffix(".imovielibrary")
                    || hasSuffix(".band") || hasSuffix(".logicx") { return .mediaLibrary }
                return nil
            }
            switch self {
            case .providers: return .cloudStorage
            case .homes: return .selectedRoot
            case .containers, .groups: return .applicationData
            case .libraries: return libraryKind()
            case .photos: return hasSuffix(".photoslibrary") ? .photos : nil
            case .applications: return hasSuffix(".app") ? .applicationBundles : nil
            case .media: return libraryKind() == .mediaLibrary ? .mediaLibrary : nil
            }
        }
    }

    struct Entry: Sendable {
        let target: ScanPermissionTarget
        let discovery: Discovery?
    }

    private let homeDirectory: URL

    init(homeDirectory: URL) { self.homeDirectory = homeDirectory.standardizedFileURL }

    func entries(for request: ScanRequest) -> [Entry] {
        let scope = ScanPermissionScope(request: request)
        let home = effectiveHome(for: request.url)
        let manager = FileManager()
        let useStandardFolders = home == manager.homeDirectoryForCurrentUser.standardizedFileURL
        func location(_ directory: FileManager.SearchPathDirectory, fallback: String) -> URL {
            if useStandardFolders, let url = manager.urls(for: directory, in: .userDomainMask).first { return url }
            return home.appendingPathComponent(fallback, isDirectory: true)
        }
        let library = location(.libraryDirectory, fallback: "Library")
        var entries: [Entry] = []
        func add(_ url: URL, _ kind: ScanPermissionTarget.Kind, _ discovery: Discovery? = nil) {
            guard let target = scope.target(for: url, kind: kind) else { return }
            // A selected descendant must not enumerate the protected parent outside its scope.
            let canDiscover = request.fileSelection == .all && ScanPermissionScope.components(of: target.url) == ScanPermissionScope.components(of: url)
            entries.append(Entry(target: target, discovery: canDiscover ? discovery : nil))
        }
        add(location(.documentDirectory, fallback: "Documents"), .documents)
        add(location(.desktopDirectory, fallback: "Desktop"), .desktop)
        add(location(.downloadsDirectory, fallback: "Downloads"), .downloads)
        add(location(.picturesDirectory, fallback: "Pictures"), .photos, .photos)
        add(location(.musicDirectory, fallback: "Music"), .mediaLibrary, .media)
        for name in ["Music", "iTunes"] {
            add(location(.musicDirectory, fallback: "Music").appendingPathComponent(name), .mediaLibrary, .media)
        }
        add(location(.moviesDirectory, fallback: "Movies"), .mediaLibrary, .media)
        add(library.appendingPathComponent("Calendars"), .calendars)
        add(library.appendingPathComponent("Reminders"), .reminders)
        add(location(.applicationSupportDirectory, fallback: "Library/Application Support").appendingPathComponent("AddressBook"), .contacts)
        add(library.appendingPathComponent("CloudStorage"), .cloudStorage, .providers)
        add(library.appendingPathComponent("Mobile Documents"), .cloudStorage, .providers)
        add(library.appendingPathComponent("Containers"), .applicationData, .containers)
        add(library.appendingPathComponent("Group Containers"), .applicationData, .groups)
        for name in ["Mail", "Messages", "Safari"] { add(library.appendingPathComponent(name), .fullDiskAccess) }
        add(home.appendingPathComponent(".Trash"), .fullDiskAccess)
        add(home.appendingPathComponent("Applications"), .applicationBundles, .applications)
        add(URL(fileURLWithPath: "/Applications", isDirectory: true), .applicationBundles, .applications)
        // Only a selection containing Users may discover additional homes. A fixture
        // injected as .../Users/name derives its own Users parent, never the real one.
        let homeParent = homeDirectory.deletingLastPathComponent()
        let users = homeParent.lastPathComponent == "Users"
            ? homeParent
            : manager.urls(for: .userDirectory, in: .localDomainMask).first ?? URL(fileURLWithPath: "/Users", isDirectory: true)
        if request.fileSelection == .all, ScanPermissionScope.contains(request.url, users) {
            add(users, .selectedRoot, .homes)
        }
        // Selecting a custom library or one of its descendants requires only the selected root.
        let rootKind = entries.first(where: { $0.target.url.path == request.url.standardizedFileURL.path })?.target.kind
            ?? request.url.pathComponents.reversed().compactMap { Discovery.libraries.kind(for: $0) }.first
            ?? .selectedRoot
        return [Entry(target: ScanPermissionTarget(url: request.url.standardizedFileURL, kind: rootKind), discovery: request.fileSelection == .all ? .libraries : nil)] + entries
    }

    private func effectiveHome(for root: URL) -> URL {
        let components = ScanPermissionScope.components(of: root)
        if components.count >= 2, components[0] == "Users" {
            return URL(fileURLWithPath: "/Users", isDirectory: true).appendingPathComponent(components[1], isDirectory: true)
        }
        return homeDirectory
    }
}
