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
        let created = TimeInterval(st.st_birthtimespec.tv_sec)
        return abs(created - busyCreationDate.timeIntervalSince1970) <= busyTolerance
    }
}
