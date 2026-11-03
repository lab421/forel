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
    var waitingForSyncOnlyPaths: Set<String> = []

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
        var hasDeferredSyncDescendants = false
        /// Modifications and known descendants of renamed folders only sync;
        /// they must not replay unrelated arrival actions.
        var syncOnly = false
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
        case .pathArrived(let path), .pathRemoved(let path):
            // A path renamed away is reported where it used to be, and one
            // removed then recreated (a safe save) is reported as removed.
            if !FileManager.default.fileExists(atPath: path) {
                handleDeleted(path: path)
            } else if waitsForSettledFiles {
                awaitSettled(path)
            } else {
                handle(path: path)
            }
        case .rescanSubtree(let path):
            handleRescanSubtree(root: path, waitsForSettledFiles: waitsForSettledFiles)
        case .pathModified(let path):
            // Non-sync watched folders keep their arrival-only behavior,
            // including avoiding snapshots of unrelated modified trees.
            let hasSync = db.withLock { db in
                guard let folder = try? db.folderForPath(path) else { return false }
                let rules = (try? db.executionRules(folderID: folder.id, isPro: isPro)) ?? []
                return rules.contains { $0.actions.contains { $0.kind == .syncFolders } }
            }
            guard hasSync else { return }
            if waitsForSettledFiles {
                awaitSettled(path, syncOnly: true)
            } else {
                handle(path: path, syncOnly: true)
            }
        }
    }

    /// Runs rules on `path` once its fingerprint has stayed the same for a
    /// full `settleInterval` and nothing marks it as still being written.
    private func awaitSettled(_ path: String, includingContents: Bool = true, syncOnly: Bool = false) {
        guard settleInterval > 0 else {
            handle(path: path, syncOnly: syncOnly)
            return
        }
        // A check is already scheduled; it will see the file's latest state.
        if var existing = settling[path] {
            existing.syncOnly = existing.syncOnly && syncOnly
            settling[path] = existing
            return
        }
        // Something arriving inside a folder that is itself still waiting is
        // already covered by that folder's snapshot. Giving every nested item
        // its own wait would re-read the tree once per item (a `git clone` or
        // an unzip creates thousands), so it is evaluated when the folder
        // settles instead.
        if let ancestor = settlingAncestor(of: path) {
            if syncOnly {
                settling[ancestor]?.hasDeferredSyncDescendants = true
            } else {
                settling[ancestor]?.hasDeferredDescendants = true
                settling[ancestor]?.syncOnly = false
            }
            return
        }
        guard FileManager.default.fileExists(atPath: path), hasPathChangedSinceLastEvaluation(path) else { return }
        settling[path] = SettlingState(
            fingerprint: FileReadiness.snapshot(path, includingContents: includingContents)?.fingerprint,
            includesContents: includingContents,
            syncOnly: syncOnly
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
        // Contents a folder arrived with never get their own FSEvents events —
        // they were created outside the watched tree — so its subtree is
        // walked, the way Run Now does. The snapshot already waited for them
        // to stop changing. A folder the watcher already knows was only
        // renamed or moved inside the watched folder: nothing new arrived.
        // Checked before `handle` records the folder under its new path.
        let isFolder = state.includesContents && isRealDirectory(path)
        let knownFolder = isFolder && wasEvaluatedBefore(path)
        let arrivedWithContents = isFolder && !knownFolder
        settling[path] = nil
        handle(path: path, syncOnly: state.syncOnly)
        if state.hasDeferredDescendants {
            handleRescanSubtree(root: path, waitsForSettledFiles: false, skipsKnownItems: knownFolder, syncOnly: state.syncOnly)
        } else if arrivedWithContents {
            handleRescanSubtree(root: path, waitsForSettledFiles: false, skipsKnownItems: true, syncOnly: state.syncOnly)
        }
        if knownFolder || state.hasDeferredSyncDescendants {
            handleRescanSubtree(root: path, waitsForSettledFiles: false, syncOnly: true)
        }
    }

    /// Whether the watcher already evaluated this item in the same watched
    /// folder, under another path before a rename or a move. Coming from
    /// another watched folder, it still gets this folder's rules.
    private func wasEvaluatedBefore(_ path: String) -> Bool {
        guard let identity = FileFingerprint.identity(path) else { return false }
        return db.withLock { db in
            guard let root = try? db.folderForPath(path)?.path,
                  let paths = try? db.watchedPaths(volumeId: identity.volumeId, fileId: identity.fileId)
            else { return false }
            return paths.contains { Self.isPath($0, under: root) }
        }
    }

    private func isRealDirectory(_ path: String) -> Bool {
        // Inspect the item itself: following a directory symlink would let a
        // subtree scan apply this watched folder's rules outside its tree.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return false }
        return (attributes[.type] as? FileAttributeType) == .typeDirectory
    }

    public func isProcessing(in root: String) -> Bool {
        activeProcessingLock.lock()
        defer { activeProcessingLock.unlock() }
        return activeProcessingRoots[root, default: 0] > 0
    }

    /// `retrying` runs the rules even though the file hasn't changed.
    func handle(path: String, retrying: Bool = false, syncOnly: Bool = false) {
        // A duplicate/coalesced FSEvent for a path a prior call already
        // moved away — common with FSEvents — would otherwise be replanned
        // (name/extension conditions don't require the file to exist) and
        // then fail at execution with a noisy "doesn't exist" entry.
        // Nothing meaningful can be evaluated against a path that's gone.
        guard FileManager.default.fileExists(atPath: path) else { return }
        guard retrying || hasPathChangedSinceLastEvaluation(path) else { return }

        guard let (folder, rules, isPro) = db.withLock({ db -> (WatchedFolder, [Rule], Bool)? in
            guard let folder = try? db.folderForPath(path) else { return nil }
            let saved = (try? db.executionRules(folderID: folder.id, isPro: self.isPro)) ?? []
            let rules = syncOnly ? Self.syncOnlyRules(saved) : saved
            guard !rules.isEmpty else { return nil }
            return (folder, rules, self.isPro)
        }) else { return }

        beginProcessing(root: folder.path)
        defer { endProcessing(root: folder.path) }

        guard let depth = RuleEngine.pathDepth(root: folder.path, path: path) else { return }
        runAndRecord(path: path, depth: depth, rules: rules, watchedRoot: folder.path, isPro: isPro, syncOnly: syncOnly)
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

    private func handleDeleted(path: String) {
        for match in syncRuleMatches(forPath: path) {
            let policy = ActionExecutor.syncDeletePolicy(match.action)
            guard policy != .keepOtherSide else { continue }
            do {
                guard try !ActionExecutor.isSyncDestinationPath(match.action, path: path) else { continue }
                let counterpart = try ActionExecutor.syncCounterpartPath(match.action, path: path, root: match.folder.path)
                guard (try? FileManager.default.attributesOfItem(atPath: counterpart)) != nil else { continue }
                let batchId = UUID().uuidString
                // Moving a folder out can report only the folder itself.
                // Match bottom-up before changing anything. A directory can
                // only be removed if every child is eligible too.
                let candidates = syncRemovalCandidates(match, counterpart: counterpart)
                var eligible = Set<String>()
                func originalPath(_ candidate: String) -> String {
                    let suffix = (candidate as NSString).pathComponents.dropFirst((counterpart as NSString).pathComponents.count)
                    return suffix.reduce(path) { ($0 as NSString).appendingPathComponent($1) }
                }
                for candidate in candidates {
                    let original = originalPath(candidate)
                    guard try !ActionExecutor.isSyncDestinationPath(match.action, path: original) else { continue }
                    _ = try ActionExecutor.syncCounterpartPath(match.action, path: original, root: match.folder.path)
                    guard syncRuleApplies(match, to: candidate) else { continue }
                    if isRealDirectory(candidate) {
                        let children = try FileManager.default.contentsOfDirectory(atPath: candidate)
                        guard children.allSatisfy({ eligible.contains((candidate as NSString).appendingPathComponent($0)) }) else { continue }
                    }
                    eligible.insert(candidate)
                }
                for candidate in candidates where eligible.contains(candidate) {
                    // Move an eligible subtree as one item. This preserves
                    // directory Undo instead of trashing parents and children
                    // separately with colliding restore operations.
                    var parent = (candidate as NSString).deletingLastPathComponent
                    var covered = false
                    while isPathPrefix(counterpart, of: parent) {
                        if eligible.contains(parent) { covered = true; break }
                        let next = (parent as NSString).deletingLastPathComponent
                        if next == parent { break }
                        parent = next
                    }
                    if covered { continue }
                    let original = originalPath(candidate)
                    if policy == .delete {
                        try FileManager.default.removeItem(atPath: candidate)
                        insertSyncHistory(match: match, batchId: batchId, originalPath: original, resultPath: candidate, undo: .none)
                    } else {
                        let trash = try moveToTrash(candidate)
                        insertSyncHistory(match: match, batchId: batchId, originalPath: original, resultPath: trash,
                                          undo: .move(from: candidate, to: trash))
                    }
                }
            } catch {
                insertSyncHistory(
                    match: match,
                    batchId: UUID().uuidString,
                    originalPath: path,
                    resultPath: path,
                    status: .failed,
                    message: String(describing: error),
                    undo: .none
                )
            }
        }
    }

    private func syncRemovalCandidates(_ match: SyncRuleMatch, counterpart: String) -> [String] {
        var candidates = [counterpart]
        if isRealDirectory(counterpart),
           let target = try? ActionExecutor.syncCounterpartPath(match.action, path: match.folder.path, root: match.folder.path),
           let depth = RuleEngine.pathDepth(root: target, path: counterpart) {
            let isRoot = (counterpart as NSString).standardizingPath == (target as NSString).standardizingPath
            let childDepth = isRoot ? 0 : depth + 1
            if let limit = match.rule.recursionDepth {
                if childDepth <= max(0, Int(limit)) {
                    candidates += RuleEngine.walkEntries(root: counterpart, maxDepth: max(0, Int(limit)) - childDepth).map(\.path)
                }
            } else {
                candidates += RuleEngine.walkEntries(root: counterpart, maxDepth: nil).map(\.path)
            }
        }
        return candidates.sorted {
            let lhs = ($0 as NSString).pathComponents.count
            let rhs = ($1 as NSString).pathComponents.count
            return lhs == rhs ? $0 < $1 : lhs > rhs
        }
    }

    private static func syncOnlyRules(_ rules: [Rule]) -> [Rule] {
        rules.compactMap { rule in
            var sync = rule
            sync.actions = rule.actions.filter { $0.kind == .syncFolders }
            return sync.actions.isEmpty ? nil : sync
        }
    }

    private struct SyncRuleMatch {
        let folder: WatchedFolder
        let rule: Rule
        let action: Action
    }

    private func syncRuleMatches(forPath path: String) -> [SyncRuleMatch] {
        db.withLock { db in
            var matches: [SyncRuleMatch] = []
            let folders = ((try? db.listFolders()) ?? []).filter(\.enabled)
            for folder in folders where isPathPrefix(folder.path, of: path) {
                let rules = (try? db.executionRules(folderID: folder.id, isPro: isPro)) ?? []
                for rule in rules {
                    for action in rule.actions where action.kind == .syncFolders {
                        matches.append(SyncRuleMatch(folder: folder, rule: rule, action: action))
                    }
                }
            }
            return matches
        }
    }

    /// The rule's conditions and depth, checked on the counterpart in the target.
    private func syncRuleApplies(_ match: SyncRuleMatch, to counterpart: String) -> Bool {
        guard let target = try? ActionExecutor.syncCounterpartPath(match.action, path: match.folder.path, root: match.folder.path),
              let depth = RuleEngine.pathDepth(root: target, path: counterpart) else { return false }
        let pro = db.withLock { _ in isPro }
        return RuleEngine.ruleMatches(match.rule, path: counterpart, depth: depth, allowOCR: pro)
    }

    private func insertSyncHistory(
        match: SyncRuleMatch,
        batchId: String,
        originalPath: String,
        resultPath: String,
        status: HistoryStatus = .applied,
        message: String? = nil,
        undo: Undo
    ) {
        let identity = FileFingerprint.identity(resultPath)
        let entry = HistoryEntry(
            batchId: batchId,
            ruleId: match.rule.id,
            ruleName: match.rule.name,
            actionKind: match.action.kind,
            originalPath: originalPath,
            resultPath: resultPath,
            undo: undo.toJSON(),
            reversible: undo.isReversible,
            status: status,
            message: message,
            resultVolumeId: identity?.volumeId,
            resultFileId: identity?.fileId
        )
        db.withLock { db in
            try? db.insertHistoryEntries([entry])
        }
        onHistoryRecorded?()
    }

    private func moveToTrash(_ path: String) throws -> String {
        let trash = (NSHomeDirectory() as NSString).appendingPathComponent(".Trash")
        try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
        let fileName = (path as NSString).lastPathComponent
        let target = uniqueTrashPath(dir: trash, fileName: fileName)
        try FileManager.default.moveItem(atPath: path, toPath: target)
        return target
    }

    private func uniqueTrashPath(dir: String, fileName: String) -> String {
        let candidate = (dir as NSString).appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: candidate) { return candidate }
        let nsName = fileName as NSString
        let stem = nsName.deletingPathExtension
        let ext = nsName.pathExtension
        var i = 1
        while true {
            let newName = ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)"
            let candidate = (dir as NSString).appendingPathComponent(newName)
            if !FileManager.default.fileExists(atPath: candidate) { return candidate }
            i += 1
        }
    }

    private func isPathPrefix(_ prefix: String, of path: String) -> Bool {
        let prefixComponents = ((prefix as NSString).standardizingPath as NSString).pathComponents
        let pathComponents = ((path as NSString).standardizingPath as NSString).pathComponents
        guard pathComponents.count >= prefixComponents.count else { return false }
        return Array(pathComponents.prefix(prefixComponents.count)) == prefixComponents
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

    /// `skipsKnownItems` leaves out what the watcher already evaluated under
    /// another path, e.g. files inside a folder that was renamed.
    private func handleRescanSubtree(root: String, waitsForSettledFiles: Bool, skipsKnownItems: Bool = false, syncOnly: Bool = false) {
        guard FileManager.default.fileExists(atPath: root) else { return }
        guard isRealDirectory(root) else {
            handle(event: syncOnly ? .pathModified(root) : .pathArrived(root), waitsForSettledFiles: waitsForSettledFiles)
            return
        }

        guard let (folder, rules, isPro) = db.withLock({ db -> (WatchedFolder, [Rule], Bool)? in
            guard let folder = try? db.folderForPath(root) else { return nil }
            let saved = (try? db.executionRules(folderID: folder.id, isPro: self.isPro)) ?? []
            let rules = syncOnly ? Self.syncOnlyRules(saved) : saved
            guard !rules.isEmpty else { return nil }
            return (folder, rules, self.isPro)
        }) else { return }
        guard let rootDepth = RuleEngine.pathDepth(root: folder.path, path: root) else { return }

        beginProcessing(root: folder.path)
        defer { endProcessing(root: folder.path) }

        // A rescan can find files that are still being written just like a
        // live arrival can, so each one goes through the same wait.
        let process: (String, Int) -> Void = { [self] path, depth in
            if skipsKnownItems, wasEvaluatedBefore(path) { return }
            if waitsForSettledFiles {
                awaitSettled(path, includingContents: false, syncOnly: syncOnly)
            } else {
                handle(path: path, depth: depth, rules: rules, watchedRoot: folder.path, isPro: isPro, syncOnly: syncOnly)
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

    private func handle(path: String, depth: Int, rules: [Rule], watchedRoot: String, isPro: Bool, syncOnly: Bool = false) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        guard hasPathChangedSinceLastEvaluation(path) else { return }

        runAndRecord(path: path, depth: depth, rules: rules, watchedRoot: watchedRoot, isPro: isPro, syncOnly: syncOnly)
    }

    private func runAndRecord(path: String, depth: Int, rules: [Rule], watchedRoot: String, isPro: Bool, syncOnly: Bool = false) {
        do {
            let result = try monthlyUsage.runWithFreePlan(path: path, depth: depth, rules: rules,
                                               batchId: UUID().uuidString, root: watchedRoot, isPro: isPro, at: now())
            monthlyUsage.removeQuotaPendingFile(path)
            record(matched: result.matched, history: result.history, path: path, rules: rules, syncOnly: syncOnly)
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
    private func record(matched: [String], history: [HistoryEntry], path: String, rules: [Rule], syncOnly: Bool = false) {
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
            waitForDisconnectedVolumes(history, path: path, rules: rules, syncOnly: syncOnly)
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
