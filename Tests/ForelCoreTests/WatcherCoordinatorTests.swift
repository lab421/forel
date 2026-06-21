import Testing
import Foundation
@testable import ForelCore

@Suite struct WatcherCoordinatorTests {
    private func makeDB() throws -> Database {
        try Database(path: ":memory:")
    }

    @Test func handleTriggersPlanAndExecution() throws {
        let db = try makeDB()
        let dir = TempDir()
        let file = dir.file("a.txt")
        let destination = dir.dir("Archive")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "archive")
        rule.conditions = [makeCondition(.extension_, .is, "txt", ruleId: rule.id)]
        rule.actions = [makeAction(.moveToFolder, .object(["destination": .string(destination)]), position: 0, ruleId: rule.id)]
        try db.insertRule(rule)

        let coordinator = WatcherCoordinator(db: db)
        coordinator.handle(path: file)

        let movedPath = (destination as NSString).appendingPathComponent("a.txt")
        #expect(FileManager.default.fileExists(atPath: movedPath))
        #expect(!FileManager.default.fileExists(atPath: file))
        #expect(try db.listHistory().count == 1)
    }

    /// The bug this whole table exists to fix: `copyToFolder` never moves
    /// its source out of scope, so repeated/duplicate FSEvents for the same
    /// untouched file used to keep re-copying — piling up Activity entries
    /// indefinitely under the watcher (Run Now, a single pass, never showed
    /// the problem).
    @Test func repeatedEventsForAnUnchangedSourceDoNotPileUpCopies() throws {
        let db = try makeDB()
        let dir = TempDir()
        let file = dir.file("a.png")
        let destination = dir.dir("PNGCopies")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "png copy")
        rule.conditions = [makeCondition(.extension_, .is, "png", ruleId: rule.id)]
        rule.actions = [makeAction(.copyToFolder, .object([
            "destination": .string(destination),
            "on_conflict": .string("replace"),
        ]), position: 0, ruleId: rule.id)]
        try db.insertRule(rule)

        let coordinator = WatcherCoordinator(db: db)
        for _ in 0..<5 {
            coordinator.handle(path: file)
        }

        #expect(try db.listHistory().count == 1)
    }

    /// A duplicate/coalesced FSEvent for the *original* path of a file the
    /// watcher just successfully moved away must not be replanned and fail
    /// with a noisy "doesn't exist" entry — there's nothing left to evaluate.
    @Test func duplicateEventForAnAlreadyMovedAwayPathRecordsNoFailure() throws {
        let db = try makeDB()
        let dir = TempDir()
        let file = dir.file("a.txt")
        let destination = dir.dir("Archive")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "archive")
        rule.conditions = [makeCondition(.extension_, .is, "txt", ruleId: rule.id)]
        rule.actions = [makeAction(.moveToFolder, .object(["destination": .string(destination)]), position: 0, ruleId: rule.id)]
        try db.insertRule(rule)

        let coordinator = WatcherCoordinator(db: db)
        coordinator.handle(path: file)
        coordinator.handle(path: file) // duplicate event for the now-vacated path

        let history = try db.listHistory()
        #expect(history.count == 1)
        #expect(history[0].status == .applied)
    }

    /// Regression guard for the inverse bug: a path nothing has evaluated
    /// before — like a file a previous rule just moved here — must still get
    /// its full chance, even though the destination folder is also watched.
    @Test func laterRuleStillAppliesAfterAnEarlierRuleMovedTheFile() throws {
        let db = try makeDB()
        let dir = TempDir()
        let file = dir.file("a.png")
        let pngDir = dir.dir("PNG")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)

        var moveRule = makeRule(folderId: folder.id, name: "move pngs")
        moveRule.conditions = [makeCondition(.extension_, .is, "png", ruleId: moveRule.id)]
        moveRule.actions = [makeAction(.moveToFolder, .object(["destination": .string(pngDir)]), position: 0, ruleId: moveRule.id)]
        try db.insertRule(moveRule)

        var colorRule = makeRule(folderId: folder.id, name: "color pngs", recursionDepth: 3)
        colorRule.conditions = [makeCondition(.extension_, .is, "png", ruleId: colorRule.id)]
        colorRule.actions = [makeAction(.setColorLabel, .object(["color": .string("Blue")]), position: 0, ruleId: colorRule.id)]
        try db.insertRule(colorRule)

        let coordinator = WatcherCoordinator(db: db)
        coordinator.handle(path: file)

        let movedPath = (pngDir as NSString).appendingPathComponent("a.png")
        #expect(FileManager.default.fileExists(atPath: movedPath))

        // The move's own follow-up FSEvent for the new path.
        coordinator.handle(path: movedPath)

        #expect(FinderTags.currentColorName(movedPath) == "blue")
        #expect(try db.listHistory().contains { $0.actionKind == .setColorLabel && $0.status == .applied })
    }

    @Test func resultEventAfterMoveAndRenameDoesNotRepeatTheSameRule() throws {
        let db = try makeDB()
        let dir = TempDir()
        let file = dir.file("a.png")
        let pngDir = dir.dir("PNG")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)

        var rule = makeRule(folderId: folder.id, name: "move and rename", recursionDepth: 2)
        rule.conditions = [makeCondition(.extension_, .is, "png", ruleId: rule.id)]
        rule.actions = [
            makeAction(.moveToFolder, .object(["destination": .string(pngDir)]), position: 0, ruleId: rule.id),
            makeAction(.rename, .object(["pattern": .string("{name}-moved")]), position: 1, ruleId: rule.id),
        ]
        try db.insertRule(rule)

        let coordinator = WatcherCoordinator(db: db)
        coordinator.handle(path: file)

        let renamedPath = (pngDir as NSString).appendingPathComponent("a-moved.png")
        #expect(FileManager.default.fileExists(atPath: renamedPath))

        coordinator.handle(path: renamedPath)

        let repeatedPath = (pngDir as NSString).appendingPathComponent("a-moved-moved.png")
        #expect(FileManager.default.fileExists(atPath: renamedPath))
        #expect(!FileManager.default.fileExists(atPath: repeatedPath))
        #expect(try db.listHistory().filter { $0.ruleId == rule.id }.count == 2)
    }

    @Test func alreadyInDestinationIsSkippedByTheWatcher() throws {
        let db = try makeDB()
        let dir = TempDir()
        let pdfDir = dir.dir("PDF")
        let existing = (pdfDir as NSString).appendingPathComponent("existing.pdf")
        try "x".write(toFile: existing, atomically: true, encoding: .utf8)

        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "sort pdf", recursionDepth: nil)
        rule.conditions = [makeCondition(.extension_, .is, "pdf", ruleId: rule.id)]
        rule.actions = [makeAction(.moveToFolder, .object(["destination": .string(pdfDir)]), position: 0, ruleId: rule.id)]
        try db.insertRule(rule)

        let coordinator = WatcherCoordinator(db: db)
        coordinator.handle(path: existing)

        #expect(FileManager.default.fileExists(atPath: existing))
        let numberedDuplicate = (pdfDir as NSString).appendingPathComponent("existing (1).pdf")
        #expect(!FileManager.default.fileExists(atPath: numberedDuplicate))
    }
}
