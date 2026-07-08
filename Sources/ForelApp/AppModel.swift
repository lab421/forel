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
import ForelCore
import Combine
import AppKit

private let historyCleanupInterval: TimeInterval = 3600

/// Central observable state for the SwiftUI app: owns the database, the
/// watcher coordinator, and the in-memory view of folders/rules. Mirrors the
/// surface of the old `useForelStore` Zustand store, but as direct Swift
@MainActor
final class AppModel: ObservableObject {
    /// Which screen the detail pane shows. History is an in-app view reached
    /// from the sidebar; Settings is its own window (see `ForelMacApp`'s
    /// `Settings` scene), matching standard macOS app structure.
    enum DetailRoute { case rules, history }

    @Published var folders: [WatchedFolder] = []
    @Published var selectedFolderId: String?
    @Published var rules: [Rule] = []
    @Published private(set) var ruleRunStats: [RuleRunStats] = []
    @Published var history: [HistoryEntry] = []
    @Published var historyTotalCount: Int = 0
    @Published var historyFolderFilterId: String?
    @Published private(set) var hasMoreHistory = false
    @Published private(set) var isLoadingHistory = false
    @Published var paused: Bool = false
    @Published var alertTitle: String = "Error"
    @Published var errorMessage: String?
    @Published var detailRoute: DetailRoute = .rules
    @Published var accentPreset: AccentPreset = .default
    @Published var showDockIcon: Bool = true
    @Published var historyMaxDays: Int = 30
    /// Bumped whenever the accent colour changes, so views can force a full
    /// re-render with `.id(model.accentVersion)` — `ForelTheme.accent` is a
    /// plain static var, not itself observable.
    @Published var accentVersion: Int = 0
    @Published private(set) var isRunningNow = false
    @Published private(set) var runNowMessage: String?
    private var runNowMessageId: UUID?
    @Published private(set) var isPreviewing = false
    @Published var previewResult: PreviewResult?
    @Published private var ruleExpansionPreferences = RuleExpansionPreferences()

    let db: Database
    private let coordinator: WatcherCoordinator
    private let historyPageSize = 200
    private let previewMatchLimit = 500
    private let ruleRunStatsWindowDays = 30
    private var historyCleanupTimer: AnyCancellable?

    init() throws {
        let appSupportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appSupport = appSupportRoot.appendingPathComponent("com.lab421.forel", isDirectory: true)
        Self.migrateLegacyAppSupportDirectoryIfNeeded(root: appSupportRoot, newDirectory: appSupport)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let dbPath = appSupport.appendingPathComponent("forel.db").path

        let db = try Database(path: dbPath)
        self.db = db
        self.coordinator = WatcherCoordinator(db: db)
        // Default to paused (watching off) on a fresh install — a brand-new
        // user hasn't set up any rules yet, and starting to watch folders
        // immediately means triggering permission prompts and risking rule-less
        // surprises before they've configured anything. Once they've explicitly
        // set this either way, that choice persists.
        let storedPaused = db.withLock { db in try? db.getSetting("paused") }
        self.paused = storedPaused.map { $0 == "1" } ?? true

        let storedAccent = db.withLock { db in (try? db.getSetting("accent_color")) ?? nil }
        let preset = storedAccent.flatMap(AccentPreset.init(rawValue:)) ?? .default
        self.accentPreset = preset
        ForelTheme.apply(preset)

        let storedShowDockIcon = db.withLock { db in try? db.getSetting("show_dock_icon") }
        self.showDockIcon = storedShowDockIcon.map { $0 == "1" } ?? true

        let storedMaxDays = db.withLock { db in (try? db.getSetting("history_max_days")).flatMap { Int($0) } }
        self.historyMaxDays = min(max(storedMaxDays ?? 30, 1), 30)

        self.ruleExpansionPreferences = db.withLock { db in RuleExpansionPreferences.load(from: db) }

        reloadFolders()
        startWatchingEnabledFolders()
        startHistoryCleanupTimer()
    }

    /// Forel's bundle identifier moved from `com.forel.app` (`.app` isn't a
    /// valid reverse-DNS component on macOS) to `com.lab421.forel`. Existing
    /// users have their database and settings under the old identifier's
    /// Application Support folder; move that folder to the new location so
    /// they don't lose rules or history. No-ops once migrated, and never
    /// overwrites a new-location folder that already exists.
    private static func migrateLegacyAppSupportDirectoryIfNeeded(root: URL, newDirectory: URL) {
        let legacyDirectory = root.appendingPathComponent("com.forel.app", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyDirectory.path), !fm.fileExists(atPath: newDirectory.path) else { return }
        try? fm.moveItem(at: legacyDirectory, to: newDirectory)
    }

    func applyDockIconPreference(keepingWindowsVisible: Bool = false) {
        let visibleWindows = NSApp.windows.filter { window in
            window.isVisible && !(window is NSPanel)
        }
        let keyWindow = NSApp.keyWindow

        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)

        guard keepingWindowsVisible else { return }

        let windowsToRestore = visibleWindows.isEmpty
            ? NSApp.windows.filter { !($0 is NSPanel) }
            : visibleWindows

        let restoreWindows = {
            for window in windowsToRestore {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
            keyWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }

        restoreWindows()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            for window in windowsToRestore {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
            keyWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }

    func setShowDockIcon(_ enabled: Bool) {
        showDockIcon = enabled
        db.withLock { db in try? db.setSetting("show_dock_icon", enabled ? "1" : "0") }
        applyDockIconPreference(keepingWindowsVisible: true)
    }

    func setAccentPreset(_ preset: AccentPreset) {
        accentPreset = preset
        ForelTheme.apply(preset)
        accentVersion += 1
        db.withLock { db in try? db.setSetting("accent_color", preset.rawValue) }
    }

    func setHistoryMaxDays(_ days: Int) {
        let clamped = min(max(days, 1), 30)
        guard clamped != historyMaxDays else { return }
        historyMaxDays = clamped
        db.withLock { db in try? db.setSetting("history_max_days", "\(clamped)") }
        runHistoryCleanup()
    }

    private func runHistoryCleanup() {
        let days = historyMaxDays
        Task.detached(priority: .background) { [db] in
            try? db.withLock { db in
                try db.purgeHistory(before: days)
            }
        }
    }

    private func startHistoryCleanupTimer() {
        historyCleanupTimer = Timer.publish(every: historyCleanupInterval, tolerance: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.runHistoryCleanup() }
        runHistoryCleanup()
    }

    func reloadFolders() {
        folders = db.withLock { db in (try? db.listFolders()) ?? [] }
        if let selectedFolderId, !folders.contains(where: { $0.id == selectedFolderId }) {
            self.selectedFolderId = folders.first?.id
        }
        if selectedFolderId == nil {
            selectedFolderId = folders.first?.id
        }
        if let historyFolderFilterId, !folders.contains(where: { $0.id == historyFolderFilterId }) {
            self.historyFolderFilterId = nil
            reloadHistory()
        }
        reloadRules()
    }

    func reloadRules() {
        guard let folderId = selectedFolderId else { rules = []; return }
        rules = db.withLock { db in (try? db.listRules(folderId: folderId)) ?? [] }
        reloadRuleRunStats()
    }

    func reloadHistory() {
        loadHistoryPage(reset: true)
        reloadRuleRunStats()
    }

    /// Success/failed run counts per rule over the last `ruleRunStatsWindowDays`
    /// days — kept in sync with `rules` and `history`, since both can change
    /// what these totals should be.
    private func reloadRuleRunStats() {
        let days = ruleRunStatsWindowDays
        ruleRunStats = db.withLock { db in (try? db.ruleRunStats(sinceDays: days)) ?? [] }
    }

    func runStats(for rule: Rule) -> RuleRunStats? {
        ruleRunStats.first { $0.id == rule.id }
    }

    func isRuleExpanded(_ rule: Rule) -> Bool {
        ruleExpansionPreferences.isExpanded(rule)
    }

    func toggleRuleExpanded(_ rule: Rule) {
        db.withLock { db in ruleExpansionPreferences.toggle(rule, in: db) }
    }

    private func clearRuleExpansionState(_ ruleId: String) {
        db.withLock { db in ruleExpansionPreferences.clear(ruleId: ruleId, in: db) }
    }

    private func clearRuleExpansionState(_ ruleIds: Set<String>) {
        db.withLock { db in ruleExpansionPreferences.clear(ruleIds: ruleIds, in: db) }
    }

    var totalSuccessCount30d: Int { ruleRunStats.reduce(0) { $0 + $1.successCount } }
    var totalFailedCount30d: Int { ruleRunStats.reduce(0) { $0 + $1.failedCount } }

    func loadMoreHistoryIfNeeded(currentEntry entry: HistoryEntry? = nil) {
        guard hasMoreHistory, !isLoadingHistory else { return }
        if let entry, history.last?.id != entry.id { return }
        loadHistoryPage(reset: false)
    }

    func setHistoryFolderFilter(_ folderId: String?) {
        guard historyFolderFilterId != folderId else { return }
        historyFolderFilterId = folderId
        reloadHistory()
    }

    private func loadHistoryPage(reset: Bool) {
        guard !isLoadingHistory else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }

        let directoryPath = historyFilterDirectoryPath
        if reset {
            history = []
            historyTotalCount = db.withLock { db in (try? db.countHistory(directoryPath: directoryPath)) ?? 0 }
        }

        let offset = reset ? 0 : history.count
        let limit = historyPageSize
        let page = db.withLock { db in (try? db.listHistory(limit: limit, offset: offset, directoryPath: directoryPath)) ?? [] }
        history = reset ? page : history + page
        hasMoreHistory = history.count < historyTotalCount
    }

    private var historyFilterDirectoryPath: String? {
        guard let historyFolderFilterId else { return nil }
        return folders.first(where: { $0.id == historyFolderFilterId })?.path
    }

    private func startWatchingEnabledFolders() {
        guard !paused else { return }
        let allFolders = db.withLock { db in (try? db.listFolders()) ?? [] }
        for folder in allFolders where folder.enabled {
            coordinator.add(folder.path)
        }
    }

    func addFolder(path: String) {
        let normalizedPath = (path as NSString).standardizingPath
        if let existingFolder = folders.first(where: { ($0.path as NSString).standardizingPath == normalizedPath }) {
            selectedFolderId = existingFolder.id
            detailRoute = .rules
            reloadRules()
            showNotice(
                title: "Folder already watched",
                message: "\"\((existingFolder.path as NSString).lastPathComponent)\" is already in your watched folders."
            )
            return
        }

        let folder = WatchedFolder(path: normalizedPath)
        do {
            try db.withLock { db in try db.insertFolder(folder) }
            if !paused { coordinator.add(normalizedPath) }
            reloadFolders()
        } catch {
            showError(error)
        }
    }

    func removeFolder(_ folder: WatchedFolder) {
        let removedRuleIds = db.withLock { db in
            Set(((try? db.listRules(folderId: folder.id)) ?? []).map(\.id))
        }
        coordinator.remove(folder.path)
        db.withLock { db in try? db.deleteFolder(folder.id) }
        clearRuleExpansionState(removedRuleIds)
        reloadFolders()
    }

    func updateFolderPath(_ folder: WatchedFolder, path: String) {
        guard !isRunningNow && !isPreviewing else {
            showNotice(
                title: "Folder is busy",
                message: "Wait for the current Run Now or Dry Run to finish before changing this watched folder."
            )
            return
        }
        guard !coordinator.isProcessing(in: folder.path) else {
            showNotice(
                title: "Folder is busy",
                message: "Forel is still processing a file event in this watched folder. Try again once it finishes."
            )
            return
        }

        let normalizedPath = (path as NSString).standardizingPath
        let oldPath = (folder.path as NSString).standardizingPath
        guard normalizedPath != oldPath else { return }

        if let existingFolder = folders.first(where: { existing in
            existing.id != folder.id && (existing.path as NSString).standardizingPath == normalizedPath
        }) {
            selectedFolderId = existingFolder.id
            detailRoute = .rules
            reloadRules()
            showNotice(
                title: "Folder already watched",
                message: "\"\((existingFolder.path as NSString).lastPathComponent)\" is already in your watched folders."
            )
            return
        }

        do {
            try db.withLock { db in try db.updateFolderPath(folder.id, path: normalizedPath) }
            if folder.enabled, !paused {
                coordinator.remove(folder.path)
                coordinator.add(normalizedPath)
            }
            reloadFolders()
            reloadRules()
            if historyFolderFilterId == folder.id {
                reloadHistory()
            }
        } catch {
            showError(error)
        }
    }

    func toggleFolder(_ folder: WatchedFolder, enabled: Bool) {
        db.withLock { db in try? db.toggleFolder(folder.id, enabled: enabled) }
        if enabled, !paused {
            coordinator.add(folder.path)
        } else {
            coordinator.remove(folder.path)
        }
        reloadFolders()
    }

    func reorderFolders(_ folderIds: [String]) {
        db.withLock { db in try? db.reorderFolders(folderIds) }
        reloadFolders()
    }

    func saveRule(_ rule: Rule) {
        do {
            let isUpdate = rules.contains(where: { $0.id == rule.id })
            try db.withLock { db in
                if isUpdate {
                    try db.updateRule(rule)
                } else {
                    try db.insertRule(rule)
                }
            }
            reloadRules()
        } catch {
            showError(error)
        }
    }

    func deleteRule(_ rule: Rule) {
        db.withLock { db in try? db.deleteRule(rule.id) }
        clearRuleExpansionState(rule.id)
        reloadRules()
    }

    func toggleRule(_ rule: Rule, enabled: Bool) {
        db.withLock { db in try? db.toggleRule(rule.id, enabled: enabled) }
        reloadRules()
    }

    func reorderRules(_ ruleIds: [String]) {
        guard let folderId = selectedFolderId else { return }
        db.withLock { db in try? db.reorderRules(folderId: folderId, ruleIds: ruleIds) }
        reloadRules()
    }

    /// Runs all enabled rules in the selected folder against every file
    /// currently in it (a manual "Run Now"), bounded by each rule's scope.
    func runNow() {
        guard !isRunningNow else { return }
        guard let folder = folders.first(where: { $0.id == selectedFolderId }) else { return }
        let folderRules = rules.filter(\.enabled)
        guard !folderRules.isEmpty else {
            showRunNowMessage("Run complete — no enabled rules")
            return
        }
        isRunningNow = true
        Task {
            defer { isRunningNow = false }
            let allHistory = await Task.detached(priority: .userInitiated) {
                let maxDepth = RuleEngine.maxRuleDepth(folderRules)
                let entries = RuleEngine.walkEntries(root: folder.path, maxDepth: maxDepth)
                let batchId = UUID().uuidString
                var allHistory: [HistoryEntry] = []
                for entry in entries {
                    let (_, history) = RuleEngine.run(path: entry.path, depth: entry.depth, rules: folderRules, batchId: batchId, root: folder.path)
                    allHistory.append(contentsOf: history)
                }
                return allHistory
            }.value
            if !allHistory.isEmpty {
                db.withLock { db in try? db.insertHistoryEntries(allHistory) }
            }
            reloadHistory()
            showRunNowMessage(
                allHistory.isEmpty
                    ? "Run complete — no matching files"
                    : "Run complete — \(allHistory.count) action\(allHistory.count == 1 ? "" : "s") applied"
            )
        }
    }

    /// Shows a transient confirmation after a manual run, auto-dismissed a
    /// few seconds later — unless a newer run has already replaced it.
    private func showRunNowMessage(_ message: String) {
        let id = UUID()
        runNowMessageId = id
        runNowMessage = message
        Task {
            try? await Task.sleep(for: .seconds(3))
            if runNowMessageId == id { runNowMessage = nil }
        }
    }

    /// Runs Dry Run off the main thread — scanning every file in a large
    /// folder can take a while, so `isPreviewing` drives a loading state on
    /// the button instead of freezing the UI. Sets `previewResult` when done,
    /// which the view presents as a sheet.
    func preview() {
        guard !isPreviewing else { return }
        guard let folder = folders.first(where: { $0.id == selectedFolderId }) else {
            previewResult = PreviewResult(filesScanned: 0, matches: [])
            return
        }
        let folderRules = rules.filter(\.enabled)
        guard !folderRules.isEmpty else {
            previewResult = PreviewResult(filesScanned: 0, matches: [])
            return
        }
        let matchLimit = previewMatchLimit
        isPreviewing = true
        Task {
            defer { isPreviewing = false }
            previewResult = await Task.detached(priority: .userInitiated) {
                let maxDepth = RuleEngine.maxRuleDepth(folderRules)
                var filesScanned = 0
                var matches: [FilePreview] = []
                var reachedMatchLimit = false
                RuleEngine.forEachEntry(root: folder.path, maxDepth: maxDepth) { entry in
                    filesScanned += 1
                    guard let match = RuleEngine.previewFile(path: entry.path, depth: entry.depth, rules: folderRules) else {
                        return
                    }
                    if matches.count < matchLimit {
                        matches.append(match)
                    } else {
                        reachedMatchLimit = true
                    }
                }
                return PreviewResult(
                    filesScanned: filesScanned,
                    matches: matches,
                    matchLimit: matchLimit,
                    reachedMatchLimit: reachedMatchLimit
                )
            }.value
        }
    }

    /// The enabled rules and watched root currently covering `path`, if
    /// watching is actually active there — empty/`nil` when paused or the
    /// folder is disabled, since the watcher wouldn't reprocess anything in
    /// that case regardless of what the rules say.
    private func activeRules(coveringRestorePath path: String) -> (rules: [Rule], watchedRoot: String?) {
        guard !paused else { return ([], nil) }
        return db.withLock { db -> (rules: [Rule], watchedRoot: String?) in
            guard let folder = try? db.folderForPath(path), folder.enabled else { return ([], nil) }
            let rules = (try? db.listRules(folderId: folder.id))?.filter(\.enabled) ?? []
            return (rules, folder.path)
        }
    }

    /// Reverses `entry` only if `UndoChecker` finds it safe right now —
    /// never a silent best-effort rollback on a file that no longer matches
    /// what Forel originally changed.
    func undo(_ entry: HistoryEntry) {
        guard entry.status == .applied else { return }
        let context = activeRules(coveringRestorePath: entry.originalPath)
        switch UndoChecker.evaluate(entry, activeRules: context.rules, watchedRoot: context.watchedRoot) {
        case .unsafe(let reason):
            showNotice(title: "Can't undo this action", message: reason)
        case .safe:
            do {
                try ActionExecutor.revert(Undo.fromJSON(entry.undo))
                try db.withLock { db in try db.markHistoryUndone(entry.id) }
                reloadHistory()
            } catch {
                showError(error)
            }
        }
    }

    /// Reverts every still-applied, reversible entry in a batch that
    /// `UndoChecker` finds safe, in reverse application order so chained
    /// actions on the same file (e.g. tag then rename) revert correctly.
    /// Entries that aren't safe — including ones that would collide with
    /// another restore in the same batch — are left untouched and reported,
    /// rather than attempted.
    func undoBatch(_ batchId: String) {
        let entries = db.withLock { db in (try? db.listHistoryBatch(batchId)) ?? [] }
        let reversible = entries.filter { $0.status == .applied && $0.reversible }
        let colliding = UndoChecker.collidingRestoreTargets(reversible)

        var failures: [String] = []
        for entry in reversible.reversed() {
            if colliding.contains(entry.id) {
                failures.append("\((entry.originalPath as NSString).lastPathComponent): would collide with another file being restored in this batch.")
                continue
            }
            let context = activeRules(coveringRestorePath: entry.originalPath)
            switch UndoChecker.evaluate(entry, activeRules: context.rules, watchedRoot: context.watchedRoot) {
            case .unsafe(let reason):
                failures.append("\((entry.originalPath as NSString).lastPathComponent): \(reason)")
            case .safe:
                do {
                    try ActionExecutor.revert(Undo.fromJSON(entry.undo))
                    try db.withLock { db in try db.markHistoryUndone(entry.id) }
                } catch {
                    failures.append("\((entry.originalPath as NSString).lastPathComponent): \(error)")
                }
            }
        }

        if !failures.isEmpty {
            showError("Some actions could not be undone:\n" + failures.joined(separator: "\n"))
        }
        reloadHistory()
    }

    func togglePaused() {
        paused.toggle()
        let isPaused = paused
        let allFolders = db.withLock { db -> [WatchedFolder] in
            try? db.setSetting("paused", isPaused ? "1" : "0")
            return (try? db.listFolders()) ?? []
        }
        for folder in allFolders {
            if paused {
                coordinator.remove(folder.path)
            } else if folder.enabled {
                coordinator.add(folder.path)
            }
        }
    }

    private func showNotice(title: String, message: String) {
        alertTitle = title
        errorMessage = message
    }

    private func showError(_ error: any Error) {
        showError("\(error)")
    }

    private func showError(_ message: String) {
        alertTitle = "Error"
        errorMessage = message
    }
}
