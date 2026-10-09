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

public enum HistoryTimestampFormatter {
    /// History is persisted as ISO-8601 UTC. Convert it only at the display
    /// boundary so database ordering remains stable while the Activity view
    /// follows the Mac's current locale, time zone, and 12/24-hour setting.
    public static func localized(
        _ timestamp: String,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String? {
        guard let date = ISO8601DateFormatter().date(from: timestamp) else { return nil }
        return date.formatted(
            Date.FormatStyle(
                date: .numeric,
                time: .shortened,
                locale: locale,
                timeZone: timeZone
            )
        )
    }

    /// Short relative label ("2 min. ago") for compact surfaces like the
    /// menu-bar quick panel, following the Mac's current locale.
    public static func relative(
        _ timestamp: String,
        relativeTo now: Date = Date(),
        locale: Locale = .autoupdatingCurrent
    ) -> String? {
        guard let date = ISO8601DateFormatter().date(from: timestamp) else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
