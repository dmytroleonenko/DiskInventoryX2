import Foundation

/// Reconciles every retained view once per arena, including a small-file detail view's parent.
struct IndexDeletion: Sendable {
    let url: URL
    let logicalSize: Int64
    let allocatedSize: Int64
    let kindIdentifier: String

    func apply(to results: [ScanResult]) -> [ScanResult] {
        var replacements: [ObjectIdentifier: DiskIndex] = [:]
        return results.map { result in
            let key = ObjectIdentifier(result.root.index)
            let index: DiskIndex
            if let replacement = replacements[key] {
                index = replacement
            } else {
                let original = result.root.index
                let rebuilt = original.removingItem(at: url, logicalSize: logicalSize, allocatedSize: allocatedSize, kindIdentifier: kindIdentifier)
                index = original.volumeSpace == nil
                    ? rebuilt
                    : rebuilt.withVolumeSpace(VolumeSpaceReader().read(at: original.rootURL))
                replacements[key] = index
            }
            let root = index.find(url: result.root.url, aggregate: result.root.isAggregate) ?? index.root
            return ScanResult(
                root: root, skippedCount: result.skippedCount, request: result.request,
                isComplete: result.isComplete, currentPath: result.currentPath,
                typeStatistics: index.presentationStatistics(for: root.id)
            )
        }
    }
}
