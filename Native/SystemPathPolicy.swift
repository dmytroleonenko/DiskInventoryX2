import Foundation

/// Root-only macOS lookup namespaces, not ordinary similarly named user entries.
struct SystemPathPolicy {
    func isReservedRootName(_ name: some StringProtocol) -> Bool {
        name == ".nofollow" || name == ".resolve" || name == ".vol" || name == ".file"
    }

    func excludes(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        // Inspect the URL before lexical normalization can hide a reserved prefix.
        let originalPath = URLComponents(url: url, resolvingAgainstBaseURL: true)?.path ?? url.path
        if hasReservedPrefix(originalPath) { return true }
        return hasReservedPrefix(url.standardizedFileURL.path)
    }

    private func hasReservedPrefix(_ path: String) -> Bool {
        guard path.first == "/" else { return false }
        let component = path.drop(while: { $0 == "/" }).prefix(while: { $0 != "/" })
        return isReservedRootName(component)
    }
}
