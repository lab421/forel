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
import Testing
@testable import ForelCore

@Suite struct HistoryTimestampFormatterTests {
    @Test func convertsStoredUTCToTheDisplayTimeZone() throws {
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let cest = try #require(TimeZone(secondsFromGMT: 2 * 60 * 60))
        let locale = Locale(identifier: "en_GB")
        let timestamp = "2026-09-01T07:55:00Z"

        let utcLabel = try #require(HistoryTimestampFormatter.localized(
            timestamp,
            locale: locale,
            timeZone: utc
        ))
        let localLabel = try #require(HistoryTimestampFormatter.localized(
            timestamp,
            locale: locale,
            timeZone: cest
        ))

        #expect(utcLabel.contains("7:55"))
        #expect(localLabel.contains("9:55"))
        #expect(localLabel != utcLabel)
    }

    @Test func followsTheSelectedLocale() throws {
        let timeZone = try #require(TimeZone(secondsFromGMT: 2 * 60 * 60))
        let timestamp = "2026-09-01T07:55:00Z"

        let french = try #require(HistoryTimestampFormatter.localized(
            timestamp,
            locale: Locale(identifier: "fr_FR"),
            timeZone: timeZone
        ))
        let american = try #require(HistoryTimestampFormatter.localized(
            timestamp,
            locale: Locale(identifier: "en_US"),
            timeZone: timeZone
        ))

        #expect(french != american)
    }

    @Test func rejectsInvalidStoredTimestamp() {
        #expect(HistoryTimestampFormatter.localized("not-a-date") == nil)
    }
}
