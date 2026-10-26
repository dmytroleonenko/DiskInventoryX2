/// Combined bytes and multiplicity for one file-kind × logarithmic-size bucket.
struct ScanMosaicBin: Sendable {
    let size: Int64
    let logicalSize: Int64
    let allocatedSize: Int64
    let count: Int
    let kindID: UInt32
}
