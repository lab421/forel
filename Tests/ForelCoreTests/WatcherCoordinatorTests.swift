import Testing
import Foundation
import CoreServices
@testable import ForelCore

@Suite struct WatcherCoordinatorTests {
    private func makeDB() throws -> Database {
        try Database(path: ":memory:")
    }

    @Test func fsEventTriggersPlanAndExecution() throws {
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
        coordinator.handle(path: file, flags: UInt32(kFSEventStreamEventFlagItemCreated))

        let movedPath = (destination as NSString).appendingPathComponent("a.txt")
        #expect(FileManager.default.fileExists(atPath: movedPath))
        #expect(!FileManager.default.fileExists(atPath: file))
        #expect(try db.listHistory().count == 1)
    }

    /// Regression test for a reported bug: moving a file into a subfolder
    /// (rule 1) must not prevent a second, deeper-scoped rule (rule 2) from
    /// still applying to it at its new location. The move's own follow-up
    /// FSEvent for the new path is how rule 2 gets its chance — it must not
    /// be swallowed as a "Forel echo".
    @Test func laterRuleStillAppliesToAFileAfterAnEarlierRuleMovedIt() throws {
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

        // Inserted second, so listRules returns it after moveRule (priority order).
        var colorRule = makeRule(folderId: folder.id, name: "color pngs", recursionDepth: 3)
        colorRule.conditions = [makeCondition(.extension_, .is, "png", ruleId: colorRule.id)]
        colorRule.actions = [makeAction(.setColorLabel, .object(["color": .string("Blue")]), position: 0, ruleId: colorRule.id)]
        try db.insertRule(colorRule)

        let coordinator = WatcherCoordinator(db: db)
        // First FSEvent: the file is created at /a.png — rule 1 moves it.
        coordinator.handle(path: file, flags: UInt32(kFSEventStreamEventFlagItemCreated))

        let movedPath = (pngDir as NSString).appendingPathComponent("a.png")
        #expect(FileManager.default.fileExists(atPath: movedPath))

        // Second FSEvent: the move itself surfaces the file at its new path.
        coordinator.handle(path: movedPath, flags: UInt32(kFSEventStreamEventFlagItemRenamed))

        #expect(FinderTags.currentColorName(movedPath) == "blue")
        #expect(try db.listHistory().contains { $0.actionKind == .setColorLabel && $0.status == .applied })
    }

    @Test func alreadyInDestinationIsSkippedByWatcher() throws {
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
        coordinator.handle(path: existing, flags: UInt32(kFSEventStreamEventFlagItemCreated))

        #expect(FileManager.default.fileExists(atPath: existing))
        let numberedDuplicate = (pdfDir as NSString).appendingPathComponent("existing (1).pdf")
        #expect(!FileManager.default.fileExists(atPath: numberedDuplicate))
        #expect(try db.listHistory().isEmpty)
    }

    @Test func startupScanUsesThePlanner() throws {
        let db = try makeDB()
        let dir = TempDir()
        _ = dir.file("a.txt")
        let destination = dir.dir("Archive")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "archive")
        rule.conditions = [makeCondition(.extension_, .is, "txt", ruleId: rule.id)]
        rule.actions = [makeAction(.moveToFolder, .object(["destination": .string(destination)]), position: 0, ruleId: rule.id)]
        try db.insertRule(rule)

        let coordinator = WatcherCoordinator(db: db)
        coordinator.runStartupScan(folder: folder)

        let movedPath = (destination as NSString).appendingPathComponent("a.txt")
        #expect(FileManager.default.fileExists(atPath: movedPath))
        #expect(try db.listHistory().count == 1)
        #expect(try db.listRecentFilesystemEvents().contains { $0.source == .scan && $0.kind == .discovered })
    }

    @Test func runNowAndWatcherProduceTheSamePlannedActionForTheSameFile() throws {
        let dir = TempDir()
        let file = dir.file("a.txt")
        let destination = dir.dir("Archive")
        var rule = makeRule(name: "archive", conditions: [makeCondition(.extension_, .is, "txt")])
        rule.actions = [makeAction(.moveToFolder, .object(["destination": .string(destination)]), position: 0)]

        let depth = RuleEngine.pathDepth(root: dir.path, path: file) ?? 0
        let viaWatcherPlanner = RulePlanner.planFile(path: file, depth: depth, rules: [rule], root: dir.path)
        let entries = RuleEngine.walkEntries(root: dir.path, maxDepth: nil)
        let viaRunNowPlan = RulePlanner.plan(entries: entries, rules: [rule], root: dir.path)

        let runNowFile = try #require(viaRunNowPlan.files.first { $0.path == file })
        let watcherFile = try #require(viaWatcherPlanner)

        #expect(runNowFile.rules.map { $0.actions.map(\.status) } == watcherFile.rules.map { $0.actions.map(\.status) })
        #expect(runNowFile.rules.map { $0.actions.map(\.targetPath) } == watcherFile.rules.map { $0.actions.map(\.targetPath) })
    }

    @Test func repeatedIdenticalEventsDoNotReapplyActionsAfterFirstRun() throws {
        let db = try makeDB()
        let dir = TempDir()
        let file = dir.file("a.txt")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "tag")
        rule.conditions = [makeCondition(.extension_, .is, "txt", ruleId: rule.id)]
        rule.actions = [makeAction(.addTag, .object(["tag": .string("Seen")]), position: 0, ruleId: rule.id)]
        try db.insertRule(rule)

        let coordinator = WatcherCoordinator(db: db)
        coordinator.handle(path: file, flags: UInt32(kFSEventStreamEventFlagItemCreated))
        #expect(try db.listHistory().count == 1)

        // A second, identical FSEvent for the same now-tagged file (its own
        // echo) must not re-run the rule.
        coordinator.handle(path: file, flags: UInt32(kFSEventStreamEventFlagItemModified))
        #expect(try db.listHistory().count == 1)
    }
}
