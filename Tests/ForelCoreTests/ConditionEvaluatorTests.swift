import Testing
import Foundation
import Darwin
@testable import ForelCore

@Suite struct ConditionEvaluatorTests {
    @Test func sizeConditionComparesParsedThresholds() throws {
        let dir = TempDir()
        let file = dir.file("data.bin", contents: "1234567890")

        #expect(ConditionEvaluator.evaluate(makeCondition(.sizeBytes, .is, "10 bytes"), path: file))
        #expect(ConditionEvaluator.evaluate(makeCondition(.sizeBytes, .isNot, "11 bytes"), path: file))
        #expect(ConditionEvaluator.evaluate(makeCondition(.sizeBytes, .greaterThan, "9 bytes"), path: file))
        #expect(ConditionEvaluator.evaluate(makeCondition(.sizeBytes, .lessThan, "1 KB"), path: file))
        #expect(ConditionEvaluator.evaluate(makeCondition(.sizeBytes, .lessThan, "1 MB"), path: file))
        #expect(ConditionEvaluator.evaluate(makeCondition(.sizeBytes, .lessThan, "1 GB"), path: file))
        #expect(!ConditionEvaluator.evaluate(makeCondition(.sizeBytes, .greaterThan, "1 KB"), path: file))
    }

    @Test func stringOperatorsWorkAcrossNameExtensionAndContents() throws {
        let dir = TempDir()
        let file = dir.file("invoice-2026.PDF", contents: "paid in full")

        #expect(ConditionEvaluator.evaluate(makeCondition(.name, .is, "invoice-2026"), path: file))
        #expect(ConditionEvaluator.evaluate(makeCondition(.name, .isNot, "receipt"), path: file))
        #expect(ConditionEvaluator.evaluate(makeCondition(.name, .contains, "voice"), path: file))
        #expect(ConditionEvaluator.evaluate(makeCondition(.name, .doesNotContain, "draft"), path: file))
        #expect(ConditionEvaluator.evaluate(makeCondition(.name, .startsWith, "invoice"), path: file))
        #expect(ConditionEvaluator.evaluate(makeCondition(.name, .endsWith, "2026"), path: file))
        #expect(ConditionEvaluator.evaluate(makeCondition(.name, .matchesRegex, #"invoice-\d{4}"#), path: file))
        #expect(ConditionEvaluator.evaluate(makeCondition(.extension_, .is, ".pdf"), path: file))

        // Contents now runs the extraction pipeline; a real plain-text file
        // exercises the string operators (a text file named ".PDF" is not a
        // valid PDF and is intentionally not read as text).
        let textFile = dir.file("invoice-2026.txt", contents: "paid in full")
        #expect(ConditionEvaluator.evaluate(makeCondition(.contents, .contains, "paid"), path: textFile))
    }

    @Test func contentsConditionReadsFileAndMatchesEveryStringOperator() throws {
        let dir = TempDir()
        let file = dir.file("notes.txt", contents: "Alpha receipt\nTotal: 42 EUR\nPaid in full")

        #expect(ConditionEvaluator.evaluate(makeCondition(.contents, .is, "Alpha receipt\nTotal: 42 EUR\nPaid in full"), path: file))
        #expect(ConditionEvaluator.evaluate(makeCondition(.contents, .isNot, "Alpha receipt"), path: file))
        #expect(ConditionEvaluator.evaluate(makeCondition(.contents, .contains, "Total: 42"), path: file))
        #expect(ConditionEvaluator.evaluate(makeCondition(.contents, .doesNotContain, "Refunded"), path: file))
        #expect(ConditionEvaluator.evaluate(makeCondition(.contents, .startsWith, "Alpha"), path: file))
        #expect(ConditionEvaluator.evaluate(makeCondition(.contents, .endsWith, "full"), path: file))
        #expect(ConditionEvaluator.evaluate(makeCondition(.contents, .matchesRegex, #"(?s)receipt.*Paid"#), path: file))

        try "Different contents".write(toFile: file, atomically: true, encoding: .utf8)
        #expect(!ConditionEvaluator.evaluate(makeCondition(.contents, .contains, "Total: 42"), path: file))
    }

    @Test func contentsConditionDoesNotMatchUnreadableOrOversizedContent() throws {
        let dir = TempDir()
        let binary = (dir.path as NSString).appendingPathComponent("binary.dat")
        try Data([0xff, 0xfe, 0xfd]).write(to: URL(fileURLWithPath: binary))

        #expect(!ConditionEvaluator.evaluate(makeCondition(.contents, .contains, "anything"), path: binary))
        #expect(!ConditionEvaluator.evaluate(makeCondition(.contents, .doesNotContain, "anything"), path: binary))

        let large = (dir.path as NSString).appendingPathComponent("large.txt")
        let data = Data(repeating: UInt8(ascii: "a"), count: 100 * 1024 * 1024 + 1)
        try data.write(to: URL(fileURLWithPath: large))
        #expect(!ConditionEvaluator.evaluate(makeCondition(.contents, .contains, "a"), path: large))
    }

    @Test func tagConditionMatchesAllSupportedStringOperators() throws {
        let dir = TempDir()
        let file = dir.file("document.txt", contents: "hello")
        _ = try ActionExecutor.execute(makeAction(.addTag, .object(["tag": .string("Project")])), path: file)

        #expect(ConditionEvaluator.evaluate(makeCondition(.tags, .is, " project "), path: file))
        #expect(ConditionEvaluator.evaluate(makeCondition(.tags, .isNot, "archive"), path: file))
        #expect(ConditionEvaluator.evaluate(makeCondition(.tags, .contains, "roj"), path: file))
        #expect(ConditionEvaluator.evaluate(makeCondition(.tags, .doesNotContain, "zzz"), path: file))
        #expect(ConditionEvaluator.evaluate(makeCondition(.tags, .startsWith, "pro"), path: file))
        #expect(ConditionEvaluator.evaluate(makeCondition(.tags, .endsWith, "ect"), path: file))
        #expect(ConditionEvaluator.evaluate(makeCondition(.tags, .matchesRegex, "^proj"), path: file))
    }

    @Test func colorLabelConditionMatchesFinderColorTagName() throws {
        let dir = TempDir()
        let file = dir.file("image.png", contents: "png")
        _ = try ActionExecutor.execute(makeAction(.setColorLabel, .object(["color": .string("Red")])), path: file)

        #expect(ConditionEvaluator.evaluate(makeCondition(.colorLabel, .is, "red"), path: file))
        #expect(ConditionEvaluator.evaluate(makeCondition(.colorLabel, .isNot, "blue"), path: file))
    }

    @Test func createdAtConditionHandlesAbsoluteAndRelativeOperators() throws {
        let dir = TempDir()
        let file = dir.file("fresh.txt", contents: "new")

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let tomorrow = formatter.string(from: Date().addingTimeInterval(86400))
        let yesterday = formatter.string(from: Date().addingTimeInterval(-86400))

        #expect(ConditionEvaluator.evaluate(makeCondition(.createdAt, .withinLast, "1 day"), path: file))
        #expect(!ConditionEvaluator.evaluate(makeCondition(.createdAt, .olderThan, "1 year"), path: file))
        #expect(ConditionEvaluator.evaluate(makeCondition(.createdAt, .before, tomorrow), path: file))
        #expect(!ConditionEvaluator.evaluate(makeCondition(.createdAt, .after, tomorrow), path: file))
        #expect(ConditionEvaluator.evaluate(makeCondition(.createdAt, .after, yesterday), path: file))
        #expect(!ConditionEvaluator.evaluate(makeCondition(.createdAt, .withinLast, ""), path: file))
        #expect(!ConditionEvaluator.evaluate(makeCondition(.createdAt, .olderThan, "5 decades"), path: file))
    }

    @Test func dateModifiedConditionHandlesAbsoluteAndRelativeOperators() throws {
        let dir = TempDir()
        let file = dir.file("fresh.txt", contents: "new")
        let oldDate = Date().addingTimeInterval(-10 * 24 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let tomorrow = formatter.string(from: Date().addingTimeInterval(86400))
        let yesterday = formatter.string(from: Date().addingTimeInterval(-86400))

        #expect(ConditionEvaluator.evaluate(makeCondition(.dateModified, .before, tomorrow), path: file))
        #expect(!ConditionEvaluator.evaluate(makeCondition(.dateModified, .after, yesterday), path: file))
        #expect(ConditionEvaluator.evaluate(makeCondition(.dateModified, .olderThan, "1 week"), path: file))
        #expect(!ConditionEvaluator.evaluate(makeCondition(.dateModified, .withinLast, "1 week"), path: file))
    }

    @Test func kindConditionClassifiesAllPickerOptionsAndSupportsIsNot() throws {
        let dir = TempDir()
        let samples: [(path: String, kind: String)] = [
            (dir.file("photo.heic", contents: "image"), "image"),
            (dir.file("clip.mov", contents: "movie"), "movie"),
            (dir.file("song.mp3", contents: "music"), "music"),
            (dir.file("paper.pdf", contents: "%PDF"), "pdf"),
            (dir.file("notes.txt", contents: "text"), "text"),
            (dir.file("report.docx", contents: "document"), "document"),
            (dir.file("slides.key", contents: "presentation"), "presentation"),
            (dir.file("backup.zip", contents: "archive"), "archive"),
            (dir.file("installer.dmg", contents: "disk image"), "disk_image"),
            (dir.dir("Folder"), "folder"),
            (dir.dir("Example.app"), "application"),
        ]

        for sample in samples {
            #expect(ConditionEvaluator.evaluate(makeCondition(.kind, .is, sample.kind), path: sample.path))
            #expect(ConditionEvaluator.evaluate(makeCondition(.kind, .isNot, "not-\(sample.kind)"), path: sample.path))
        }
    }

    // MARK: - Download metadata conditions

    @Test func downloadedFromWebsiteMatchesAnExtractedURL() throws {
        let dir = TempDir()
        let file = dir.file("report.zip")
        try setWhereFroms(file, ["https://example.com/downloads/report.zip", "https://example.com/"])

        #expect(ConditionEvaluator.evaluate(makeCondition(.downloadedFromWebsite, .contains, "example.com"), path: file))
        #expect(ConditionEvaluator.evaluate(
            makeCondition(.downloadedFromWebsite, .is, "https://example.com/downloads/report.zip"), path: file
        ))
        #expect(!ConditionEvaluator.evaluate(makeCondition(.downloadedFromWebsite, .contains, "other.com"), path: file))
    }

    @Test func downloadedWithAppMatchesTheQuarantineAgent() throws {
        let dir = TempDir()
        let file = dir.file("installer.dmg")
        try setQuarantineAgent(file, agent: "Safari")

        #expect(ConditionEvaluator.evaluate(makeCondition(.downloadedWithApp, .is, "Safari"), path: file))
        #expect(!ConditionEvaluator.evaluate(makeCondition(.downloadedWithApp, .is, "Chrome"), path: file))
    }

    @Test func downloadedWithAppMatchesChromeBundleDisplayName() throws {
        let dir = TempDir()
        let file = dir.file("release.zip")
        try setQuarantineAgent(file, agent: "Chrome")

        #expect(ConditionEvaluator.evaluate(makeCondition(.downloadedWithApp, .is, "Google Chrome"), path: file))
    }

    @Test func rawWhereFromMetadataMatchesAnyStoredValue() throws {
        let dir = TempDir()
        let file = dir.file("note.txt")
        try setWhereFroms(file, ["Safari", "https://example.com/"])

        #expect(ConditionEvaluator.evaluate(makeCondition(.rawWhereFromMetadata, .contains, "Safari"), path: file))
        #expect(ConditionEvaluator.evaluate(makeCondition(.rawWhereFromMetadata, .contains, "example"), path: file))
    }

    @Test func metadataStringOperatorsStayCaseSensitiveLikeOtherStringConditions() throws {
        let dir = TempDir()
        let file = dir.file("doc.pdf")
        try setWhereFroms(file, ["https://Example.com/File.zip"])

        #expect(!ConditionEvaluator.evaluate(makeCondition(.downloadedFromWebsite, .contains, "example.com"), path: file))
        #expect(ConditionEvaluator.evaluate(makeCondition(.downloadedFromWebsite, .contains, "Example.com"), path: file))
    }

    @Test func missingDownloadMetadataMatchesNothingPositiveAndEverythingNegative() throws {
        let dir = TempDir()
        let file = dir.file("plain.txt")
        // No kMDItemWhereFroms, no quarantine xattr at all.

        for kind: ConditionKind in [.downloadedFromWebsite, .downloadedWithApp, .rawWhereFromMetadata] {
            #expect(!ConditionEvaluator.evaluate(makeCondition(kind, .is, "anything"), path: file))
            #expect(!ConditionEvaluator.evaluate(makeCondition(kind, .contains, "anything"), path: file))
            #expect(!ConditionEvaluator.evaluate(makeCondition(kind, .startsWith, "anything"), path: file))
            #expect(!ConditionEvaluator.evaluate(makeCondition(kind, .endsWith, "anything"), path: file))
            #expect(!ConditionEvaluator.evaluate(makeCondition(kind, .matchesRegex, "any.*"), path: file))
            #expect(ConditionEvaluator.evaluate(makeCondition(kind, .isNot, "anything"), path: file))
            #expect(ConditionEvaluator.evaluate(makeCondition(kind, .doesNotContain, "anything"), path: file))
        }
    }

    @Test func malformedWhereFromsPlistNeverThrowsAndBehavesAsAbsent() throws {
        let dir = TempDir()
        let file = dir.file("broken.txt")
        let garbage = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let result = garbage.withUnsafeBytes { bytes in
            setxattr(file, "com.apple.metadata:kMDItemWhereFroms", bytes.baseAddress, garbage.count, 0, 0)
        }
        #expect(result == 0)

        #expect(!ConditionEvaluator.evaluate(makeCondition(.downloadedFromWebsite, .contains, "anything"), path: file))
        #expect(ConditionEvaluator.evaluate(makeCondition(.downloadedFromWebsite, .isNot, "anything"), path: file))
    }
}
