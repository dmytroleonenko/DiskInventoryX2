import Darwin
import Foundation

/// Exercises real APFS clone metadata against clonefile, copy-on-write
/// divergence, independent copies, and unavailable paths.
@MainActor
struct CloneFileMetadataSmoke {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    private static func clone(_ source: URL, to destination: URL) throws {
        let status = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return Int32(-1) }
                return clonefile(sourcePath, destinationPath, 0)
            }
        }
        guard status == 0 else {
            throw Failure(description: "clonefile failed: \(String(cString: strerror(errno)))")
        }
    }

    private static func allocatedBlocks(_ url: URL) throws -> Int64 {
        var info = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &info)
        }
        guard status == 0 else { throw Failure(description: "lstat failed: \(url.path)") }
        return Int64(info.st_blocks) * 512
    }

    private static func metadata(_ url: URL) throws -> CloneFileMetadata {
        guard let metadata = CloneFileMetadata.read(at: url) else {
            throw Failure(description: "Missing clone metadata: \(url.path)")
        }
        return metadata
    }

    static func run(root: URL) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let original = root.appendingPathComponent("original.bin")
        var bytes = [UInt8](repeating: 0, count: 1_048_576)
        var state: UInt32 = 0x9e37_79b9
        for index in bytes.indices {
            state = state &* 1_664_525 &+ 1_013_904_223
            bytes[index] = UInt8(truncatingIfNeeded: state >> 16)
        }
        let payload = Data(bytes)
        try payload.write(to: original)
        let resourceFork = URL(fileURLWithPath: original.path + "/..namedfork/rsrc")
        try Data(repeating: 0x52, count: 512 * 1024).write(to: resourceFork)

        try check(CloneFileMetadata.read(at: original) == nil, "An ordinary file acquired clone metadata before any clone existed")

        let cloneURL = root.appendingPathComponent("clone.bin")
        try clone(original, to: cloneURL)

        let total = try allocatedBlocks(original)
        let originalMetadata = try metadata(original)
        let cloneMetadata = try metadata(cloneURL)
        try check(originalMetadata.isFullClone && originalMetadata.mayShareBlocks, "The clone source was not part of the full-clone group")
        try check(cloneMetadata.isFullClone && cloneMetadata.mayShareBlocks, "A pure clone was not reported as sharing all blocks")
        try check(originalMetadata.identity == cloneMetadata.identity, "A pure clone did not share its source's clone identity")
        try check(originalMetadata.cloneReferenceCount >= 2 && cloneMetadata.cloneReferenceCount >= 2, "A full-clone group did not report more than one member")
        try check(originalMetadata.dataAllocatedSize > 0 && cloneMetadata.dataAllocatedSize == originalMetadata.dataAllocatedSize, "The clone did not retain the source's data-fork allocation")
        try check(total > originalMetadata.dataAllocatedSize, "Data-fork allocation absorbed resource-fork bytes")

        let realCopy = root.appendingPathComponent("real-copy.bin")
        try payload.write(to: realCopy)
        try check(CloneFileMetadata.read(at: realCopy) == nil, "An independently written copy was reported as a clone")

        let divergent = root.appendingPathComponent("divergent.bin")
        try clone(original, to: divergent)
        let beforeDivergence = try metadata(divergent)
        try check(beforeDivergence.identity == cloneMetadata.identity && beforeDivergence.isFullClone, "A second pure clone did not join the clone group")

        let handle = try FileHandle(forWritingTo: divergent)
        _ = try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(repeating: 0xa7, count: 4096))
        try handle.synchronize()
        try handle.close()

        let afterDivergence = try metadata(divergent)
        try check(!afterDivergence.isFullClone && afterDivergence.mayShareBlocks, "A copy-on-write divergence was still reported as a pure clone")
        try check(afterDivergence.dataAllocatedSize > 0, "A divergent clone lost its data-fork allocation")
        let unaffected = try metadata(cloneURL)
        try check(unaffected.isFullClone && unaffected.identity == originalMetadata.identity, "Modifying one clone disturbed a sibling's full-clone identity")

        try check(CloneFileMetadata.read(at: root.appendingPathComponent("missing.bin")) == nil, "A missing path produced clone metadata")
        try check(CloneFileMetadata.read(at: root) == nil, "A directory produced clone metadata")

        let link = root.appendingPathComponent("link.bin")
        try manager.createSymbolicLink(at: link, withDestinationURL: original)
        try check(CloneFileMetadata.read(at: link) == nil, "A symbolic link was followed to its clone-sharing target")

        let dangling = root.appendingPathComponent("dangling.bin")
        try manager.createSymbolicLink(at: dangling, withDestinationURL: root.appendingPathComponent("missing.bin"))
        try check(CloneFileMetadata.read(at: dangling) == nil, "A dangling symbolic link produced clone metadata")

        print("PASS: APFS full-clone identity and reference count; data-fork-only allocation; copy-on-write divergence flags; ordinary copies, directories, symlinks, missing paths, and unsupported metadata return nil")
    }
}
