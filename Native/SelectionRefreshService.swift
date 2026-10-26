import Foundation
import Darwin

/// Resolves only the selected path's ancestors, never following links or enumerating siblings.
actor SelectionRefreshService {
    func directory(for url: URL, scanRoot: URL) throws -> URL {
        try ScanIOPolicy().perform {
            let policy = SystemPathPolicy()
            guard url.isFileURL, scanRoot.isFileURL,
                  !policy.excludes(url), !policy.excludes(scanRoot) else {
                throw CocoaError(.fileReadNoPermission, userInfo: [NSURLErrorKey: url])
            }
            let root = DiskIndex.lexicalURL(scanRoot)
            let target = DiskIndex.lexicalURL(url)
            let rootParts = root.pathComponents
            let parts = target.pathComponents
            guard parts.starts(with: rootParts) else {
                throw CocoaError(.fileReadNoPermission, userInfo: [NSURLErrorKey: target])
            }
            let mounts = try ScanMountPolicy()
            guard mounts.statusForCandidate(at: root, scanRoot: root) != .automount,
                  mounts.statusForCandidate(at: target, scanRoot: root) == nil else {
                throw CocoaError(.fileReadNoPermission, userInfo: [NSURLErrorKey: target])
            }
            var descriptor = open(root.path, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard descriptor >= 0 else { throw posixError(at: root) }
            defer { close(descriptor) }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else { throw posixError(at: root) }
            guard metadata.st_flags & UInt32(SF_DATALESS) == 0 else {
                throw CocoaError(.fileReadNoPermission, userInfo: [NSURLErrorKey: root])
            }
            var directory = root
            for (offset, component) in parts.dropFirst(rootParts.count).enumerated() {
                try Task.checkCancellation()
                let candidate = directory.appendingPathComponent(component)
                var value = stat()
                if fstatat(descriptor, component, &value, AT_SYMLINK_NOFOLLOW) != 0 {
                    if errno == ENOENT { return directory }
                    throw posixError(at: candidate)
                }
                let kind = value.st_mode & S_IFMT
                if kind == S_IFREG, offset == parts.count - rootParts.count - 1 { return directory }
                guard kind == S_IFDIR, value.st_flags & UInt32(SF_DATALESS) == 0 else {
                    throw CocoaError(.fileReadNoPermission, userInfo: [NSURLErrorKey: candidate])
                }
                let next = openat(descriptor, component, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard next >= 0 else { throw posixError(at: candidate) }
                var opened = stat()
                guard fstat(next, &opened) == 0 else {
                    let error = posixError(at: candidate)
                    close(next)
                    throw error
                }
                guard opened.st_dev == value.st_dev, opened.st_ino == value.st_ino,
                      opened.st_flags & UInt32(SF_DATALESS) == 0 else {
                    close(next)
                    throw CocoaError(.fileReadNoPermission, userInfo: [NSURLErrorKey: candidate])
                }
                close(descriptor)
                descriptor = next
                directory = candidate
            }
            try Task.checkCancellation()
            return directory
        }
    }

    private func posixError(at url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
    }
}
