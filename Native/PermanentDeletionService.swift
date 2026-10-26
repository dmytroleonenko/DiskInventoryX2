import Foundation
import Darwin

actor PermanentDeletionService {
    private let fileManager = FileManager()
    private let systemPaths = SystemPathPolicy()

    func prepare(url: URL, scanRoot: URL) throws -> PermanentDeletionTarget {
        try ScanIOPolicy().perform {
            let mounts = try ScanMountPolicy()
            guard mounts.status(at: scanRoot, scanRoot: scanRoot) != .automount,
                  mounts.status(at: url, scanRoot: scanRoot) == nil else {
                throw PermanentDeletionError.protectedLocation
            }
            return try prepareProtected(url: url, scanRoot: scanRoot)
        }
    }

    private func prepareProtected(url: URL, scanRoot: URL) throws -> PermanentDeletionTarget {
        guard !systemPaths.excludes(scanRoot), !systemPaths.excludes(url) else {
            throw PermanentDeletionError.protectedLocation
        }
        let root = scanRoot.resolvingSymlinksInPath().standardizedFileURL
        let item = url.standardizedFileURL
        let resolved = item.resolvingSymlinksInPath().standardizedFileURL
        guard !systemPaths.excludes(root), !systemPaths.excludes(resolved) else {
            throw PermanentDeletionError.protectedLocation
        }
        let rootParts = root.pathComponents
        let itemParts = resolved.pathComponents
        guard itemParts.count > rootParts.count,
              itemParts.starts(with: rootParts),
              try item.resourceValues(forKeys: [.isVolumeKey]).isVolume != true else {
            throw PermanentDeletionError.protectedLocation
        }
        let identity = try identity(at: item)
        let kind = identity.st_mode & S_IFMT
        guard kind == S_IFDIR || kind == S_IFREG else {
            throw PermanentDeletionError.changedItem
        }
        return PermanentDeletionTarget(
            url: item, device: identity.st_dev, inode: identity.st_ino,
            isDirectory: kind == S_IFDIR
        )
    }

    func remove(_ target: PermanentDeletionTarget) throws {
        try ScanIOPolicy().perform {
            try verifyMutation(target)
            // Foundation does not follow symlinks while recursively removing a directory.
            // Failures can be partial: the controller must reconcile with the filesystem.
            try fileManager.removeItem(at: target.url)
        }
    }

    /// Returns Foundation's actual destination, including any Trash collision rename.
    func trash(_ target: PermanentDeletionTarget) throws -> URL {
        try ScanIOPolicy().perform {
            try verifyMutation(target)
            var destination: NSURL?
            try fileManager.trashItem(at: target.url, resultingItemURL: &destination)
            guard let destination else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: target.url])
            }
            return destination as URL
        }
    }

    private func verifyMutation(_ target: PermanentDeletionTarget) throws {
        let mounts = try ScanMountPolicy()
        guard mounts.status(at: target.url, scanRoot: target.url) != .automount,
              !systemPaths.excludes(target.url) else {
            throw PermanentDeletionError.protectedLocation
        }
        try verify(target)
        if target.isDirectory { try rejectNestedVolumes(in: target.url) }
        try Task.checkCancellation()
        try verify(target)
    }

    private func identity(at url: URL) throws -> stat {
        var value = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &value)
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
        return value
    }

    private func verify(_ target: PermanentDeletionTarget) throws {
        let current = try identity(at: target.url)
        let kind = current.st_mode & S_IFMT
        guard current.st_dev == target.device, current.st_ino == target.inode,
              kind == (target.isDirectory ? S_IFDIR : S_IFREG) else {
            throw PermanentDeletionError.changedItem
        }
    }

    private func rejectNestedVolumes(in url: URL) throws {
        guard let volumes = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: url])
        }
        let components = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        for volume in volumes {
            let mounted = volume.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            if mounted.count > components.count, mounted.starts(with: components) {
                throw PermanentDeletionError.nestedVolume
            }
        }
    }
}
