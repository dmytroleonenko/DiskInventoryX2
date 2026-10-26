import Foundation

struct FileTypeStat: Sendable {
    let kindID: UInt32
    let name: String
    let size: Int64
    let count: Int
}
