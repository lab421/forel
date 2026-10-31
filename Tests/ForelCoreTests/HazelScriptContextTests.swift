import Foundation
import Testing
@testable import ForelCore

@Suite struct HazelScriptContextTests {
    private func script(_ source: String, outputs: [String] = []) -> Condition {
        let spec = HazelScriptCondition(language: .javaScript, source: source, outputNames: outputs)
        return makeCondition(.hazelScriptCondition, .is, spec.encoded)
    }

    @Test func conditionOutputsFeedActionPatternsAcrossPaths() throws {
        let dir = TempDir()
        let folder = WatchedFolder(path: dir.path)
        let db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "script condition", conditions: [script("return {hazelPassesScript:true, hazelOutputAttributes:{value:'produced'}};", outputs: ["answer"])])
        rule.isHazelImported = true
        rule.conditions[0].ruleId = rule.id
        rule.actions = [makeAction(.rename, .object([ActionParam.pattern: .string("dynamic"), HazelPattern.tokensKey: .array([
            .object(["type": .string("attribute"), "value": .string("answer")]),
            .object(["type": .string("extension")])
        ])]), ruleId: rule.id)]
        let preview = dir.file("preview.txt")
        let manual = dir.file("manual.txt")
        let watched = dir.file("watcher.txt")
        let predicted = try #require(RuleEngine.previewFile(path: preview, depth: 0, rules: [rule]))
        #expect(predicted.rules.first?.conditions.first?.detail == "Executed during Dry Run")
        #expect(predicted.rules.first?.actions.first?.targetPath == (dir.path as NSString).appendingPathComponent("produced.txt"))
        let result = RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "condition")
        #expect(result.history.first?.status == .applied)
        #expect(FileManager.default.fileExists(atPath: (dir.path as NSString).appendingPathComponent("produced.txt")))
        try FileManager.default.removeItem(atPath: (dir.path as NSString).appendingPathComponent("produced.txt"))
        try db.insertRule(rule)
        WatcherCoordinator(db: db).handle(path: watched)
        #expect(try db.listHistory().first?.status == .applied)
    }

    @Test func errorsInNegatedGroupsNeverCauseActions() throws {
        let dir = TempDir()
        let path = dir.file("item.txt")
        let fail = script("throw Error('failure');")
        let group = ConditionGroup(match: .none, conditions: [fail])
        var rule = makeRule(name: "error", conditions: [makeCondition(.conditionGroup, .is, group.encoded)], actions: [makeAction(.delete, .object([:]))])
        rule.isHazelImported = true
        let preview = try #require(RuleEngine.previewFile(path: path, depth: 0, rules: [rule]))
        #expect(preview.rules.first?.actions.first?.status == .blocked)
        let result = RuleEngine.run(path: path, depth: 0, rules: [rule], batchId: "failure")
        #expect(result.history.first?.status == .failed)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func groupShortCircuitsBeforeUnneededConditionScript() throws {
        let dir = TempDir()
        let path = dir.file("item.txt")
        let marker = (dir.path as NSString).appendingPathComponent("marker")
        let script = HazelScriptCondition(source: "touch '\(marker)'\nexit 0")
        let child = makeCondition(.hazelScriptCondition, .is, script.encoded)
        let group = ConditionGroup(match: .any, conditions: [makeCondition(.name, .is, "item"), child])
        let condition = makeCondition(.conditionGroup, .is, group.encoded)
        #expect(ConditionEvaluator.evaluate(condition, path: path, depth: 0))
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test func folderConditionScriptRunsOnceWhenRecursing() throws {
        let dir = TempDir()
        let outside = TempDir()
        let folderPath = dir.dir("nested")
        _ = dir.file("nested/item.txt")
        let marker = (outside.path as NSString).appendingPathComponent("count")
        let spec = HazelScriptCondition(source: "printf x >> '\(marker)'\ntest -d \"$1\"")
        var rule = makeRule(name: "recurse", conditions: [makeCondition(.hazelScriptCondition, .is, spec.encoded)], actions: [makeAction(.hazelRecurse, .object([:]))])
        rule.isHazelImported = true
        RuleEngine.forEachRuleEntryExecuting(root: dir.path, rules: [rule]) { entry, rules, recurse in
            RuleEngine.runWithTraversal(path: entry.path, depth: entry.depth, rules: rules, batchId: "test", onRecurse: recurse).recurses
        }
        // The folder and its one child each execute the predicate once.
        #expect(try String(contentsOfFile: marker, encoding: .utf8) == "xx")
        try FileManager.default.removeItem(atPath: marker)
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        rule.folderId = folder.id
        rule.conditions[0].ruleId = rule.id
        rule.actions[0].ruleId = rule.id
        try db.insertRule(rule)
        let watcher = WatcherCoordinator(db: db, settleInterval: 0.01)
        watcher.enqueue(event: .rescanSubtree(dir.path))
        #expect(watcher.waitForPendingEvents())
        #expect(try String(contentsOfFile: marker, encoding: .utf8) == "xx")
        #expect(FileManager.default.fileExists(atPath: folderPath))
    }
}
