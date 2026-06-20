import Testing
import Foundation
@testable import ForelCore

@Suite struct PlanExecutorTests {
    private func makeDB() throws -> Database {
        try Database(path: ":memory:")
    }

    @Test func executesSimpleMoveCopyAndTagPlan() throws {
        let dir = TempDir()
        let file = dir.file("invoice.pdf", contents: "paid")
        let destination = dir.dir("Processed")
        var rule = makeRule(name: "archive invoice", conditions: [makeCondition(.extension_, .is, "pdf")])
        rule.actions = [
            makeAction(.addTag, .object(["tag": .string("Reviewed")]), position: 0),
            makeAction(.moveToFolder, .object(["destination": .string(destination)]), position: 1),
        ]

        let entries = RuleEngine.walkEntries(root: dir.path, maxDepth: nil)
        let plan = RulePlanner.plan(entries: entries, rules: [rule], root: dir.path, status: .ready)
        let result = PlanExecutor.execute(plan)

        let expectedDest = (destination as NSString).appendingPathComponent("invoice.pdf")
        #expect(FileManager.default.fileExists(atPath: expectedDest))
        #expect(!FileManager.default.fileExists(atPath: file))
        #expect(result.history.filter { $0.status == .applied }.count == 2)
    }

    @Test func respectsAlreadyInDestinationSkip() throws {
        let dir = TempDir()
        let pdfDir = dir.dir("PDF")
        let existing = (pdfDir as NSString).appendingPathComponent("existing.pdf")
        try "x".write(toFile: existing, atomically: true, encoding: .utf8)

        var rule = makeRule(name: "sort pdf", conditions: [makeCondition(.extension_, .is, "pdf")], recursionDepth: nil)
        rule.actions = [makeAction(.moveToFolder, .object(["destination": .string(pdfDir)]), position: 0)]

        let entries = RuleEngine.walkEntries(root: dir.path, maxDepth: nil)
        let plan = RulePlanner.plan(entries: entries, rules: [rule], root: dir.path, status: .ready)
        let result = PlanExecutor.execute(plan)

        #expect(FileManager.default.fileExists(atPath: existing))
        let numberedDuplicate = (pdfDir as NSString).appendingPathComponent("existing (1).pdf")
        #expect(!FileManager.default.fileExists(atPath: numberedDuplicate))
        #expect(result.history.isEmpty)
    }

    @Test func moveToFolderConfiguredToSkipNeverDuplicatesOnConflict() throws {
        let dir = TempDir()
        let destination = dir.dir("Archive")
        let existing = (destination as NSString).appendingPathComponent("note.txt")
        try "old".write(toFile: existing, atomically: true, encoding: .utf8)
        let file = dir.file("note.txt", contents: "new")

        var rule = makeRule(name: "archive", conditions: [makeCondition(.extension_, .is, "txt")])
        rule.actions = [makeAction(.moveToFolder, .object([
            "destination": .string(destination),
            "on_conflict": .string("skip"),
        ]), position: 0)]

        let entries = RuleEngine.walkEntries(root: dir.path, maxDepth: nil)
        let plan = RulePlanner.plan(entries: entries, rules: [rule], root: dir.path, status: .ready)
        let result = PlanExecutor.execute(plan)

        #expect(FileManager.default.fileExists(atPath: file))
        #expect(try String(contentsOfFile: existing, encoding: .utf8) == "old")
        let numberedDuplicate = (destination as NSString).appendingPathComponent("note (1).txt")
        #expect(!FileManager.default.fileExists(atPath: numberedDuplicate))
        #expect(result.history.isEmpty)
    }

    @Test func actionsAfterASkippedMoveDoNotRunOnTheUnmovedFile() throws {
        let dir = TempDir()
        let destination = dir.dir("Archive")
        let existing = (destination as NSString).appendingPathComponent("note.txt")
        try "old".write(toFile: existing, atomically: true, encoding: .utf8)
        let file = dir.file("note.txt", contents: "new")

        var rule = makeRule(name: "archive then tag", conditions: [makeCondition(.extension_, .is, "txt")])
        rule.actions = [
            makeAction(.moveToFolder, .object([
                "destination": .string(destination),
                "on_conflict": .string("skip"),
            ]), position: 0),
            makeAction(.addTag, .object(["tag": .string("Archived")]), position: 1),
        ]

        let entries = RuleEngine.walkEntries(root: dir.path, maxDepth: nil)
        let plan = RulePlanner.plan(entries: entries, rules: [rule], root: dir.path, status: .ready)
        let result = PlanExecutor.execute(plan)

        #expect(FileManager.default.fileExists(atPath: file))
        #expect(FinderTags.read(file).isEmpty)
        #expect(result.history.isEmpty)
    }

    @Test func blocksWhenSourceFingerprintChangedSincePlanning() throws {
        let dir = TempDir()
        let file = dir.file("a.txt", contents: "v1")
        let destination = dir.dir("Archive")
        var rule = makeRule(name: "archive", conditions: [makeCondition(.extension_, .is, "txt")])
        rule.actions = [makeAction(.moveToFolder, .object(["destination": .string(destination)]), position: 0)]

        let entries = RuleEngine.walkEntries(root: dir.path, maxDepth: nil)
        let plan = RulePlanner.plan(entries: entries, rules: [rule], root: dir.path, status: .ready)

        // File changes after planning but before execution.
        try "v2-with-more-bytes".write(toFile: file, atomically: true, encoding: .utf8)

        let result = PlanExecutor.execute(plan)

        #expect(FileManager.default.fileExists(atPath: file))
        #expect(!FileManager.default.fileExists(atPath: (destination as NSString).appendingPathComponent("a.txt")))
        #expect(result.history.count == 1)
        #expect(result.history[0].status == .failed)
        #expect(result.history[0].message?.contains("changed") == true)
    }

    @Test func executionUpdatesFileStateInDatabase() throws {
        let db = try makeDB()
        let dir = TempDir()
        let file = dir.file("a.txt")
        let destination = dir.dir("Archive")
        var rule = makeRule(name: "archive", conditions: [makeCondition(.extension_, .is, "txt")])
        rule.actions = [makeAction(.moveToFolder, .object(["destination": .string(destination)]), position: 0)]

        let entries = RuleEngine.walkEntries(root: dir.path, maxDepth: nil)
        let plan = RulePlanner.plan(entries: entries, rules: [rule], root: dir.path, status: .ready)
        let result = PlanExecutor.execute(plan)

        for state in result.fileStateUpserts { try db.upsertFileState(state) }
        for path in result.fileStateDeletes { try db.deleteFileState(path) }

        let movedPath = (destination as NSString).appendingPathComponent("a.txt")
        #expect(try db.getFileState(file) == nil)
        #expect(try db.getFileState(movedPath) != nil)
    }

    @Test func recordsAppliedActionsInActionHistory() throws {
        let db = try makeDB()
        let dir = TempDir()
        _ = dir.file("a.txt")
        var rule = makeRule(name: "tag", conditions: [makeCondition(.extension_, .is, "txt")])
        rule.actions = [makeAction(.addTag, .object(["tag": .string("Seen")]), position: 0)]

        let entries = RuleEngine.walkEntries(root: dir.path, maxDepth: nil)
        let plan = RulePlanner.plan(entries: entries, rules: [rule], root: dir.path, status: .ready)
        let result = PlanExecutor.execute(plan)
        try db.insertHistoryEntries(result.history)

        let stored = try db.listHistory()
        #expect(stored.count == 1)
        #expect(stored[0].status == .applied)
    }

    @Test func recordsForelActionEvents() throws {
        let dir = TempDir()
        _ = dir.file("a.txt")
        var rule = makeRule(name: "tag", conditions: [makeCondition(.extension_, .is, "txt")])
        rule.actions = [makeAction(.addTag, .object(["tag": .string("Seen")]), position: 0)]

        let entries = RuleEngine.walkEntries(root: dir.path, maxDepth: nil)
        let plan = RulePlanner.plan(entries: entries, rules: [rule], root: dir.path, status: .ready)
        let result = PlanExecutor.execute(plan)

        #expect(result.events.count == 1)
        #expect(result.events[0].source == .forelAction)
        #expect(result.events[0].isForelOriginated)
    }
}
