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
@testable import ForelCore

@Suite struct SystemFileFilterTests {
    @Test func excludesKnownNoisySystemFiles() {
        #expect(SystemFileFilter.isExcluded(".DS_Store"))
        #expect(SystemFileFilter.isExcluded(".forel-uncompress-123456"))
        #expect(SystemFileFilter.isExcluded("._report.pdf")) // AppleDouble resource fork
        #expect(SystemFileFilter.isExcluded("~$budget.docx")) // Office lock file
    }

    @Test func excludesIncompleteBrowserDownloads() {
        #expect(SystemFileFilter.isExcluded("report.pdf.crdownload"))
        #expect(SystemFileFilter.isExcluded("Unconfirmed 123456.crdownload"))
        #expect(SystemFileFilter.isExcluded("Archive.ZIP.CRDOWNLOAD"))
        #expect(SystemFileFilter.isExcluded("video.mp4.download"))
        #expect(SystemFileFilter.isExcluded("installer.dmg.part"))
        #expect(SystemFileFilter.isExcluded("archive.zip.opdownload"))
        #expect(SystemFileFilter.isExcluded("dataset.tar.aria2"))
        #expect(SystemFileFilter.isExcluded(".com.google.Chrome.4kwGYJ"))
        #expect(SystemFileFilter.isExcluded(".com.microsoft.edgemac.QjS9aV"))
        #expect(SystemFileFilter.isExcluded(".com.brave.Browser.QjS9aV"))
        #expect(SystemFileFilter.isExcluded(".com.vivaldi.Vivaldi.QjS9aV"))
        #expect(SystemFileFilter.isExcluded(".com.operasoftware.Opera.QjS9aV"))
        #expect(SystemFileFilter.isExcluded(".org.chromium.Chromium.QjS9aV"))
    }

    @Test func doesNotExcludeRegularFiles() {
        #expect(!SystemFileFilter.isExcluded("report.pdf"))
        #expect(!SystemFileFilter.isExcluded("budget.docx"))
        #expect(!SystemFileFilter.isExcluded("invoice_march_2026.pdf"))
        #expect(!SystemFileFilter.isExcluded("downloaded-report.pdf"))
    }
}
