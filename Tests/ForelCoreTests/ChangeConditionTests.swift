import Foundation
import Testing
@testable import ForelCore

@Suite struct ChangeConditionTests {
    private final class Platform: ActionPlatform, @unchecked Sendable {
        var fail = true
        var calls = 0
        func notify(text: String, sound: Bool) throws { calls += 1; if fail { throw ActionError("fixture failure") } }
        func open(path: String, application: String?, passFile: Bool, bringToFront: Bool) throws {}
        func showInFinder(path: String, bringToFront: Bool) throws {}
        func pause(seconds: TimeInterval) throws {}
        func trash(path: String) throws -> String { throw ActionError("unexpected trash") }
    }

    @Test func previewDoesNotSeedAndFailedActionsRetryChangedValue() throws {
        let dir = TempDir(), folder = WatchedFolder(path: dir.path), db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "size changed")
        let condition = Condition(ruleId: rule.id, kind: .sizeBytes, operator: .didChange, value: "")
        rule.conditions = [condition]
        rule.actions = [makeAction(.displayNotification, .object([ActionParam.notificationText: .string("changed")]), ruleId: rule.id)]
        try db.insertRule(rule)
        let store = DatabaseHazelMatchStateStore(db: db), platform = Platform()
        let file = dir.file("fixture.txt", contents: "a")
        let item = store.itemKey(path: file), key = ChangeCondition.key(condition)
        #expect(RuleEngine.previewFile(path: file, depth: 0, rules: [rule], matchState: store) == nil)
        #expect(try store.changeBaseline(ruleId: rule.id, itemKey: item, conditionKey: key) == nil)
        #expect(RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "initial", platform: platform, matchState: store).history.isEmpty)
        let storedBaseline = try store.changeBaseline(ruleId: rule.id, itemKey: item, conditionKey: key)
        let baseline = try #require(storedBaseline)
        try "longer".write(toFile: file, atomically: false, encoding: .utf8)
        #expect(RuleEngine.previewFile(path: file, depth: 0, rules: [rule], matchState: store) != nil)
        #expect(try store.changeBaseline(ruleId: rule.id, itemKey: item, conditionKey: key) == baseline)
        #expect(RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "fail", platform: platform, matchState: store).history.first?.status == .failed)
        #expect(try store.changeBaseline(ruleId: rule.id, itemKey: item, conditionKey: key) == baseline)
        platform.fail = false
        #expect(RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "retry", platform: platform, matchState: store).history.first?.status == .applied)
        #expect(try store.changeBaseline(ruleId: rule.id, itemKey: item, conditionKey: key) != baseline)
        #expect(RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "unchanged", platform: platform, matchState: store).history.isEmpty)
        try "longer again".write(toFile: file, atomically: false, encoding: .utf8)
        #expect(RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "changed-again", platform: platform, matchState: store).history.first?.status == .applied)
    }

    @Test func nestedAnyChildKeepsSeparateBaselinesAndRetries() throws {
        let dir = TempDir(), folder = WatchedFolder(path: dir.path), db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        let watched = dir.dir("watched")
        let first = (watched as NSString).appendingPathComponent("a.txt")
        let second = (watched as NSString).appendingPathComponent("b.txt")
        try "a".write(toFile: first, atomically: true, encoding: .utf8)
        try "bb".write(toFile: second, atomically: true, encoding: .utf8)
        var rule = makeRule(folderId: folder.id, name: "child changed")
        let leaf = Condition(ruleId: rule.id, kind: .sizeBytes, operator: .didChange, value: "")
        let group = ConditionGroup(match: .any, target: .anyChild, conditions: [leaf])
        rule.conditions = [Condition(ruleId: rule.id, kind: .conditionGroup, operator: .is, value: group.encoded)]
        rule.actions = [makeAction(.displayNotification, .object([ActionParam.notificationText: .string("changed")]), ruleId: rule.id)]
        try db.insertRule(rule)
        let store = DatabaseHazelMatchStateStore(db: db), platform = Platform()
        #expect(RuleEngine.previewFile(path: watched, depth: 0, rules: [rule], matchState: store) == nil)
        #expect(try store.changeBaseline(ruleId: rule.id, itemKey: store.itemKey(path: first), conditionKey: ChangeCondition.key(leaf)) == nil)
        #expect(RuleEngine.run(path: watched, depth: 0, rules: [rule], batchId: "initial", platform: platform, matchState: store).history.isEmpty)
        try "longer".write(toFile: second, atomically: false, encoding: .utf8)
        #expect(RuleEngine.previewFile(path: watched, depth: 0, rules: [rule], matchState: store) != nil)
        #expect(RuleEngine.run(path: watched, depth: 0, rules: [rule], batchId: "fail", platform: platform, matchState: store).history.first?.status == .failed)
        platform.fail = false
        #expect(RuleEngine.run(path: watched, depth: 0, rules: [rule], batchId: "retry", platform: platform, matchState: store).history.first?.status == .applied)
        #expect(RuleEngine.run(path: watched, depth: 0, rules: [rule], batchId: "unchanged", platform: platform, matchState: store).history.isEmpty)
    }

    @Test func nestedNoneObservesAChangeThenMatchesWhenStable() throws {
        let dir = TempDir(), folder = WatchedFolder(path: dir.path), db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "not changed")
        let leaf = Condition(ruleId: rule.id, kind: .sizeBytes, operator: .didChange, value: "")
        rule.conditions = [Condition(ruleId: rule.id, kind: .conditionGroup, operator: .is, value: ConditionGroup(match: .none, target: .current, conditions: [leaf]).encoded)]
        rule.actions = [makeAction(.displayNotification, .object([ActionParam.notificationText: .string("stable")]), ruleId: rule.id)]
        try db.insertRule(rule)
        let store = DatabaseHazelMatchStateStore(db: db), platform = Platform(); platform.fail = false
        let file = dir.file("fixture.txt", contents: "a")
        #expect(RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "initial", platform: platform, matchState: store).history.first?.status == .applied)
        try "longer".write(toFile: file, atomically: false, encoding: .utf8)
        #expect(RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "changed", platform: platform, matchState: store).history.isEmpty)
        #expect(RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "stable", platform: platform, matchState: store).history.first?.status == .applied)
    }
}
