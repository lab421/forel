import Foundation
import Testing
@testable import ForelCore

@Suite struct ArchiveNamingTests {
    @Test func namesSupportLiteralsSourceNamesAndLocalDates() throws {
        let date = try #require(Calendar(identifier: .gregorian).date(from:
            DateComponents(year: 2026, month: 10, day: 26, hour: 14, minute: 35, second: 7)))
        #expect(try ActionExecutor.archiveFileName(pattern: "Backup", sourceName: "report", at: date) == "Backup.zip")
        #expect(try ActionExecutor.archiveFileName(pattern: "Backup.ZIP", sourceName: "report", at: date) == "Backup.ZIP")
        #expect(try ActionExecutor.archiveFileName(pattern: "", sourceName: "report", at: date) == "report.zip")
        #expect(try ActionExecutor.archiveFileName(pattern: "  ", sourceName: "report", at: date) == "report.zip")
        #expect(try ActionExecutor.archiveFileName(pattern: "{name}-{current_date}-{timestamp}", sourceName: "report", at: date)
            == "report-2026-10-26-2026-10-26_14-35-07.zip")
        #expect(try ActionExecutor.archiveFileName(pattern: "{name}", sourceName: "{timestamp}", at: date) == "{timestamp}.zip")
    }

    @Test(arguments: ["../outside", "/tmp/outside.zip", ".", "..", "bad\0name", "bad.", String(repeating: "é", count: 126)])
    func invalidNamesAreRejectedBeforeWriting(pattern: String) throws {
        let dir = TempDir()
        let file = dir.file("report.txt", contents: "original")
        let action = makeAction(.compress, .object([ActionParam.archiveName: .string(pattern)]))
        #expect(!RuleValidator.validate([action]).isEmpty)
        #expect(throws: ActionError.self) { try ActionExecutor.plan(action, path: file) }
        #expect(throws: ActionError.self) { try ActionExecutor.execute(action, path: file) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["report.txt"])
    }

    @Test(arguments: ["preview", "manual", "watcher"], [false, true])
    func savedNamesAndConflictsWorkAcrossExecutionPaths(execution: String, isFolder: Bool) throws {
        let dir = TempDir()
        let watched = dir.dir("Watched")
        let source: String
        let original: String
        let sourceName: String
        let entryName: String
        if isFolder {
            source = dir.dir("Watched/Project.2026")
            original = dir.file("Watched/Project.2026/report.txt", contents: "original")
            sourceName = "Project.2026"
            entryName = "Project.2026/report.txt"
        } else {
            source = dir.file("Watched/report.txt", contents: "original")
            original = source
            sourceName = "report"
            entryName = "report.txt"
        }
        let existing = dir.file("Watched/\(sourceName)-backup.zip", contents: "existing archive")
        let expected = watched + "/\(sourceName)-backup (1).zip"
        let folder = WatchedFolder(path: watched)
        var rule = makeRule(folderId: folder.id, name: "Compress")
        rule.conditions = [isFolder
            ? makeCondition(.kind, .is, "folder", ruleId: rule.id)
            : makeCondition(.extension_, .is, "txt", ruleId: rule.id)]
        rule.actions = [makeAction(.compress, .object([ActionParam.archiveName: .string("{name}-backup")]), ruleId: rule.id)]
        let databasePath = dir.path + "/rules.db"
        do {
            let db = try Database(path: databasePath)
            try db.insertFolder(folder)
            try db.insertRule(rule)
        }
        let db = try Database(path: databasePath)
        #expect(try db.listRules(folderId: folder.id).first?.actions == rule.actions)
        let rules = try db.executionRules(folderID: folder.id, isPro: false)
        #expect(RuleValidator.validate(rules[0].actions).isEmpty)
        if execution == "watcher" {
            let coordinator = WatcherCoordinator(db: db, settleInterval: 0.01)
            coordinator.enqueue(event: .pathArrived(source))
            coordinator.waitForPendingEvents()
            let history = try db.listHistory()
            #expect(history.count == 1)
            #expect(history.first?.status == .applied)
            #expect(history.first?.resultPath == expected)
        } else {
            let entries = RuleEngine.walkEntries(root: watched, maxDepth: RuleEngine.maxRuleDepth(rules))
            for entry in entries {
                if execution == "preview" {
                    let preview = RuleEngine.previewFile(path: entry.path, depth: entry.depth, rules: rules, isPro: false)
                    if entry.path == source {
                        #expect(preview?.rules.first?.actions.first?.targetPath == expected)
                    } else {
                        #expect(preview == nil)
                    }
                } else {
                    let result = RuleEngine.run(path: entry.path, depth: entry.depth, rules: rules, batchId: "manual", root: watched, isPro: false)
                    if entry.path == source {
                        #expect(result.history.count == 1)
                        #expect(result.history.first?.status == .applied)
                        #expect(result.history.first?.resultPath == expected)
                    } else {
                        #expect(result.history.isEmpty)
                    }
                }
            }
        }
        #expect(try String(contentsOfFile: original, encoding: .utf8) == "original")
        #expect(try String(contentsOfFile: existing, encoding: .utf8) == "existing archive")
        if execution == "preview" {
            #expect(!FileManager.default.fileExists(atPath: expected))
        } else {
            let extracted = TempDir()
            try FileManager.default.unzipItem(at: URL(fileURLWithPath: expected), to: URL(fileURLWithPath: extracted.path))
            #expect(try String(contentsOfFile: extracted.path + "/" + entryName, encoding: .utf8) == "original")
        }
    }
}
