import Foundation
import Testing
@testable import ForelCore

@Suite struct HazelTimedRuleTests {
    @Test func scheduleRelationsUseCurrentLocalDayAcrossMidnightAndDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let parse = ISO8601DateFormatter()
        func date(_ value: String) throws -> Date { try #require(parse.date(from: value)) }
        let schedule = CurrentTimeCondition.Schedule(time: "22:00", weekdays: "2", relation: .after).encoded
        #expect(!CurrentTimeCondition.matches(schedule, now: try date("2024-01-16T06:00:00Z"), calendar: calendar)) // Monday 22:00
        #expect(CurrentTimeCondition.matches(schedule, now: try date("2024-01-16T07:59:00Z"), calendar: calendar))
        #expect(!CurrentTimeCondition.matches(schedule, now: try date("2024-01-16T08:00:00Z"), calendar: calendar)) // Tuesday
        let before = CurrentTimeCondition.Schedule(time: "02:00", relation: .before).encoded
        #expect(CurrentTimeCondition.matches(before, now: try date("2024-03-10T09:59:00Z"), calendar: calendar))
        #expect(!CurrentTimeCondition.matches(before, now: try date("2024-03-10T10:00:00Z"), calendar: calendar)) // DST skips 02:00
        #expect(CurrentTimeCondition.matches("09:00", now: try date("2024-01-15T17:00:00Z"), calendar: calendar))
    }
    @Test func nextTickUsesCurrentMinuteAfterSlowScanOrWake() {
        let initial = Date(timeIntervalSince1970: 1_800_000_005)
        let first = WatcherCoordinator.nextMinuteBoundary(after: initial)
        #expect(first.timeIntervalSince(initial) == 55)
        // A scan or sleep that spans several minutes schedules one future
        // check, rather than processing the missed historical minutes.
        let resumed = initial.addingTimeInterval(367)
        let next = WatcherCoordinator.nextMinuteBoundary(after: resumed)
        #expect(next > resumed)
        #expect(next.timeIntervalSince(resumed) <= 60)
        #expect(WatcherCoordinator.nextMinuteBoundary(after: first) == first.addingTimeInterval(60))
    }
    private final class Platform: ActionPlatform, @unchecked Sendable {
        private let lock = NSLock()
        private var countValue = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return countValue }
        func notify(text: String, sound: Bool) throws { lock.lock(); countValue += 1; lock.unlock() }
        func open(path: String, application: String?, passFile: Bool, bringToFront: Bool) throws {}
        func showInFinder(path: String, bringToFront: Bool) throws {}
        func pause(seconds: TimeInterval) throws {}
        func trash(path: String) throws -> String { throw ActionError("Not used") }
    }

    @Test func elapsedTimeTriggersOnceAndStateSurvivesRestart() throws {
        let dir = TempDir()
        let path = dir.file("document.txt")
        let initial = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: initial.addingTimeInterval(-43_200)], ofItemAtPath: path)
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "older", conditions: [makeCondition(.dateModified, .olderThan, "1 days")])
        rule.isHazelImported = true
        rule.conditions[0].ruleId = rule.id
        rule.actions = [makeAction(.displayNotification, .object([ActionParam.notificationText: .string("aged")]), ruleId: rule.id)]
        try db.insertRule(rule)
        let platform = Platform()
        let first = WatcherCoordinator(db: db, actionPlatform: platform)
        first.recheckTimeSensitiveRules(root: dir.path, now: initial)
        #expect(platform.count == 0)
        let later = initial.addingTimeInterval(86_400)
        first.recheckTimeSensitiveRules(root: dir.path, now: later)
        first.recheckTimeSensitiveRules(root: dir.path, now: later.addingTimeInterval(60))
        #expect(platform.count == 1)
        let restarted = WatcherCoordinator(db: db, actionPlatform: platform)
        restarted.recheckTimeSensitiveRules(root: dir.path, now: later.addingTimeInterval(120))
        #expect(platform.count == 1)
        // A condition transition back to false permits a future new match.
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: path)
        restarted.recheckTimeSensitiveRules(root: dir.path, now: later.addingTimeInterval(180))
        restarted.recheckTimeSensitiveRules(root: dir.path, now: later.addingTimeInterval(2 * 86_400))
        #expect(platform.count == 2)
        let store = DatabaseHazelMatchStateStore(db: db)
        let storedState = try store.state(ruleId: rule.id, itemKey: store.itemKey(path: path))
        let state = try #require(storedState)
        #expect(state.matched)
        #expect(state.conditionSignature.count == 64)
        #expect(state.lastMatched == later.addingTimeInterval(2 * 86_400))
    }

    @Test func lastMatchedIsRecordedForRuleAndAvailableToConditions() throws {
        let dir = TempDir()
        let path = dir.file("item.txt")
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "first", conditions: [makeCondition(.dateLastMatched, .isBlank, "")])
        rule.isHazelImported = true
        rule.conditions[0].ruleId = rule.id
        rule.actions = [makeAction(.ignore, .object([:]), ruleId: rule.id)]
        try db.insertRule(rule)
        let store = DatabaseHazelMatchStateStore(db: db)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(RuleEngine.run(path: path, depth: 0, rules: [rule], batchId: "first", matchState: store, now: now).matched == ["first"])
        #expect(RuleEngine.run(path: path, depth: 0, rules: [rule], batchId: "second", matchState: store, now: now.addingTimeInterval(60)).matched.isEmpty)
        let stored = try store.state(ruleId: rule.id, itemKey: store.itemKey(path: path))
        let saved = try #require(stored)
        #expect(saved.lastMatched == now)
        #expect(!saved.matched)
    }

    @Test func conditionSignatureChangesWhenConditionOrderChanges() throws {
        let dir = TempDir()
        let path = dir.file("sample.txt")
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        let store = DatabaseHazelMatchStateStore(db: db)
        var rule = makeRule(folderId: folder.id, name: "ordered", conditions: [makeCondition(.extension_, .is, "txt"), makeCondition(.name, .contains, "sample")], actions: [makeAction(.displayNotification, .object([ActionParam.notificationText: .string("matched")]))])
        rule.isHazelImported = true
        for index in rule.conditions.indices { rule.conditions[index].ruleId = rule.id }
        rule.actions[0].ruleId = rule.id
        try db.insertRule(rule)
        let platform = Platform()
        #expect(RuleEngine.run(path: path, depth: 0, rules: [rule], batchId: "one", platform: platform, matchState: store).matched == ["ordered"])
        #expect(RuleEngine.run(path: path, depth: 0, rules: [rule], batchId: "two", platform: platform, matchState: store).matched.isEmpty)
        rule.conditions.reverse()
        #expect(RuleEngine.run(path: path, depth: 0, rules: [rule], batchId: "three", platform: platform, matchState: store).matched == ["ordered"])
        #expect(platform.count == 2)
    }

    @Test func noneModeKeepsUnavailableDatesUnknown() throws {
        let dir = TempDir()
        let path = dir.file("item.txt")
        var rule = makeRule(name: "none", conditions: [makeCondition(.dateLastMatched, .olderThan, "1 days")], actions: [makeAction(.delete, .object([:]))])
        rule.isHazelImported = true
        rule.conditionMatch = .none
        #expect(RuleEngine.previewFile(path: path, depth: 0, rules: [rule]) == nil)
        #expect(RuleEngine.run(path: path, depth: 0, rules: [rule], batchId: "none").matched.isEmpty)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func nativeTimeRulesRecheckWithoutRepeatingAndFileChangeCanRetrigger() throws {
        let dir = TempDir()
        let path = dir.file("item.txt")
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        var rule = makeRule(folderId: folder.id, name: "time", conditions: [makeCondition(.currentTime, .is, formatter.string(from: now))])
        rule.conditions[0].ruleId = rule.id
        rule.actions = [makeAction(.displayNotification, .object([ActionParam.notificationText: .string("time")]), ruleId: rule.id)]
        try db.insertRule(rule)
        let platform = Platform()
        let watcher = WatcherCoordinator(db: db, actionPlatform: platform)
        watcher.recheckTimeSensitiveRules(root: dir.path, now: now)
        watcher.recheckTimeSensitiveRules(root: dir.path, now: now)
        #expect(platform.count == 1)
        try "changed".write(toFile: path, atomically: false, encoding: .utf8)
        watcher.recheckTimeSensitiveRules(root: dir.path, now: now)
        #expect(platform.count == 2)
    }

    @Test func manualRunCanOverridePriorSuccessfulMatch() throws {
        let dir = TempDir()
        let path = dir.file("item.txt")
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "notify")
        rule.isHazelImported = true
        rule.actions = [makeAction(.displayNotification, .object([ActionParam.notificationText: .string("done")]), ruleId: rule.id)]
        try db.insertRule(rule)
        let platform = Platform()
        let store = DatabaseHazelMatchStateStore(db: db)
        _ = RuleEngine.run(path: path, depth: 0, rules: [rule], batchId: "one", platform: platform, matchState: store)
        _ = RuleEngine.run(path: path, depth: 0, rules: [rule], batchId: "two", platform: platform, matchState: store)
        #expect(platform.count == 1)
        _ = RuleEngine.run(path: path, depth: 0, rules: [rule], batchId: "manual", platform: platform, matchState: store, forceRunPreviouslyMatched: true)
        #expect(platform.count == 2)
    }
}
