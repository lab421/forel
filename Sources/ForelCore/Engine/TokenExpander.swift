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

import Foundation

/// Token substitution shared by the Rename action's pattern and the
/// Move/Copy actions' destination path — e.g. `{year}-{month}` for a
/// monthly archive folder, or `{name}-{current_date}.{extension}` for a
/// renamed file.
public enum TokenExpander {
    /// Substitutes tokens against a real file at `path`: `{name}`,
    /// `{extension}`, `{current_date}`, `{year}`, `{month}`, `{day}`,
    /// `{date_modified}`, `{date_created}`, `{size}`. The last three read
    /// the file's actual attributes and require it to exist; every other
    /// token only needs `path` for its name/extension and doesn't touch the
    /// disk. `now` is the moment of evaluation (rule run or Dry Run) — the
    /// date tokens use it, not any date embedded in the file itself.
    public static func expand(_ template: String, path: String, now: Date = Date()) throws -> String {
        let url = URL(fileURLWithPath: path)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        var result = substituteCommonTokens(template, name: stem, extension: ext, now: now)

        if result.contains("{date_modified}") || result.contains("{date_created}") || result.contains("{size}") {
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let modified = (attrs[.modificationDate] as? Date) ?? now
            let created = (attrs[.creationDate] as? Date) ?? now
            let size = (attrs[.size] as? UInt64) ?? 0
            result = result
                .replacingOccurrences(of: "{date_modified}", with: dayFormatter.string(from: modified))
                .replacingOccurrences(of: "{date_created}", with: dayFormatter.string(from: created))
                .replacingOccurrences(of: "{size}", with: formatFileSize(size))
        }

        return result
    }

    /// Same token set with placeholder values (a fixed sample name/extension
    /// and size, `now`'s date, no disk access, never throws) — for live
    /// previews in the rule editor before a concrete file exists to
    /// evaluate against.
    public static func previewExpand(_ template: String, now: Date = Date()) -> String {
        substituteCommonTokens(template, name: "file", extension: "txt", now: now)
            .replacingOccurrences(of: "{date_modified}", with: dayFormatter.string(from: now))
            .replacingOccurrences(of: "{date_created}", with: dayFormatter.string(from: now))
            .replacingOccurrences(of: "{size}", with: "1.2MB")
    }

    private static func substituteCommonTokens(_ template: String, name: String, extension ext: String, now: Date) -> String {
        template
            .replacingOccurrences(of: "{name}", with: name)
            .replacingOccurrences(of: "{extension}", with: ext)
            .replacingOccurrences(of: "{current_date}", with: dayFormatter.string(from: now))
            .replacingOccurrences(of: "{year}", with: yearFormatter.string(from: now))
            .replacingOccurrences(of: "{month}", with: monthFormatter.string(from: now))
            .replacingOccurrences(of: "{day}", with: dayOfMonthFormatter.string(from: now))
    }

    private static func formatFileSize(_ bytes: UInt64) -> String {
        let kb: Double = 1024
        let mb = 1024 * kb
        let gb = 1024 * mb
        let value = Double(bytes)
        if value >= gb { return String(format: "%.1fGB", value / gb) }
        if value >= mb { return String(format: "%.1fMB", value / mb) }
        if value >= kb { return String(format: "%.1fKB", value / kb) }
        return "\(bytes)B"
    }

    private static var dayFormatter: DateFormatter { formatter("yyyy-MM-dd") }
    private static var yearFormatter: DateFormatter { formatter("yyyy") }
    private static var monthFormatter: DateFormatter { formatter("MM") }
    private static var dayOfMonthFormatter: DateFormatter { formatter("dd") }

    private static func formatter(_ dateFormat: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = dateFormat
        formatter.timeZone = .current
        return formatter
    }
}
