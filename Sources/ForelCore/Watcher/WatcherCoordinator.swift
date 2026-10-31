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
    private var isPro = false
    private let now: @Sendable () -> Date
    private var quotaRetryScheduled = false
    private let watcher: FileWatcher
    private let actionPlatform: any ActionPlatform
    private let lastOpened: any LastOpenedMetadataProvider
    private let matchState: any HazelMatchStateStore
    private let counterStore: any FolderCounterStore
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
    private var peerSettling: [String: SettlingState] = [:]
    private var peerGeneration: [String: UInt64] = [:]
    /// Folders currently watched. Only touched on `processingQueue`.
    private var watchedRoots: Set<String> = []
    private var timeRecheckScheduled = false
    private var nextTimeRecheck: Date?
    private struct TraversalResult {
        let recurses: Bool
        let fingerprint: String?
        let volumeId: Int64?
        let fileId: Int64?
        let rules: Data
    }
    private var hazelTraversalResults: [String: TraversalResult] = [:]
    private var activeHazelTraversal: Set<String> = []

    private func ruleSignature(_ rules: [Rule]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(rules)) ?? Data()
    }

    private func traversalDecision(_ path: String, rules: [Rule]) -> Bool? {
        if activeHazelTraversal.contains(path) { return true }
        guard let result = hazelTraversalResults[path], result.rules == ruleSignature(rules),
              result.fingerprint == FileFingerprint.current(path) else { return nil }
        let identity = FileFingerprint.identity(path)
        guard result.volumeId == identity?.volumeId, result.fileId == identity?.fileId else { return nil }
        return result.recurses
    }

    private func recordTraversal(_ path: String, recurses: Bool, rules: [Rule]) {
        let identity = FileFingerprint.identity(path)
        hazelTraversalResults[path] = TraversalResult(recurses: recurses, fingerprint: FileFingerprint.current(path), volumeId: identity?.volumeId, fileId: identity?.fileId, rules: ruleSignature(rules))
    }

    private func ensureTraversalAncestors(root: String, path: String, rules: [Rule]) {
        guard rules.contains(where: { $0.enabled && $0.isHazelImported }) else { return }
        let rootParts = (root as NSString).pathComponents
        let pathParts = (path as NSString).pathComponents
        guard pathParts.count > rootParts.count + 1, Array(pathParts.prefix(rootParts.count)) == rootParts else { return }
        var ancestor = root
        for component in pathParts[rootParts.count..<(pathParts.count - 1)] {
            ancestor = (ancestor as NSString).appendingPathComponent(component)
            if traversalDecision(ancestor, rules: rules) == nil {
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: ancestor),
                      (attributes[.type] as? FileAttributeType) == .typeDirectory,
                      let depth = RuleEngine.pathDepth(root: root, path: ancestor) else { return }
                _ = handle(path: ancestor, depth: depth, rules: rules, watchedRoot: root, force: true)
            }
            guard traversalDecision(ancestor, rules: rules) == true else { return }
        }
    }
    /// A file that stays marked busy without changing is a stalled transfer.
    /// Nothing signals the marker being lifted, so keep checking, but less
    /// and less often, up to this interval.
    private let maxStalledInterval: TimeInterval = 60
    public var onRuleMatched: (@Sendable (String, String) -> Void)?
    public var onActivity: (@Sendable (WatcherActivitySummary) -> Void)?
    public var onVolumeUnavailable: (@Sendable (VolumeUnavailableEvent) -> Void)?
    public var onHistoryRecorded: (@Sendable () -> Void)?
    public var onMonthlyQuotaReached: (@Sendable () -> Void)?
    public var onProcessingError: (@Sendable (String) -> Void)?
    var waitingForVolume: [String: Set<String>] = [:]

    public func setProAccess(_ enabled: Bool) {
        db.withLock { _ in isPro = enabled }
        processingQueue.async { [weak self] in
            self?.hazelTraversalResults.removeAll()
            self?.retryQuotaPendingFiles()
        }
    }

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

    public init(db: Database, monthlyUsage: MonthlyFileUsageStore = MonthlyFileUsageStore(), settleInterval: TimeInterval = 1.0, now: @escaping @Sendable () -> Date = { Date() }, actionPlatform: any ActionPlatform = MacActionPlatform(), lastOpened: any LastOpenedMetadataProvider = SpotlightLastOpenedMetadata()) {
        self.db = db
        self.monthlyUsage = monthlyUsage
        self.now = now
        self.settleInterval = settleInterval
        self.actionPlatform = actionPlatform
        self.lastOpened = lastOpened
        self.matchState = DatabaseHazelMatchStateStore(db: db)
        self.counterStore = DatabaseFolderCounterStore(db: db)
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
            guard let self else { return }
            self.watchedRoots.insert(path)
            self.scheduleTimeRecheck()
            self.retryQuotaPendingFiles()
        }
    }

    private func scheduleTimeRecheck() {
        guard !timeRecheckScheduled else { return }
        guard !watchedRoots.isEmpty else { nextTimeRecheck = nil; return }
        let now = Date()
        nextTimeRecheck = Self.nextMinuteBoundary(after: now)
        let due = nextTimeRecheck!
        timeRecheckScheduled = true
        processingQueue.asyncAfter(deadline: .now() + max(0, due.timeIntervalSinceNow)) { [weak self] in
            guard let self else { return }
            self.timeRecheckScheduled = false
            // A delayed timer observes the current state and current time once;
            // replaying missed minutes would apply old conditions to new files.
            for root in self.watchedRoots.sorted() { self.recheckTimeSensitiveRules(root: root, now: Date()) }
            self.scheduleTimeRecheck()
        }
    }

    static func nextMinuteBoundary(after date: Date) -> Date {
        Date(timeIntervalSince1970: (floor(date.timeIntervalSince1970 / 60) + 1) * 60)
    }

    /// Re-evaluate time-dependent rules even when the filesystem has
    /// not emitted an event. Per-rule match state prevents repeated actions.
    func recheckTimeSensitiveRules(root: String, now: Date = Date()) {
        let pro = db.withLock { _ in isPro }
        // Timer scans can be retried on the next tick after quota resets. Do
        // not enqueue every scanned file as though it were a new arrival.
        guard pro || !monthlyUsage.monthlyFileUsage(at: now).isExhausted else { return }
        guard let (folder, rules) = db.withLock({ db -> (WatchedFolder, [Rule])? in
            guard let folder = try? db.folderForPath(root), folder.path == root else { return nil }
            return (folder, (try? db.executionRules(folderID: folder.id, isPro: pro)) ?? [])
        }), rules.contains(where: { $0.enabled && RuleEngine.isTimeSensitive($0) }) else { return }
        beginProcessing(root: root)
        defer { endProcessing(root: root) }
        RuleEngine.forEachRuleEntryExecuting(root: folder.path, rules: rules, isPro: pro, lastOpened: lastOpened) { entry, _, recurse in
            guard pro || !self.monthlyUsage.monthlyFileUsage(at: now).isExhausted else { return false }
            guard (try? self.db.withLock { try $0.folderForPath(entry.path) })?.id == folder.id else { return false }
            return self.handle(path: entry.path, depth: entry.depth, rules: rules, watchedRoot: root, force: true, timedRecheck: true, now: now, onRecurse: recurse)
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
        peerGeneration[root, default: 0] &+= 1
        watchedRoots.remove(root)
        keepWaiting { path in watchedRoots.contains { Self.isPath(path, under: $0) } }
        hazelTraversalResults = hazelTraversalResults.filter { path, _ in
            !Self.isPath(path, under: root) || watchedRoots.contains { Self.isPath(path, under: $0) }
        }
        settling = settling.filter { path, _ in
            !Self.isPath(path, under: root) || watchedRoots.contains { Self.isPath(path, under: $0) }
        }
        peerSettling = peerSettling.filter { path, _ in
            !Self.isPath(path, under: root) || watchedRoots.contains { Self.isPath(path, under: $0) }
        }
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
    @discardableResult
    func waitForPendingEvents(timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while processingQueue.sync(execute: { !settling.isEmpty || !peerSettling.isEmpty }) {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: max(settleInterval / 4, 0.01))
        }
        processingQueue.sync {}
        return true
    }

    /// Processes `event`. Live watcher events wait for each file to settle
    /// first; passing `false` evaluates the files as they are right now.
    func handle(event: FileWatcherEvent, waitsForSettledFiles: Bool = false) {
        switch event {
        case .pathArrived(let path):
            if !FileManager.default.fileExists(atPath: path) { recheckPeerRules(near: path); return }
            if waitsForSettledFiles {
                awaitSettled(path)
            } else {
                handle(path: path)
            }
        case .rescanSubtree(let path):
            handleRescanSubtree(root: path, waitsForSettledFiles: waitsForSettledFiles)
        case .peerChanged(let path):
            guard hasPeerRules(near: path) else { return }
            if waitsForSettledFiles && FileManager.default.fileExists(atPath: path) { awaitPeerSettled(path) }
            else { recheckPeerRules(near: path) }
        }
    }

    private func hasPeerRules(near path: String) -> Bool {
        db.withLock { db in
            guard let folder = try? db.folderForPath(path), let rules = try? db.executionRules(folderID: folder.id, isPro: self.isPro) else { return false }
            return rules.contains { $0.enabled && RuleEngine.isPeerSensitive($0) }
        }
    }

    private func awaitPeerSettled(_ path: String) {
        guard settleInterval > 0 else { recheckPeerRules(near: path); return }
        guard peerSettling[path] == nil else { return }
        peerSettling[path] = SettlingState(fingerprint: FileReadiness.snapshot(path, includingContents: false)?.fingerprint, includesContents: false)
        schedulePeerSettleCheck(path)
    }
    private func schedulePeerSettleCheck(_ path: String, after delay: TimeInterval? = nil) {
        processingQueue.asyncAfter(deadline: .now() + (delay ?? settleInterval)) { [weak self] in self?.checkPeerSettled(path) }
    }
    private func checkPeerSettled(_ path: String) {
        guard var state = peerSettling[path] else { return }
        guard let snapshot = FileReadiness.snapshot(path, includingContents: false) else {
            peerSettling[path] = nil; recheckPeerRules(near: path); return
        }
        if snapshot.fingerprint != state.fingerprint {
            state.fingerprint = snapshot.fingerprint; state.stalledChecks = 0; peerSettling[path] = state
            schedulePeerSettleCheck(path); return
        }
        if snapshot.isMarkedBusy {
            state.stalledChecks += 1; peerSettling[path] = state
            schedulePeerSettleCheck(path, after: min(settleInterval * pow(2, Double(min(state.stalledChecks, 16))), maxStalledInterval)); return
        }
        peerSettling[path] = nil; recheckPeerRules(near: path)
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
        // A rescan may have queued both a folder and its descendants. Wait
        // for the folder's actual actions before deciding whether Hazel may
        // process anything inside it.
        var parent = (path as NSString).deletingLastPathComponent
        while parent.count > 1 {
            if settling[parent] != nil {
                scheduleSettleCheck(path)
                return
            }
            parent = (parent as NSString).deletingLastPathComponent
        }
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
        // Existing contents of an arriving folder may have no events of
        // their own. A full-tree settling snapshot covers those contents;
        // rescan only real folders so links cannot escape the watched tree.
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let isRealDirectory = (attributes?[.type] as? FileAttributeType) == .typeDirectory
        if state.hasDeferredDescendants || (state.includesContents && isRealDirectory) {
            handleRescanSubtree(root: path, waitsForSettledFiles: false)
        }
    }

    public func isProcessing(in root: String) -> Bool {
        activeProcessingLock.lock()
        defer { activeProcessingLock.unlock() }
        return activeProcessingRoots[root, default: 0] > 0
    }

    func handle(path: String, retrying: Bool = false) {
        // A duplicate/coalesced FSEvent for a path a prior call already
        // moved away — common with FSEvents — would otherwise be replanned
        // (name/extension conditions don't require the file to exist) and
        // then fail at execution with a noisy "doesn't exist" entry.
        // Nothing meaningful can be evaluated against a path that's gone.
        guard FileManager.default.fileExists(atPath: path) else { return }
        guard retrying || hasPathChangedSinceLastEvaluation(path) else { return }

        guard let (folder, rules) = db.withLock({ db -> (WatchedFolder, [Rule])? in
            guard let folder = try? db.folderForPath(path) else { return nil }
            let rules = (try? db.executionRules(folderID: folder.id, isPro: self.isPro)) ?? []
            guard !rules.isEmpty else { return nil }
            return (folder, rules)
        }) else { return }
        defer { recheckPeerRules(near: path) }

        beginProcessing(root: folder.path)
        defer { endProcessing(root: folder.path) }

        guard let depth = RuleEngine.pathDepth(root: folder.path, path: path) else { return }
        ensureTraversalAncestors(root: folder.path, path: path, rules: rules)
        let pro = db.withLock { _ in isPro }
        _ = handle(path: path, depth: depth, rules: rules, watchedRoot: folder.path, retrying: retrying, onRecurse: { target in
            RuleEngine.forEachRuleEntryExecuting(root: folder.path, rules: rules, subtree: target, isPro: pro, lastOpened: self.lastOpened, ancestorDecision: { self.traversalDecision($0, rules: rules) ?? false }) { entry, _, recurse in
                if entry.path == target { return true }
                return self.handle(path: entry.path, depth: entry.depth, rules: rules, watchedRoot: folder.path, onRecurse: recurse)
            }
        })
    }

    private func recheckPeerRules(near path: String) {
        guard let (folder, _) = db.withLock({ db -> (WatchedFolder, [Rule])? in
            guard let folder = try? db.folderForPath(path) else { return nil }
            let rules = ((try? db.executionRules(folderID: folder.id, isPro: self.isPro)) ?? []).filter { $0.enabled && RuleEngine.isPeerSensitive($0) }
            return rules.isEmpty ? nil : (folder, rules)
        }) else { return }
        let parent = (path as NSString).deletingLastPathComponent
        guard let peers = try? FileManager.default.contentsOfDirectory(atPath: parent), peers.count <= 10_000 else { return }
        recheckPeerBatch(parent: parent, names: peers.sorted(), offset: 0, root: folder.path, folderId: folder.id, generation: peerGeneration[folder.path, default: 0])
    }

    private func recheckPeerBatch(parent: String, names: [String], offset: Int, root: String, folderId: String, generation: UInt64) {
        guard peerGeneration[root, default: 0] == generation else { return }
        let rules = db.withLock { (try? $0.executionRules(folderID: folderId, isPro: self.isPro)) ?? [] }
        guard rules.contains(where: { $0.enabled && RuleEngine.isPeerSensitive($0) }) else { return }
        beginProcessing(root: root); defer { endProcessing(root: root) }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        for index in offset..<names.count {
            if ProcessInfo.processInfo.systemUptime > deadline {
                processingQueue.async { [weak self] in self?.recheckPeerBatch(parent: parent, names: names, offset: index, root: root, folderId: folderId, generation: generation) }
                return
            }
            let name = names[index]
            if SystemFileFilter.isExcluded(name) { continue }
            let peer = (parent as NSString).appendingPathComponent(name)
            guard (try? db.withLock { try $0.folderForPath(peer) })?.id == folderId,
                  let depth = RuleEngine.pathDepth(root: root, path: peer) else { continue }
            // A peer-only event can be the first event after a restart. Recover
            // each folder's actual Hazel decision before selecting its rules.
            // Cached decisions avoid replaying folder actions for every peer.
            ensureTraversalAncestors(root: root, path: peer, rules: rules)
            guard peerGeneration[root, default: 0] == generation,
                  FileManager.default.fileExists(atPath: peer),
                  (try? db.withLock { try $0.folderForPath(peer) })?.id == folderId else { continue }
            let pro = db.withLock { _ in isPro }
            let eligible = RuleEngine.rulesForPath(root: root, path: peer, rules: rules, isPro: pro, lastOpened: lastOpened, recurseDecision: { self.traversalDecision($0, rules: rules) ?? false })
            guard let result = executeWithQuota(path: peer, depth: depth, rules: eligible, root: root, pro: pro, peerRecheckOnly: true) else { continue }
            record(matched: result.matched, history: result.history, path: peer, rules: rules, cacheOriginal: false)
        }
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
            let rules = (try? db.executionRules(folderID: folder.id, isPro: self.isPro)) ?? []
            guard !rules.isEmpty else { return nil }
            return (folder, rules)
        }) else { return }
        guard RuleEngine.pathDepth(root: folder.path, path: root) != nil else { return }

        beginProcessing(root: folder.path)
        defer { endProcessing(root: folder.path) }
        ensureTraversalAncestors(root: folder.path, path: root, rules: rules)

        // A rescan can find files that are still being written just like a
        // live arrival can, so each one goes through the same wait.
        let pro = db.withLock { _ in isPro }
        if waitsForSettledFiles {
            let hasHazelRules = rules.contains { $0.enabled && $0.isHazelImported }
            RuleEngine.forEachRuleEntryExecuting(root: folder.path, rules: rules, subtree: root, isPro: pro, lastOpened: lastOpened, ancestorDecision: { self.traversalDecision($0, rules: rules) ?? false }) { entry, _, _ in
                self.awaitSettled(entry.path, includingContents: hasHazelRules)
                return false
            }
        } else {
            RuleEngine.forEachRuleEntryExecuting(root: folder.path, rules: rules, subtree: root, isPro: pro, lastOpened: lastOpened, ancestorDecision: { self.traversalDecision($0, rules: rules) ?? false }) { entry, _, recurse in
                self.handle(path: entry.path, depth: entry.depth, rules: rules, watchedRoot: folder.path, onRecurse: recurse)
            }
        }
    }

    private func handle(path: String, depth: Int, rules: [Rule], watchedRoot: String, force: Bool = false, retrying: Bool = false, timedRecheck: Bool = false, now: Date? = nil, onRecurse: ((String) -> Void)? = nil) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        var recoveringHazelDecision = force
        if !force && !retrying && !hasPathChangedSinceLastEvaluation(path) {
            if let cached = traversalDecision(path, rules: rules) { return cached }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
                  rules.contains(where: { $0.enabled && $0.isHazelImported }) else { return false }
            recoveringHazelDecision = true
        }

        let pro = db.withLock { _ in isPro }
        let eligibleRules = RuleEngine.rulesForPath(root: watchedRoot, path: path, rules: rules, isPro: pro, lastOpened: lastOpened, recurseDecision: { self.traversalDecision($0, rules: rules) ?? false })
        let activeRules = timedRecheck ? eligibleRules.filter { $0.isHazelImported || RuleEngine.isTimeSensitive($0) } : recoveringHazelDecision ? eligibleRules.filter(\.isHazelImported) : eligibleRules
        guard let result = executeWithQuota(path: path, depth: depth, rules: activeRules, root: watchedRoot, pro: pro, date: now, onRecurse: { target in
            self.activeHazelTraversal.insert(target)
            defer { self.activeHazelTraversal.remove(target) }
            onRecurse?(target)
        }) else { return false }
        recordTraversal(path, recurses: result.recurses, rules: rules)
        record(matched: result.matched, history: result.history, path: path, rules: rules)
        return result.recurses
    }

    private func executeWithQuota(path: String, depth: Int, rules: [Rule], root: String, pro: Bool, date: Date? = nil, peerRecheckOnly: Bool = false, onRecurse: ((String) -> Void)? = nil) -> (matched: [String], history: [HistoryEntry], recurses: Bool)? {
        do {
            let result = try monthlyUsage.withFreePlan(isPro: pro, at: date ?? now()) { beforeAction in
                let result = RuleEngine.runWithTraversal(path: path, depth: depth, rules: rules, batchId: UUID().uuidString, root: root, isPro: pro, platform: actionPlatform, lastOpened: lastOpened, matchState: matchState, counterStore: counterStore, now: date ?? now(), peerRecheckOnly: peerRecheckOnly, beforeAction: beforeAction, onRecurse: onRecurse)
                return (result, result.history)
            }
            monthlyUsage.removeQuotaPendingFile(path)
            return result
        } catch FreePlanError.monthlyFileLimit {
            monthlyUsage.queueQuotaPendingFile(path)
            onMonthlyQuotaReached?()
            scheduleQuotaRetry()
            return nil
        } catch {
            onProcessingError?(error.localizedDescription)
            return nil
        }
    }

    func retryQuotaPendingFiles() {
        guard !watchedRoots.isEmpty else { return }
        let pro = db.withLock { _ in isPro }
        guard pro || !monthlyUsage.monthlyFileUsage(at: now()).isExhausted else {
            scheduleQuotaRetry()
            return
        }
        for path in monthlyUsage.quotaPendingFiles() where watchedRoots.contains(where: { Self.isPath(path, under: $0) }) {
            guard FileManager.default.fileExists(atPath: path) else {
                monthlyUsage.removeQuotaPendingFile(path)
                continue
            }
            do { try db.withLock { try $0.deleteWatchedPathState(path) } }
            catch { onProcessingError?(error.localizedDescription); continue }
            handle(event: .pathArrived(path), waitsForSettledFiles: true)
        }
    }

    private func scheduleQuotaRetry() {
        guard !quotaRetryScheduled else { return }
        quotaRetryScheduled = true
        let period = MonthlyFileUsage(at: now())
        let delay = max(1, min(3600, period.resetsAt.timeIntervalSince(now())))
        processingQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.quotaRetryScheduled = false
            self.retryQuotaPendingFiles()
        }
    }

    private func record(matched: [String], history: [HistoryEntry], path: String, rules: [Rule], cacheOriginal: Bool = true) {
        for ruleName in matched { onRuleMatched?(ruleName, path) }
        if !history.isEmpty {
            db.withLock { try? $0.insertHistoryEntries(history) }
            recordEvaluatedResultStates(history)
            notifyActivity(from: history)
            onHistoryRecorded?()
            waitForDisconnectedVolumes(history, path: path, rules: rules)
        }
        if cacheOriginal { recordEvaluatedState(path) }
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
