// Forel - A native macOS file-automation app
// Copyright (C) 2026  Lab421
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import Darwin
import Foundation

/// Whether another process has marked a file as still being written.
///
/// macOS has no notification for "the writer closed this file", but Finder
/// (and transfers built on the same convention, e.g. AirDrop) stamps a file
/// it is still writing with a fixed creation date in February 1946, shows it
/// greyed out, and restores the real date when the copy completes. No rule
/// should touch a file in that state: moving it mid-transfer leaves an empty
/// or truncated file behind. Checked by `RuleEngine` so Dry Run, Run Now, and
/// the watcher all leave such a file alone.
enum FileReadiness {
    /// 14 February 1946 08:34:56 UTC, Finder's "busy" creation date.
    static let busyCreationDate = Date(timeIntervalSince1970: -753_549_904)

    /// The marker was historically written as a local time, so allow for any
    /// time zone offset around it; no real file is created in 1946.
    private static let busyTolerance: TimeInterval = 24 * 60 * 60

    static func isMarkedBusy(_ path: String) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0 else { return false }
        return isBusy(st)
    }

    private static func isBusy(_ st: stat) -> Bool {
        let created = TimeInterval(st.st_birthtimespec.tv_sec)
        return abs(created - busyCreationDate.timeIntervalSince1970) <= busyTolerance
    }

    /// Whether `path` or, for a folder, anything inside it is marked busy.
    /// Walks the whole folder, so callers use it only for a folder they are
    /// about to act on, never for every entry of a scan.
    static func containsBusyItem(_ path: String) -> Bool {
        if isMarkedBusy(path) { return true }
        guard let contents = descendants(of: path) else { return false }
        for case let child as String in contents {
            var st = stat()
            if lstat((path as NSString).appendingPathComponent(child), &st) == 0, isBusy(st) { return true }
        }
        return false
    }

    /// Enumerates a real folder's contents. A symbolic link to a folder is
    /// treated as a single item: what it points to is not part of the
    /// transfer and may be an entire volume.
    private static func descendants(of path: String) -> FileManager.DirectoryEnumerator? {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return nil }
        return FileManager.default.enumerator(atPath: path)
    }

    /// What the watcher compares between two checks to decide an arriving
    /// item has stopped changing. A folder's own size and modification time
    /// only move when a direct child is added or removed, not while a file
    /// inside it is still growing, so a folder is summarised by everything
    /// it contains.
    struct Snapshot: Equatable {
        let fingerprint: String
        let isMarkedBusy: Bool
    }

    /// `includingContents: false` looks at the item alone, for callers that
    /// already visit a folder's contents one by one.
    static func snapshot(_ path: String, includingContents: Bool = true) -> Snapshot? {
        guard let own = FileFingerprint.current(path) else { return nil }
        var isBusy = isMarkedBusy(path)

        guard includingContents, let contents = descendants(of: path) else {
            return Snapshot(fingerprint: own, isMarkedBusy: isBusy)
        }

        var count = 0
        var totalSize: Int64 = 0
        var latestModification = timespec()
        for case let child as String in contents {
            var st = stat()
            guard lstat((path as NSString).appendingPathComponent(child), &st) == 0 else { continue }
            count += 1
            totalSize &+= Int64(truncatingIfNeeded: st.st_size)
            let modified = st.st_mtimespec
            if (modified.tv_sec, modified.tv_nsec) > (latestModification.tv_sec, latestModification.tv_nsec) {
                latestModification = modified
            }
            if Self.isBusy(st) {
                isBusy = true
            }
        }
        return Snapshot(
            fingerprint: "\(own)|\(count)-\(totalSize)-\(latestModification.tv_sec)-\(latestModification.tv_nsec)",
            isMarkedBusy: isBusy
        )
    }
}
