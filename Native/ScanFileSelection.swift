/// Small-file drill requests include direct regular files only.
enum ScanFileSelection: Sendable, Equatable {
    case all
    case smallFilesOnly

    static let smallFileByteLimit: Int64 = 1_000_000

    func includes(size: Int64) -> Bool {
        switch self {
        case .all: true
        case .smallFilesOnly: size < Self.smallFileByteLimit
        }
    }
}
