import Foundation

/// Wires `FileWatcher` events to the database and rule engine: for every
/// created/renamed path, finds the owning watched folder, loads its rules,
/// evaluates them, and persists any resulting action history. Mirrors
/// `watcher::on_event` / `load_folder_and_rules_for_path`.
public final class WatcherCoordinator: @unchecked Sendable {
    private let db: Database
    private let watcher: FileWatcher
    public var onRuleMatched: (@Sendable (String, String) -> Void)?

    public init(db: Database) {
        self.db = db
        var watcherRef: FileWatcher!
        watcherRef = FileWatcher(onEvent: { _ in })
        self.watcher = watcherRef
        self.watcher.replaceHandler { [weak self] path in
            self?.handle(path: path)
        }
    }

    public func add(_ path: String) { watcher.add(path) }
    public func remove(_ path: String) { watcher.remove(path) }

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
        }
        recordEvaluatedState(path)
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
        guard let volumeId = cached.volumeId, let fileId = cached.fileId else { return true }
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
}
