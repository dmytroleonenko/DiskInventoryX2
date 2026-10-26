import Foundation

// Foundation invokes each enumerator's error handler synchronously; this state is
// confined to one scan producer, including its nested, serial enumerators.
final class ScanEnumerationIssues: @unchecked Sendable {
    let rootPath: String
    var skippedCount = 0
    private var directoryStatuses: [String: ScanEntryStatus] = [:]

    init(rootPath: String) {
        self.rootPath = rootPath
    }

    func record(url: URL, error: any Error, directory: URL) -> Bool {
        let isDirectoryFailure = url.standardizedFileURL.path == directory.path
        let status: ScanEntryStatus = isDirectoryFailure ? Self.unavailableStatus(for: error) ?? .unreadable : .partial
        if directoryStatuses[directory.path] == nil || status != .partial {
            directoryStatuses[directory.path] = status
        }
        skippedCount += 1
        return !isDirectoryFailure
    }

    func status(for directory: URL) -> ScanEntryStatus {
        directoryStatuses[directory.path] ?? .complete
    }

    static func unavailableStatus(for error: any Error) -> ScanEntryStatus? {
        var current = error as NSError
        var fallback: ScanEntryStatus?
        for _ in 0..<8 {
            if current.domain == NSPOSIXErrorDomain {
                if current.code == Int(EDEADLK) { return .cloudOnly }
                if current.code == Int(EACCES) || current.code == Int(EPERM) { fallback = .unreadable }
            }
            if current.domain == NSCocoaErrorDomain, current.code == CocoaError.fileReadNoPermission.rawValue {
                fallback = .unreadable
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        return fallback
    }
}
