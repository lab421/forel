import Foundation
import Testing
@testable import ForelCore

@Suite struct LockedConditionTests {
    @Test(arguments: [false, true])
    func matchesFinderLockAndTracksChanges(isFolder: Bool) throws {
        let dir = TempDir()
        let path = isFolder ? dir.dir("Project") : dir.file("report.txt", contents: "report")
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: path) }
        #expect(ConditionKind.locked.validOperators == [.isTrue, .isFalse])
        #expect(ConditionKind.locked.defaultOperator == .isTrue)
        #expect(RuleSchema.conditionKinds.contains(.locked))
        for locked in [false, true, false] {
            try FileManager.default.setAttributes([.immutable: locked], ofItemAtPath: path)
            for op in ConditionKind.locked.validOperators {
                let condition = makeCondition(.locked, op, "")
                #expect(RuleSchema.valueKind(for: .locked, operator: op) == .none)
                #expect(RuleValidator.validate([condition]).isEmpty)
                #expect(ConditionEvaluator.evaluate(condition, path: path) == (locked == (op == .isTrue)))
            }
        }
    }

    @Test func readOnlyIsNotLockedAndMissingFilesNeverMatch() throws {
        let dir = TempDir()
        let path = dir.file("read-only.txt", contents: "report")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path)
        #expect(!ConditionEvaluator.evaluate(makeCondition(.locked, .isTrue, ""), path: path))
        #expect(ConditionEvaluator.evaluate(makeCondition(.locked, .isFalse, ""), path: path))
        for op in ConditionKind.locked.validOperators {
            #expect(!ConditionEvaluator.evaluate(makeCondition(.locked, op, ""), path: dir.path + "/missing"))
        }
        let invalid = makeCondition(.locked, .contains, "true")
        #expect(!RuleValidator.validate([invalid]).isEmpty)
        #expect(!ConditionEvaluator.evaluate(invalid, path: path))
    }

    @Test(arguments: ["preview", "manual", "watcher"], [Operator.isTrue, .isFalse])
    func persistedRulesMatchAcrossExecutionPaths(execution: String, op: Operator) throws {
        let dir = TempDir()
        let input = dir.dir("Input")
        let destination = dir.dir("Copies")
        let locked = dir.file("Input/locked.txt", contents: "locked contents")
        let unlocked = dir.file("Input/unlocked.txt", contents: "unlocked contents")
        let expected = op == .isTrue ? locked : unlocked
        let target = destination + "/" + (expected as NSString).lastPathComponent
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked)
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: target)
        }
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked)
        let folder = WatchedFolder(path: input)
        var rule = makeRule(folderId: folder.id, name: "Locked")
        rule.conditions = [makeCondition(.locked, op, "", ruleId: rule.id)]
        rule.actions = [makeAction(.copyToFolder, .object([ActionParam.destination: .string(destination)]), ruleId: rule.id)]
        let databasePath = dir.path + "/rules.db"
        do {
            let saved = try Database(path: databasePath)
            try saved.insertFolder(folder)
            try saved.insertRule(rule)
        }
        let db = try Database(path: databasePath)
        let rules = try db.executionRules(folderID: folder.id, isPro: false)
        #expect(rules.first?.conditions == rule.conditions)
        #expect(RuleValidator.validate(try #require(rules.first).conditions).isEmpty)
        let entries = RuleEngine.walkEntries(root: input, maxDepth: RuleEngine.maxRuleDepth(rules))
        if execution == "preview" {
            let matches = entries.compactMap {
                RuleEngine.previewFile(path: $0.path, depth: $0.depth, rules: rules, root: input, isPro: false)
            }
            try #require(matches.count == 1)
            #expect(matches[0].path == expected)
            #expect(matches[0].rules[0].actions[0].targetPath == target)
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination).isEmpty)
        } else {
            let history: [HistoryEntry]
            if execution == "manual" {
                history = entries.flatMap {
                    RuleEngine.run(path: $0.path, depth: $0.depth, rules: rules, batchId: "manual", root: input, isPro: false).history
                }
            } else {
                let coordinator = WatcherCoordinator(db: db, settleInterval: 0.01)
                for entry in entries { coordinator.enqueue(event: .pathArrived(entry.path)) }
                coordinator.waitForPendingEvents()
                history = try db.listHistory()
            }
            #expect(history.map(\.status) == [.applied])
            #expect(history.first?.originalPath == expected)
            #expect(try String(contentsOfFile: target, encoding: .utf8) == String(contentsOfFile: expected, encoding: .utf8))
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination).count == 1)
        }
        #expect(FileManager.default.fileExists(atPath: locked))
        #expect(FileManager.default.fileExists(atPath: unlocked))
    }
}
