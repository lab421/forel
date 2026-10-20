import Foundation
import Testing
@testable import ForelCore

@Suite struct MonthlyFileUsageTests {
    @Test(arguments: ["manual", "watcher", "rescan"])
    func fiveHundredthFileRunsButNextFileStaysUntouched(path: String) throws {
        let fixture = try Fixture()
        try fixture.seed(499)
        let file = fixture.dir.file("input-500.txt")
        let next = fixture.dir.file("input-501.txt")
        let watcher = fixture.watcher()
        switch path {
        case "manual":
            let result = try fixture.run(file)
            #expect(result.history.count == 1)
            #expect(result.history.first?.status == .applied)
        case "watcher": watcher.handle(path: file)
        default: watcher.handle(event: .rescanSubtree(fixture.dir.path))
        }
        #expect(!FileManager.default.fileExists(atPath: file))
        #expect(FileManager.default.fileExists(atPath: next))
        #expect(try fixture.usage().processed == 500)
        #expect(throws: FreePlanError.monthlyFileLimit) { _ = try fixture.run(next) }
        watcher.handle(path: next)
        watcher.handle(event: .rescanSubtree(fixture.dir.path))
        #expect(FileManager.default.fileExists(atPath: next))
        #expect(try fixture.usage().processed == 500)
        #expect(try fixture.db.quotaPendingFiles().contains(next))

        // Dry Run still shows matching rules at the limit and never consumes.
        for _ in 0..<3 {
            #expect(RuleEngine.previewFile(path: next, depth: 0, rules: [fixture.rule], isPro: false) != nil)
        }
        #expect(try fixture.usage().processed == 500)
        #expect(FileManager.default.fileExists(atPath: next))
    }

    @Test func onlyAppliedFilesCountAndActionChainsCountOnce() throws {
        let fixture = try Fixture()
        let ignored = fixture.dir.file("ignored.txt")
        _ = try fixture.run(ignored)
        #expect(try fixture.usage().processed == 0)
        let file = fixture.dir.file("input.txt")
        var noOp = fixture.rule
        noOp.actions = [makeAction(.rename, .object(["pattern": .string("input.txt")]), ruleId: noOp.id)]
        let skipped = try fixture.run(file, rule: noOp)
        #expect(skipped.history.allSatisfy { $0.status == .skipped })
        #expect(try fixture.usage().processed == 0)
        var failed = fixture.rule
        failed.actions = [makeAction(.moveToFolder, .object(["destination": .string("")]), ruleId: failed.id)]
        let failure = try fixture.run(file, rule: failed)
        #expect(failure.history.allSatisfy { $0.status == .failed })
        #expect(try fixture.usage().processed == 0)

        var chain = fixture.rule
        chain.actions = [
            makeAction(.rename, .object(["pattern": .string("step1.txt")]), position: 0, ruleId: chain.id),
            makeAction(.rename, .object(["pattern": .string("step2.txt")]), position: 1, ruleId: chain.id),
            makeAction(.moveToFolder, .object(["destination": .string("")]), position: 2, ruleId: chain.id),
        ]
        let result = try fixture.run(file, rule: chain)
        #expect(result.history.map(\.status) == [.applied, .applied, .failed])
        #expect(try fixture.usage().processed == 1)
    }

    @Test func counterSurvivesRestartAndHistoryCleanupAndRenewsAtLocalMonthBoundary() throws {
        let dir = TempDir()
        let preferences = Preferences()
        let dbPath = dir.path + "/forel.db"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Paris"))
        let october = ISO8601DateFormatter().date(from: "2026-10-31T22:59:59Z")!
        let november = october.addingTimeInterval(1)
        var rule = makeRule(name: "rename")
        rule.actions = [makeAction(.rename, .object(["pattern": .string("done.txt")]), ruleId: rule.id)]
        do {
            let db = try Database(path: dbPath, monthlyUsagePreferences: preferences.defaults)
            let result = try db.runWithFreePlan(path: dir.file("input.txt"), depth: 0, rules: [rule], batchId: "month",
                                                isPro: false, at: october, calendar: calendar)
            try db.insertHistoryEntries(result.history)
            try db.exec("DELETE FROM action_history")
        }
        let reopened = try Database(path: dbPath, monthlyUsagePreferences: UserDefaults(suiteName: preferences.name)!)
        #expect(try reopened.monthlyFileUsage(at: october, calendar: calendar).processed == 1)
        #expect(try reopened.monthlyFileUsage(at: november, calendar: calendar).processed == 0)
        #expect(try reopened.monthlyFileUsage(at: october, calendar: calendar).resetsAt == november)
        let restored = try Database(path: ":memory:", monthlyUsagePreferences: preferences.defaults)
        #expect(try restored.monthlyFileUsage(at: october, calendar: calendar).processed == 1)
        #expect(try restored.monthlyFileUsage(at: november, calendar: calendar).processed == 0)
    }

    @Test(arguments: ["manual", "watcher", "rescan"])
    func deletingDatabaseRestoresExhaustedAllowanceFromPreferences(path: String) throws {
        let dir = TempDir()
        let preferences = Preferences()
        let dbPath = dir.path + "/forel.db"
        let date = Date()
        let period = MonthlyFileUsage(at: date)
        let folder = WatchedFolder(path: dir.path)
        var rule = makeRule(folderId: folder.id, name: "rename inputs")
        rule.conditions = [makeCondition(.name, .startsWith, "input", ruleId: rule.id)]
        rule.actions = [makeAction(.rename, .object(["pattern": .string("processed-{name}")]), ruleId: rule.id)]
        do {
            let db = try Database(path: dbPath, monthlyUsagePreferences: preferences.defaults)
            let stmt = try db.statement("INSERT INTO monthly_file_usage (month, processed) VALUES (?1, 499)")
            stmt.bind(1, period.month)
            try stmt.runToCompletion()
            let result = try db.runWithFreePlan(path: dir.file("input-500.txt"), depth: 0, rules: [rule],
                                               batchId: "before-deletion", isPro: false, at: date)
            #expect(result.history.first?.status == .applied)
        }
        try FileManager.default.removeItem(atPath: dbPath)
        let restored = try Database(path: dbPath, monthlyUsagePreferences: UserDefaults(suiteName: preferences.name)!)
        try restored.insertFolder(folder)
        try restored.insertRule(rule)
        let next = dir.file("input-501.txt")
        // Exercise admission before the UI has read or restored the counter.
        let watcher = WatcherCoordinator(db: restored, now: { date })
        switch path {
        case "manual":
            #expect(throws: FreePlanError.monthlyFileLimit) {
                _ = try restored.runWithFreePlan(path: next, depth: 0, rules: [rule], batchId: "after-deletion",
                                                 isPro: false, at: date)
            }
        case "watcher": watcher.handle(path: next)
        default: watcher.handle(event: .rescanSubtree(dir.path))
        }
        #expect(FileManager.default.fileExists(atPath: next))
        #expect(try restored.monthlyFileUsage(at: date).processed == 500)
        #expect(RuleEngine.previewFile(path: next, depth: 0, rules: [rule], isPro: false) != nil)
        #expect(try restored.monthlyFileUsage(at: date).processed == 500)
    }

    @Test(arguments: [(300, 400), (400, 300), (400, 0)])
    func reconciliationKeepsHigherCountAndRepairsBothStores(counts: (Int, Int)) throws {
        let preferences = Preferences()
        let db = try Database(path: ":memory:", monthlyUsagePreferences: preferences.defaults)
        let date = Date()
        let period = MonthlyFileUsage(at: date)
        let key = "free.monthlyFileUsage.\(period.month)"
        let stmt = try db.statement("INSERT INTO monthly_file_usage (month, processed) VALUES (?1, ?2)")
        stmt.bind(1, period.month)
        stmt.bind(2, Int64(counts.0))
        try stmt.runToCompletion()
        if counts.1 > 0 { preferences.defaults.set(counts.1, forKey: key) }
        #expect(try db.monthlyFileUsage(at: date).processed == 400)
        #expect(preferences.defaults.integer(forKey: key) == 400)
        let stored = try db.statement("SELECT processed FROM monthly_file_usage WHERE month = ?1")
        stored.bind(1, period.month)
        #expect(try stored.step())
        #expect(stored.columnInt64(0) == 400)
    }

    @Test(arguments: [false, true])
    func queuedWatcherFilesResumeAfterRenewalOrProActivation(pro: Bool) throws {
        let fixture = try Fixture()
        try fixture.seed(500)
        let file = fixture.dir.file("input-pending.txt")
        do {
            let watcher = fixture.watcher()
            watcher.handle(path: file)
            #expect(FileManager.default.fileExists(atPath: file))
        }
        // A new coordinator models restarting the app with the pending row.
        let nextMonth = fixture.usageDate.resetsAt.addingTimeInterval(1)
        try FileManager.default.setAttributes([.creationDate: FileReadiness.busyCreationDate], ofItemAtPath: file)
        let watcher = WatcherCoordinator(db: fixture.db, settleInterval: 0.05, now: { pro ? fixture.date : nextMonth })
        watcher.setProAccess(pro)
        watcher.add(fixture.dir.path)
        watcher.processingQueue.sync {}
        Thread.sleep(forTimeInterval: 0.15)
        #expect(FileManager.default.fileExists(atPath: file))
        #expect(try fixture.db.withLock { try $0.quotaPendingFiles().contains(file) })
        try FileManager.default.setAttributes([.creationDate: Date()], ofItemAtPath: file)
        watcher.waitForPendingEvents()
        #expect(!FileManager.default.fileExists(atPath: file))
        #expect(try fixture.db.quotaPendingFiles().isEmpty)
        #expect(try fixture.usage().processed == 500)
        #expect(try fixture.db.monthlyFileUsage(at: nextMonth).processed == (pro ? 0 : 1))
        watcher.remove(fixture.dir.path)
        watcher.waitForPendingEvents()
    }

    @Test func proProcessingBypassesAnExhaustedFreeAllowance() throws {
        let fixture = try Fixture()
        try fixture.seed(500)
        let result = try fixture.db.runWithFreePlan(path: fixture.dir.file("input-pro.txt"), depth: 0,
                                                   rules: [fixture.rule], batchId: "pro", isPro: true, at: fixture.date)
        #expect(result.history.first?.status == .applied)
        #expect(try fixture.usage().processed == 500)
    }

    @Test func simultaneousManualAndAutomaticRunsCannotSpendTheLastSlotTwice() throws {
        let fixture = try Fixture()
        try fixture.seed(499)
        let first = fixture.dir.file("input-first.txt")
        let second = fixture.dir.file("input-second.txt")
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            _ = try? fixture.run(index == 0 ? first : second)
        }
        let remaining = [first, second].filter { FileManager.default.fileExists(atPath: $0) }
        #expect(remaining.count == 1)
        #expect(try fixture.usage().processed == 500)
    }

    @Test func upgradingAnExistingDatabaseKeepsRulesAndStartsWithAnUnusedAllowance() throws {
        let dir = TempDir()
        let path = dir.path + "/forel.db"
        let folder = WatchedFolder(path: dir.path)
        let rule = makeRule(folderId: folder.id, name: "Existing rule")
        do {
            let db = try Database(path: path)
            try db.insertFolder(folder)
            try db.insertRule(rule)
            // Reconstruct the previous schema, before the quota tables.
            try db.exec("DROP TABLE monthly_file_usage; DROP TABLE quota_pending_files;")
            try db.setUserVersion(8)
        }
        let upgraded = try Database(path: path)
        #expect(try upgraded.userVersion() == Database.currentSchemaVersion)
        #expect(try upgraded.listRules(folderId: folder.id).first?.id == rule.id)
        #expect(try upgraded.monthlyFileUsage().processed == 0)
        #expect(try upgraded.quotaPendingFiles().isEmpty)
    }

    private final class Fixture: @unchecked Sendable {
        let dir = TempDir()
        let preferences = Preferences()
        let db: Database
        let folder: WatchedFolder
        let rule: Rule
        let date = Date()
        var usageDate: MonthlyFileUsage { MonthlyFileUsage(at: date) }

        init() throws {
            db = try Database(path: ":memory:", monthlyUsagePreferences: preferences.defaults)
            folder = WatchedFolder(path: dir.path)
            try db.insertFolder(folder, isPro: false)
            var rule = makeRule(folderId: folder.id, name: "rename inputs")
            rule.conditions = [makeCondition(.name, .startsWith, "input", ruleId: rule.id)]
            rule.actions = [makeAction(.rename, .object(["pattern": .string("processed-{name}")]), ruleId: rule.id)]
            self.rule = rule
            try db.insertRule(rule, isPro: false)
        }

        func seed(_ count: Int) throws {
            let stmt = try db.statement("INSERT INTO monthly_file_usage (month, processed) VALUES (?1, ?2)")
            stmt.bind(1, usageDate.month)
            stmt.bind(2, Int64(count))
            try stmt.runToCompletion()
        }

        func usage() throws -> MonthlyFileUsage { try db.monthlyFileUsage(at: date) }
        func watcher() -> WatcherCoordinator { WatcherCoordinator(db: db, now: { self.date }) }
        func run(_ path: String, rule: Rule? = nil) throws -> (matched: [String], history: [HistoryEntry]) {
            try db.runWithFreePlan(path: path, depth: 0, rules: [rule ?? self.rule], batchId: "manual", isPro: false, at: date)
        }
    }

    private final class Preferences {
        let name = "com.lab421.forel.tests.monthlyUsage.\(UUID().uuidString)"
        let defaults: UserDefaults

        init() { defaults = UserDefaults(suiteName: name)! }
        deinit { defaults.removePersistentDomain(forName: name) }
    }
}
