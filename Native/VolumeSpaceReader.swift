import Foundation

/// Samples only a whole mounted-volume scope; a folder's complement is not snapshots.
struct VolumeSpaceReader {
    func read(at url: URL) -> VolumeSpaceSnapshot? {
        try? ScanIOPolicy().perform {
            var root = url.standardizedFileURL
            root.removeAllCachedResourceValues()
            let values = try root.resourceValues(forKeys: [.volumeURLKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey])
            guard let volume = values.volume,
                  root.path == volume.standardizedFileURL.path,
                  let capacity = values.volumeTotalCapacity,
                  let free = values.volumeAvailableCapacity,
                  capacity >= 0, free >= 0, free <= capacity else { return nil }
            return VolumeSpaceSnapshot(volumeURL: volume, capacityBytes: Int64(capacity), freeBytes: Int64(free))
        }
    }
}
