import Foundation
import Darwin

struct ScanPermissionScopeSmoke {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    static func run(root: URL) async throws {
        try boundaries()
        let manager = FileManager()
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        // Keep the raw temporary URL: /var ancestor aliases must behave like the scanner.
        let fixture = root
        let home = fixture.appendingPathComponent("Home", isDirectory: true)
        let paths = [
            "Documents", "Desktop", "Downloads", "Pictures/Family.photoslibrary/originals",
            "Library/Calendars", "Library/Reminders", "Library/Application Support/AddressBook",
            "Music/Main.musiclibrary", "Music/Music/Nested.musiclibrary", "Movies/Main.imovielibrary",
            "Library/CloudStorage/Provider", "Library/Mobile Documents/iCloud.test",
            "Library/Containers/example.app/Data", "Library/Group Containers/group.example",
            "Applications/Example.app/Contents", "Library/Mail", "Library/Messages", "Library/Safari", ".Trash"
        ]
        for path in paths { try manager.createDirectory(at: home.appendingPathComponent(path), withIntermediateDirectories: true) }
        for parent in ["Library/CloudStorage", "Library/Containers", "Library/Group Containers"] {
            try Data().write(to: home.appendingPathComponent(parent).appendingPathComponent("OrdinaryFile"))
            try manager.createSymbolicLink(at: home.appendingPathComponent(parent).appendingPathComponent("SymlinkAlias"), withDestinationURL: home.appendingPathComponent("Documents"))
        }
        let service = ScanPermissionService(homeDirectory: home)
        let all = try await collect(service, ScanRequest(url: home))
        try check(all.report.denied.isEmpty, "Readable fake home produced a denial")
        let expected = ["Documents", "Desktop", "Downloads", "Pictures/Family.photoslibrary", "Library/Calendars", "Library/Reminders", "Library/Application Support/AddressBook", "Music/Main.musiclibrary", "Movies/Main.imovielibrary", "Library/CloudStorage/Provider", "Library/Mobile Documents/iCloud.test", "Library/Containers/example.app", "Library/Containers/example.app/Data", "Library/Group Containers/group.example", "Applications/Example.app", "Library/Mail", "Library/Messages", "Library/Safari", ".Trash"]
        for path in expected {
            try check(all.targets.contains(where: { $0.url.path == home.appendingPathComponent(path).path }), "Missing relevant upfront probe: \(path)")
        }
        try check(all.targets.contains(where: { $0.url.path == home.appendingPathComponent("Music/Music/Nested.musiclibrary").path }), "Standard nested Music library was not discovered")
        try check(Set(all.targets.map(\.url.path)).count == all.targets.count, "Preflight repeated a directory probe")
        try check(all.report.checkedCount >= expected.count, "Relevant directories were not actually opened")
        try check(!all.targets.contains(where: { $0.url.lastPathComponent == "OrdinaryFile" || $0.url.pathComponents.contains("SymlinkAlias") }), "Provider/container discovery retained an obvious file or symlink")

        for path in expected + ["Documents/Inside", "Pictures/Family.photoslibrary/originals"] {
            let selected = home.appendingPathComponent(path)
            try manager.createDirectory(at: selected, withIntermediateDirectories: true)
            let result = try await collect(service, ScanRequest(url: selected))
            try check(result.report.checkedCount == 1 && result.targets.count == 1 && result.targets[0].url.path == selected.path, "Selected protected root/descendant accessed an out-of-scope ancestor: \(path)")
        }
        let direct = try await collect(service, ScanRequest(url: home, fileSelection: .smallFilesOnly))
        try check(direct.targets.count == 1 && direct.report.checkedCount == 1, "Small-file drill requested descendant directory permissions")

        let unrelated = fixture.appendingPathComponent("Documents2")
        try manager.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let irrelevant = try await collect(service, ScanRequest(url: unrelated))
        try check(irrelevant.targets.count == 1 && irrelevant.report.checkedCount == 1, "Unrelated scope touched a fake-home privacy folder")
        let custom = fixture.appendingPathComponent("Custom")
        for name in ["Outside.photoslibrary", "UPPER.PHOTOSLIBRARY", "Editor.app", "Nested/NotDiscovered.photoslibrary"] {
            try manager.createDirectory(at: custom.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        for name in (0..<64).map({ "ordinary-\($0).bin" }) + ["NotDirectory.photoslibrary", "NotDirectory.app"] {
            try Data().write(to: custom.appendingPathComponent(name))
        }
        let customResult = try await collect(service, ScanRequest(url: custom))
        try check(customResult.targets.contains(where: { $0.kind == .photos && $0.url.lastPathComponent == "Outside.photoslibrary" }), "Custom immediate photo library was not discovered")
        try check(customResult.targets.contains(where: { $0.kind == .applicationBundles && $0.url.lastPathComponent == "Editor.app" }), "Custom immediate app bundle was not discovered")
        try check(!customResult.targets.contains(where: { $0.url.lastPathComponent == "NotDiscovered.photoslibrary" }), "Preflight became a second recursive inventory")
        try check(customResult.targets.contains(where: { $0.kind == .photos && $0.url.lastPathComponent == "UPPER.PHOTOSLIBRARY" }), "ASCII case-insensitive library suffix was not recognized")
        try check(customResult.targets.count == 4 && customResult.report.checkedCount == 4, "Immediate ordinary files or file-shaped packages were retained as discovery candidates")

        let file = fixture.appendingPathComponent("regular-file")
        try Data([1, 2, 3]).write(to: file)
        try check(chmod(file.path, 0) == 0, "Cannot restrict regular-file fixture")
        defer { chmod(file.path, S_IRUSR | S_IWUSR) }
        let regular = try await collect(service, ScanRequest(url: file))
        try check(regular.report.checkedCount == 0 && regular.report.denied.isEmpty, "Selected regular file was opened for contents")
        let pipe = fixture.appendingPathComponent("pipe")
        try check(mkfifo(pipe.path, S_IRUSR | S_IWUSR) == 0, "Cannot create isolated FIFO")
        let fifo = try await collect(service, ScanRequest(url: pipe))
        try check(fifo.report.checkedCount == 0 && fifo.report.denied.isEmpty, "Special-file root was opened")
        let missing = try await collect(service, ScanRequest(url: fixture.appendingPathComponent("Missing")))
        try check(missing.report.checkedCount == 0 && missing.report.denied.isEmpty, "Missing directory became a permission denial")

        let alias = custom.appendingPathComponent("Alias.photoslibrary")
        try manager.createSymbolicLink(at: alias, withDestinationURL: home.appendingPathComponent("Documents"))
        let link = try await collect(service, ScanRequest(url: alias))
        let throughLink = try await collect(service, ScanRequest(url: alias.appendingPathComponent("Inside")))
        try check(link.report.checkedCount == 0 && link.report.denied.isEmpty, "Preflight followed a selected symlink root")
        try check(throughLink.report.checkedCount == 1 && throughLink.report.denied.isEmpty, "Explicit root through an ancestor alias was rejected")
        let discoveredLinks = try await collect(service, ScanRequest(url: custom))
        try check(discoveredLinks.report.checkedCount == customResult.report.checkedCount, "Discovered symlink library was opened")
        let internalHome = fixture.appendingPathComponent("InternalSymlinkHome")
        try manager.createDirectory(at: internalHome, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: internalHome.appendingPathComponent("Library"), withDestinationURL: home.appendingPathComponent("Library"))
        let internalLinks = try await collect(ScanPermissionService(homeDirectory: internalHome), ScanRequest(url: internalHome))
        try check(internalLinks.report.checkedCount == 1 && internalLinks.report.denied.isEmpty, "Jumped candidate followed an internal symlink ancestor")

        let deniedURL = home.appendingPathComponent("Library/Calendars")
        try check(chmod(deniedURL.path, 0) == 0, "Cannot restrict protected-directory fixture")
        defer { chmod(deniedURL.path, S_IRWXU) }
        let denied = try await collect(service, ScanRequest(url: deniedURL))
        try check(denied.report.denied.count == 1 && denied.report.denied[0].target.url.path == deniedURL.path, "Denied root did not retain its actual path")
        try check(denied.report.denied[0].code == EACCES || denied.report.denied[0].code == EPERM, "Denied root lost its actual POSIX error")
        let deniedChild = try await collect(service, ScanRequest(url: home))
        try check(deniedChild.report.denied.contains(where: { $0.target.url.path == deniedURL.path }), "Denied protected descendant was silently treated as granted")
        let documents = home.appendingPathComponent("Documents")
        try check(chmod(documents.path, 0) == 0, "Cannot restrict raw temporary-URL Documents fixture")
        defer { chmod(documents.path, S_IRWXU) }
        let rawTemporaryDenied = try await collect(service, ScanRequest(url: home))
        try check(rawTemporaryDenied.report.denied.contains(where: { $0.target.url.path == documents.path && ($0.code == EACCES || $0.code == EPERM) }), "Raw temporary URL ancestor alias hid the Documents denial")
        let aliasDenied = try await collect(service, ScanRequest(url: alias.appendingPathComponent("Inside")))
        try check(aliasDenied.report.denied.count == 1 && aliasDenied.report.denied[0].target.url.path == alias.appendingPathComponent("Inside").path, "Selected root through an alias ancestor lost its actual denial path")

        let mounted = ScanPermissionService(homeDirectory: home, mounts: [.init(path: home.appendingPathComponent("Library").path, isAutofs: false)])
        let isolated = try await collect(mounted, ScanRequest(url: home))
        try check(!isolated.targets.contains(where: { $0.url.path.hasPrefix(home.appendingPathComponent("Library").path + "/") }), "Jumped catalog candidate crossed a nested mount")
        let automount = ScanPermissionService(homeDirectory: home, mounts: [.init(path: custom.path, isAutofs: true)])
        let automatic = try await collect(automount, ScanRequest(url: custom))
        try check(automatic.targets.isEmpty && automatic.report.checkedCount == 0 && automatic.report.denied.isEmpty, "Autofs root was touched or became a denial")
        let explicitMount = ScanPermissionService(homeDirectory: home, mounts: [.init(path: unrelated.path, isAutofs: false)])
        let explicit = try await collect(explicitMount, ScanRequest(url: unrelated))
        try check(explicit.report.checkedCount == 1, "Explicitly selected mounted root did not receive its consent read")

        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await collect(service, ScanRequest(url: home))
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        let cancelledBeforeProbing = await cancelled.value
        try check(cancelledBeforeProbing, "Cancelled preflight completed instead of throwing cancellation")
        try await otherHomes(root: fixture)
        print("PASS: scoped directory-only consent; fake-home category discovery and selected descendants; no unrelated/recursive probes; small-file/file/FIFO/missing/symlink handling; actual chmod denial paths/codes; cancellation; mount/autofs/firmlink/dataless boundaries")
    }

    private static func otherHomes(root: URL) async throws {
        let manager = FileManager()
        let users = root.appendingPathComponent("Users", isDirectory: true)
        let current = users.appendingPathComponent("current", isDirectory: true)
        let other = users.appendingPathComponent("other", isDirectory: true)
        let otherDocuments = other.appendingPathComponent("Documents")
        let otherPhotos = other.appendingPathComponent("Pictures/Other.photoslibrary")
        for directory in [current.appendingPathComponent("Documents"), otherDocuments, otherPhotos, other.appendingPathComponent("Deep/NotDiscovered.photoslibrary")] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try manager.createSymbolicLink(at: users.appendingPathComponent("Alias"), withDestinationURL: other)
        try Data().write(to: users.appendingPathComponent("OrdinaryFile"))
        let service = ScanPermissionService(homeDirectory: current)
        for selected in [users, root] {
            let report = try await collect(service, ScanRequest(url: selected))
            try check(report.targets.contains(where: { $0.url.path == otherDocuments.path && $0.kind == .documents }), "Shallow Users discovery missed another home's Documents")
            try check(report.targets.contains(where: { $0.url.path == otherPhotos.path && $0.kind == .photos }), "Shallow Users discovery missed another home's photo library")
            try check(!report.targets.contains(where: { $0.url.pathComponents.contains("Alias") || $0.url.lastPathComponent == "OrdinaryFile" || $0.url.lastPathComponent == "NotDiscovered.photoslibrary" }), "Home discovery followed an alias/file or recursed into arbitrary directories")
            try check(report.report.denied.isEmpty, "Readable local homes produced a denial")
        }
        let unrelated = root.appendingPathComponent("UnrelatedUsersScope")
        try manager.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let outside = try await collect(service, ScanRequest(url: unrelated))
        try check(outside.targets.count == 1 && outside.report.checkedCount == 1, "Unrelated scope visited Users")
        let direct = try await collect(service, ScanRequest(url: users, fileSelection: .smallFilesOnly))
        try check(direct.targets.count == 1 && direct.report.checkedCount == 1, "Small-file scope discovered other homes")
        let mounted = ScanPermissionService(homeDirectory: current, mounts: [.init(path: other.path, isAutofs: false)])
        let isolated = try await collect(mounted, ScanRequest(url: users))
        try check(!isolated.targets.contains(where: { ScanPermissionScope.contains(other, $0.url) }), "Discovered home crossed a nested mount")
        try check(chmod(otherDocuments.path, 0) == 0, "Cannot restrict other-home Documents fixture")
        defer { chmod(otherDocuments.path, S_IRWXU) }
        let denied = try await collect(service, ScanRequest(url: users))
        try check(denied.report.denied.contains(where: { $0.target.url.path == otherDocuments.path && ($0.code == EACCES || $0.code == EPERM) }), "Discovered other-home directory was not actually opened or lost its denial")
    }

    private static func collect(_ service: ScanPermissionService, _ request: ScanRequest) async throws -> (targets: [ScanPermissionTarget], report: ScanPermissionReport) {
        var targets: [ScanPermissionTarget] = []
        var report: ScanPermissionReport?
        for try await event in service.prepare(request) {
            try check(report == nil, "Preflight published an event after finished")
            switch event {
            case .checking(let target): targets.append(target)
            case .finished(let value): report = value
            }
        }
        guard let report else { throw Failure(description: "Preflight omitted its finished report") }
        return (targets, report)
    }

    private static func boundaries() throws {
        let documents = URL(fileURLWithPath: "/Users/example/Documents", isDirectory: true)
        for path in ["/Users/example", "/Users/example/Documents", "/Users/example/Documents/Inside", "/System/Volumes/Data/Users/example/Documents/Inside"] {
            let scope = ScanPermissionScope(request: ScanRequest(url: URL(fileURLWithPath: path)))
            guard let target = scope.target(for: documents, kind: .documents) else { throw Failure(description: "Relevant boundary excluded: \(path)") }
            let expected = path.hasSuffix("example") ? path + "/Documents" : path
            try check(target.url.path == expected, "Probe URL escaped the requested spelling/scope")
        }
        let physical = ScanPermissionScope(request: ScanRequest(url: URL(fileURLWithPath: "/System/Volumes/Data/Users/example")))
        try check(physical.target(for: documents, kind: .documents)?.url.path == "/System/Volumes/Data/Users/example/Documents", "Data alias was not anchored under selected physical root")
        for path in ["/bin", "/Users/other", "/Users/example/Documents2", "/Users/example2"] {
            try check(ScanPermissionScope(request: ScanRequest(url: URL(fileURLWithPath: path))).target(for: documents, kind: .documents) == nil, "Component boundary accepted unrelated scope: \(path)")
        }
        let small = ScanPermissionScope(request: ScanRequest(url: URL(fileURLWithPath: "/Users/example"), fileSelection: .smallFilesOnly))
        try check(small.target(for: documents, kind: .documents) == nil, "Small-file scope included a protected descendant")
        try check(ScanPermissionScope.permitsDirectory(mode: S_IFDIR, flags: 0), "Ordinary directory was excluded")
        try check(!ScanPermissionScope.permitsDirectory(mode: S_IFDIR, flags: UInt32(SF_DATALESS)), "Dataless directory would be hydrated")
        for mode in [S_IFREG, S_IFLNK, S_IFIFO, S_IFSOCK] {
            try check(!ScanPermissionScope.permitsDirectory(mode: mode, flags: 0), "Non-directory would receive a read probe")
        }
        let mounts = ScanMountPolicy(mounts: [.init(path: "/System/Volumes/Data/Volumes/External", isAutofs: false), .init(path: "/System/Volumes/Data/home", isAutofs: true)])
        let root = URL(fileURLWithPath: "/")
        try check(mounts.statusForCandidate(at: URL(fileURLWithPath: "/Volumes/External/deep/Documents"), scanRoot: root) == .otherVolume, "Deep mount jump bypassed firmlink alias")
        try check(mounts.statusForCandidate(at: URL(fileURLWithPath: "/home/user/Documents"), scanRoot: root) == .automount, "Deep autofs jump bypassed firmlink alias")
        try check(mounts.statusForCandidate(at: URL(fileURLWithPath: "/Volumes/External-copy/Documents"), scanRoot: root) == nil, "Mount prefix collision excluded ordinary path")
        let visible = ScanMountPolicy(mounts: [.init(path: "/Volumes/External", isAutofs: false)])
        try check(visible.statusForCandidate(at: URL(fileURLWithPath: "/System/Volumes/Data/Volumes/External/deep/Documents"), scanRoot: URL(fileURLWithPath: "/System/Volumes/Data")) == .otherVolume, "Physical Data scan bypassed a visible mount-table spelling")
        try check(visible.statusForCandidate(at: URL(fileURLWithPath: "/Volumes/External/deep/Documents"), scanRoot: URL(fileURLWithPath: "/Volumes/External")) == nil, "Descendant of explicitly selected mounted root was incorrectly blocked")
        try check(SystemPathPolicy().excludes(URL(fileURLWithPath: "/.resolve/Users/example")), "Reserved lookup namespace was not excluded")
        let other = ScanPermissionCatalog(homeDirectory: URL(fileURLWithPath: "/Users/current")).entries(for: ScanRequest(url: URL(fileURLWithPath: "/Users/other/Library")))
        try check(other.contains(where: { $0.target.url.path == "/Users/other/Library/Calendars" }), "Explicit other-home scope used the current user's catalog")
        try check(other.allSatisfy { ScanPermissionScope.contains(URL(fileURLWithPath: "/Users/other/Library"), $0.target.url) }, "Other-home catalog escaped selected subtree")
    }
}
