import Foundation
import Darwin

/// A cached mount-table snapshot prevents probing autofs or crossing nested mounts.
struct ScanMountPolicy {
    struct Mount: Sendable {
        let path: String
        let isAutofs: Bool
    }

    private let mounts: [Mount]

    init() throws {
        var table: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&table, MNT_NOWAIT)
        guard count > 0, let table else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno == 0 ? EIO : errno))
        }
        defer { free(table) }
        var mounts: [Mount] = []
        for offset in 0..<Int(count) {
            var entry = table[offset]
            let path = withUnsafeBytes(of: &entry.f_mntonname) { bytes in
                String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            let type = withUnsafeBytes(of: &entry.f_fstypename) { bytes in
                String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            mounts.append(Mount(path: path, isAutofs: type == "autofs"))
        }
        self.init(mounts: mounts)
    }

    init(mounts: [Mount]) {
        var aliases = mounts
        // Match visible and physical spellings without aliasing the Data mount itself to "/".
        let dataPrefix = "/System/Volumes/Data/"
        for mount in mounts {
            if mount.path.hasPrefix(dataPrefix) {
                aliases.append(Mount(path: "/" + mount.path.dropFirst(dataPrefix.count), isAutofs: mount.isAutofs))
            } else if mount.path != "/" && mount.path != "/System/Volumes/Data" {
                aliases.append(Mount(path: "/System/Volumes/Data" + mount.path, isAutofs: mount.isAutofs))
            }
        }
        self.mounts = aliases
    }

    func status(at url: URL, scanRoot: URL) -> ScanEntryStatus? {
        let path = url.path
        let root = scanRoot.path
        for mount in mounts where mount.isAutofs {
            if path == mount.path || path.hasPrefix(mount.path + "/") { return .automount }
        }
        for mount in mounts where mount.path != root && mount.path == path {
            if root == "/" || mount.path.hasPrefix(root + "/") { return .otherVolume }
        }
        return nil
    }

    /// Unlike the walk's single-entry check, a catalog jump must inspect every mount ancestor.
    func statusForCandidate(at url: URL, scanRoot: URL) -> ScanEntryStatus? {
        if let status = status(at: url, scanRoot: scanRoot) { return status }
        let path = url.standardizedFileURL.path
        let root = scanRoot.standardizedFileURL.path
        for mount in mounts where mount.path != root {
            let liesBelowRoot = root == "/" || mount.path.hasPrefix(root + "/")
            let containsCandidate = path == mount.path || path.hasPrefix(mount.path + "/")
            if liesBelowRoot && containsCandidate {
                return mount.isAutofs ? .automount : .otherVolume
            }
        }
        return nil
    }
}
