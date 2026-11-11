import Darwin
import Foundation

/// APFS clone-stream metadata for one regular file.
///
/// `read(at:)` returns `nil` unless the volume reports clone accounting for the
/// path and the file actually shares blocks with another file. Ordinary files,
/// directories, symbolic links, unsupported filesystems, unreadable paths, and
/// truncated attribute buffers also return `nil`.
struct CloneFileMetadata: Hashable, Sendable {
    /// The data stream that a full clone shares with its siblings.
    struct Identity: Hashable, Sendable {
        let device: UInt64
        let stream: UInt64
    }

    let identity: Identity
    /// Allocated bytes in the data fork only. The resource fork, extended
    /// attributes, and clone-shared extents are not added to this value.
    let dataAllocatedSize: Int64
    /// `EF_SHARES_ALL_BLOCKS`: every data block is shared with another file,
    /// so this file is a pure clone.
    let sharesAllBlocks: Bool
    /// `EF_MAY_SHARE_BLOCKS`: at least some extents may still be shared. This
    /// is true for pure clones and for clones that diverged through
    /// copy-on-write.
    let mayShareBlocks: Bool
    /// Kernel-reported count of full clones on this stream from
    /// `ATTR_CMNEXT_CLONE_REFCNT`. The stream is only deduplicated when the
    /// sharing flags above are set.
    let cloneReferenceCount: UInt32

    var isFullClone: Bool { sharesAllBlocks }

    /// Reads clone metadata with `getattrlist(2)` and never follows a final
    /// symbolic link. Returns `nil` rather than guessing when any requested
    /// attribute is missing, zero, negative, or truncated.
    static func read(at url: URL) -> CloneFileMetadata? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_OBJTYPE)
        request.fileattr = attrgroup_t(ATTR_FILE_DATAALLOCSIZE)
        request.forkattr = attrgroup_t(ATTR_CMNEXT_REALDEVID)
            | attrgroup_t(ATTR_CMNEXT_CLONEID)
            | attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)
            | attrgroup_t(ATTR_CMNEXT_CLONE_REFCNT)
        // The fixed set of attributes fits in 64 bytes; keep this hot-path buffer on the stack.
        var buffer = (UInt64(0), UInt64(0), UInt64(0), UInt64(0),
                      UInt64(0), UInt64(0), UInt64(0), UInt64(0))
        let options = UInt32(FSOPT_NOFOLLOW) | UInt32(FSOPT_ATTR_CMN_EXTENDED)
        return url.withUnsafeFileSystemRepresentation { path -> CloneFileMetadata? in
            guard let path else { return nil }
            return withUnsafeMutableBytes(of: &buffer) { bytes in
                guard let base = bytes.baseAddress,
                      getattrlist(path, &request, base, bytes.count, options) == 0 else { return nil }
                return parse(UnsafeRawBufferPointer(bytes))
            }
        }
    }

    private static func parse(_ buffer: UnsafeRawBufferPointer) -> CloneFileMetadata? {
        // The returned attribute buffer starts with its own byte length, then
        // an attribute_set_t laid out as five u_int32 fields in host order.
        let returnedSetSize = 5 * MemoryLayout<UInt32>.size
        guard let declared = readUInt32(buffer, at: 0, limit: buffer.count),
              declared >= UInt32(4 + returnedSetSize),
              Int(declared) <= buffer.count else { return nil }
        let limit = Int(declared)
        guard let common = readUInt32(buffer, at: 4, limit: limit),
              let file = readUInt32(buffer, at: 4 + 3 * MemoryLayout<UInt32>.size, limit: limit),
              let fork = readUInt32(buffer, at: 4 + 4 * MemoryLayout<UInt32>.size, limit: limit) else { return nil }
        var offset = 4 + returnedSetSize
        let requiredCommon = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_OBJTYPE)
        let requiredFile = attrgroup_t(ATTR_FILE_DATAALLOCSIZE)
        let requiredFork = attrgroup_t(ATTR_CMNEXT_REALDEVID)
            | attrgroup_t(ATTR_CMNEXT_CLONEID)
            | attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)
            | attrgroup_t(ATTR_CMNEXT_CLONE_REFCNT)
        guard (common & requiredCommon) == requiredCommon,
              (file & requiredFile) == requiredFile,
              (fork & requiredFork) == requiredFork else { return nil }

        guard let objectType = readUInt32(buffer, at: offset, limit: limit),
              objectType == VREG.rawValue else { return nil }
        offset += MemoryLayout<UInt32>.size
        guard let allocated = readInt64(buffer, at: offset, limit: limit), allocated >= 0 else { return nil }
        offset += MemoryLayout<Int64>.size
        guard let device = readInt32(buffer, at: offset, limit: limit), device > 0 else { return nil }
        offset += MemoryLayout<Int32>.size
        guard let stream = readUInt64(buffer, at: offset, limit: limit), stream != 0 else { return nil }
        offset += MemoryLayout<UInt64>.size
        guard let extendedFlags = readUInt64(buffer, at: offset, limit: limit) else { return nil }
        offset += MemoryLayout<UInt64>.size
        guard let referenceCount = readUInt32(buffer, at: offset, limit: limit) else { return nil }

        let sharesAllBlocks = extendedFlags & UInt64(EF_SHARES_ALL_BLOCKS) != 0
        let mayShareBlocks = extendedFlags & UInt64(EF_MAY_SHARE_BLOCKS) != 0
        guard sharesAllBlocks || mayShareBlocks else { return nil }
        return CloneFileMetadata(
            identity: Identity(device: UInt64(device), stream: stream),
            dataAllocatedSize: allocated,
            sharesAllBlocks: sharesAllBlocks,
            mayShareBlocks: mayShareBlocks,
            cloneReferenceCount: referenceCount
        )
    }

    private static func fits(_ offset: Int, _ size: Int, _ limit: Int) -> Bool {
        offset >= 0 && size >= 0 && offset <= limit && size <= limit - offset
    }

    private static func readUInt32(_ buffer: UnsafeRawBufferPointer, at offset: Int, limit: Int) -> UInt32? {
        guard fits(offset, MemoryLayout<UInt32>.size, limit) else { return nil }
        return buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
    }

    private static func readInt32(_ buffer: UnsafeRawBufferPointer, at offset: Int, limit: Int) -> Int32? {
        guard fits(offset, MemoryLayout<Int32>.size, limit) else { return nil }
        return buffer.loadUnaligned(fromByteOffset: offset, as: Int32.self)
    }

    private static func readInt64(_ buffer: UnsafeRawBufferPointer, at offset: Int, limit: Int) -> Int64? {
        guard fits(offset, MemoryLayout<Int64>.size, limit) else { return nil }
        return buffer.loadUnaligned(fromByteOffset: offset, as: Int64.self)
    }

    private static func readUInt64(_ buffer: UnsafeRawBufferPointer, at offset: Int, limit: Int) -> UInt64? {
        guard fits(offset, MemoryLayout<UInt64>.size, limit) else { return nil }
        return buffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
    }
}
