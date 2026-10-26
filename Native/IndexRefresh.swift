import Foundation

/// Reconciles immutable recursive and small-file arenas after one directory rescan.
struct IndexRefresh: Sendable {
    let url: URL
    let replacement: DiskIndex
    let detailReplacements: [URL: DiskIndex]

    init(url: URL, replacement: DiskIndex, detailReplacements: [URL: DiskIndex] = [:]) {
        self.url = DiskIndex.lexicalURL(url)
        self.replacement = replacement
        self.detailReplacements = detailReplacements
    }

    /// Histograms have no member names: obtain exact direct-file scans before committing.
    func detailRequests(for results: [ScanResult]) -> [ScanRequest] {
        var seen: Set<URL> = []
        var requests: [ScanRequest] = []
        let scopeComponents = url.standardizedFileURL.pathComponents
        for result in results where result.request.fileSelection == .smallFilesOnly {
            let directory = result.root.index.rootURL.standardizedFileURL
            guard directory.pathComponents.starts(with: scopeComponents),
                  seen.insert(directory).inserted,
                  let group = replacement.find(url: directory, aggregate: true),
                  let request = group.groupRequest else { continue }
            requests.append(ScanRequest(
                url: directory, fileSelection: .smallFilesOnly, sizeMode: result.root.index.sizeMode,
                retainedFileNames: request.retainedFileNames
            ))
        }
        return requests
    }

    /// A new inode identity can alias an unnamed old sibling; rescan the enclosing scope.
    func requiresFullRescan(for results: [ScanResult]) -> Bool {
        results.contains {
            $0.request.fileSelection == .all
                && $0.root.index.requiresFullRescan(at: url, replacement: replacement)
        }
    }

    /// Call only after requiresFullRescan is false and requested detail scans have finished.
    func apply(to results: [ScanResult]) -> [ScanResult] {
        var replacements: [ObjectIdentifier: (index: DiskIndex, skippedDelta: Int)] = [:]
        let scopeComponents = url.standardizedFileURL.pathComponents
        return results.map { result in
            let original = result.root.index
            let key = ObjectIdentifier(original)
            let index: DiskIndex
            let skippedDelta: Int
            if let retained = replacements[key] {
                index = retained.index
                skippedDelta = retained.skippedDelta
            } else {
                let rebuilt: DiskIndex
                let directory = original.rootURL.standardizedFileURL
                if result.request.fileSelection == .smallFilesOnly,
                   directory.pathComponents.starts(with: scopeComponents) {
                    if let detail = detailReplacements[directory] {
                        rebuilt = detail.withSizeMode(original.sizeMode)
                    } else if let node = replacement.find(url: directory) {
                        if replacement.find(url: directory, aggregate: true) != nil {
                            // Without the requested name-bearing scan, expose an honest
                            // recursive scope, never an alleged ungrouped detail snapshot.
                            rebuilt = replacement.copyingSubtree(at: node.id, sizeMode: original.sizeMode)
                        } else {
                            rebuilt = replacement.smallFileProjection(at: node.id, sizeMode: original.sizeMode)
                        }
                    } else {
                        rebuilt = replacement.withSizeMode(original.sizeMode)
                    }
                } else {
                    rebuilt = original.grafting(at: url, replacement: replacement)
                }
                if original.volumeSpace != nil, rebuilt !== original {
                    let snapshot = replacement.rootURL.standardizedFileURL == rebuilt.rootURL.standardizedFileURL
                        ? replacement.volumeSpace
                        : VolumeSpaceReader().read(at: rebuilt.rootURL)
                    index = rebuilt.withVolumeSpace(snapshot)
                } else {
                    index = rebuilt
                }
                skippedDelta = index === original ? 0 : index.unavailableEntryCount - original.unavailableEntryCount
                replacements[key] = (index, skippedDelta)
            }
            let root = index.find(url: result.root.url, aggregate: result.root.isAggregate) ?? index.root
            let detailScopeSurvived = index.rootURL.standardizedFileURL == original.rootURL.standardizedFileURL
            let missingDetail = original.rootURL.standardizedFileURL.pathComponents.starts(with: scopeComponents)
                && replacement.find(url: original.rootURL, aggregate: true) != nil
                && detailReplacements[original.rootURL.standardizedFileURL] == nil
            let request: ScanRequest
            if !detailScopeSurvived || (result.request.fileSelection == .smallFilesOnly && missingDetail) {
                request = ScanRequest(url: index.rootURL, sizeMode: index.sizeMode)
            } else if result.request.fileSelection == .smallFilesOnly,
                      let fresh = replacement.find(url: index.rootURL, aggregate: true)?.groupRequest {
                request = ScanRequest(url: index.rootURL, fileSelection: .smallFilesOnly, sizeMode: index.sizeMode, retainedFileNames: fresh.retainedFileNames)
            } else if result.request.fileSelection == .smallFilesOnly,
                      original.rootURL.standardizedFileURL.pathComponents.starts(with: scopeComponents) {
                request = ScanRequest(url: index.rootURL, fileSelection: .smallFilesOnly, sizeMode: index.sizeMode)
            } else {
                request = result.request
            }
            return ScanResult(
                root: root, skippedCount: max(0, result.skippedCount + skippedDelta),
                request: request, isComplete: result.isComplete, currentPath: result.currentPath,
                typeStatistics: index.presentationStatistics(for: root.id)
            )
        }
    }
}
