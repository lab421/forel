import Darwin
import Foundation

/// Stable on-disk identity for a file: which volume it's on and its inode
/// number. Used only by `WatcherCoordinator` to tell whether a path still
/// refers to the same file it last evaluated.
struct FileIdentity: Equatable {
    let volumeId: Int64
    let fileId: Int64
}

enum FileFingerprint {
    /// Cheap content fingerprint based on size and modification time —
    /// enough to detect "this file changed since we last looked" without
    /// hashing file contents.
    static func current(_ path: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return "\(st.st_size)-\(st.st_mtimespec.tv_sec)-\(st.st_mtimespec.tv_nsec)"
    }

    static func identity(_ path: String) -> FileIdentity? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return FileIdentity(volumeId: Int64(st.st_dev), fileId: Int64(st.st_ino))
    }
}
