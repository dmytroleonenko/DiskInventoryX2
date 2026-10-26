import Foundation
import Darwin

/// A single producer owns this iterative metadata walk and all mutable arena state.
final class ScanTraversal {
    private static let prefetchedKeys: [URLResourceKey] = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey,
        .typeIdentifierKey, .localizedTypeDescriptionKey,
        .totalFileSizeKey, .fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .volumeURLKey,
        .linkCountKey,
    ]
    private static let resourceKeys = Set(prefetchedKeys)

    private let fileManager = FileManager()
    private let systemPaths = SystemPathPolicy()
    private let request: ScanRequest
    private let rootURL: URL
    private let continuation: AsyncThrowingStream<ScanResult, Error>.Continuation
    private let issues: ScanEnumerationIssues
    private let builder: DiskIndexBuilder
    private let clock = ContinuousClock()
    private var lastPublication: ContinuousClock.Instant
    private var rootVolume: URL?
    private var totals = ScanTypeAccumulator()
    private var currentDirectoryURL: URL?
    private var observedHardLinks: Set<FileIdentity> = []

    init(request: ScanRequest, continuation: AsyncThrowingStream<ScanResult, Error>.Continuation) {
        self.request = request
        rootURL = request.url.standardizedFileURL
        self.continuation = continuation
        issues = ScanEnumerationIssues(rootPath: rootURL.path)
        builder = DiskIndexBuilder(rootURL: rootURL, sizeMode: request.sizeMode)
        lastPublication = clock.now
    }

    func run() throws {
        try Task.checkCancellation()
        guard rootURL.isFileURL else {
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSURLErrorKey: rootURL])
        }
        guard !systemPaths.excludes(request.url) else {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSURLErrorKey: rootURL])
        }
        try ScanIOPolicy().perform {
            let mounts = try ScanMountPolicy()
            guard mounts.status(at: rootURL, scanRoot: rootURL) != .automount else {
                throw CocoaError(.fileReadNoPermission, userInfo: [NSURLErrorKey: rootURL])
            }
            try walk(mounts: mounts)
        }
    }

    private func walk(mounts: ScanMountPolicy) throws {
        let root: Metadata
        do {
            root = try autoreleasepool { try readMetadata(at: rootURL) }
        } catch {
            root = try unavailableMetadata(at: rootURL, error: error)
        }
        guard !root.isSymbolicLink else { throw readError(for: rootURL) }
        let component = rootURL.lastPathComponent
        let rootName = component.isEmpty ? rootURL.path : component
        if root.isRegularFile, let logicalSize = root.logicalSize, let allocatedSize = root.allocatedSize {
            totals.add(logicalSize: logicalSize, allocatedSize: allocatedSize, kind: root.kind)
            builder.append(
                parent: -1, name: rootName, logicalSize: logicalSize, allocatedSize: allocatedSize,
                fileCount: 1, isDirectory: false, kind: root.kind, isPackage: root.isPackage,
                scanStatus: root.status, hardLink: root.hardLink
            )
            try publishFinal()
            return
        }
        guard root.isDirectory || root.status != .complete else { throw readError(for: rootURL) }
        rootVolume = root.volume
        builder.append(parent: -1, name: rootName, isDirectory: root.isDirectory, kind: root.kind, isPackage: root.isPackage, scanStatus: root.status)
        guard root.status == .complete else {
            issues.skippedCount += 1
            try publishFinal()
            return
        }
        var stack: [ScanDirectoryFrame] = []
        do {
            stack.append(ScanDirectoryFrame(id: 0, url: rootURL, enumerator: try makeEnumerator(at: rootURL)))
        } catch {
            builder.markIncomplete(0, status: ScanEnumerationIssues.unavailableStatus(for: error) ?? .unreadable)
            issues.skippedCount += 1
        }
        publishProgress(currentURL: rootURL)
        while let frame = stack.last {
            try Task.checkCancellation()
            currentDirectoryURL = frame.url
            guard let entry = try nextEntry(
                in: frame.enumerator, mounts: mounts,
                excludingReservedRootEntries: frame.id == 0 && issues.rootPath == "/"
            ) else {
                let status = issues.status(for: frame.url)
                if status != .complete { builder.markIncomplete(frame.id, status: status) }
                finishDirectory(frame)
                stack.removeLast()
                continue
            }
            if entry.status != .complete {
                if request.fileSelection == .all {
                    builder.append(parent: frame.id, name: entry.url.lastPathComponent, isDirectory: entry.isDirectory, kind: entry.kind, isPackage: entry.isPackage, scanStatus: entry.status)
                } else if !entry.isDirectory {
                    builder.markIncomplete(frame.id, status: .partial)
                }
            } else if entry.isDirectory {
                if request.fileSelection == .all {
                    let id = builder.append(parent: frame.id, name: entry.url.lastPathComponent, isDirectory: true, kind: entry.kind, isPackage: entry.isPackage)
                    do {
                        let enumerator = try makeEnumerator(at: entry.url)
                        stack.append(ScanDirectoryFrame(id: id, url: entry.url, enumerator: enumerator))
                    } catch {
                        builder.markIncomplete(id, status: ScanEnumerationIssues.unavailableStatus(for: error) ?? .unreadable)
                        issues.skippedCount += 1
                    }
                }
            } else if let logicalSize = entry.logicalSize, request.fileSelection.includes(size: logicalSize),
                      request.fileSelection == .all || entry.hardLink == nil {
                observeFile(entry, in: frame)
            }
            publishIfDue(currentURL: entry.url)
        }
        try publishFinal()
    }

    private func observeFile(_ entry: Metadata, in frame: ScanDirectoryFrame) {
        guard let logicalSize = entry.logicalSize, let allocatedSize = entry.allocatedSize else { return }
        autoreleasepool {
            let ownsBytes = entry.hardLink.map { observedHardLinks.insert($0).inserted } ?? true
            totals.add(logicalSize: ownsBytes ? logicalSize : 0, allocatedSize: ownsBytes ? allocatedSize : 0, kind: entry.kind)
            if request.fileSelection == .all, entry.hardLink == nil, logicalSize < ScanFileSelection.smallFileByteLimit {
                frame.smallFiles.add(
                    name: entry.url.lastPathComponent, logicalSize: logicalSize, allocatedSize: allocatedSize,
                    kind: entry.kind, isPackage: entry.isPackage
                )
            } else {
                builder.append(
                    parent: frame.id, name: entry.url.lastPathComponent,
                    logicalSize: logicalSize, allocatedSize: allocatedSize, fileCount: 1,
                    isDirectory: false, kind: entry.kind, isPackage: entry.isPackage, hardLink: entry.hardLink
                )
            }
        }
    }

    private func finishDirectory(_ frame: ScanDirectoryFrame) {
        if frame.smallFiles.isGrouped {
            builder.append(
                parent: frame.id, name: "", logicalSize: frame.smallFiles.logicalSize, allocatedSize: frame.smallFiles.allocatedSize,
                fileCount: frame.smallFiles.count, isDirectory: true,
                isAggregate: true, bins: frame.smallFiles.bins
            )
        } else {
            for file in frame.smallFiles.candidates {
                builder.append(
                    parent: frame.id, name: file.name, logicalSize: file.logicalSize, allocatedSize: file.allocatedSize,
                    fileCount: 1, isDirectory: false, kind: file.kind, isPackage: file.isPackage
                )
            }
        }
    }

    private func makeEnumerator(at url: URL) throws -> FileManager.DirectoryEnumerator {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
        defer { close(descriptor) }
        let issues = issues
        let enumerator = autoreleasepool {
            fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: Self.prefetchedKeys,
                options: [.skipsSubdirectoryDescendants],
                errorHandler: { failedURL, error in issues.record(url: failedURL, error: error, directory: url) }
            )
        }
        guard let enumerator else { throw readError(for: url) }
        return enumerator
    }

    private func nextEntry(
        in enumerator: FileManager.DirectoryEnumerator,
        mounts: ScanMountPolicy,
        excludingReservedRootEntries: Bool
    ) throws -> Metadata? {
        while true {
            try Task.checkCancellation()
            let outcome: EnumerationStep = try autoreleasepool {
                guard let url = enumerator.nextObject() as? URL else { return .finished }
                try Task.checkCancellation()
                if excludingReservedRootEntries, systemPaths.isReservedRootName(url.lastPathComponent) {
                    issues.skippedCount += 1
                    return .excluded
                }
                if request.fileSelection == .smallFilesOnly, request.retainedFileNames.contains(url.lastPathComponent) {
                    return .excluded
                }
                if let status = mounts.status(at: url, scanRoot: rootURL) {
                    issues.skippedCount += 1
                    return .entry(Metadata(url: url, isSymbolicLink: false, isDirectory: true, kind: builder.internKind(identifier: "public.folder", fallbackName: nil), status: status))
                }
                do {
                    var entry = try readMetadata(at: url)
                    if entry.isSymbolicLink || (!entry.isDirectory && !entry.isRegularFile) {
                        issues.skippedCount += 1
                        return .excluded
                    }
                    if entry.volume != rootVolume {
                        entry.status = .otherVolume
                        issues.skippedCount += 1
                    } else if entry.status != .complete {
                        issues.skippedCount += 1
                    }
                    return .entry(entry)
                } catch {
                    issues.skippedCount += 1
                    if let entry = try? unavailableMetadata(at: url, error: error) { return .entry(entry) }
                    return .excluded
                }
            }
            switch outcome {
            case .entry(let entry): return entry
            case .finished: return nil
            case .excluded: publishIfDue(currentURL: currentDirectoryURL ?? rootURL)
            }
        }
    }

    private func readMetadata(at url: URL) throws -> Metadata {
        var cleanURL = url
        let values = try cleanURL.resourceValues(forKeys: Self.resourceKeys)
        guard let isSymbolicLink = values.isSymbolicLink else { throw readError(for: url) }
        if isSymbolicLink {
            cleanURL.removeAllCachedResourceValues()
            return Metadata(url: cleanURL, isSymbolicLink: true)
        }
        guard let isDirectory = values.isDirectory, let isRegularFile = values.isRegularFile else { throw readError(for: url) }
        guard isDirectory || isRegularFile else {
            return Metadata(url: url, isSymbolicLink: false)
        }
        guard var volume = values.volume else { throw readError(for: url) }
        var logicalSize: Int64?
        var allocatedSize: Int64?
        var hardLink: FileIdentity?
        var status = ScanEntryStatus.complete
        if isDirectory || values.linkCount == nil || (values.linkCount ?? 1) > 1 {
            var identity = stat()
            guard lstat(url.path, &identity) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
            }
            let type = identity.st_mode & S_IFMT
            guard type == (isDirectory ? S_IFDIR : S_IFREG) else { throw readError(for: url) }
            if isRegularFile, identity.st_nlink > 1 {
                hardLink = FileIdentity(device: identity.st_dev, inode: identity.st_ino)
            }
            if isDirectory, identity.st_flags & UInt32(SF_DATALESS) != 0 { status = .cloudOnly }
        }
        if isRegularFile {
            guard let logical = values.totalFileSize ?? values.fileSize, logical >= 0,
                  let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize, allocated >= 0 else {
                throw readError(for: url)
            }
            logicalSize = Int64(logical)
            allocatedSize = Int64(allocated)
        }
        let kind = builder.internKind(
            identifier: values.typeIdentifier ?? (isDirectory ? "public.folder" : "public.data"),
            fallbackName: values.localizedTypeDescription
        )
        volume.removeAllCachedResourceValues()
        cleanURL.removeAllCachedResourceValues()
        return Metadata(
            url: cleanURL, isSymbolicLink: false, isDirectory: isDirectory, isRegularFile: isRegularFile,
            isPackage: values.isPackage ?? false, logicalSize: logicalSize, allocatedSize: allocatedSize,
            kind: kind, volume: volume, status: status, hardLink: hardLink
        )
    }

    private func unavailableMetadata(at url: URL, error: any Error) throws -> Metadata {
        var identity = stat()
        let result = lstat(url.path, &identity)
        let status = ScanEnumerationIssues.unavailableStatus(for: error) ?? .unreadable
        if result != 0, ScanEnumerationIssues.unavailableStatus(for: error) == nil { throw error }
        let type = identity.st_mode & S_IFMT
        if result == 0, type == S_IFLNK { return Metadata(url: url, isSymbolicLink: true) }
        let directory = result == 0 ? type == S_IFDIR : url.hasDirectoryPath
        let kind = builder.internKind(identifier: directory ? "public.folder" : "public.data", fallbackName: nil)
        return Metadata(url: url, isSymbolicLink: false, isDirectory: directory, kind: kind, status: status)
    }

    private func publishIfDue(currentURL: URL) {
        guard clock.now - lastPublication >= .milliseconds(250) else { return }
        publishProgress(currentURL: currentURL)
    }

    private func publishProgress(currentURL: URL) {
        // Constant-size lower bounds avoid copying the growing arena on every tick.
        // The full recursive hierarchy is transferred only once, at completion.
        let component = rootURL.lastPathComponent
        let statistics = totals.statistics(kinds: builder.kinds, sizeMode: request.sizeMode)
        let index = DiskIndex(
            rootURL: rootURL, sizeMode: request.sizeMode, kinds: builder.kinds,
            entries: [DiskIndex.Entry(
                logicalSize: totals.logicalSize, allocatedSize: totals.allocatedSize,
                fileCount: totals.fileCount, parent: -1, name: 0, flags: 1
            )],
            names: [component.isEmpty ? rootURL.path : component], childLinks: [], histograms: [],
            progressTotals: totals
        )
        publish(index, isComplete: false, currentPath: currentURL.path, statistics: statistics)
    }

    private func publishFinal() throws {
        try Task.checkCancellation()
        let volumeSpace = request.fileSelection == .all ? VolumeSpaceReader().read(at: rootURL) : nil
        let index = builder.finish(volumeSpace: volumeSpace)
        try Task.checkCancellation()
        publish(index, isComplete: true, currentPath: nil, statistics: index.presentationStatistics(for: 0))
    }

    private func publish(_ index: DiskIndex, isComplete: Bool, currentPath: String?, statistics: [FileTypeStat]) {
        continuation.yield(ScanResult(
            root: index.root, skippedCount: issues.skippedCount, request: request,
            isComplete: isComplete, currentPath: currentPath, typeStatistics: statistics
        ))
        lastPublication = clock.now
    }

    private func readError(for url: URL) -> CocoaError {
        CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: url])
    }

    private struct Metadata {
        let url: URL
        let isSymbolicLink: Bool
        var isDirectory = false
        var isRegularFile = false
        var isPackage = false
        var logicalSize: Int64?
        var allocatedSize: Int64?
        var kind: UInt32 = 0
        var volume: URL?
        var status = ScanEntryStatus.complete
        var hardLink: FileIdentity?
    }

    private enum EnumerationStep {
        case entry(Metadata)
        case excluded
        case finished
    }
}
