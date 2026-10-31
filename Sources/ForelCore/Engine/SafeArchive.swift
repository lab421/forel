import Foundation
import Darwin
import CArchive

/// Reads archive entries without delegating path creation to an extractor.
/// Links, special files, traversal paths and oversized output are rejected.
enum SafeArchive {
    private static let maxEntries = 100_000
    private static let maxBytes: UInt64 = 10 * 1024 * 1024 * 1024
    private static let timeout: TimeInterval = 300

    static func topLevelItems(path: String) throws -> [String] {
        try process(path: path, destination: nil)
    }

    static func extract(path: String, destination: String, maxOutputBytes: UInt64 = maxBytes, zipDates: [String: Date]? = nil) throws {
        let quarantine = try readQuarantine(path: path)
        _ = try process(path: path, destination: destination, limit: maxOutputBytes, quarantine: quarantine, zipDates: zipDates)
    }

    static func readQuarantine(path: String) throws -> Data? {
        let size = getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
        if size < 0 {
            if errno == ENOATTR || errno == ENOTSUP { return nil }
            throw ActionError("Cannot read archive quarantine metadata")
        }
        guard size <= 4096 else { throw ActionError("Archive quarantine metadata is too large") }
        var data = Data(count: size)
        let actual = data.withUnsafeMutableBytes { bytes in
            getxattr(path, "com.apple.quarantine", bytes.baseAddress, size, 0, XATTR_NOFOLLOW)
        }
        guard actual == size else { throw ActionError("Archive quarantine metadata changed during extraction") }
        return data
    }

    static func applyQuarantine(_ value: Data?, to path: String) throws {
        guard let value else { return }
        let result = value.withUnsafeBytes { bytes in
            setxattr(path, "com.apple.quarantine", bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
        }
        guard result == 0 else { throw ActionError("Cannot preserve archive quarantine metadata") }
    }

    private static func process(path: String, destination: String?, limit: UInt64 = maxBytes, quarantine: Data? = nil, zipDates: [String: Date]? = nil) throws -> [String] {
        guard let archive = archive_read_new() else { throw ActionError("Cannot initialize archive reader") }
        defer { archive_read_free(archive) }
        // Some libarchive builds register PATH-based helper programs when a
        // codec is unavailable. A separate probe lets us exclude those before
        // they can be attached to the reader handling untrusted input.
        for code: Int32 in [0, 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14] {
            guard let probe = archive_read_new() else { throw ActionError("Cannot initialize archive filter probe") }
            let supported = archive_read_support_filter_by_code(probe, code) == ARCHIVE_OK
            archive_read_free(probe)
            if supported, archive_read_support_filter_by_code(archive, code) != ARCHIVE_OK {
                throw ActionError("Cannot safely configure archive filters")
            }
        }
        archive_read_support_format_all(archive)
        archive_read_support_format_raw(archive)
        guard archive_read_open_filename(archive, path, 65_536) == ARCHIVE_OK else {
            throw failure(archive, "Cannot open archive")
        }
        let deadline = Date().addingTimeInterval(timeout)
        var entry: OpaquePointer?
        var count = 0
        var total: UInt64 = 0
        var roots = Set<String>()
        var directoryMetadata: [(String, mode_t, [FileAttributeKey: Any])] = []
        while true {
            guard !Task.isCancelled, Date() < deadline else { throw ActionError("Archive processing was cancelled or timed out") }
            let status = archive_read_next_header(archive, &entry)
            if status == ARCHIVE_EOF { break }
            guard status == ARCHIVE_OK, let item = entry else { throw failure(archive, "Cannot read archive entry") }
            count += 1
            guard count <= maxEntries else { throw ActionError("Archive contains too many entries") }
            guard archive_entry_symlink(item) == nil, archive_entry_hardlink(item) == nil else {
                throw ActionError("Archive contains a symbolic or hard link")
            }
            let type = archive_entry_filetype(item)
            guard type == AE_IFREG || type == AE_IFDIR else { throw ActionError("Archive contains a special file") }
            let raw = (archive_format(archive) & ARCHIVE_FORMAT_BASE_MASK) == ARCHIVE_FORMAT_RAW
            if raw && archive_filter_code(archive, 0) == ARCHIVE_FILTER_NONE {
                throw ActionError("The file is not a supported archive")
            }
            let name: String
            if raw {
                name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            } else {
                guard let pointer = archive_entry_pathname(item), let value = String(validatingUTF8: pointer), value.utf8.count <= 4096 else {
                    throw ActionError("Archive entry has an invalid name")
                }
                name = value
            }
            let rawParts = name.split(separator: "/", omittingEmptySubsequences: true)
            let parts = rawParts.filter { $0 != "." }
            guard !name.hasPrefix("/"), !parts.contains(".."), !parts.isEmpty else {
                if type == AE_IFDIR && (name == "." || name == "./") { continue }
                throw ActionError("Archive contains an unsafe path")
            }
            roots.insert(String(parts[0]))
            let size = archive_entry_size(item)
            if size > 0 {
                guard UInt64(size) <= limit - total else { throw ActionError("Archive exceeds the extraction size limit") }
            }
            guard let destination else {
                guard archive_read_data_skip(archive) == ARCHIVE_OK else { throw failure(archive, "Cannot inspect archive") }
                if size > 0 { total += UInt64(size) }
                continue
            }
            let relative = parts.map(String.init).joined(separator: "/")
            let target = (destination as NSString).appendingPathComponent(relative)
            var dates = try entryDates(item)
            if let zipDate = zipDates?[relative] {
                guard zipDate.timeIntervalSince1970.isFinite else { throw ActionError("Archive entry has an invalid timestamp") }
                dates[.modificationDate] = zipDate
            }
            if type == AE_IFDIR {
                try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
                var ancestor = destination
                for component in parts {
                    ancestor = (ancestor as NSString).appendingPathComponent(String(component))
                    try applyQuarantine(quarantine, to: ancestor)
                }
                directoryMetadata.append((target, archive_entry_perm(item) & 0o777, dates))
                continue
            }
            try FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            var ancestor = destination
            for component in parts.dropLast() {
                ancestor = (ancestor as NSString).appendingPathComponent(String(component))
                try applyQuarantine(quarantine, to: ancestor)
            }
            let fd = open(target, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw ActionError("Cannot safely create an archive entry") }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try applyQuarantine(quarantine, to: target)
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                guard !Task.isCancelled, Date() < deadline else { throw ActionError("Archive extraction was cancelled or timed out") }
                let readCount = buffer.withUnsafeMutableBytes { bytes in
                    archive_read_data(archive, bytes.baseAddress, bytes.count)
                }
                guard readCount >= 0 else { throw failure(archive, "Cannot extract archive entry") }
                if readCount == 0 { break }
                guard UInt64(readCount) <= limit - total else { throw ActionError("Archive exceeds the extraction size limit") }
                total += UInt64(readCount)
                try file.write(contentsOf: Data(buffer.prefix(readCount)))
            }
            if !dates.isEmpty { try FileManager.default.setAttributes(dates, ofItemAtPath: target) }
            guard fchmod(fd, archive_entry_perm(item) & 0o777) == 0 else { throw ActionError("Cannot set extracted file permissions") }
            try file.close()
        }
        for (directory, permissions, dates) in directoryMetadata.sorted(by: { $0.0.split(separator: "/").count > $1.0.split(separator: "/").count }) {
            if !dates.isEmpty { try FileManager.default.setAttributes(dates, ofItemAtPath: directory) }
            guard chmod(directory, permissions) == 0 else { throw ActionError("Cannot set extracted folder permissions") }
        }
        return roots.sorted()
    }

    private static func entryDates(_ entry: OpaquePointer) throws -> [FileAttributeKey: Any] {
        func date(_ seconds: time_t, _ nanoseconds: Int) throws -> Date {
            guard seconds >= -62_135_596_800, seconds <= 253_402_300_799,
                  (0..<1_000_000_000).contains(nanoseconds) else {
                throw ActionError("Archive entry has an invalid timestamp")
            }
            let value = Double(seconds) + Double(nanoseconds) / 1_000_000_000
            guard value.isFinite else { throw ActionError("Archive entry has an invalid timestamp") }
            return Date(timeIntervalSince1970: value)
        }
        var attributes: [FileAttributeKey: Any] = [:]
        if archive_entry_mtime_is_set(entry) != 0 {
            attributes[.modificationDate] = try date(archive_entry_mtime(entry), archive_entry_mtime_nsec(entry))
        }
        if archive_entry_birthtime_is_set(entry) != 0 {
            attributes[.creationDate] = try date(archive_entry_birthtime(entry), archive_entry_birthtime_nsec(entry))
        }
        return attributes
    }

    private static func failure(_ archive: OpaquePointer, _ prefix: String) -> ActionError {
        let detail = archive_error_string(archive).map { String(cString: $0) } ?? "unsupported or damaged archive"
        return ActionError("\(prefix): \(detail)")
    }
}
