import CoreServices
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
        watcherRef = FileWatcher(onEvent: { _, _ in })
        self.watcher = watcherRef
        self.watcher.replaceHandler { [weak self] path, flags in
            self?.handle(path: path, flags: flags)
        }
    }

    public func add(_ path: String) { watcher.add(path) }
    public func remove(_ path: String) { watcher.remove(path) }

    /// Catches up on files that changed while Forel wasn't running (missed
    /// FSEvents) by planning and executing the folder's rules against every
    /// file currently in scope — the same pipeline a manual Run Now uses.
    /// Safe to call repeatedly: rules already satisfied simply plan to
    /// `wouldSkip`.
    public func runStartupScan(folder: WatchedFolder) {
        let rules = db.withLock { db in (try? db.listRules(folderId: folder.id)) ?? [] }
        guard !rules.isEmpty else { return }

        let maxDepth = RuleEngine.maxRuleDepth(rules)
        let entries = RuleEngine.walkEntries(root: folder.path, maxDepth: maxDepth)
        let scanBatchId = UUID().uuidString
        let scanEvents = entries.map { entry in
            FilesystemEvent(batchId: scanBatchId, source: .scan, kind: .discovered, path: entry.path)
        }
        db.withLock { db in try? db.insertFilesystemEvents(scanEvents) }

        let plan = RulePlanner.plan(entries: entries, rules: rules, root: folder.path, folderId: folder.id, status: .ready)
        persist(PlanExecutor.execute(plan))
    }

    func handle(path: String, flags: UInt32) {
        journalFSEvent(path: path, flags: flags)

        guard let (folder, rules) = db.withLock({ db -> (WatchedFolder, [Rule])? in
            guard let folder = try? db.folderForPath(path) else { return nil }
            let rules = (try? db.listRules(folderId: folder.id)) ?? []
            return (folder, rules)
        }) else { return }

        guard let depth = RuleEngine.pathDepth(root: folder.path, path: path) else { return }
        guard let plannedFile = RulePlanner.planFile(path: path, depth: depth, rules: rules, root: folder.path) else { return }

        for plannedRule in plannedFile.rules {
            onRuleMatched?(plannedRule.ruleName, path)
        }

        let plan = ExecutionPlan(folderId: folder.id, status: .ready, files: [plannedFile])
        persist(PlanExecutor.execute(plan))
    }

    private func persist(_ result: PlanExecutionResult) {
        guard !result.history.isEmpty else { return }
        db.withLock { db in
            try? db.insertHistoryEntries(result.history)
            try? db.insertFilesystemEvents(result.events)
            for state in result.fileStateUpserts { try? db.upsertFileState(state) }
            for path in result.fileStateDeletes { try? db.deleteFileState(path) }
        }
    }

    /// Records the raw FSEvents flag for `path` so the journal distinguishes
    /// observed facts from Forel's own planning/execution later.
    private func journalFSEvent(path: String, flags: UInt32) {
        let identity = FileFingerprint.identity(path)
        let event = FilesystemEvent(
            source: .fsevents,
            kind: WatcherCoordinator.kind(forFlags: flags),
            path: path,
            volumeId: identity?.volumeId,
            fileId: identity?.fileId,
            contentFingerprint: FileFingerprint.current(path),
            rawFlags: Int64(flags)
        )
        db.withLock { db in
            try? db.insertFilesystemEvent(event)
        }
    }

    static func kind(forFlags flags: UInt32) -> FilesystemEventKind {
        if flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 { return .renamed }
        if flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0 { return .created }
        return .unknown
    }
}
