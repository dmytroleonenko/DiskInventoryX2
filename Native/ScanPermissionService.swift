import Foundation
import Darwin

/// Performs directory-only privacy reads before inventory traversal, never API-level grants.
actor ScanPermissionService: ScanPermissionsPreparing {
    private let homeDirectory: URL
    // Constructor injection permits mount-boundary tests without mounting anything.
    private let mountSnapshot: [ScanMountPolicy.Mount]?

    init(homeDirectory: URL = FileManager().homeDirectoryForCurrentUser, mounts: [ScanMountPolicy.Mount]? = nil) {
        self.homeDirectory = homeDirectory
        self.mountSnapshot = mounts
    }

    nonisolated func prepare(_ request: ScanRequest) -> AsyncThrowingStream<ScanPermissionEvent, Error> {
        AsyncThrowingStream { continuation in
            guard !Task.isCancelled else {
                continuation.finish(throwing: CancellationError())
                return
            }
            let producer = Task.detached(priority: .userInitiated) {
                do {
                    try await self.produce(request, continuation: continuation)
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    private func produce(_ request: ScanRequest, continuation: AsyncThrowingStream<ScanPermissionEvent, Error>.Continuation) throws {
        try Task.checkCancellation()
        try ScanIOPolicy().perform {
            let mounts = try mountSnapshot.map { ScanMountPolicy(mounts: $0) } ?? ScanMountPolicy()
            let policy = SystemPathPolicy()
            guard request.url.isFileURL, !policy.excludes(request.url) else {
                throw CocoaError(.fileReadNoPermission, userInfo: [NSURLErrorKey: request.url])
            }
            let root = request.url.standardizedFileURL
            var queue = ScanPermissionCatalog(homeDirectory: homeDirectory).entries(for: request)
            var discoveryByPath: [String: ScanPermissionCatalog.Discovery] = [:]
            for entry in queue {
                if let discovery = entry.discovery,
                   discoveryByPath[entry.target.url.path] == nil || discovery != .libraries {
                    discoveryByPath[entry.target.url.path] = discovery
                }
            }
            var checked: Set<String> = []
            var blocked: [URL] = []
            var denied: [ScanPermissionDenial] = []
            var checkedCount = 0
            var index = 0
            while index < queue.count {
                try Task.checkCancellation()
                let entry = queue[index]
                index += 1
                let target = entry.target
                guard checked.insert(target.url.path).inserted,
                      !policy.excludes(target.url),
                      mounts.statusForCandidate(at: target.url, scanRoot: root) == nil,
                      !blocked.contains(where: { ScanPermissionScope.contains($0, target.url) }) else { continue }
                // Prefer a specific discovery rule over the generic selected-directory rule.
                let discovery = discoveryByPath[target.url.path]
                continuation.yield(.checking(target))
                try Task.checkCancellation()
                let result = try probe(target, root: root, mounts: mounts, discovery: discovery)
                if result.attempted { checkedCount += 1 }
                if let failure = result.denial {
                    if !denied.contains(where: { $0.target.url.path == failure.target.url.path }) { denied.append(failure) }
                    blocked.append(failure.target.url)
                }
                if let discovery {
                    for candidate in result.candidates {
                        try Task.checkCancellation()
                        let child = target.url.appendingPathComponent(candidate.name, isDirectory: true)
                        if discovery == .homes {
                            let homeRequest = ScanRequest(url: child)
                            for homeEntry in ScanPermissionCatalog(homeDirectory: child).entries(for: homeRequest) {
                                guard !checked.contains(homeEntry.target.url.path) else { continue }
                                if let rule = homeEntry.discovery,
                                   discoveryByPath[homeEntry.target.url.path] == nil || rule != .libraries {
                                    discoveryByPath[homeEntry.target.url.path] = rule
                                }
                                queue.append(homeEntry)
                            }
                            continue
                        }
                        queue.append(.init(target: .init(url: child, kind: candidate.kind), discovery: nil))
                        if discovery == .containers {
                            queue.append(.init(target: .init(url: child.appendingPathComponent("Data", isDirectory: true), kind: candidate.kind), discovery: nil))
                        }
                    }
                }
            }
            try Task.checkCancellation()
            continuation.yield(.finished(ScanPermissionReport(checkedCount: checkedCount, denied: denied)))
        }
    }

    private struct ProbeResult {
        var attempted = false
        var denial: ScanPermissionDenial?
        var candidates: [(name: String, kind: ScanPermissionTarget.Kind)] = []
    }

    /// Match the scanner's explicit-root semantics: ancestor aliases are permitted,
    /// but the selected root itself and every descendant component are no-follow.
    private func probe(_ target: ScanPermissionTarget, root: URL, mounts: ScanMountPolicy, discovery: ScanPermissionCatalog.Discovery?) throws -> ProbeResult {
        var result = ProbeResult()
        guard mounts.statusForCandidate(at: root, scanRoot: root) == nil else { return result }
        try Task.checkCancellation()
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0 else {
            let code = errno
            result.denial = denial(target: .init(url: root, kind: target.kind), code: code)
            result.attempted = result.denial != nil
            return result
        }
        guard ScanPermissionScope.permitsDirectory(mode: rootInfo.st_mode, flags: rootInfo.st_flags) else { return result }
        var descriptor = open(root.path, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            let code = errno
            result.denial = denial(target: .init(url: root, kind: target.kind), code: code)
            result.attempted = result.denial != nil
            return result
        }
        defer { if descriptor >= 0 { close(descriptor) } }
        var openedRoot = stat()
        guard fstat(descriptor, &openedRoot) == 0 else {
            let code = errno
            result.denial = denial(target: .init(url: root, kind: target.kind), code: code)
            result.attempted = result.denial != nil
            return result
        }
        guard openedRoot.st_flags & UInt32(SF_DATALESS) == 0 else { return result }
        let components = Array(target.url.pathComponents.dropFirst(root.pathComponents.count))
        var current = root
        for (index, component) in components.enumerated() {
            try Task.checkCancellation()
            current.appendPathComponent(component, isDirectory: true)
            // Check jumps before even looking up metadata; autofs can trigger on lookup.
            guard mounts.statusForCandidate(at: current, scanRoot: root) == nil else { return result }
            var info = stat()
            guard fstatat(descriptor, component, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                let code = errno
                let failed = ScanPermissionScope.contains(root, current) ? current : target.url
                result.denial = denial(target: .init(url: failed, kind: target.kind), code: code)
                result.attempted = result.denial != nil
                return result
            }
            guard ScanPermissionScope.permitsDirectory(mode: info.st_mode, flags: info.st_flags) else { return result }
            let final = index == components.count - 1
            let flags = (final ? O_RDONLY : O_EVTONLY) | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
            let next = openat(descriptor, component, flags)
            guard next >= 0 else {
                let code = errno
                let failed = ScanPermissionScope.contains(root, current) ? current : target.url
                result.denial = denial(target: .init(url: failed, kind: target.kind), code: code)
                result.attempted = final || result.denial != nil
                return result
            }
            close(descriptor)
            descriptor = next
            // Recheck the opened inode in case the entry was replaced after fstatat.
            var opened = stat()
            guard fstat(descriptor, &opened) == 0 else {
                let code = errno
                let failed = ScanPermissionScope.contains(root, current) ? current : target.url
                result.denial = denial(target: .init(url: failed, kind: target.kind), code: code)
                result.attempted = final || result.denial != nil
                return result
            }
            guard opened.st_flags & UInt32(SF_DATALESS) == 0 else { return result }
        }
        try Task.checkCancellation()
        if components.isEmpty {
            let readable = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard readable >= 0 else {
                result.denial = denial(target: target, code: errno)
                result.attempted = true
                return result
            }
            close(descriptor)
            descriptor = readable
        }
        result.attempted = true
        guard let directory = fdopendir(descriptor) else {
            result.denial = denial(target: target, code: errno)
            return result
        }
        descriptor = -1 // fdopendir now owns the descriptor.
        defer { closedir(directory) }
        repeat {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(directory) else {
                result.denial = denial(target: target, code: errno)
                break
            }
            if let discovery {
                let type = Int32(entry.pointee.d_type)
                guard type == DT_DIR || type == DT_UNKNOWN else { continue }
                let length = Int(entry.pointee.d_namlen)
                let candidate = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { name -> (name: String, kind: ScanPermissionTarget.Kind)? in
                        guard let kind = discovery.kind(for: UnsafeBufferPointer(start: name, count: length)) else { return nil }
                        let value = String(cString: name)
                        if type == DT_UNKNOWN {
                            let child = target.url.appendingPathComponent(value, isDirectory: true)
                            guard mounts.statusForCandidate(at: child, scanRoot: root) == nil else { return nil }
                            var info = stat()
                            if fstatat(dirfd(directory), name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                                guard ScanPermissionScope.permitsDirectory(mode: info.st_mode, flags: info.st_flags) else { return nil }
                            } else {
                                let code = errno
                                // Retain actual permission failures for the normal reporting probe.
                                guard code == EPERM || code == EACCES else { return nil }
                            }
                        }
                        return (value, kind)
                    }
                }
                if let candidate { result.candidates.append(candidate) }
            }
        } while discovery != nil
        return result
    }

    private func denial(target: ScanPermissionTarget, code: Int32) -> ScanPermissionDenial? {
        guard code == EPERM || code == EACCES else { return nil }
        return ScanPermissionDenial(target: target, code: code)
    }
}
