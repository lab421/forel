import Foundation
import Testing
@testable import ForelCore

@Suite struct DateComparisonTests {
    private final class Platform: ActionPlatform, @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        func notify(text: String, sound: Bool) throws { lock.lock(); value += 1; lock.unlock() }
        func open(path: String, application: String?, passFile: Bool, bringToFront: Bool) throws {}
        func showInFinder(path: String, bringToFront: Bool) throws {}
        func pause(seconds: TimeInterval) throws {}
        func trash(path: String) throws -> String { throw ActionError("Not used") }
    }

    @Test func localPeriodsAndRecurrenceAcrossDSTAndYear() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let parser = ISO8601DateFormatter()
        func date(_ value: String) throws -> Date { try #require(parser.date(from: value)) }
        let now = try date("2024-03-10T10:30:00Z") // 03:30 after spring transition
        var spec = DateComparisonCondition()
        spec.relation = .yesterday
        #expect(spec.compare(try date("2024-03-09T20:00:00Z"), right: nil, now: now, calendar: calendar) == true)
        spec.relation = .withinPrevious
        spec.amount = 1
        spec.unit = .days
        #expect(spec.compare(try date("2024-03-09T11:30:00Z"), right: nil, now: now, calendar: calendar) == true)
        #expect(spec.compare(try date("2024-03-09T11:00:00Z"), right: nil, now: now, calendar: calendar) == true)
        #expect(spec.compare(try date("2024-03-09T10:29:59Z"), right: nil, now: now, calendar: calendar) == false)
        spec.relation = .thisQuarter
        #expect(spec.compare(try date("2024-01-01T08:00:00Z"), right: nil, now: now, calendar: calendar) == true)
        #expect(spec.compare(try date("2024-04-01T07:00:00Z"), right: nil, now: now, calendar: calendar) == false)
        spec.relation = .thisYear
        #expect(spec.compare(try date("2024-01-01T07:59:59Z"), right: nil, now: now, calendar: calendar) == false)
        spec.relation = .occursAfter
        spec.schedule = CurrentTimeCondition.Schedule(time: "22:00", weekdays: "2").encoded
        #expect(spec.compare(try date("2024-01-16T07:59:00Z"), right: nil, now: now, calendar: calendar) == true)
        #expect(spec.compare(try date("2024-01-16T08:01:00Z"), right: nil, now: now, calendar: calendar) == false)
    }

    @Test func customDateComparisonPreservesUnknown() throws {
        let dir = TempDir()
        let path = dir.file("item")
        var spec = DateComparisonCondition()
        spec.left = .custom
        spec.leftAttribute = "captured"
        spec.right = .fixed
        spec.fixedDate = "2024-01-02T00:00:00Z"
        let condition = makeCondition(.dateComparison, .is, spec.encoded)
        var attributes: [String: JSONValue] = [:]
        #expect(try ConditionEvaluator.evaluateWithContext(condition, path: path, depth: 0, lastOpened: SpotlightLastOpenedMetadata(), attributes: &attributes) == nil)
        attributes["captured"] = .object(["__forelDate": .number(1_704_067_200)])
        #expect(try ConditionEvaluator.evaluateWithContext(condition, path: path, depth: 0, lastOpened: SpotlightLastOpenedMetadata(), attributes: &attributes) == true)
    }

    @Test func comparisonWorksThroughPreviewManualAndWatcher() throws {
        let dir = TempDir()
        let manual = dir.file("manual")
        let watched = dir.file("watched")
        let past = Date(timeIntervalSinceNow: -3600)
        for path in [manual, watched] { try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: path) }
        var spec = DateComparisonCondition()
        spec.left = .modified
        spec.relation = .before
        spec.right = .current
        let condition = makeCondition(.dateComparison, .is, spec.encoded)
        let action = makeAction(.displayNotification, .object([ActionParam.notificationText: .string("match")]))
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "date", conditions: [condition], actions: [action])
        rule.conditions[0].ruleId = rule.id
        rule.actions[0].ruleId = rule.id
        let platform = Platform()
        #expect(RuleEngine.previewFile(path: manual, depth: 0, rules: [rule]) != nil)
        #expect(platform.count == 0)
        #expect(RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "manual", platform: platform).matched == ["date"])
        try db.insertRule(rule)
        WatcherCoordinator(db: db, actionPlatform: platform).handle(path: watched)
        #expect(platform.count == 2)
    }
}
