import Foundation
import Testing
@testable import ForelCore

@Suite struct MonthlyFileUsageTests {
    @Test(arguments: ["manual", "watcher", "rescan"])
    func threeHundredthFileRunsButNextFileStaysUntouched(path: String) throws {
        let fixture = try Fixture()
        try fixture.seed(299)
        let file = fixture.dir.file("input-300.txt")
        let next = fixture.dir.file("input-301.txt")
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
        #expect(try fixture.usage().processed == 300)
        #expect(throws: FreePlanError.monthlyFileLimit) { _ = try fixture.run(next) }
        watcher.handle(path: next)
        watcher.handle(event: .rescanSubtree(fixture.dir.path))
        #expect(FileManager.default.fileExists(atPath: next))
        #expect(try fixture.usage().processed == 300)
        #expect(fixture.usageStore.quotaPendingFiles().contains(next))

        // Dry Run still shows matching rules at the limit and never consumes.
        for _ in 0..<3 {
            #expect(RuleEngine.previewFile(path: next, depth: 0, rules: [fixture.rule], isPro: false) != nil)
        }
        #expect(try fixture.usage().processed == 300)
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
            let db = try Database(path: dbPath)
            let usageStore = MonthlyFileUsageStore(preferences: preferences.defaults)
            let result = try usageStore.runWithFreePlan(path: dir.file("input.txt"), depth: 0, rules: [rule], batchId: "month",
                                                isPro: false, at: october, calendar: calendar)
            try db.insertHistoryEntries(result.history)
            try db.exec("DELETE FROM action_history")
        }
        let reopened = MonthlyFileUsageStore(preferences: UserDefaults(suiteName: preferences.name)!)
        #expect(reopened.monthlyFileUsage(at: october, calendar: calendar).processed == 1)
        #expect(reopened.monthlyFileUsage(at: november, calendar: calendar).processed == 0)
        #expect(reopened.monthlyFileUsage(at: october, calendar: calendar).resetsAt == november)
    }

    @Test(arguments: ["manual", "watcher", "rescan"])
    func deletingDatabaseRestoresExhaustedAllowanceFromPreferences(path: String) throws {
        let dir = TempDir()
        let preferences = Preferences()
        let dbPath = dir.path + "/forel.db"
        let date = Date()
        let period = MonthlyFileUsage(at: date)
        let next = dir.file("input-301.txt")
        let folder = WatchedFolder(path: dir.path)
        var rule = makeRule(folderId: folder.id, name: "rename inputs")
        rule.conditions = [makeCondition(.name, .startsWith, "input", ruleId: rule.id)]
        rule.actions = [makeAction(.rename, .object(["pattern": .string("processed-{name}")]), ruleId: rule.id)]
        do {
            let db = try Database(path: dbPath)
            try db.insertFolder(folder)
            try db.insertRule(rule)
            preferences.defaults.set(299, forKey: "free.monthlyFileUsage.\(period.month)")
            let usageStore = MonthlyFileUsageStore(preferences: preferences.defaults)
            let result = try usageStore.runWithFreePlan(path: dir.file("input-300.txt"), depth: 0, rules: [rule],
                                               batchId: "before-deletion", isPro: false, at: date)
            #expect(result.history.first?.status == .applied)
            let watcher = WatcherCoordinator(db: db, monthlyUsage: usageStore, now: { date })
            watcher.handle(path: next)
            #expect(usageStore.quotaPendingFiles() == [next])
        }
        try FileManager.default.removeItem(atPath: dbPath)
        let restored = try Database(path: dbPath)
        let usageStore = MonthlyFileUsageStore(preferences: UserDefaults(suiteName: preferences.name)!)
        try restored.insertFolder(folder)
        try restored.insertRule(rule)
        #expect(usageStore.quotaPendingFiles() == [next])
        // Exercise admission before the UI has read the saved counter.
        let watcher = WatcherCoordinator(db: restored, monthlyUsage: usageStore, now: { date })
        switch path {
        case "manual":
            #expect(throws: FreePlanError.monthlyFileLimit) {
                _ = try usageStore.runWithFreePlan(path: next, depth: 0, rules: [rule], batchId: "after-deletion",
                                                 isPro: false, at: date)
            }
        case "watcher": watcher.handle(path: next)
        default: watcher.handle(event: .rescanSubtree(dir.path))
        }
        #expect(FileManager.default.fileExists(atPath: next))
        #expect(usageStore.monthlyFileUsage(at: date).processed == 300)
        #expect(RuleEngine.previewFile(path: next, depth: 0, rules: [rule], isPro: false) != nil)
        #expect(usageStore.monthlyFileUsage(at: date).processed == 300)
    }

    @Test func pendingFilesRemainUniqueAndTheirRemovalSurvivesRestart() {
        let preferences = Preferences()
        let store = MonthlyFileUsageStore(preferences: preferences.defaults)
        store.queueQuotaPendingFile("/tmp/b.txt")
        store.queueQuotaPendingFile("/tmp/a.txt")
        store.queueQuotaPendingFile("/tmp/a.txt")
        #expect(store.quotaPendingFiles() == ["/tmp/a.txt", "/tmp/b.txt"])
        store.removeQuotaPendingFile("/tmp/a.txt")
        let restarted = MonthlyFileUsageStore(preferences: UserDefaults(suiteName: preferences.name)!)
        #expect(restarted.quotaPendingFiles() == ["/tmp/b.txt"])
        restarted.removeQuotaPendingFile("/tmp/b.txt")
        #expect(store.quotaPendingFiles().isEmpty)
    }

    @Test(arguments: [false, true])
    func queuedWatcherFilesResumeAfterRenewalOrProActivation(pro: Bool) throws {
        let fixture = try Fixture()
        try fixture.seed(300)
        let file = fixture.dir.file("input-pending.txt")
        do {
            let watcher = fixture.watcher()
            watcher.handle(path: file)
            #expect(FileManager.default.fileExists(atPath: file))
        }
        // A new store and coordinator model restarting with saved pending files.
        let nextMonth = fixture.usageDate.resetsAt.addingTimeInterval(1)
        try FileManager.default.setAttributes([.creationDate: FileReadiness.busyCreationDate], ofItemAtPath: file)
        let usageStore = MonthlyFileUsageStore(preferences: UserDefaults(suiteName: fixture.preferences.name)!)
        let watcher = WatcherCoordinator(db: fixture.db, monthlyUsage: usageStore, settleInterval: 0.05,
                                         now: { pro ? fixture.date : nextMonth })
        watcher.setProAccess(pro)
        watcher.add(fixture.dir.path)
        watcher.processingQueue.sync {}
        Thread.sleep(forTimeInterval: 0.15)
        #expect(FileManager.default.fileExists(atPath: file))
        #expect(usageStore.quotaPendingFiles().contains(file))
        try FileManager.default.setAttributes([.creationDate: Date()], ofItemAtPath: file)
        watcher.waitForPendingEvents()
        #expect(!FileManager.default.fileExists(atPath: file))
        #expect(usageStore.quotaPendingFiles().isEmpty)
        #expect(try fixture.usage().processed == 300)
        #expect(usageStore.monthlyFileUsage(at: nextMonth).processed == (pro ? 0 : 1))
        watcher.remove(fixture.dir.path)
        watcher.waitForPendingEvents()
    }

    @Test(arguments: [false, true], [ActionKind.moveToFolder, .copyToFolder])
    func unchangedFilesWaitingForADiskResumeAfterQuotaIsLifted(pro: Bool, kind: ActionKind) throws {
        let fixture = try Fixture()
        let file = fixture.dir.file("input-invoice.txt", contents: "invoice")
        let destination = fixture.dir.dir("ConnectedDisk")
        let resultPath = destination + "/input-invoice.txt"
        let volume = "ForelMissingShare-\(UUID().uuidString)"
        var rule = fixture.rule
        rule.actions = [makeAction(kind, .object(["destination": .string("/Volumes/\(volume)/Inbox")]), ruleId: rule.id)]
        try fixture.db.updateRule(rule)
        do {
            let watcher = fixture.watcher()
            watcher.handle(path: file)
            #expect(try fixture.db.listHistory().map(\.status) == [.failed])
            #expect(try fixture.db.getWatchedPathState(file)?.fingerprint == FileFingerprint.current(file))
            #expect(try fixture.usage().processed == 0)

            // Other files exhaust the allowance before the disk reconnects.
            try fixture.seed(300)
            // Model a reconnected disk with a reachable temporary folder,
            // as in WatcherDisconnectedVolumeTests, without using /Volumes.
            rule.actions[0].params = .object(["destination": .string(destination)])
            try fixture.db.updateRule(rule)
            watcher.volumeDidMount(atPath: "/Volumes/\(volume)")
            watcher.waitForPendingEvents()
            #expect(fixture.usageStore.quotaPendingFiles() == [file])
            #expect(try fixture.db.getWatchedPathState(file)?.fingerprint == FileFingerprint.current(file))
        }

        #expect(RuleEngine.previewFile(path: file, depth: 0, rules: [rule], isPro: false) != nil)
        #expect(try fixture.usage().processed == 300)
        // Even an unchanged queued file may now be in use by a writer.
        try FileManager.default.setAttributes([.creationDate: FileReadiness.busyCreationDate], ofItemAtPath: file)
        #expect(try fixture.db.getWatchedPathState(file)?.fingerprint == FileFingerprint.current(file))
        let resumedAt = pro ? fixture.date : fixture.usageDate.resetsAt.addingTimeInterval(1)
        // A fresh store and coordinator verify that fingerprints in SQLite
        // and pending files in preferences still allow the retry after restart.
        let usageStore = MonthlyFileUsageStore(preferences: UserDefaults(suiteName: fixture.preferences.name)!)
        let watcher = WatcherCoordinator(db: fixture.db, monthlyUsage: usageStore, settleInterval: 0.05, now: { resumedAt })
        watcher.setProAccess(pro)
        watcher.add(fixture.dir.path)
        watcher.processingQueue.sync {}
        Thread.sleep(forTimeInterval: 0.15)
        #expect(FileManager.default.fileExists(atPath: file))
        #expect(!FileManager.default.fileExists(atPath: resultPath))
        #expect(usageStore.quotaPendingFiles() == [file])
        try FileManager.default.setAttributes([.creationDate: Date()], ofItemAtPath: file)
        watcher.waitForPendingEvents()
        #expect(FileManager.default.fileExists(atPath: resultPath))
        #expect(FileManager.default.fileExists(atPath: file) == (kind == .copyToFolder))
        #expect(usageStore.quotaPendingFiles().isEmpty)
        #expect(try fixture.db.listHistory().filter { $0.status == .applied }.count == 1)
        #expect(usageStore.monthlyFileUsage(at: resumedAt).processed == (pro ? 300 : 1))

        // Normal duplicate events must still be deduplicated after the retry,
        // including a Copy that leaves the source file in place.
        watcher.processingQueue.sync { watcher.handle(path: file) }
        #expect(try fixture.db.listHistory().count == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination) == ["input-invoice.txt"])
        watcher.remove(fixture.dir.path)
        watcher.waitForPendingEvents()
    }

    @Test func proProcessingBypassesAnExhaustedFreeAllowance() throws {
        let fixture = try Fixture()
        try fixture.seed(300)
        let result = try fixture.usageStore.runWithFreePlan(path: fixture.dir.file("input-pro.txt"), depth: 0,
                                                   rules: [fixture.rule], batchId: "pro", isPro: true, at: fixture.date)
        #expect(result.history.first?.status == .applied)
        #expect(try fixture.usage().processed == 300)
    }

    @Test func simultaneousManualAndAutomaticRunsCannotSpendTheLastSlotTwice() throws {
        let fixture = try Fixture()
        try fixture.seed(299)
        let first = fixture.dir.file("input-first.txt")
        let second = fixture.dir.file("input-second.txt")
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            _ = try? fixture.run(index == 0 ? first : second)
        }
        let remaining = [first, second].filter { FileManager.default.fileExists(atPath: $0) }
        #expect(remaining.count == 1)
        #expect(try fixture.usage().processed == 300)
    }

    @Test func usageSavedAboveTheNewLimitStaysBlockedUntilNextMonth() throws {
        let fixture = try Fixture()
        try fixture.seed(500)
        let usage = MonthlyFileUsageStore(preferences: fixture.preferences.defaults)
        let file = fixture.dir.file("input-existing-usage.txt")
        #expect(usage.monthlyFileUsage(at: fixture.date).isExhausted)
        #expect(throws: FreePlanError.monthlyFileLimit) {
            _ = try usage.runWithFreePlan(path: file, depth: 0, rules: [fixture.rule],
                                         batchId: "current-month", isPro: false, at: fixture.date)
        }
        #expect(FileManager.default.fileExists(atPath: file))
        #expect(usage.monthlyFileUsage(at: fixture.date).processed == 500)
        let nextMonth = fixture.usageDate.resetsAt.addingTimeInterval(1)
        let result = try usage.runWithFreePlan(path: file, depth: 0, rules: [fixture.rule],
                                              batchId: "next-month", isPro: false, at: nextMonth)
        #expect(result.history.first?.status == .applied)
        #expect(usage.monthlyFileUsage(at: nextMonth).processed == 1)
    }

    @Test func quotaProcessingKeepsTheDatabaseAtVersionEightForRollback() throws {
        let dir = TempDir()
        let preferences = Preferences()
        let path = dir.path + "/forel.db"
        let folder = WatchedFolder(path: dir.path)
        var rule = makeRule(folderId: folder.id, name: "Existing rule")
        rule.actions = [makeAction(.rename, .object(["pattern": .string("processed.txt")]), ruleId: rule.id)]
        do {
            let db = try Database(path: path)
            try db.insertFolder(folder)
            try db.insertRule(rule)
            #expect(try db.userVersion() == Database.currentSchemaVersion)
            let usageStore = MonthlyFileUsageStore(preferences: preferences.defaults)
            let result = try usageStore.runWithFreePlan(path: dir.file("input.txt"), depth: 0, rules: [rule],
                                                       batchId: "quota", isPro: false)
            try db.insertHistoryEntries(result.history)
            #expect(usageStore.monthlyFileUsage().processed == 1)
        }
        let reopened = try Database(path: path)
        #expect(Database.currentSchemaVersion == 15)
        #expect(try reopened.userVersion() == Database.currentSchemaVersion)
        #expect(try reopened.listRules(folderId: folder.id).first?.id == rule.id)
        #expect(try reopened.listHistory().first?.status == .applied)
        let quotaTables = try reopened.statement("SELECT name FROM sqlite_master WHERE name IN ('monthly_file_usage', 'quota_pending_files')")
        #expect(try !quotaTables.step())
    }

    private final class Fixture: @unchecked Sendable {
        let dir = TempDir()
        let preferences = Preferences()
        let db: Database
        let usageStore: MonthlyFileUsageStore
        let folder: WatchedFolder
        let rule: Rule
        let date = Date()
        var usageDate: MonthlyFileUsage { MonthlyFileUsage(at: date) }

        init() throws {
            db = try Database(path: ":memory:")
            usageStore = MonthlyFileUsageStore(preferences: preferences.defaults)
            folder = WatchedFolder(path: dir.path)
            try db.insertFolder(folder, isPro: false)
            var rule = makeRule(folderId: folder.id, name: "rename inputs")
            rule.conditions = [makeCondition(.name, .startsWith, "input", ruleId: rule.id)]
            rule.actions = [makeAction(.rename, .object(["pattern": .string("processed-{name}")]), ruleId: rule.id)]
            self.rule = rule
            try db.insertRule(rule, isPro: false)
        }

        func seed(_ count: Int) throws {
            preferences.defaults.set(count, forKey: "free.monthlyFileUsage.\(usageDate.month)")
        }

        func usage() throws -> MonthlyFileUsage { usageStore.monthlyFileUsage(at: date) }
        func watcher() -> WatcherCoordinator { WatcherCoordinator(db: db, monthlyUsage: usageStore, now: { self.date }) }
        func run(_ path: String, rule: Rule? = nil) throws -> (matched: [String], history: [HistoryEntry]) {
            try usageStore.runWithFreePlan(path: path, depth: 0, rules: [rule ?? self.rule], batchId: "manual", isPro: false, at: date)
        }
    }

    private final class Preferences {
        let name = "com.lab421.forel.tests.monthlyUsage.\(UUID().uuidString)"
        let defaults: UserDefaults

        init() { defaults = UserDefaults(suiteName: name)! }
        deinit { defaults.removePersistentDomain(forName: name) }
    }
}
