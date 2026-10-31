// Forel - A native macOS file-automation app
// Copyright (C) 2026 Lab421
import Foundation
import Darwin

/// Anchors the source to an open descriptor and refuses symlinks in every
/// relative component. A private snapshot prevents a later path swap from
/// changing the file consumed by curl or URLSession.
final class UploadLocalFiles {
    private let root: Int32
    private let directory: Bool
    init(path: String, directory: Bool) throws {
        self.directory = directory
        root = open(path, O_RDONLY | O_NOFOLLOW | (directory ? O_DIRECTORY : 0))
        guard root >= 0 else { throw ActionError("Cannot safely open the upload source") }
        var info = stat()
        guard fstat(root, &info) == 0, (info.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG) else {
            close(root); throw ActionError("Upload source changed or is not a regular file")
        }
    }
    deinit { close(root) }

    func withSnapshot<T>(_ relative: String?, _ body: (URL) throws -> T) throws -> T {
        var current = dup(root)
        guard current >= 0 else { throw ActionError("Cannot safely open the upload source") }
        defer { close(current) }
        if directory {
            guard let relative else { throw ActionError("Missing upload file path") }
            let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw ActionError("Invalid upload file path") }
            for (index, part) in parts.enumerated() {
                let next = openat(current, String(part), O_RDONLY | O_NOFOLLOW | (index == parts.count - 1 ? 0 : O_DIRECTORY))
                guard next >= 0 else { throw ActionError("Upload file changed or contains a symbolic link") }
                close(current); current = next
            }
        } else if relative != nil { throw ActionError("Invalid upload file path") }
        var info = stat()
        guard fstat(current, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw ActionError("Upload file changed or is not a regular file") }
        guard lseek(current, 0, SEEK_SET) >= 0 else { throw ActionError("Cannot read upload file") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("forel-upload-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("data")
        guard FileManager.default.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ActionError("Cannot prepare upload file") }
        let inputFD = dup(current)
        guard inputFD >= 0 else { throw ActionError("Cannot read upload file") }
        let input = FileHandle(fileDescriptor: inputFD, closeOnDealloc: true)
        let output = try FileHandle(forWritingTo: path)
        defer { try? input.close(); try? output.close() }
        while let chunk = try input.read(upToCount: 131_072), !chunk.isEmpty {
            if Task<Never, Never>.isCancelled { throw ActionError("Upload was cancelled") }
            try output.write(contentsOf: chunk)
        }
        var after = stat()
        guard fstat(current, &after) == 0,
              after.st_dev == info.st_dev, after.st_ino == info.st_ino, after.st_size == info.st_size,
              after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec else {
            throw ActionError("Upload file changed while it was being read")
        }
        try output.close()
        return try body(path)
    }
}
