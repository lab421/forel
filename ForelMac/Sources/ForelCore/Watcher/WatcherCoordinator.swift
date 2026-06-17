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

    private func handle(path: String) {
        guard let (folder, rules) = db.withLock({ db -> (WatchedFolder, [Rule])? in
            guard let folder = try? db.folderForPath(path) else { return nil }
            let rules = (try? db.listRules(folderId: folder.id)) ?? []
            return (folder, rules)
        }) else { return }

        guard let depth = RuleEngine.pathDepth(root: folder.path, path: path) else { return }
        let batchId = UUID().uuidString
        let (matched, history) = RuleEngine.evaluateFile(path: path, depth: depth, rules: rules, batchId: batchId, root: folder.path)
        for ruleName in matched {
            onRuleMatched?(ruleName, path)
        }
        if !history.isEmpty {
            db.withLock { db in
                try? db.insertHistoryEntries(history)
            }
        }
    }
}
