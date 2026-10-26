import Foundation

/// A recursive scan, or an explicit ungrouped drill into direct small files.
struct ScanRequest: Sendable, Equatable {
    let url: URL
    let fileSelection: ScanFileSelection
    let sizeMode: DiskSizeMode
    /// Individual sibling files are not members of the aggregate being drilled.
    let retainedFileNames: Set<String>

    init(url: URL, fileSelection: ScanFileSelection = .all, sizeMode: DiskSizeMode = .physical, retainedFileNames: Set<String> = []) {
        self.url = url
        self.fileSelection = fileSelection
        self.sizeMode = sizeMode
        self.retainedFileNames = retainedFileNames
    }
}
