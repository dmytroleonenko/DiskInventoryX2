import Foundation

actor VolumeCatalog {
    func volumes(showHidden: Bool) throws -> [DiskVolume] {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeLocalizedFormatDescriptionKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        guard var urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: showHidden ? [] : [.skipHiddenVolumes]
        ) else { throw CocoaError(.fileReadUnknown) }
        // The startup filesystem must remain selectable even if the OS hides it from browsing.
        if !urls.contains(where: { $0.standardizedFileURL.path == "/" }) {
            urls.append(URL(fileURLWithPath: "/", isDirectory: true))
        }
        // Foundation may omit the mounted Data member of the startup APFS group.
        let dataURL = URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true)
        if showHidden,
           !urls.contains(where: { $0.standardizedFileURL == dataURL }),
           let mountedAt = try? dataURL.resourceValues(forKeys: [.volumeURLKey]).volume,
           mountedAt.standardizedFileURL == dataURL {
            urls.append(dataURL)
        }
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: keys)
            return DiskVolume(url: url, name: values?.volumeName ?? url.lastPathComponent,
                              formatDescription: values?.volumeLocalizedFormatDescription,
                              totalCapacity: values?.volumeTotalCapacity.map(Int64.init),
                              availableCapacity: values?.volumeAvailableCapacity.map(Int64.init))
        }.sorted {
            if $0.isStartup != $1.isStartup { return $0.isStartup }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
