import Foundation

/// Active traversal state only; URLs/enumerators are released when a directory ends.
final class ScanDirectoryFrame {
    let id: Int
    let url: URL
    let enumerator: FileManager.DirectoryEnumerator
    var smallFiles = ScanSmallFiles()

    init(id: Int, url: URL, enumerator: FileManager.DirectoryEnumerator) {
        self.id = id
        self.url = url
        self.enumerator = enumerator
    }
}
