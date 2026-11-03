import Foundation
import Darwin
import Testing
@testable import ForelCore

@Suite struct FinderCommentTests {
    private func writeComment(_ value: Any, to path: String, format: PropertyListSerialization.PropertyListFormat = .binary) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: format, options: 0)
        try writeAttribute(data, to: path)
    }

    private func writeAttribute(_ data: Data, to path: String) throws {
        let result = data.withUnsafeBytes { bytes in
            setxattr(path, FinderComment.xattrName, bytes.baseAddress, data.count, 0, 0)
        }
        try #require(result == 0)
    }

    @Test(arguments: [false, true])
    func matchesEveryNameOperatorOnFinderComments(isFolder: Bool) throws {
        let dir = TempDir()
        let path = isFolder ? dir.dir("Project") : dir.file("report.txt", contents: "unrelated file contents")
        let comment = "À valider\nProjet Client 2026.pdf"
        try writeComment(comment, to: path)
        #expect(FinderComment.read(path) == comment)
        #expect(ConditionKind.comment.validOperators == ConditionKind.name.validOperators)
        #expect(RuleSchema.conditionKinds.contains(.comment))
        let fixtures: [Operator: String] = [
            .is: comment, .isNot: "Other comment", .contains: "Client",
            .doesNotContain: "Rejected", .startsWith: "À valider",
            .endsWith: "2026.pdf", .matchesRegex: "(?s)^À valider.*2026\\.pdf$",
        ]
        #expect(Set(fixtures.keys) == Set(ConditionKind.comment.validOperators))
        for (op, value) in fixtures {
            #expect(ConditionEvaluator.evaluate(makeCondition(.comment, op, value), path: path), "\(op)")
        }
        let nonmatches: [Operator: String] = [
            .is: "2026", .isNot: comment, .contains: "client",
            .doesNotContain: "Client", .startsWith: "Projet", .endsWith: "2026",
            .matchesRegex: "^Rejected",
        ]
        for (op, value) in nonmatches {
            #expect(!ConditionEvaluator.evaluate(makeCondition(.comment, op, value), path: path), "\(op)")
        }
        #expect(!ConditionEvaluator.evaluate(makeCondition(.comment, .matchesRegex, "["), path: path))
    }

    @Test func absentCommentsAreEmptyButInvalidOrMissingFilesDoNotMatchNegativeConditions() throws {
        let dir = TempDir()
        let path = dir.file("report.txt")
        #expect(FinderComment.read(path) == "")
        #expect(!ConditionEvaluator.evaluate(makeCondition(.comment, .contains, "Hold"), path: path))
        #expect(ConditionEvaluator.evaluate(makeCondition(.comment, .isNot, "Hold"), path: path))
        #expect(ConditionEvaluator.evaluate(makeCondition(.comment, .doesNotContain, "Hold"), path: path))
        try writeComment("", to: path)
        #expect(FinderComment.read(path) == "")
        #expect(ConditionEvaluator.evaluate(makeCondition(.comment, .isNot, "Hold"), path: path))
        let invalidValues = [
            Data("not a property list".utf8),
            Data(),
            try PropertyListSerialization.data(fromPropertyList: ["Hold"], format: .binary, options: 0),
        ]
        for data in invalidValues {
            try writeAttribute(data, to: path)
            #expect(FinderComment.read(path) == nil)
            #expect(!ConditionEvaluator.evaluate(makeCondition(.comment, .isNot, "Hold"), path: path))
            #expect(!ConditionEvaluator.evaluate(makeCondition(.comment, .doesNotContain, "Hold"), path: path))
        }
        try FileManager.default.removeItem(atPath: path)
        #expect(FinderComment.read(path) == nil)
        #expect(!ConditionEvaluator.evaluate(makeCondition(.comment, .isNot, "Hold"), path: path))
    }

    @Test func xmlCommentsAreDecodedWithoutChangingWhitespaceOrCase() throws {
        let dir = TempDir()
        let path = dir.file("report.txt")
        let comment = "  À conserver\nClient A  "
        try writeComment(comment, to: path, format: .xml)
        #expect(ConditionEvaluator.evaluate(makeCondition(.comment, .is, comment), path: path))
        #expect(!ConditionEvaluator.evaluate(makeCondition(.comment, .is, comment.trimmingCharacters(in: .whitespacesAndNewlines)), path: path))
    }

    @Test(arguments: ["preview", "manual", "watcher"], [false, true])
    func savedCommentRulesWorkAcrossAllExecutionPaths(execution: String, isFolder: Bool) throws {
        let dir = TempDir()
        let watched = dir.dir("Watched")
        let source = isFolder ? dir.dir("Watched/Project") : dir.file("Watched/report.txt", contents: "original")
        let held = dir.file("Watched/held.txt", contents: "keep")
        try writeComment("Ready for archive", to: source)
        try writeComment("Hold", to: held)
        let expected = watched + (isFolder ? "/processed-Project" : "/processed-report.txt")
        let folder = WatchedFolder(path: watched)
        var rule = makeRule(folderId: folder.id, name: "Process reviewed items")
        rule.conditions = [makeCondition(.comment, .contains, "Ready", ruleId: rule.id)]
        rule.actions = [makeAction(.rename, .object([ActionParam.pattern: .string("processed-{name}")]), ruleId: rule.id)]
        let databasePath = dir.path + "/rules.db"
        do {
            let db = try Database(path: databasePath)
            try db.insertFolder(folder)
            try db.insertRule(rule)
        }
        let db = try Database(path: databasePath)
        let rules = try db.executionRules(folderID: folder.id, isPro: false)
        #expect(rules.first?.conditions == rule.conditions)
        #expect(RuleValidator.validate(rules[0].conditions).isEmpty)
        if execution == "preview" {
            let entries = RuleEngine.walkEntries(root: watched, maxDepth: RuleEngine.maxRuleDepth(rules))
            let matches = entries.compactMap { RuleEngine.previewFile(path: $0.path, depth: $0.depth, rules: rules, root: watched, isPro: false) }
            try #require(matches.count == 1)
            #expect(matches[0].path == source)
            #expect(matches[0].rules[0].conditions[0].kind == .comment)
            #expect(matches[0].rules[0].conditions[0].matched)
            #expect(matches[0].rules[0].actions[0].targetPath == expected)
            #expect(FileManager.default.fileExists(atPath: source))
            #expect(!FileManager.default.fileExists(atPath: expected))
        } else {
            let history: [HistoryEntry]
            if execution == "manual" {
                history = RuleEngine.walkEntries(root: watched, maxDepth: RuleEngine.maxRuleDepth(rules)).flatMap {
                    RuleEngine.run(path: $0.path, depth: $0.depth, rules: rules, batchId: "manual", root: watched, isPro: false).history
                }
            } else {
                let watcher = WatcherCoordinator(db: db, settleInterval: 0.01)
                watcher.enqueue(event: .pathArrived(source))
                watcher.enqueue(event: .pathArrived(held))
                watcher.waitForPendingEvents()
                history = try db.listHistory()
            }
            #expect(history.map(\.status) == [.applied])
            #expect(history.first?.resultPath == expected)
            #expect(!FileManager.default.fileExists(atPath: source))
            #expect(FileManager.default.fileExists(atPath: expected))
            #expect(FinderComment.read(expected) == "Ready for archive")
        }
        #expect(try String(contentsOfFile: held, encoding: .utf8) == "keep")
        #expect(!FileManager.default.fileExists(atPath: watched + "/processed-held.txt"))
    }
}
