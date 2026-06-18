import Foundation
import ForelCore
import Combine

/// Central observable state for the SwiftUI app: owns the database, the
/// watcher coordinator, and the in-memory view of folders/rules. Mirrors the
/// surface of the old `useForelStore` Zustand store, but as direct Swift
@MainActor
final class AppModel: ObservableObject {
    /// Which screen the detail pane shows. Settings and History are in-app
    /// views (not separate windows) reached from the sidebar or menu bar.
    enum DetailRoute { case rules, history, settings }

    @Published var folders: [WatchedFolder] = []
    @Published var selectedFolderId: String?
    @Published var rules: [Rule] = []
    @Published var history: [HistoryEntry] = []
    @Published var paused: Bool = false
    @Published var errorMessage: String?
    @Published var detailRoute: DetailRoute = .rules
    @Published var appTheme: AppTheme = .system
    @Published var accentPreset: AccentPreset = .default
    /// Bumped whenever the accent colour changes, so views can force a full
    /// re-render with `.id(model.accentVersion)` — `ForelTheme.accent` is a
    /// plain static var, not itself observable.
    @Published var accentVersion: Int = 0
    @Published private(set) var isRunningNow = false
    @Published private(set) var runNowMessage: String?
    private var runNowMessageId: UUID?
    @Published private(set) var isPreviewing = false
    @Published var previewResult: PreviewResult?

    let db: Database
    private let coordinator: WatcherCoordinator

    init() throws {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.forel.app", isDirectory: true)
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
        let storedPaused = try? db.getSetting("paused")
        self.paused = storedPaused.map { $0 == "1" } ?? true

        let storedAccent = (try? db.getSetting("accent_color")) ?? nil
        let preset = storedAccent.flatMap(AccentPreset.init(rawValue:)) ?? .default
        self.accentPreset = preset
        ForelTheme.apply(preset)

        let storedTheme = (try? db.getSetting("theme")) ?? nil
        self.appTheme = storedTheme.flatMap(AppTheme.init(rawValue:)) ?? .system

        reloadFolders()
        startWatchingEnabledFolders()
    }

    func setAppTheme(_ theme: AppTheme) {
        appTheme = theme
        try? db.setSetting("theme", theme.rawValue)
    }

    func setAccentPreset(_ preset: AccentPreset) {
        accentPreset = preset
        ForelTheme.apply(preset)
        accentVersion += 1
        try? db.setSetting("accent_color", preset.rawValue)
    }

    func reloadFolders() {
        folders = (try? db.listFolders()) ?? []
        if let selectedFolderId, !folders.contains(where: { $0.id == selectedFolderId }) {
            self.selectedFolderId = folders.first?.id
        }
        if selectedFolderId == nil {
            selectedFolderId = folders.first?.id
        }
        reloadRules()
    }

    func reloadRules() {
        guard let folderId = selectedFolderId else { rules = []; return }
        rules = (try? db.listRules(folderId: folderId)) ?? []
    }

    func reloadHistory() {
        history = (try? db.listHistory()) ?? []
    }

    private func startWatchingEnabledFolders() {
        guard !paused else { return }
        for folder in (try? db.listFolders()) ?? [] where folder.enabled {
            coordinator.add(folder.path)
        }
    }

    func addFolder(path: String) {
        let folder = WatchedFolder(path: path)
        do {
            try db.insertFolder(folder)
            if !paused { coordinator.add(path) }
            reloadFolders()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func removeFolder(_ folder: WatchedFolder) {
        coordinator.remove(folder.path)
        try? db.deleteFolder(folder.id)
        reloadFolders()
    }

    func toggleFolder(_ folder: WatchedFolder, enabled: Bool) {
        try? db.toggleFolder(folder.id, enabled: enabled)
        if enabled, !paused {
            coordinator.add(folder.path)
        } else {
            coordinator.remove(folder.path)
        }
        reloadFolders()
    }

    func saveRule(_ rule: Rule) {
        do {
            if rules.contains(where: { $0.id == rule.id }) {
                try db.updateRule(rule)
            } else {
                try db.insertRule(rule)
            }
            reloadRules()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func deleteRule(_ rule: Rule) {
        try? db.deleteRule(rule.id)
        reloadRules()
    }

    func toggleRule(_ rule: Rule, enabled: Bool) {
        try? db.toggleRule(rule.id, enabled: enabled)
        reloadRules()
    }

    func reorderRules(_ ruleIds: [String]) {
        guard let folderId = selectedFolderId else { return }
        try? db.reorderRules(folderId: folderId, ruleIds: ruleIds)
        reloadRules()
    }

    /// Runs all enabled rules in the selected folder against every file
    /// currently in it (a manual "Run Now"), bounded by each rule's scope.
    func runNow() {
        guard !isRunningNow else { return }
        guard let folder = folders.first(where: { $0.id == selectedFolderId }) else { return }
        let folderRules = rules
        isRunningNow = true
        Task {
            defer { isRunningNow = false }
            let allHistory = await Task.detached(priority: .userInitiated) {
                let maxDepth = RuleEngine.maxRuleDepth(folderRules)
                let entries = RuleEngine.walkEntries(root: folder.path, maxDepth: maxDepth)
                let batchId = UUID().uuidString
                var allHistory: [HistoryEntry] = []
                for entry in entries {
                    let (_, history) = RuleEngine.evaluateFile(path: entry.path, depth: entry.depth, rules: folderRules, batchId: batchId, root: folder.path)
                    allHistory.append(contentsOf: history)
                }
                return allHistory
            }.value
            if !allHistory.isEmpty {
                try? db.insertHistoryEntries(allHistory)
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
        let folderRules = rules
        isPreviewing = true
        Task {
            defer { isPreviewing = false }
            previewResult = await Task.detached(priority: .userInitiated) {
                let maxDepth = RuleEngine.maxRuleDepth(folderRules)
                let entries = RuleEngine.walkEntries(root: folder.path, maxDepth: maxDepth)
                let matches = entries.compactMap { entry in
                    RuleEngine.previewFile(path: entry.path, depth: entry.depth, rules: folderRules)
                }
                return PreviewResult(filesScanned: entries.count, matches: matches)
            }.value
        }
    }

    func undo(_ entry: HistoryEntry) {
        guard entry.status == .applied else { return }
        do {
            try ActionExecutor.revert(Undo.fromJSON(entry.undo))
            try db.markHistoryUndone(entry.id)
            reloadHistory()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Reverts every still-applied, reversible entry in a batch. Entries are
    /// undone in reverse application order so chained actions on the same file
    /// (e.g. tag then rename) revert correctly.
    func undoBatch(_ batchId: String) {
        let entries = (try? db.listHistoryBatch(batchId)) ?? []
        let reversible = entries
            .filter { $0.status == .applied && $0.reversible }
            .reversed()

        var failures: [String] = []
        for entry in reversible {
            do {
                try ActionExecutor.revert(Undo.fromJSON(entry.undo))
                try db.markHistoryUndone(entry.id)
            } catch {
                failures.append("\((entry.originalPath as NSString).lastPathComponent): \(error)")
            }
        }

        if !failures.isEmpty {
            errorMessage = "Some actions could not be undone:\n" + failures.joined(separator: "\n")
        }
        reloadHistory()
    }

    func togglePaused() {
        paused.toggle()
        try? db.setSetting("paused", paused ? "1" : "0")
        let allFolders = (try? db.listFolders()) ?? []
        for folder in allFolders {
            if paused {
                coordinator.remove(folder.path)
            } else if folder.enabled {
                coordinator.add(folder.path)
            }
        }
    }
}
