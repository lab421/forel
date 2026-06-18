import Testing
import Foundation
import Darwin
@testable import ForelCore

@Suite struct DownloadMetadataTests {
    // MARK: - whereFroms parsing

    @Test func whereFromsReadsAStoredList() throws {
        let dir = TempDir()
        let file = dir.file("invoice.pdf")
        try setWhereFroms(file, ["https://example.com/invoice.pdf", "https://example.com/"])

        #expect(DownloadMetadata.whereFroms(file) == ["https://example.com/invoice.pdf", "https://example.com/"])
    }

    @Test func whereFromsReturnsEmptyWhenAttributeIsAbsent() throws {
        let dir = TempDir()
        let file = dir.file("plain.txt")

        #expect(DownloadMetadata.whereFroms(file).isEmpty)
    }

    @Test func whereFromsReturnsEmptyForAnInvalidPlist() throws {
        let dir = TempDir()
        let file = dir.file("broken.txt")
        let garbage = Data([0x00, 0x01, 0x02, 0xFF, 0xFE])
        let result = garbage.withUnsafeBytes { bytes in
            setxattr(file, "com.apple.metadata:kMDItemWhereFroms", bytes.baseAddress, garbage.count, 0, 0)
        }
        #expect(result == 0)

        #expect(DownloadMetadata.whereFroms(file).isEmpty)
    }

    @Test func whereFromsIgnoresNonStringValues() throws {
        let dir = TempDir()
        let file = dir.file("mixed.txt")
        let mixed: [Any] = ["https://example.com/", 42, true]
        let data = try PropertyListSerialization.data(fromPropertyList: mixed, format: .binary, options: 0)
        let result = data.withUnsafeBytes { bytes in
            setxattr(file, "com.apple.metadata:kMDItemWhereFroms", bytes.baseAddress, data.count, 0, 0)
        }
        #expect(result == 0)

        #expect(DownloadMetadata.whereFroms(file) == ["https://example.com/"])
    }

    // MARK: - websiteURLs

    @Test func websiteURLsKeepsOnlyHttpEntries() throws {
        let dir = TempDir()
        let file = dir.file("doc.pdf")
        try setWhereFroms(file, ["https://example.com/file.zip", "Safari", "http://example.com/page"])

        #expect(DownloadMetadata.websiteURLs(file) == ["https://example.com/file.zip", "http://example.com/page"])
    }

    // MARK: - downloadedWithApp

    @Test func downloadedWithAppReadsTheQuarantineAgentField() throws {
        let dir = TempDir()
        let file = dir.file("app.dmg")
        try setQuarantineAgent(file, agent: "Safari")

        #expect(DownloadMetadata.downloadedWithApp(file) == "Safari")
    }

    @Test func downloadedWithAppIsNilWhenQuarantineAttributeIsAbsent() throws {
        let dir = TempDir()
        let file = dir.file("local.txt")

        #expect(DownloadMetadata.downloadedWithApp(file) == nil)
    }

    @Test func downloadedWithAppIsNilWhenAgentFieldIsEmpty() throws {
        let dir = TempDir()
        let file = dir.file("ambiguous.txt")
        try setQuarantineAgent(file, agent: "")

        #expect(DownloadMetadata.downloadedWithApp(file) == nil)
    }

    @Test func downloadedWithAppNeverGuessesFromWhereFroms() throws {
        // Even if kMDItemWhereFroms text happens to mention a browser, that's
        // not a reliable signal — downloadedWithApp must stay nil here.
        let dir = TempDir()
        let file = dir.file("note.txt")
        try setWhereFroms(file, ["https://safari-extensions.example.com/page"])

        #expect(DownloadMetadata.downloadedWithApp(file) == nil)
    }
}
