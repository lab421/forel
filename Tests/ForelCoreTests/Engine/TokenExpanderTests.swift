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

import Testing
import Foundation
@testable import ForelCore

struct TokenExpanderTests {
    @Test func expandsYearMonthDayTokens() throws {
        let dir = TempDir()
        let file = dir.file("report.txt")

        let result = try TokenExpander.expand("{year}-{month}-{day}", path: file, now: fixedDate())

        #expect(result == "2026-03-05")
    }

    @Test func leavesUnknownTokensUntouched() throws {
        let dir = TempDir()
        let file = dir.file("report.txt")

        let result = try TokenExpander.expand("{not_a_token}", path: file)

        #expect(result == "{not_a_token}")
    }

    @Test func expandsNameAndExtensionWithoutRequiringTheFileToExist() throws {
        // {name}/{extension} only need `path` itself, not a real file on
        // disk — unlike {date_modified}/{date_created}/{size} below.
        let result = try TokenExpander.expand("{name}.{extension}", path: "/nonexistent/report.pdf")

        #expect(result == "report.pdf")
    }

    @Test func throwsWhenASizeOrDateAttributeTokenNeedsAMissingFile() {
        #expect(throws: (any Error).self) {
            try TokenExpander.expand("{size}", path: "/nonexistent/report.pdf")
        }
    }

    @Test func previewExpandNeverThrowsAndUsesPlaceholderValues() {
        let result = TokenExpander.previewExpand("{name}-{year}-{month}-{day}.{extension}", now: fixedDate())

        #expect(result == "file-2026-03-05.txt")
    }

    private func fixedDate() -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 5
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: components)!
    }
}
