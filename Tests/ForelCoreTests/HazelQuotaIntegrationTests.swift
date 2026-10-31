import Foundation
import Testing
@testable import ForelCore

@Suite struct HazelQuotaIntegrationTests {
    @Test(arguments: [300, 299]) func timedScansStopAtQuotaAndResumeNextMonth(initialUsage: Int) throws {
        let dir = TempDir()
        let first = dir.file("a-match.txt")
        let second = dir.file("b-match.txt")
        for index in 0..<5 { _ = dir.file("z-unmatched-\(index).txt") }
        let suite = "com.lab421.forel.tests.hazeltimerquota.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let date = Date()
        let usagePeriod = MonthlyFileUsage(at: date)
        defaults.set(initialUsage, forKey: "free.monthlyFileUsage.\(usagePeriod.month)")
        let usage = MonthlyFileUsageStore(preferences: defaults)
        let pendingArrival = "\(dir.path)/genuine-arrival"
        usage.queueQuotaPendingFile(pendingArrival)
        for path in [first, second] {
            try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(-172_800)], ofItemAtPath: path)
        }
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "aged matches", conditions: [makeCondition(.name, .contains, "match"), makeCondition(.dateModified, .olderThan, "1 days")], actions: [makeAction(.rename, .object(["pattern": .string("done-{name}")]))])
        // The nonmatching files intentionally contain "unmatched", so use a
        // prefix to make the two eligible files unambiguous.
        rule.conditions[0] = makeCondition(.name, .startsWith, "a-")
        if initialUsage == 299 { rule.conditions[0] = makeCondition(.extension_, .is, "txt") }
        for index in rule.conditions.indices { rule.conditions[index].ruleId = rule.id }
        rule.actions[0].ruleId = rule.id
        try db.insertRule(rule)
        let watcher = WatcherCoordinator(db: db, monthlyUsage: usage, settleInterval: 0, now: { date })
        watcher.recheckTimeSensitiveRules(root: dir.path, now: date)
        #expect(usage.quotaPendingFiles() == [pendingArrival])
        #expect(try db.listHistory().count == (initialUsage == 299 ? 1 : 0))
        #expect(FileManager.default.fileExists(atPath: first) == (initialUsage == 300))
        #expect(FileManager.default.fileExists(atPath: second))
        if initialUsage == 300 {
            let nextMonth = usagePeriod.resetsAt.addingTimeInterval(60)
            watcher.recheckTimeSensitiveRules(root: dir.path, now: nextMonth)
            #expect(!FileManager.default.fileExists(atPath: first))
            #expect(usage.monthlyFileUsage(at: nextMonth).processed == 1)
            #expect(usage.quotaPendingFiles() == [pendingArrival])
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true]) func oneRemainingSlotAcrossRecursiveFiles(watcherMode: Bool) throws {
        let dir = TempDir()
        let childFolder = dir.dir("folder")
        let first = dir.file("folder/one.txt")
        let second = dir.file("folder/two.txt")
        let suite = "com.lab421.forel.tests.hazelquota.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let date = Date()
        defaults.set(299, forKey: "free.monthlyFileUsage.\(MonthlyFileUsage(at: date).month)")
        let usage = MonthlyFileUsageStore(preferences: defaults)
        let db = try Database(path: ":memory:")
        let watched = WatchedFolder(path: dir.path)
        try db.insertFolder(watched)
        var recurse = makeRule(folderId: watched.id, name: "recurse", conditions: [makeCondition(.name, .is, "folder")], actions: [makeAction(.hazelRecurse, .object([:]))])
        recurse.isHazelImported = true
        var rename = makeRule(folderId: watched.id, name: "rename", conditions: [makeCondition(.extension_, .is, "txt")], actions: [makeAction(.rename, .object(["pattern": .string("done-{name}")]))])
        rename.isHazelImported = true
        for index in recurse.conditions.indices { recurse.conditions[index].ruleId = recurse.id }
        for index in recurse.actions.indices { recurse.actions[index].ruleId = recurse.id }
        for index in rename.conditions.indices { rename.conditions[index].ruleId = rename.id }
        for index in rename.actions.indices { rename.actions[index].ruleId = rename.id }
        try db.insertRule(recurse)
        try db.insertRule(rename)
        let rules = try db.executionRules(folderID: watched.id, isPro: false)
        _ = RuleEngine.previewFile(path: first, depth: 1, rules: rules, root: dir.path, isPro: false)
        #expect(usage.monthlyFileUsage(at: date).processed == 299)
        if watcherMode {
            let watcher = WatcherCoordinator(db: db, monthlyUsage: usage, now: { date })
            watcher.handle(path: childFolder)
            #expect(usage.quotaPendingFiles().count == 1)
        } else {
            RuleEngine.forEachRuleEntryExecuting(root: dir.path, rules: rules, isPro: false) { entry, active, descend in
                do {
                    return try usage.withFreePlan(isPro: false, at: date) { beforeAction in
                        let result = RuleEngine.runWithTraversal(path: entry.path, depth: entry.depth, rules: active, batchId: "manual", root: dir.path, isPro: false, beforeAction: beforeAction, onRecurse: descend)
                        return (result.recurses, result.history)
                    }
                } catch { return false }
            }
        }
        #expect(usage.monthlyFileUsage(at: date).processed == 300)
        #expect([first, second].filter { FileManager.default.fileExists(atPath: $0) }.count == 1)
        #expect(["done-one.txt", "done-two.txt"].filter { FileManager.default.fileExists(atPath: (childFolder as NSString).appendingPathComponent($0)) }.count == 1)
    }
}
