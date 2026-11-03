import Foundation
import Darwin
import Testing
@testable import ForelCore

@Suite struct LastOpenedDateTests {
    private func writeDate(_ date: Date, to path: String) throws {
        let interval = date.timeIntervalSince1970
        let seconds = Int64(interval.rounded(.down))
        let nanos = Int64((interval - Double(seconds)) * 1_000_000_000)
        var values = [seconds.littleEndian, nanos.littleEndian]
        let data = values.withUnsafeMutableBytes { Data($0) }
        try writeAttribute(data, to: path)
    }

    private func writeAttribute(_ data: Data, to path: String) throws {
        let result = data.withUnsafeBytes { bytes in
            setxattr(path, LastOpenedDate.xattrName, bytes.baseAddress, data.count, 0, 0)
        }
        try #require(result == 0)
    }

    @Test(arguments: [false, true])
    func supportsAllDateOperatorsAndUsesLastOpenedMetadata(isFolder: Bool) throws {
        let dir = TempDir()
        let path = isFolder ? dir.dir("Project") : dir.file("report.txt", contents: "original")
        let opened = try #require(Calendar.current.date(byAdding: .day, value: -10, to: Date()))
        try writeDate(opened, to: path)
        let read = try #require(LastOpenedDate.read(path))
        #expect(abs(read.timeIntervalSince(opened)) < 0.001)
        #expect(ConditionKind.dateLastOpened.validOperators == ConditionKind.dateModified.validOperators)
        #expect(RuleSchema.conditionKinds.contains(.dateLastOpened))
        #expect(RuleSchema.valueKind(for: .dateLastOpened, operator: .before) == .absoluteDate)
        #expect(RuleSchema.valueKind(for: .dateLastOpened, operator: .withinLast) == .relativeDate)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let before = formatter.string(from: Date())
        let after = formatter.string(from: try #require(Calendar.current.date(byAdding: .day, value: -20, to: Date())))
        let cases: [Operator: String] = [.before: before, .after: after, .olderThan: "5 days", .withinLast: "30 days"]
        #expect(Set(cases.keys) == Set(ConditionKind.dateLastOpened.validOperators))
        for (op, value) in cases {
            #expect(ConditionEvaluator.evaluate(makeCondition(.dateLastOpened, op, value), path: path))
        }
        #expect(!ConditionEvaluator.evaluate(makeCondition(.dateLastOpened, .olderThan, "30 days"), path: path))
        #expect(!ConditionEvaluator.evaluate(makeCondition(.dateLastOpened, .withinLast, "5 days"), path: path))
        // Reading contents or changing other filesystem timestamps must not
        // turn an old last-opened date into a recent one.
        if !isFolder { _ = try Data(contentsOf: URL(fileURLWithPath: path)) }
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path)
        #expect(abs(try #require(LastOpenedDate.read(path)).timeIntervalSince(opened)) < 0.001)
    }

    @Test func unavailableAndMalformedDatesNeverMatch() throws {
        let dir = TempDir()
        let path = dir.file("report.txt")
        #expect(LastOpenedDate.read(path) == nil)
        let invalid: [Data] = [
            Data(), Data([1, 2, 3]), Data(repeating: 0, count: 16),
            Data(repeating: 0xff, count: 16), Data(repeating: 1, count: 17),
        ]
        for data in invalid {
            try writeAttribute(data, to: path)
            #expect(LastOpenedDate.read(path) == nil)
            for (op, value) in [(Operator.before, "2999-01-01"), (.after, "1900-01-01"), (.olderThan, "1 days"), (.withinLast, "30 years")] {
                #expect(!ConditionEvaluator.evaluate(makeCondition(.dateLastOpened, op, value), path: path))
            }
        }
        #expect(LastOpenedDate.read(dir.path + "/missing.txt") == nil)
    }

    @Test(arguments: ["preview", "manual", "watcher"], [Operator.olderThan, .withinLast])
    func persistedHourlyRulesAreConsistentAcrossExecutionPaths(execution: String, op: Operator) throws {
        let dir = TempDir()
        let input = dir.dir("Input")
        let destination = dir.dir("Processed")
        let recent = dir.file("Input/recent.txt", contents: "recent")
        let old = dir.file("Input/old.txt", contents: "old")
        let unknown = dir.file("Input/unknown.txt", contents: "unknown")
        try writeDate(Date().addingTimeInterval(-30 * 60), to: recent)
        try writeDate(Date().addingTimeInterval(-90 * 60), to: old)
        let expected = op == .withinLast ? recent : old
        let untouched = op == .withinLast ? old : recent
        let folder = WatchedFolder(path: input)
        var rule = makeRule(folderId: folder.id, name: "Last opened")
        rule.conditions = [makeCondition(.dateLastOpened, op, "1 hours", ruleId: rule.id)]
        rule.actions = [makeAction(.moveToFolder, .object([ActionParam.destination: .string(destination)]), ruleId: rule.id)]
        let databasePath = dir.path + "/rules.db"
        do {
            let saved = try Database(path: databasePath)
            try saved.insertFolder(folder)
            try saved.insertRule(rule)
        }
        let db = try Database(path: databasePath)
        let rules = try db.executionRules(folderID: folder.id, isPro: false)
        #expect(rules.first?.conditions == rule.conditions)
        #expect(RuleValidator.validate(rules[0].conditions).isEmpty)
        let entries = RuleEngine.walkEntries(root: input, maxDepth: RuleEngine.maxRuleDepth(rules))
        if execution == "preview" {
            let matches = entries.compactMap { RuleEngine.previewFile(path: $0.path, depth: $0.depth, rules: rules, root: input, isPro: false) }
            try #require(matches.count == 1)
            #expect(matches[0].path == expected)
            #expect(matches[0].rules[0].conditions[0].kind == .dateLastOpened)
            #expect(matches[0].rules[0].actions[0].targetPath == destination + "/" + (expected as NSString).lastPathComponent)
            #expect(FileManager.default.fileExists(atPath: expected))
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination).isEmpty)
        } else {
            let history: [HistoryEntry]
            if execution == "manual" {
                history = entries.flatMap { RuleEngine.run(path: $0.path, depth: $0.depth, rules: rules, batchId: "manual", root: input, isPro: false).history }
            } else {
                let coordinator = WatcherCoordinator(db: db, settleInterval: 0.01)
                for entry in entries { coordinator.enqueue(event: .pathArrived(entry.path)) }
                coordinator.waitForPendingEvents()
                history = try db.listHistory()
            }
            #expect(history.map(\.status) == [.applied])
            #expect(history.first?.originalPath == expected)
            #expect(!FileManager.default.fileExists(atPath: expected))
            #expect(FileManager.default.fileExists(atPath: destination + "/" + (expected as NSString).lastPathComponent))
        }
        #expect(FileManager.default.fileExists(atPath: untouched))
        #expect(FileManager.default.fileExists(atPath: unknown))
    }
}
