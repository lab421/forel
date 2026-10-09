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
    private let watcher: FileWatcher
    /// FSEvents callbacks must return promptly. File operations can take an
    /// arbitrary amount of time, especially when moving across volumes or to
    /// a network share, so process their immutable event snapshots here
    /// instead of blocking the native stream's delivery queue.
    private let processingQueue = DispatchQueue(label: "app.forel.watcher-processing")
    private let activeProcessingLock = NSLock()
    private var activeProcessingRoots: [String: Int] = [:]
    /// How long a newly arrived file's size and modification time must stay
    /// unchanged before rules run on it. FSEvents reports a file as soon as
    /// it is created, which for an in-place transfer (AirDrop, a Finder copy,
    /// a network download) is long before its contents are complete.
    private let settleInterval: TimeInterval
    /// Paths waiting to settle. Only touched on `processingQueue`.
    private var settling: [String: SettlingState] = [:]
    /// A file that stays marked busy without changing is a stalled or
    /// abandoned transfer; stop polling it after this many checks. A later
    /// event for the same path starts the wait again.
    private let maxStalledChecks = 600
    public var onRuleMatched: (@Sendable (String, String) -> Void)?
    public var onActivity: (@Sendable (WatcherActivitySummary) -> Void)?

    private struct SettlingState {
        var fingerprint: String?
        var stalledChecks = 0
    }

    public init(db: Database, settleInterval: TimeInterval = 1.0) {
        self.db = db
        self.settleInterval = settleInterval
        var watcherRef: FileWatcher!
        watcherRef = FileWatcher(onEvent: { _ in })
        self.watcher = watcherRef
        self.watcher.replaceHandler { [weak self] event in
            self?.enqueue(event: event)
        }
    }

    public func add(_ path: String) { watcher.add(path) }
    public func remove(_ path: String) { watcher.remove(path) }

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
    private func awaitSettled(_ path: String) {
        guard settleInterval > 0 else {
            handle(path: path)
            return
        }
        // A check is already scheduled; it will see the file's latest state.
        guard settling[path] == nil else { return }
        guard FileManager.default.fileExists(atPath: path), hasPathChangedSinceLastEvaluation(path) else { return }
        settling[path] = SettlingState(fingerprint: FileFingerprint.current(path))
        scheduleSettleCheck(path)
    }

    private func scheduleSettleCheck(_ path: String) {
        processingQueue.asyncAfter(deadline: .now() + settleInterval) { [weak self] in
            self?.checkSettled(path)
        }
    }

    private func checkSettled(_ path: String) {
        guard var state = settling[path] else { return }
        guard let fingerprint = FileFingerprint.current(path) else {
            settling[path] = nil
            return
        }
        if fingerprint != state.fingerprint {
            settling[path] = SettlingState(fingerprint: fingerprint)
            scheduleSettleCheck(path)
            return
        }
        if FileReadiness.isMarkedBusy(path) {
            guard state.stalledChecks < maxStalledChecks else {
                settling[path] = nil
                return
            }
            state.stalledChecks += 1
            settling[path] = state
            scheduleSettleCheck(path)
            return
        }
        settling[path] = nil
        handle(path: path)
    }

    public func isProcessing(in root: String) -> Bool {
        activeProcessingLock.lock()
        defer { activeProcessingLock.unlock() }
        return activeProcessingRoots[root, default: 0] > 0
    }

    func handle(path: String) {
        // A duplicate/coalesced FSEvent for a path a prior call already
        // moved away — common with FSEvents — would otherwise be replanned
        // (name/extension conditions don't require the file to exist) and
        // then fail at execution with a noisy "doesn't exist" entry.
        // Nothing meaningful can be evaluated against a path that's gone.
        guard FileManager.default.fileExists(atPath: path) else { return }
        guard hasPathChangedSinceLastEvaluation(path) else { return }

        guard let (folder, rules) = db.withLock({ db -> (WatchedFolder, [Rule])? in
            guard let folder = try? db.folderForPath(path) else { return nil }
            let rules = (try? db.listRules(folderId: folder.id)) ?? []
            return (folder, rules)
        }) else { return }

        beginProcessing(root: folder.path)
        defer { endProcessing(root: folder.path) }

        guard let depth = RuleEngine.pathDepth(root: folder.path, path: path) else { return }
        let batchId = UUID().uuidString
        let (matched, history) = RuleEngine.run(path: path, depth: depth, rules: rules, batchId: batchId, root: folder.path)
        for ruleName in matched {
            onRuleMatched?(ruleName, path)
        }
        if !history.isEmpty {
            db.withLock { db in
                try? db.insertHistoryEntries(history)
            }
            recordEvaluatedResultStates(history)
            notifyActivity(from: history)
        }
        recordEvaluatedState(path)
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

        guard let (folder, rules) = db.withLock({ db -> (WatchedFolder, [Rule])? in
            guard let folder = try? db.folderForPath(root) else { return nil }
            let rules = (try? db.listRules(folderId: folder.id)) ?? []
            return (folder, rules)
        }) else { return }
        guard let rootDepth = RuleEngine.pathDepth(root: folder.path, path: root) else { return }

        beginProcessing(root: folder.path)
        defer { endProcessing(root: folder.path) }

        // A rescan can find files that are still being written just like a
        // live arrival can, so each one goes through the same wait.
        let process: (String, Int) -> Void = { [self] path, depth in
            if waitsForSettledFiles {
                awaitSettled(path)
            } else {
                handle(path: path, depth: depth, rules: rules, watchedRoot: folder.path)
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

    private func handle(path: String, depth: Int, rules: [Rule], watchedRoot: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        guard hasPathChangedSinceLastEvaluation(path) else { return }

        let batchId = UUID().uuidString
        let (matched, history) = RuleEngine.run(path: path, depth: depth, rules: rules, batchId: batchId, root: watchedRoot)
        for ruleName in matched {
            onRuleMatched?(ruleName, path)
        }
        if !history.isEmpty {
            db.withLock { db in
                try? db.insertHistoryEntries(history)
            }
            recordEvaluatedResultStates(history)
            notifyActivity(from: history)
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
