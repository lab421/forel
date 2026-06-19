import Foundation

/// Lightweight, user-facing snapshot of what the watcher has been doing
/// (plan Lot C): when it last caught up via a scan, how many files it has run
/// through the rules, and the most recent watcher-level problem if any.
public struct WatcherStatus: Sendable, Equatable {
    public var lastScanAt: Date?
    public var processedCount: Int
    public var lastError: String?

    public init(lastScanAt: Date? = nil, processedCount: Int = 0, lastError: String? = nil) {
        self.lastScanAt = lastScanAt
        self.processedCount = processedCount
        self.lastError = lastError
    }
}

/// Orchestrates the stateful watcher (plan Lot B). FSEvents and folder scans both
/// feed paths into a single serial worker, which:
///   1. waits for each file to settle (stop changing) — plan D3;
///   2. consults persistent `file_state` to decide new-or-changed — plan D1;
///   3. blocks runaway reprocessing loops — plan D7;
///   4. runs the rules and stores the *post-action* fingerprint so a file's own
///      rule-induced change doesn't look "changed" next time — plan D2.
///
/// All mutable state and rule execution happen on `workQueue` (serial), so there
/// is no concurrent access; the lock only guards the in-memory dictionaries for
/// `@unchecked Sendable` correctness. Filesystem stats are never taken while the
/// database lock is held — plan D4.
public final class WatcherCoordinator: @unchecked Sendable {
    private let db: Database
    private let watcher: FileWatcher
    private let statProvider: FileStatProvider
    private let clock: Clock
    private let scheduler: WatcherScheduler
    private let policy: WatcherPolicy
    private let workQueue: DispatchQueue

    public var onRuleMatched: (@Sendable (String, String) -> Void)?
    /// Fired (off the main thread) whenever the watcher status changes.
    public var onStatusChanged: (@Sendable (WatcherStatus) -> Void)?
    private var status = WatcherStatus()

    /// Per-path settle progress and per-path recent automatic-run timestamps.
    private struct Tracking {
        var previous: FileStat?
        var attempt: Int
        var firstObserved: Date
    }
    private let lock = NSLock()
    private var tracking: [String: Tracking] = [:]
    private var recentRuns: [String: [Date]] = [:]

    public init(
        db: Database,
        statProvider: FileStatProvider = SystemFileStatProvider(),
        clock: Clock = SystemClock(),
        policy: WatcherPolicy = .default,
        scheduler: WatcherScheduler? = nil
    ) {
        self.db = db
        self.statProvider = statProvider
        self.clock = clock
        self.policy = policy
        let queue = DispatchQueue(label: "app.forel.watcher.worker")
        self.workQueue = queue
        self.scheduler = scheduler ?? DispatchWatcherScheduler(queue: queue)

        var watcherRef: FileWatcher!
        watcherRef = FileWatcher(onEvent: { _ in })
        self.watcher = watcherRef
        self.watcher.replaceHandler { [weak self] path in self?.enqueue(path) }
    }

    // MARK: - Folder membership

    public func add(_ path: String) { watcher.add(path) }

    public func remove(_ path: String) {
        watcher.remove(path)
        lock.lock()
        tracking = tracking.filter { !Self.isWithin(path, $0.key) }
        recentRuns = recentRuns.filter { !Self.isWithin(path, $0.key) }
        lock.unlock()
    }

    // MARK: - Scans (plan: startup / resume / per-folder catch-up)

    /// Scans every enabled folder for files never seen or changed since last run.
    /// Used both at startup and when the watcher is resumed from pause.
    public func startupScan() { scanAllEnabled() }
    public func resumeScan() { scanAllEnabled() }

    public func scanFolder(_ folderPath: String) {
        workQueue.async { [weak self] in self?.performScanFolder(folderPath) }
    }

    private func scanAllEnabled() {
        workQueue.async { [weak self] in
            guard let self else { return }
            let folders = self.db.withLock { (try? $0.listFolders()) ?? [] }
            for folder in folders where folder.enabled {
                self.performScanFolder(folder.path)
            }
        }
    }

    /// Internal so tests can drive a scan synchronously (bypassing `workQueue`).
    func performScanFolder(_ folderPath: String) {
        let rules = db.withLock { db -> [Rule] in
            guard let folder = try? db.folderForPath(folderPath) else { return [] }
            return (try? db.listRules(folderId: folder.id)) ?? []
        }
        let maxDepth = RuleEngine.maxRuleDepth(rules)
        for entry in RuleEngine.walkEntries(root: folderPath, maxDepth: maxDepth) {
            observe(entry.path)
        }
        updateStatus { $0.lastScanAt = clock.now() }
    }

    // MARK: - Run Now (forced)

    /// Forces every file in `folderPath` through the rules, bypassing the
    /// new-or-changed and loop gates (it's a manual test tool — plan D6), while
    /// still updating `file_state` so the automatic watcher doesn't redundantly
    /// reprocess what Run Now just handled. Dry Run is unaffected: it never
    /// touches `file_state`. `completion` receives the number of actions recorded
    /// and is called on the worker queue.
    public func runNow(folderPath: String, completion: @escaping @Sendable (Int) -> Void) {
        workQueue.async { [weak self] in
            guard let self else { completion(0); return }
            completion(self.performRunNow(folderPath))
        }
    }

    private func performRunNow(_ folderPath: String) -> Int {
        let info = db.withLock { db -> (WatchedFolder, [Rule])? in
            // Exact-path lookup (not `folderForPath`) so Run Now works on the
            // selected folder even if it is disabled, matching prior behaviour.
            guard let folder = (try? db.listFolders())?.first(where: { $0.path == folderPath }) else { return nil }
            return (folder, (try? db.listRules(folderId: folder.id)) ?? [])
        }
        guard let (folder, rules) = info else { return 0 }

        let maxDepth = RuleEngine.maxRuleDepth(rules)
        let now = clock.now()
        var total = 0
        for entry in RuleEngine.walkEntries(root: folderPath, maxDepth: maxDepth) {
            guard let stat = statProvider.stat(entry.path) else { continue }
            let existing = loadState(entry.path, stat: stat)
            total += executeAndPersist(path: entry.path, stat: stat, folder: folder, rules: rules, now: now, existing: existing)
        }
        return total
    }

    // MARK: - Event intake

    private func enqueue(_ path: String) {
        workQueue.async { [weak self] in self?.observe(path) }
    }

    /// One observation pass for `path`: settle, then decide & process if stable.
    /// Internal so tests can drive it synchronously with injected fakes.
    func observe(_ path: String) {
        if WatcherDecision.shouldIgnore(path: path) { clearTracking(path); return }

        guard let (folder, rules) = loadFolderAndRules(path) else { clearTracking(path); return }

        let now = clock.now()
        let current = statProvider.stat(path)
        let track = trackingState(path, now: now)
        let elapsed = now.timeIntervalSince(track.firstObserved)
        let outcome = WatcherDecision.settle(
            previous: track.previous, current: current,
            attempt: track.attempt, elapsed: elapsed, policy: policy
        )

        switch outcome {
        case .vanished:
            clearTracking(path)
            db.withLock { try? $0.deleteFileState(path: path) }
        case .giveUp:
            clearTracking(path)
            let message = "File kept changing; stopped waiting for it to settle."
            db.withLock { try? $0.recordFileProcessingError(path: path, error: message, at: Self.iso(now)) }
            updateStatus { $0.lastError = "\((path as NSString).lastPathComponent): \(message)" }
        case .keepWaiting(let delay):
            setTracking(path, Tracking(previous: current, attempt: track.attempt + 1, firstObserved: track.firstObserved))
            scheduler.schedule(after: delay) { [weak self] in self?.observe(path) }
        case .stable:
            clearTracking(path)
            if let current {
                process(path: path, stat: current, folder: folder, rules: rules, now: now)
            }
        }
    }

    // MARK: - Processing

    /// Automatic path: applies the new-or-changed and loop gates before running.
    private func process(path: String, stat: FileStat, folder: WatchedFolder, rules: [Rule], now: Date) {
        let existing = loadState(path, stat: stat)

        let decision = WatcherDecision.processDecision(
            fileState: existing, stat: stat, recentRuns: recentRunsList(path), now: now, policy: policy
        )

        switch decision {
        case .skipUnchanged:
            upsertSeen(path: path, folderId: folder.id, stat: stat, existing: existing, now: now)
            return
        case .loopBlocked:
            let message = "Stopped: this file changed too many times in a short period."
            db.withLock { try? $0.recordFileProcessingError(path: path, error: message, at: Self.iso(now)) }
            updateStatus { $0.lastError = "\((path as NSString).lastPathComponent): \(message)" }
            return
        case .process:
            break
        }

        recordRun(path, now: now)
        executeAndPersist(path: path, stat: stat, folder: folder, rules: rules, now: now, existing: existing)
    }

    /// Runs the rules against `path` and stores the post-action state. Shared by
    /// the automatic watcher (after its gate) and the forced Run Now path; returns
    /// the number of history entries produced.
    @discardableResult
    private func executeAndPersist(path: String, stat: FileStat, folder: WatchedFolder, rules: [Rule], now: Date, existing: FileState?) -> Int {
        upsertSeen(path: path, folderId: folder.id, stat: stat, existing: existing, now: now)

        guard let depth = RuleEngine.pathDepth(root: folder.path, path: path) else { return 0 }
        let batchId = UUID().uuidString
        let result = RuleEngine.evaluateFile(path: path, depth: depth, rules: rules, batchId: batchId, root: folder.path)
        for ruleName in result.matched { onRuleMatched?(ruleName, path) }
        if !result.history.isEmpty {
            db.withLock { try? $0.insertHistoryEntries(result.history) }
        }

        persistOutcome(originalPath: path, folderId: folder.id, result: result, existing: existing, now: now)
        updateStatus { $0.processedCount += 1; $0.lastError = nil }
        return result.history.count
    }

    private func loadState(_ path: String, stat: FileStat) -> FileState? {
        db.withLock { db -> FileState? in
            if let byIdentity = try? db.fileStateForIdentity(volumeId: stat.volumeId, fileId: stat.fileId) {
                return byIdentity
            }
            guard let byPath = try? db.fileStateForPath(path) else { return nil }
            if Self.identitiesMatch(byPath, stat: stat) || byPath.volumeId == nil || byPath.fileId == nil || stat.volumeId == nil || stat.fileId == nil {
                return byPath
            }
            return nil
        }
    }

    private static func identitiesMatch(_ state: FileState, stat: FileStat) -> Bool {
        state.volumeId == stat.volumeId && state.fileId == stat.fileId
    }

    /// Stores the post-action state of the file (plan D2): terminal actions remove
    /// the row; renames move it to the new path; in-place changes just refresh the
    /// fingerprint so the rule-induced FSEvent is recognised as already handled.
    private func persistOutcome(originalPath: String, folderId: String, result: EvaluationResult, existing: FileState?, now: Date) {
        let matched = !result.matched.isEmpty

        if result.removed {
            db.withLock { try? $0.deleteFileState(path: originalPath) }
            return
        }

        guard let postStat = statProvider.stat(result.finalPath) else {
            db.withLock { try? $0.deleteFileState(path: originalPath) }
            return
        }

        let fingerprint = postStat.contentFingerprint
        if result.finalPath == originalPath {
            db.withLock {
                try? $0.recordFileProcessingResult(
                    path: originalPath,
                    contentFingerprint: fingerprint,
                    sizeBytes: postStat.sizeBytes,
                    modifiedAt: postStat.modifiedAtKey,
                    matched: matched,
                    at: Self.iso(now)
                )
            }
            return
        }

        // Rename within the folder: migrate the state row to the new path,
        // preserving the original first-seen timestamp where possible.
        db.withLock { db in
            let prior = (try? db.fileStateForPath(originalPath)) ?? existing
            try? db.deleteFileState(path: originalPath)
            var moved = prior ?? FileState(folderId: folderId, path: result.finalPath, firstSeenAt: Self.iso(now))
            moved.folderId = folderId
            moved.path = result.finalPath
            moved.volumeId = postStat.volumeId
            moved.fileId = postStat.fileId
            moved.contentFingerprint = fingerprint
            moved.sizeBytes = postStat.sizeBytes
            moved.modifiedAt = postStat.modifiedAtKey
            moved.lastSeenAt = Self.iso(now)
            moved.lastProcessedAt = Self.iso(now)
            if matched { moved.lastMatchedAt = Self.iso(now) }
            moved.lastError = nil
            moved.updatedAt = Self.iso(now)
            try? db.upsertFileState(moved)
        }
    }

    /// Ensures a `file_state` row exists for `path`, refreshing identity and
    /// last-seen while preserving its existing fingerprint and first-seen marker.
    private func upsertSeen(path: String, folderId: String, stat: FileStat, existing: FileState?, now: Date) {
        var state = existing ?? FileState(folderId: folderId, path: path, firstSeenAt: Self.iso(now), lastSeenAt: Self.iso(now))
        state.folderId = folderId
        state.path = path
        state.volumeId = stat.volumeId
        state.fileId = stat.fileId
        state.lastSeenAt = Self.iso(now)
        state.updatedAt = Self.iso(now)
        db.withLock { try? $0.upsertFileState(state) }
    }

    // MARK: - Helpers

    private func loadFolderAndRules(_ path: String) -> (WatchedFolder, [Rule])? {
        db.withLock { db -> (WatchedFolder, [Rule])? in
            guard let folder = try? db.folderForPath(path) else { return nil }
            let rules = (try? db.listRules(folderId: folder.id)) ?? []
            return (folder, rules)
        }
    }

    private func trackingState(_ path: String, now: Date) -> Tracking {
        lock.lock(); defer { lock.unlock() }
        if let existing = tracking[path] { return existing }
        return Tracking(previous: nil, attempt: 0, firstObserved: now)
    }

    private func setTracking(_ path: String, _ value: Tracking) {
        lock.lock(); tracking[path] = value; lock.unlock()
    }

    private func clearTracking(_ path: String) {
        lock.lock(); tracking[path] = nil; lock.unlock()
    }

    private func recentRunsList(_ path: String) -> [Date] {
        lock.lock(); defer { lock.unlock() }
        return recentRuns[path] ?? []
    }

    private func recordRun(_ path: String, now: Date) {
        lock.lock(); defer { lock.unlock() }
        var runs = recentRuns[path] ?? []
        runs.append(now)
        runs = runs.filter { now.timeIntervalSince($0) < policy.loopWindow }
        recentRuns[path] = runs
    }

    private func updateStatus(_ mutate: (inout WatcherStatus) -> Void) {
        lock.lock()
        mutate(&status)
        let snapshot = status
        let handler = onStatusChanged
        lock.unlock()
        handler?(snapshot)
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// Component-wise containment: is `path` inside (or equal to) `root`?
    private static func isWithin(_ root: String, _ path: String) -> Bool {
        let rootComponents = (root as NSString).pathComponents
        let pathComponents = (path as NSString).pathComponents
        guard pathComponents.count >= rootComponents.count else { return false }
        return Array(pathComponents.prefix(rootComponents.count)) == rootComponents
    }
}
