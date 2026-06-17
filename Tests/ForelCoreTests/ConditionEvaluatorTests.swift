import Testing
import Foundation
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
        #expect(ConditionEvaluator.evaluate(makeCondition(.contents, .contains, "paid"), path: file))
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
}
