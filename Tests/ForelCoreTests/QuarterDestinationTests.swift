import Foundation
import Testing
@testable import ForelCore

@Suite struct QuarterDestinationTests {
    private func setCreationDate(_ path: String, year: Int, month: Int) throws {
        let date = try #require(Calendar.current.date(from: DateComponents(year: year, month: month, day: 15, hour: 12)))
        try FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: path)
        let stored = try #require(FileManager.default.attributesOfItem(atPath: path)[.creationDate] as? Date)
        #expect(abs(stored.timeIntervalSince(date)) < 1)
    }

    @Test(arguments: 1...12, [ActionKind.moveToFolder, .copyToFolder])
    func allMonthsResolveAlongsideExistingTokens(month: Int, kind: ActionKind) throws {
        let dir = TempDir()
        let path = dir.file("receipt.txt", contents: "receipt")
        try setCreationDate(path, year: 2020, month: month)
        let destination = dir.path + "/{year} - Q{quarter}/{month}-{day}/Q{quarter}/{unknown}"
        let expected = dir.path + "/2020 - Q\((month - 1) / 3 + 1)/\(String(format: "%02d", month))-15/Q\((month - 1) / 3 + 1)/{unknown}/receipt.txt"
        let action = makeAction(kind, .object([ActionParam.destination: .string(destination)]))
        #expect(try ActionExecutor.plan(action, path: path).targetPath == expected)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(!FileManager.default.fileExists(atPath: expected))
    }

    @Test(arguments: ["preview", "manual", "watcher"], [ActionKind.moveToFolder, .copyToFolder])
    func persistedQuarterlyDestinationsAcrossExecutionPaths(execution: String, kind: ActionKind) throws {
        let dir = TempDir()
        let input = dir.dir("Input")
        let output = dir.dir("Archive")
        let path = dir.file("Input/receipt.txt", contents: "receipt")
        try setCreationDate(path, year: 2026, month: 10)
        let destination = output + "/{year} - Q{quarter}"
        let expected = output + "/2026 - Q4/receipt.txt"
        let folder = WatchedFolder(path: input)
        var rule = makeRule(folderId: folder.id, name: "Quarterly filing")
        rule.conditions = [makeCondition(.extension_, .is, "txt", ruleId: rule.id)]
        rule.actions = [makeAction(kind, .object([ActionParam.destination: .string(destination)]), ruleId: rule.id)]
        let databasePath = dir.path + "/rules.db"
        do {
            let saved = try Database(path: databasePath)
            try saved.insertFolder(folder)
            try saved.insertRule(rule)
        }
        let db = try Database(path: databasePath)
        let rules = try db.executionRules(folderID: folder.id, isPro: false)
        #expect(rules.first?.actions == rule.actions)
        if execution == "preview" {
            let entries = RuleEngine.walkEntries(root: input, maxDepth: RuleEngine.maxRuleDepth(rules))
            let previews = entries.compactMap {
                RuleEngine.previewFile(path: $0.path, depth: $0.depth, rules: rules, root: input, isPro: false)
            }
            let preview = try #require(previews.first)
            #expect(previews.count == 1)
            #expect(preview.rules[0].actions[0].targetPath == expected)
            #expect(preview.rules[0].actions[0].status == .wouldRun)
            #expect(FileManager.default.fileExists(atPath: path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: output).isEmpty)
        } else {
            let history: [HistoryEntry]
            if execution == "manual" {
                history = RuleEngine.walkEntries(root: input, maxDepth: RuleEngine.maxRuleDepth(rules)).flatMap {
                    RuleEngine.run(path: $0.path, depth: $0.depth, rules: rules, batchId: "quarter", root: input, isPro: false).history
                }
            } else {
                let coordinator = WatcherCoordinator(db: db, settleInterval: 0.01)
                coordinator.enqueue(event: .pathArrived(path))
                coordinator.waitForPendingEvents()
                history = try db.listHistory()
            }
            #expect(history.map(\.status) == [.applied])
            #expect(history.first?.resultPath == expected)
            #expect(try String(contentsOfFile: expected, encoding: .utf8) == "receipt")
            #expect(FileManager.default.fileExists(atPath: path) == (kind == .copyToFolder))
            #expect(!FileManager.default.fileExists(atPath: destination))
        }
    }
}
