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
    private let activeProcessingLock = NSLock()
    private var activeProcessingRoots: [String: Int] = [:]
    public var onRuleMatched: (@Sendable (String, String) -> Void)?
    public var onActivity: (@Sendable (WatcherActivitySummary) -> Void)?

    public init(db: Database) {
        self.db = db
        var watcherRef: FileWatcher!
        watcherRef = FileWatcher(onEvent: { _ in })
        self.watcher = watcherRef
        self.watcher.replaceHandler { [weak self] event in
            self?.handle(event: event)
        }
    }

    public func add(_ path: String) { watcher.add(path) }
    public func remove(_ path: String) { watcher.remove(path) }

    func handle(event: FileWatcherEvent) {
        switch event {
        case .pathArrived(let path):
            handle(path: path)
        case .rescanSubtree(let path):
            handleRescanSubtree(root: path)
        }
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

    private func handleRescanSubtree(root: String) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir) else { return }
        guard isDir.boolValue else {
            handle(path: root)
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

        let maxDepth = RuleEngine.maxRuleDepth(rules)
        if root != folder.path, !SystemFileFilter.isExcluded((root as NSString).lastPathComponent) {
            handle(path: root, depth: rootDepth, rules: rules, watchedRoot: folder.path)
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
            handle(path: entry.path, depth: depth, rules: rules, watchedRoot: folder.path)
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
