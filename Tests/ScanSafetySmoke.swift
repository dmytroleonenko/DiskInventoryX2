import Foundation
import Darwin

struct ScanSafetySmoke {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }
    private struct DeliberateFailure: Error {}

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    static func run(root: URL) async throws {
        try verifyIOPolicies()
        try verifyMountBoundaries()
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let real = root.appendingPathComponent("Real", isDirectory: true)
        try manager.createDirectory(at: real, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 43).write(to: real.appendingPathComponent("payload.bin"))
        try manager.createSymbolicLink(at: root.appendingPathComponent("Loop"), withDestinationURL: root)
        try manager.createSymbolicLink(at: root.appendingPathComponent("Alias"), withDestinationURL: real)
        try check(mkfifo(root.appendingPathComponent("pipe").path, S_IRUSR | S_IWUSR) == 0, "Could not create isolated FIFO")
        for name in ["cores", ".Trashes", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100"] {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 2, count: 7).write(to: directory.appendingPathComponent("data.bin"))
        }
        let result = try await scan(root)
        try check(result.root.logicalSize == 78 && result.root.fileCount == 6, "Symlinks, special files or real hidden folders changed accounting")
        try check(result.skippedCount == 3 && result.root.scanStatus == .complete, "Intentional non-file exclusions should not masquerade as unreadable contents")
        try check(result.root.index.find(url: root.appendingPathComponent("Loop")) == nil, "Scanner retained a cyclic symlink")
        for name in ["cores", ".Trashes", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100"] {
            try check(result.root.index.find(url: root.appendingPathComponent(name))?.logicalSize == 7, "Real system-like folder was filtered by name: \(name)")
        }
        do {
            _ = try await scan(root.appendingPathComponent("Alias"))
            throw Failure(description: "Direct scan followed a symlink")
        } catch is CocoaError {}

        let sparse = root.appendingPathComponent("sparse.bin")
        let fd = open(sparse.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Failure(description: "Cannot create isolated sparse file") }
        let truncateResult = ftruncate(fd, 64 * 1024 * 1024)
        close(fd)
        try check(truncateResult == 0, "Cannot size isolated sparse file")
        var info = stat()
        try check(lstat(sparse.path, &info) == 0, "Cannot stat isolated sparse file")
        let sparseResult = try await scan(sparse)
        try check(sparseResult.root.logicalSize == 64 * 1024 * 1024, "Sparse logical size is incorrect")
        try check(sparseResult.root.allocatedSize == info.st_blocks * 512, "Sparse allocation did not match filesystem blocks")
        try check(sparseResult.root.index.withSizeMode(.logical).root.size == 64 * 1024 * 1024, "Cached size-mode toggle lost sparse logical bytes")

        let unreadable = root.appendingPathComponent("Unreadable", isDirectory: true)
        try manager.createDirectory(at: unreadable, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 47).write(to: unreadable.appendingPathComponent("secret.bin"))
        try check(chmod(unreadable.path, 0) == 0, "Cannot restrict isolated directory")
        defer { chmod(unreadable.path, S_IRWXU) }
        let deniedRoot = try await scan(unreadable)
        try check(deniedRoot.root.scanStatus == .unreadable && deniedRoot.skippedCount > 0, "Denied scan root was presented as complete empty folder")
        try check(deniedRoot.root.fileCount == 0, "Denied scan root invented file counts")

        let mounts = try ScanMountPolicy()
        let systemRoot = URL(fileURLWithPath: "/", isDirectory: true)
        let home = URL(fileURLWithPath: "/home", isDirectory: true)
        if mounts.status(at: home, scanRoot: systemRoot) == .automount {
            var publications = 0
            do {
                for try await _ in DiskScanner().scan(ScanRequest(url: home)) { publications += 1 }
                throw Failure(description: "Scanner entered actual autofs root")
            } catch let error as CocoaError {
                try check(error.code == .fileReadNoPermission && publications == 0, "Autofs scan was not rejected before traversal")
            }
            let deletion = PermanentDeletionService()
            do {
                _ = try await deletion.prepare(url: home, scanRoot: systemRoot)
                throw Failure(description: "Deletion preflight probed an autofs location")
            } catch PermanentDeletionError.protectedLocation {}
            do {
                try await deletion.remove(PermanentDeletionTarget(url: home, device: 0, inode: 0, isDirectory: true))
                throw Failure(description: "Deletion entered an autofs location")
            } catch PermanentDeletionError.protectedLocation {}
        }
        try check(VolumeSpaceReader().read(at: root) == nil, "Folder scan was misrepresented as whole-volume accounting")
        guard let volume = VolumeSpaceReader().read(at: systemRoot) else { throw Failure(description: "Cannot read actual startup volume capacity") }
        try check(volume.usedBytes + volume.freeBytes == volume.capacityBytes && volume.freeBytes >= 0, "Actual volume snapshot is inconsistent")
        print("PASS: kernel no-materialization/no-automount policies and thread-policy restoration; mount/firmlink boundaries; real symlink/FIFO/hidden-folder/sparse scans; denied scan root; actual autofs rejection; volume-scope accounting")
    }

    private static func verifyIOPolicies() throws {
        let before = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        let processBefore = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS)
        try ScanIOPolicy().perform {
            try check(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == IOPOL_MATERIALIZE_DATALESS_FILES_OFF, "Dataless materialization was not disabled")
            try check(getiopolicy_np(IOPOL_TYPE_VFS_TRIGGER_RESOLVE, IOPOL_SCOPE_PROCESS) == IOPOL_VFS_TRIGGER_RESOLVE_OFF, "Automount trigger resolution was not disabled")
            try ScanIOPolicy().perform {
                try check(getiopolicy_np(IOPOL_TYPE_VFS_TRIGGER_RESOLVE, IOPOL_SCOPE_PROCESS) == IOPOL_VFS_TRIGGER_RESOLVE_OFF, "Nested policy enabled trigger resolution")
            }
            try check(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == IOPOL_MATERIALIZE_DATALESS_FILES_OFF, "Nested scope restored the wrong materialization policy")
        }
        try check(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == before, "Successful scan leaked thread I/O policy")
        do {
            try ScanIOPolicy().perform { throw DeliberateFailure() }
        } catch is DeliberateFailure {}
        try check(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == before, "Throwing scan leaked thread I/O policy")
        try check(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS) == processBefore, "Scanner changed process-wide materialization policy")
        try check(getiopolicy_np(IOPOL_TYPE_VFS_TRIGGER_RESOLVE, IOPOL_SCOPE_PROCESS) == IOPOL_VFS_TRIGGER_RESOLVE_OFF, "Throwing/nested operation re-enabled implicit mounts")
        try check(ScanEnumerationIssues.unavailableStatus(for: NSError(domain: NSPOSIXErrorDomain, code: Int(EDEADLK))) == .cloudOnly, "Blocked materialization lost its distinct unavailable state")
        let wrappedCloudError = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoPermission.rawValue, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EDEADLK))
        ])
        try check(ScanEnumerationIssues.unavailableStatus(for: wrappedCloudError) == .cloudOnly, "Foundation's permission wrapper hid blocked materialization")
    }

    private static func verifyMountBoundaries() throws {
        let policy = ScanMountPolicy(mounts: [
            .init(path: "/", isAutofs: false),
            .init(path: "/System/Volumes/Data", isAutofs: false),
            .init(path: "/System/Volumes/Data/home", isAutofs: true),
            .init(path: "/System/Volumes/VM", isAutofs: false),
            .init(path: "/System/Volumes/Data/Volumes/External", isAutofs: false)
        ])
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        for path in ["/home", "/home/user", "/System/Volumes/Data/home/user"] {
            try check(policy.status(at: URL(fileURLWithPath: path), scanRoot: root) == .automount, "Autofs path/alias was not blocked: \(path)")
        }
        for path in ["/System/Volumes/Data", "/System/Volumes/VM", "/Volumes/External"] {
            try check(policy.status(at: URL(fileURLWithPath: path), scanRoot: root) == .otherVolume, "Nested mount was not isolated: \(path)")
        }
        for path in ["/Users", "/Applications", "/Library", "/private", "/usr/local", "/homework", "/Volumes/External-copy"] {
            try check(policy.status(at: URL(fileURLWithPath: path), scanRoot: root) == nil, "Mount rule hid an ordinary path: \(path)")
        }
        let explicit = URL(fileURLWithPath: "/Volumes/External", isDirectory: true)
        try check(policy.status(at: explicit, scanRoot: explicit) == nil, "Explicit scan of an already mounted volume was blocked")
    }

    private static func scan(_ url: URL) async throws -> ScanResult {
        var completed: ScanResult?
        for try await result in DiskScanner().scan(ScanRequest(url: url)) where result.isComplete { completed = result }
        guard let completed else { throw Failure(description: "No complete scan result") }
        return completed
    }
}
