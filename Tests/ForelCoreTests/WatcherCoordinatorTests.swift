import Testing
import Foundation
@testable import ForelCore

@Suite struct WatcherCoordinatorTests {
    /// Manual clock so the loop window / settle ceiling can be reasoned about
    /// without real time passing.
    final class ManualClock: Clock, @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date
        init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) { current = start }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }
        func advance(_ t: TimeInterval) { lock.lock(); current = current.addingTimeInterval(t); lock.unlock() }
    }

    /// Runs scheduled settle re-checks synchronously, advancing the clock by the
    /// requested delay so the whole settle loop resolves within one `observe` call.
    final class ImmediateAdvancingScheduler: WatcherScheduler, @unchecked Sendable {
        let clock: ManualClock
        init(_ clock: ManualClock) { self.clock = clock }
        func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) {
            clock.advance(delay)
            work()
        }
    }

    final class MatchLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(rule: String, path: String)] = []
        func record(_ rule: String, _ path: String) { lock.lock(); entries.append((rule, path)); lock.unlock() }
        func reset() { lock.lock(); entries = []; lock.unlock() }
        var rules: [String] { lock.lock(); defer { lock.unlock() }; return entries.map(\.rule) }
        var paths: [String] { lock.lock(); defer { lock.unlock() }; return entries.map(\.path) }
    }

    final class StatusBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: WatcherStatus?
        func set(_ status: WatcherStatus) { lock.lock(); value = status; lock.unlock() }
        var current: WatcherStatus? { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func makeSetup() throws -> (Database, WatchedFolder, TempDir, WatcherCoordinator, MatchLog, ManualClock) {
        let db = try Database(path: ":memory:")
        let dir = TempDir()
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        let clock = ManualClock()
        let coordinator = WatcherCoordinator(
            db: db,
            statProvider: SystemFileStatProvider(),
            clock: clock,
            policy: .default,
            scheduler: ImmediateAdvancingScheduler(clock)
        )
        let log = MatchLog()
        coordinator.onRuleMatched = { rule, path in log.record(rule, path) }
        return (db, folder, dir, coordinator, log, clock)
    }

    /// A rule that matches every file and runs no actions (so it never modifies
    /// the file). Lets tests exercise the watcher's decision flow in isolation.
    private func insertMatchAllRule(_ db: Database, _ folder: WatchedFolder, name: String = "match all") throws {
        try db.insertRule(makeRule(folderId: folder.id, name: name))
    }

    /// Inserts a match-all rule with the given actions, fixing up each action's
    /// `ruleId` so the `actions.rule_id` foreign key is satisfied on insert.
    @discardableResult
    private func insertRule(_ db: Database, _ folder: WatchedFolder, name: String, actions: [Action]) throws -> Rule {
        var rule = makeRule(folderId: folder.id, name: name)
        rule.actions = actions.map { var action = $0; action.ruleId = rule.id; return action }
        try db.insertRule(rule)
        return rule
    }

    // MARK: - New / unchanged / changed (plan D1)

    @Test func newFileIsProcessedAndStateRecorded() throws {
        let (db, folder, dir, coordinator, log, _) = try makeSetup()
        try insertMatchAllRule(db, folder)
        let file = dir.file("a.txt", contents: "hello")

        coordinator.observe(file)

        #expect(log.rules == ["match all"])
        let state = try #require(try db.fileStateForPath(file))
        #expect(state.lastProcessedAt != nil)
        #expect(state.lastMatchedAt != nil)
        #expect(state.contentFingerprint != nil)
    }

    @Test func unchangedFileIsSkippedOnSecondObservation() throws {
        let (db, folder, dir, coordinator, log, _) = try makeSetup()
        try insertMatchAllRule(db, folder)
        let file = dir.file("a.txt", contents: "hello")

        coordinator.observe(file)
        log.reset()
        coordinator.observe(file)

        #expect(log.rules.isEmpty)
    }

    @Test func fileRecreatedAtSamePathIsProcessedAsNewIdentity() throws {
        let (db, folder, dir, coordinator, log, _) = try makeSetup()
        try insertMatchAllRule(db, folder)
        let file = dir.file("a.txt", contents: "hello")
        let stat = try #require(SystemFileStatProvider().stat(file))

        var stale = FileState(folderId: folder.id, volumeId: stat.volumeId, fileId: (stat.fileId ?? 0) + 1, path: file)
        stale.contentFingerprint = stat.contentFingerprint
        stale.sizeBytes = stat.sizeBytes
        stale.modifiedAt = stat.modifiedAtKey
        stale.lastProcessedAt = "2026-06-19T00:00:00Z"
        try db.upsertFileState(stale)

        coordinator.observe(file)

        #expect(log.rules == ["match all"])
        let current = try #require(try db.fileStateForPath(file))
        #expect(current.fileId == stat.fileId)
        #expect(current.contentFingerprint == stat.contentFingerprint)
    }

    @Test func changedFileIsReprocessed() throws {
        let (db, folder, dir, coordinator, log, _) = try makeSetup()
        try insertMatchAllRule(db, folder)
        let file = dir.file("a.txt", contents: "hello")

        coordinator.observe(file)
        log.reset()
        try "hello, world!".write(toFile: file, atomically: true, encoding: .utf8)
        coordinator.observe(file)

        #expect(log.rules == ["match all"])
    }

    // MARK: - Settle (plan D3)

    @Test func ignoredPathsAreNeverProcessed() throws {
        let (db, folder, dir, coordinator, log, _) = try makeSetup()
        try insertMatchAllRule(db, folder)
        let invisible = dir.file(".hidden", contents: "x")
        let partial = dir.file("download.crdownload", contents: "x")

        coordinator.observe(invisible)
        coordinator.observe(partial)

        #expect(log.rules.isEmpty)
        #expect(try db.fileStateForPath(invisible) == nil)
        #expect(try db.fileStateForPath(partial) == nil)
    }

    // MARK: - Post-action fingerprint prevents self-loops (plan D2)

    @Test func terminalMoveRemovesFileState() throws {
        let (db, folder, dir, coordinator, _, _) = try makeSetup()
        let archived = dir.dir("Archived")
        try insertRule(db, folder, name: "archive",
            actions: [makeAction(.moveToFolder, .object(["destination": .string(archived)]))])
        let file = dir.file("doc.txt", contents: "x")

        coordinator.observe(file)

        #expect(try db.fileStateForPath(file) == nil)
        #expect(!FileManager.default.fileExists(atPath: file))
        #expect(FileManager.default.fileExists(atPath: (archived as NSString).appendingPathComponent("doc.txt")))
    }

    @Test func renameMovesStateToNewPathAndDoesNotReprocess() throws {
        let (db, folder, dir, coordinator, log, _) = try makeSetup()
        try insertRule(db, folder, name: "rename",
            actions: [makeAction(.rename, .object(["pattern": .string("renamed.txt")]))])
        let file = dir.file("orig.txt", contents: "x")

        coordinator.observe(file)

        let renamed = (dir.path as NSString).appendingPathComponent("renamed.txt")
        #expect(try db.fileStateForPath(file) == nil)
        let movedState = try #require(try db.fileStateForPath(renamed))
        #expect(movedState.lastProcessedAt != nil)
        #expect(movedState.contentFingerprint != nil)

        // The rename produced an FSEvent-equivalent for the new path; observing
        // it must NOT run the rules again (post-action fingerprint matches).
        log.reset()
        coordinator.observe(renamed)
        #expect(log.rules.isEmpty)
        #expect(FileManager.default.fileExists(atPath: renamed))
    }

    // MARK: - Loop detection (plan D7)

    @Test func runawayReprocessingIsBlockedAndRecordsError() throws {
        let (db, folder, dir, coordinator, log, _) = try makeSetup()
        try insertMatchAllRule(db, folder)
        let file = dir.file("loop.txt", contents: "0")

        // Five genuine changes are processed; each advances the clock ~1s, well
        // inside the 60s loop window.
        for i in 1...5 {
            try String(repeating: "x", count: i).write(toFile: file, atomically: true, encoding: .utf8)
            coordinator.observe(file)
        }
        #expect(log.rules.count == 5)

        log.reset()
        try String(repeating: "x", count: 6).write(toFile: file, atomically: true, encoding: .utf8)
        coordinator.observe(file)

        #expect(log.rules.isEmpty)
        let state = try #require(try db.fileStateForPath(file))
        #expect(state.lastError != nil)
    }

    // MARK: - Run Now forced path (plan D6)

    private func runNowAndWait(_ coordinator: WatcherCoordinator, _ folderPath: String) {
        let semaphore = DispatchSemaphore(value: 0)
        coordinator.runNow(folderPath: folderPath) { _ in semaphore.signal() }
        semaphore.wait()
    }

    @Test func runNowForcesEvaluationAndUpdatesStateSoWatcherThenSkips() throws {
        let (db, folder, dir, coordinator, log, _) = try makeSetup()
        try insertMatchAllRule(db, folder)
        let file = dir.file("a.txt", contents: "hello")

        runNowAndWait(coordinator, dir.path)

        #expect(log.rules == ["match all"])
        let state = try #require(try db.fileStateForPath(file))
        #expect(state.lastProcessedAt != nil)

        // Run Now recorded file_state, so the automatic watcher now treats the
        // unchanged file as already handled.
        log.reset()
        coordinator.observe(file)
        #expect(log.rules.isEmpty)
    }

    @Test func runNowReprocessesEvenWhenFingerprintUnchanged() throws {
        let (db, folder, dir, coordinator, log, _) = try makeSetup()
        try insertMatchAllRule(db, folder)
        let file = dir.file("a.txt", contents: "hello")

        coordinator.observe(file)   // watcher processes once and stores state
        log.reset()

        runNowAndWait(coordinator, dir.path)   // forced: runs again despite no change

        #expect(log.rules == ["match all"])
    }

    // MARK: - Status reporting (plan Lot C)

    @Test func statusTracksProcessingScanAndErrors() throws {
        let (db, folder, dir, coordinator, _, _) = try makeSetup()
        try insertMatchAllRule(db, folder)
        let statusBox = StatusBox()
        coordinator.onStatusChanged = { statusBox.set($0) }

        let file = dir.file("loop.txt", contents: "0")
        for i in 1...5 {
            try String(repeating: "x", count: i).write(toFile: file, atomically: true, encoding: .utf8)
            coordinator.observe(file)
        }
        #expect(statusBox.current?.processedCount == 5)
        #expect(statusBox.current?.lastError == nil)

        try String(repeating: "x", count: 6).write(toFile: file, atomically: true, encoding: .utf8)
        coordinator.observe(file)
        #expect(statusBox.current?.lastError != nil)

        coordinator.performScanFolder(dir.path)
        #expect(statusBox.current?.lastScanAt != nil)
    }

    // MARK: - Scans (plan: startup / resume / per-folder catch-up)

    @Test func scanProcessesUnseenFilesThenSkipsUnchanged() throws {
        let (db, folder, dir, coordinator, log, _) = try makeSetup()
        try insertMatchAllRule(db, folder)
        let one = dir.file("one.txt", contents: "a")
        let two = dir.file("two.txt", contents: "b")

        coordinator.performScanFolder(dir.path)

        #expect(Set(log.paths) == Set([one, two]))
        #expect(try db.listFileStates(folderId: folder.id).count == 2)

        log.reset()
        coordinator.performScanFolder(dir.path)
        #expect(log.rules.isEmpty)
    }
}
