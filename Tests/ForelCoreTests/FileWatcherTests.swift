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

import CoreServices
import Testing
@testable import ForelCore

@Suite struct FileWatcherTests {
    @Test func reportsCreatedAndRenamedArrivals() {
        #expect(FileWatcher.shouldReportEvent(path: "/tmp/report.pdf", flags: UInt32(kFSEventStreamEventFlagItemCreated)))
        #expect(FileWatcher.shouldReportEvent(path: "/tmp/report.pdf", flags: UInt32(kFSEventStreamEventFlagItemRenamed)))
        #expect(FileWatcher.reportedEvent(path: "/tmp/report.pdf", flags: UInt32(kFSEventStreamEventFlagItemCreated)) == .pathArrived("/tmp/report.pdf"))
        #expect(FileWatcher.reportedEvent(path: "/tmp/report.pdf", flags: UInt32(kFSEventStreamEventFlagItemRenamed)) == .pathArrived("/tmp/report.pdf"))
    }

    @Test func doesNotReportExistingFileMetadataOrContentChanges() {
        #expect(!FileWatcher.shouldReportEvent(path: "/tmp/report.pdf", flags: UInt32(kFSEventStreamEventFlagItemModified)))
        #expect(!FileWatcher.shouldReportEvent(path: "/tmp/report.pdf", flags: UInt32(kFSEventStreamEventFlagItemXattrMod)))
        #expect(!FileWatcher.shouldReportEvent(path: "/tmp/report.pdf", flags: UInt32(kFSEventStreamEventFlagItemInodeMetaMod)))
        #expect(FileWatcher.reportedEvent(path: "/tmp/report.pdf", flags: UInt32(kFSEventStreamEventFlagItemModified)) == nil)
        #expect(FileWatcher.reportedEvent(path: "/tmp/report.pdf", flags: UInt32(kFSEventStreamEventFlagItemXattrMod)) == nil)
        #expect(FileWatcher.reportedEvent(path: "/tmp/report.pdf", flags: UInt32(kFSEventStreamEventFlagItemInodeMetaMod)) == nil)
    }

    @Test func reportsDroppedEventRecoveryAsSubtreeRescan() {
        #expect(FileWatcher.reportedEvent(path: "/tmp/Downloads", flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs)) == .rescanSubtree("/tmp/Downloads"))
        #expect(FileWatcher.reportedEvent(path: "/tmp/Downloads", flags: UInt32(kFSEventStreamEventFlagUserDropped)) == .rescanSubtree("/tmp/Downloads"))
        #expect(FileWatcher.reportedEvent(path: "/tmp/Downloads", flags: UInt32(kFSEventStreamEventFlagKernelDropped)) == .rescanSubtree("/tmp/Downloads"))
    }

    @Test func doesNotReportExcludedTemporaryDownloadArrivals() {
        #expect(!FileWatcher.shouldReportEvent(path: "/tmp/report.pdf.download", flags: UInt32(kFSEventStreamEventFlagItemCreated)))
        #expect(!FileWatcher.shouldReportEvent(path: "/tmp/report.pdf.crdownload", flags: UInt32(kFSEventStreamEventFlagItemRenamed)))
        #expect(FileWatcher.reportedEvent(path: "/tmp/report.pdf.download", flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs)) == nil)
    }
}
