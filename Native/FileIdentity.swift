import Darwin

/// Device and inode identify hard links; APFS clones have distinct identities.
struct FileIdentity: Hashable, Sendable {
    let device: dev_t
    let inode: ino_t
}
