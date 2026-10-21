// Forel - A native macOS file-automation app
// Copyright (C) 2026  Lab421
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import Foundation

public struct WatcherActivitySummary: Equatable, Sendable {
    public let actionCount: Int
    public let fileCount: Int
    public let ruleNames: [String]
}

/// Wires `FileWatcher` events to the database and rule engine: for every
/// created/renamed path, finds the owning watched folder, loads its rules,
/// evaluates them, and persists any resulting action history. Mirrors
/// `watcher::on_event` / `load_folder_and_rules_for_path`.
public final class WatcherCoordinator: @unchecked Sendable {
    private let db: Database
    private let monthlyUsage: MonthlyFileUsageStore
    private let watcher: FileWatcher
    private var isPro = false
    private let now: @Sendable () -> Date
    private var quotaRetryScheduled = false

    public func setProAccess(_ enabled: Bool) {
        db.withLock { _ in isPro = enabled }
        processingQueue.async { [weak self] in self?.retryQuotaPendingFiles() }
    }
    /// FSEvents callbacks must return promptly. File operations can take an
    /// arbitrary amount of time, especially when moving across volumes or to
    /// a network share, so process their immutable event snapshots here
    /// instead of blocking the native stream's delivery queue.
    let processingQueue = DispatchQueue(label: "app.forel.watcher-processing")
    private let activeProcessingLock = NSLock()
    private var activeProcessingRoots: [String: Int] = [:]
    /// How long a newly arrived file's size and modification time must stay
    /// unchanged before rules run on it. FSEvents reports a file as soon as
    /// it is created, which for an in-place transfer (AirDrop, a Finder copy,
    /// a network download) is long before its contents are complete.
    private let settleInterval: TimeInterval
    /// Paths waiting to settle. Only touched on `processingQueue`.
    private var settling: [String: SettlingState] = [:]
    /// Folders currently watched. Only touched on `processingQueue`.
    private var watchedRoots: Set<String> = []
    /// A file that stays marked busy without changing is a stalled transfer.
    /// Nothing signals the marker being lifted, so keep checking, but less
    /// and less often, up to this interval.
    private let maxStalledInterval: TimeInterval = 60
    public var onRuleMatched: (@Sendable (String, String) -> Void)?
    public var onActivity: (@Sendable (WatcherActivitySummary) -> Void)?
    public var onVolumeUnavailable: (@Sendable (VolumeUnavailableEvent) -> Void)?
    /// Called whenever an automatic run records history, failures included.
    public var onHistoryRecorded: (@Sendable () -> Void)?
    public var onMonthlyQuotaReached: (@Sendable () -> Void)?
    public var onProcessingError: (@Sendable (String) -> Void)?
    /// Files to run the rules on again, by the /Volumes name of the disk or
    /// share they wait for. Only touched on `processingQueue`; not persisted.
    var waitingForVolume: [String: Set<String>] = [:]

    private struct SettlingState {
        var fingerprint: String?
        var stalledChecks = 0
        /// Whether a folder is watched through everything it contains. Off
        /// for a rescan, which already visits the contents one by one down
        /// to the depth the rules need; reading each folder's whole tree on
        /// top of that would ignore that limit.
        var includesContents = true
        /// Items that arrived inside this folder while it was waiting.
        var hasDeferredDescendants = false
    }

    public init(db: Database, monthlyUsage: MonthlyFileUsageStore = MonthlyFileUsageStore(),
                settleInterval: TimeInterval = 1.0, now: @escaping @Sendable () -> Date = { Date() }) {
        self.db = db
        self.monthlyUsage = monthlyUsage
        self.settleInterval = settleInterval
        self.now = now
        var watcherRef: FileWatcher!
        watcherRef = FileWatcher(onEvent: { _ in })
        self.watcher = watcherRef
        self.watcher.replaceHandler { [weak self] event in
            self?.enqueue(event: event)
        }
    }

    public func add(_ path: String) {
        watcher.add(path)
        processingQueue.async { [weak self] in
            self?.watchedRoots.insert(path)
            self?.retryQuotaPendingFiles()
        }
    }

    public func remove(_ path: String) {
        watcher.remove(path)
        processingQueue.async { [weak self] in
            self?.stopSettling(under: path)
        }
    }

    /// Stopping a folder's watcher (pause, disable, removal) must also drop
    /// the files still waiting to settle under it; otherwise their rules
    /// would run once the transfer completes, long after watching stopped.
    /// Files that a still-watched nested folder covers keep waiting.
    private func stopSettling(under root: String) {
        watchedRoots.remove(root)
        let isStillWatched: (String) -> Bool = { [watchedRoots] path in
            !Self.isPath(path, under: root) || watchedRoots.contains { Self.isPath(path, under: $0) }
        }
        settling = settling.filter { path, _ in isStillWatched(path) }
        // Nor may they run once their disk or share comes back.
        keepWaiting(where: isStillWatched)
    }

    private static func isPath(_ path: String, under root: String) -> Bool {
        let rootComponents = (root as NSString).pathComponents
        let pathComponents = (path as NSString).pathComponents
        return pathComponents.count >= rootComponents.count
            && Array(pathComponents.prefix(rootComponents.count)) == rootComponents
    }

    func enqueue(event: FileWatcherEvent) {
        processingQueue.async { [weak self] in
            self?.handle(event: event, waitsForSettledFiles: true)
        }
    }

    /// Test synchronization point for events already accepted by `enqueue`,
    /// including files still waiting to settle.
    func waitForPendingEvents() {
        while processingQueue.sync(execute: { !settling.isEmpty }) {
            Thread.sleep(forTimeInterval: max(settleInterval / 4, 0.01))
        }
        processingQueue.sync {}
    }

    /// Processes `event`. Live watcher events wait for each file to settle
    /// first; passing `false` evaluates the files as they are right now.
    func handle(event: FileWatcherEvent, waitsForSettledFiles: Bool = false) {
        switch event {
        case .pathArrived(let path):
            if waitsForSettledFiles {
                awaitSettled(path)
            } else {
                handle(path: path)
            }
        case .rescanSubtree(let path):
            handleRescanSubtree(root: path, waitsForSettledFiles: waitsForSettledFiles)
        }
    }

    /// Runs rules on `path` once its fingerprint has stayed the same for a
    /// full `settleInterval` and nothing marks it as still being written.
    private func awaitSettled(_ path: String, includingContents: Bool = true) {
        guard settleInterval > 0 else {
            handle(path: path)
            return
        }
        // A check is already scheduled; it will see the file's latest state.
        guard settling[path] == nil else { return }
        // Something arriving inside a folder that is itself still waiting is
        // already covered by that folder's snapshot. Giving every nested item
        // its own wait would re-read the tree once per item (a `git clone` or
        // an unzip creates thousands), so it is evaluated when the folder
        // settles instead.
        if let ancestor = settlingAncestor(of: path) {
            settling[ancestor]?.hasDeferredDescendants = true
            return
        }
        guard FileManager.default.fileExists(atPath: path), hasPathChangedSinceLastEvaluation(path) else { return }
        settling[path] = SettlingState(
            fingerprint: FileReadiness.snapshot(path, includingContents: includingContents)?.fingerprint,
            includesContents: includingContents
        )
        scheduleSettleCheck(path)
    }

    private func settlingAncestor(of path: String) -> String? {
        var parent = (path as NSString).deletingLastPathComponent
        while parent.count > 1 {
            if settling[parent]?.includesContents == true { return parent }
            parent = (parent as NSString).deletingLastPathComponent
        }
        return nil
    }

    private func scheduleSettleCheck(_ path: String, after delay: TimeInterval? = nil) {
        processingQueue.asyncAfter(deadline: .now() + (delay ?? settleInterval)) { [weak self] in
            self?.checkSettled(path)
        }
    }

    private func checkSettled(_ path: String) {
        guard var state = settling[path] else { return }
        guard let snapshot = FileReadiness.snapshot(path, includingContents: state.includesContents) else {
            settling[path] = nil
            return
        }
        if snapshot.fingerprint != state.fingerprint {
            state.fingerprint = snapshot.fingerprint
            state.stalledChecks = 0
            settling[path] = state
            scheduleSettleCheck(path)
            return
        }
        if snapshot.isMarkedBusy {
            state.stalledChecks += 1
            settling[path] = state
            let backoff = settleInterval * pow(2, Double(min(state.stalledChecks, 16)))
            scheduleSettleCheck(path, after: min(backoff, maxStalledInterval))
            return
        }
        settling[path] = nil
        handle(path: path)
        if state.hasDeferredDescendants {
            handleRescanSubtree(root: path, waitsForSettledFiles: false)
        }
    }

    public func isProcessing(in root: String) -> Bool {
        activeProcessingLock.lock()
        defer { activeProcessingLock.unlock() }
        return activeProcessingRoots[root, default: 0] > 0
    }

    /// `retrying` runs the rules even though the file hasn't changed.
    func handle(path: String, retrying: Bool = false) {
        // A duplicate/coalesced FSEvent for a path a prior call already
        // moved away — common with FSEvents — would otherwise be replanned
        // (name/extension conditions don't require the file to exist) and
        // then fail at execution with a noisy "doesn't exist" entry.
        // Nothing meaningful can be evaluated against a path that's gone.
        guard FileManager.default.fileExists(atPath: path) else { return }
        guard retrying || hasPathChangedSinceLastEvaluation(path) else { return }

        guard let (folder, rules, isPro) = db.withLock({ db -> (WatchedFolder, [Rule], Bool)? in
            guard let folder = try? db.folderForPath(path) else { return nil }
            let rules = (try? db.executionRules(folderID: folder.id, isPro: self.isPro)) ?? []
            guard !rules.isEmpty else { return nil }
            return (folder, rules, self.isPro)
        }) else { return }

        beginProcessing(root: folder.path)
        defer { endProcessing(root: folder.path) }

        guard let depth = RuleEngine.pathDepth(root: folder.path, path: path) else { return }
        runAndRecord(path: path, depth: depth, rules: rules, watchedRoot: folder.path, isPro: isPro)
    }

    private func beginProcessing(root: String) {
        activeProcessingLock.lock()
        activeProcessingRoots[root, default: 0] += 1
        activeProcessingLock.unlock()
    }

    private func endProcessing(root: String) {
        activeProcessingLock.lock()
        let count = activeProcessingRoots[root, default: 0]
        if count <= 1 {
            activeProcessingRoots[root] = nil
        } else {
            activeProcessingRoots[root] = count - 1
        }
        activeProcessingLock.unlock()
    }

    /// Whether `path` looks different from the last time the watcher fully
    /// evaluated it (same identity and fingerprint means nothing meaningful
    /// changed). Without this, an action that doesn't move the file out of
    /// scope — `copyToFolder` in particular, which has no
    /// `alreadyInDestination`-style no-op the way `moveToFolder` does —
    /// would repeat itself on every duplicate/coalesced FSEvent for the same
    /// untouched source, piling up copies indefinitely.
    ///
    /// This checks the *observed* path itself, not anything an action
    /// produced, so a path nothing has evaluated before — e.g. a file a
    /// previous rule just moved here — always proceeds; only a path whose
    /// own state was already fully evaluated gets skipped.
    private func hasPathChangedSinceLastEvaluation(_ path: String) -> Bool {
        guard let cached = db.withLock({ db in try? db.getWatchedPathState(path) }) else { return true }
        guard let currentFingerprint = FileFingerprint.current(path), cached.fingerprint == currentFingerprint else {
            return true
        }
        // Fingerprint matches — file hasn't changed. No need to check identity
        // (inode/volume) unless it happens to already be cached; rows written
        // before migration V7 have nil volumeId/fileId and would otherwise
        // trigger a spurious re-evaluation.
        guard let volumeId = cached.volumeId, let fileId = cached.fileId else { return false }
        guard let identity = FileFingerprint.identity(path) else { return true }
        return !(identity.volumeId == volumeId && identity.fileId == fileId)
    }

    private func recordEvaluatedState(_ path: String) {
        // Nothing meaningful to cache once the file's gone (e.g. it was
        // just moved away) — and caching a path's only-just-vacated state
        // would just be inert until something new shows up there anyway.
        guard FileManager.default.fileExists(atPath: path) else { return }
        let identity = FileFingerprint.identity(path)
        let state = WatchedPathState(path: path, volumeId: identity?.volumeId, fileId: identity?.fileId, fingerprint: FileFingerprint.current(path))
        db.withLock { db in try? db.upsertWatchedPathState(state) }
    }

    private func recordEvaluatedResultStates(_ history: [HistoryEntry]) {
        let paths = Set(
            history
                .filter { $0.status == .applied }
                .map(\.resultPath)
        )
        for path in paths {
            recordEvaluatedState(path)
        }
    }

    private func handleRescanSubtree(root: String, waitsForSettledFiles: Bool) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir) else { return }
        guard isDir.boolValue else {
            handle(event: .pathArrived(root), waitsForSettledFiles: waitsForSettledFiles)
            return
        }

        guard let (folder, rules, isPro) = db.withLock({ db -> (WatchedFolder, [Rule], Bool)? in
            guard let folder = try? db.folderForPath(root) else { return nil }
            let rules = (try? db.executionRules(folderID: folder.id, isPro: self.isPro)) ?? []
            guard !rules.isEmpty else { return nil }
            return (folder, rules, self.isPro)
        }) else { return }
        guard let rootDepth = RuleEngine.pathDepth(root: folder.path, path: root) else { return }

        beginProcessing(root: folder.path)
        defer { endProcessing(root: folder.path) }

        // A rescan can find files that are still being written just like a
        // live arrival can, so each one goes through the same wait.
        let process: (String, Int) -> Void = { [self] path, depth in
            if waitsForSettledFiles {
                awaitSettled(path, includingContents: false)
            } else {
                handle(path: path, depth: depth, rules: rules, watchedRoot: folder.path, isPro: isPro)
            }
        }

        let maxDepth = RuleEngine.maxRuleDepth(rules)
        if root != folder.path, !SystemFileFilter.isExcluded((root as NSString).lastPathComponent) {
            process(root, rootDepth)
        }

        let remainingDepth: Int?
        if let maxDepth {
            let rootChildDepth = root == folder.path ? 0 : rootDepth + 1
            guard rootChildDepth <= maxDepth else { return }
            remainingDepth = maxDepth - rootChildDepth
        } else {
            remainingDepth = nil
        }

        RuleEngine.forEachEntry(root: root, maxDepth: remainingDepth) { entry in
            guard let depth = RuleEngine.pathDepth(root: folder.path, path: entry.path) else { return }
            process(entry.path, depth)
        }
    }

    private func handle(path: String, depth: Int, rules: [Rule], watchedRoot: String, isPro: Bool) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        guard hasPathChangedSinceLastEvaluation(path) else { return }

        runAndRecord(path: path, depth: depth, rules: rules, watchedRoot: watchedRoot, isPro: isPro)
    }

    private func runAndRecord(path: String, depth: Int, rules: [Rule], watchedRoot: String, isPro: Bool) {
        do {
            let result = try monthlyUsage.runWithFreePlan(path: path, depth: depth, rules: rules,
                                               batchId: UUID().uuidString, root: watchedRoot, isPro: isPro, at: now())
            monthlyUsage.removeQuotaPendingFile(path)
            record(matched: result.matched, history: result.history, path: path, rules: rules)
        } catch FreePlanError.monthlyFileLimit {
            monthlyUsage.queueQuotaPendingFile(path)
            onMonthlyQuotaReached?()
            scheduleQuotaRetry()
        } catch {
            onProcessingError?(error.localizedDescription)
        }
    }

    /// Kept in preferences so a restart does not lose files waiting for quota.
    /// Only still-watched paths are resumed, including after a Pro activation.
    func retryQuotaPendingFiles() {
        guard !watchedRoots.isEmpty else { return }
        let pro = db.withLock { _ in isPro }
        guard pro || !monthlyUsage.monthlyFileUsage(at: now()).isExhausted else {
            scheduleQuotaRetry()
            return
        }
        let paths = monthlyUsage.quotaPendingFiles()
        for path in paths where watchedRoots.contains(where: { Self.isPath(path, under: $0) }) {
            guard FileManager.default.fileExists(atPath: path) else {
                monthlyUsage.removeQuotaPendingFile(path)
                continue
            }
            // A prior failure (e.g. a disconnected disk) may have cached the
            // unchanged file before its retry hit the quota. It still needs
            // another evaluation, through the normal settling checks.
            do {
                try db.withLock { try $0.deleteWatchedPathState(path) }
            } catch {
                onProcessingError?(error.localizedDescription)
                continue
            }
            handle(event: .pathArrived(path), waitsForSettledFiles: true)
        }
    }

    private func scheduleQuotaRetry() {
        guard !quotaRetryScheduled else { return }
        quotaRetryScheduled = true
        let period = MonthlyFileUsage(at: now())
        // Recheck hourly too, so waking the Mac or changing its time zone
        // cannot leave an obsolete reset deadline scheduled for a whole month.
        let delay = max(1, min(3600, period.resetsAt.timeIntervalSince(now())))
        processingQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.quotaRetryScheduled = false
            self.retryQuotaPendingFiles()
        }
    }

    /// Persists what a run on `path` did and tells whoever listens.
    private func record(matched: [String], history: [HistoryEntry], path: String, rules: [Rule]) {
        for ruleName in matched {
            onRuleMatched?(ruleName, path)
        }
        if !history.isEmpty {
            db.withLock { db in
                try? db.insertHistoryEntries(history)
            }
            recordEvaluatedResultStates(history)
            notifyActivity(from: history)
            onHistoryRecorded?()
            waitForDisconnectedVolumes(history, path: path, rules: rules)
        }
        recordEvaluatedState(path)
    }

    private func notifyActivity(from history: [HistoryEntry]) {
        guard let summary = Self.activitySummary(from: history) else { return }
        onActivity?(summary)
    }

    static func activitySummary(from history: [HistoryEntry]) -> WatcherActivitySummary? {
        let applied = history.filter { $0.status == .applied }
        guard !applied.isEmpty else { return nil }
        return WatcherActivitySummary(
            actionCount: applied.count,
            fileCount: Set(applied.map(\.originalPath)).count,
            ruleNames: Array(Set(applied.map(\.ruleName))).sorted()
        )
    }
}
