import Foundation
import Darwin

/// Lexical scope only: never resolves symlinks or asks the filesystem about ancestry.
struct ScanPermissionScope: Sendable {
    let request: ScanRequest

    static func permitsDirectory(mode: mode_t, flags: UInt32) -> Bool {
        mode & S_IFMT == S_IFDIR && flags & UInt32(SF_DATALESS) == 0
    }

    static func components(of url: URL) -> [String] {
        var parts = url.standardizedFileURL.pathComponents.filter { $0 != "/" }
        if parts.starts(with: ["System", "Volumes", "Data"]) { parts.removeFirst(3) }
        return parts
    }

    static func contains(_ ancestor: URL, _ descendant: URL) -> Bool {
        components(of: descendant).starts(with: components(of: ancestor))
    }

    /// Reanchors firmlink aliases under the exact path selected by the caller.
    func target(for protectedURL: URL, kind: ScanPermissionTarget.Kind) -> ScanPermissionTarget? {
        guard request.url.isFileURL, protectedURL.isFileURL else { return nil }
        let root = Self.components(of: request.url)
        let candidate = Self.components(of: protectedURL)
        if root.starts(with: candidate) {
            return ScanPermissionTarget(url: request.url.standardizedFileURL, kind: kind)
        }
        guard request.fileSelection == .all, candidate.starts(with: root) else { return nil }
        let url = candidate.dropFirst(root.count).reduce(request.url.standardizedFileURL) {
            $0.appendingPathComponent($1, isDirectory: true)
        }
        return ScanPermissionTarget(url: url, kind: kind)
    }
}
