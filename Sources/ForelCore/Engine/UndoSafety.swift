import Foundation

/// Whether reversing a past action is currently safe — never a silent
/// best-effort rollback on a file that no longer matches what Forel
/// actually changed.
public enum UndoSafety: Equatable, Sendable {
    case safe
    case unsafe(reason: String)
}

/// Decides whether undoing a `HistoryEntry` is safe right now, against the
/// live filesystem and the rules currently active for it. Performs no
/// filesystem mutation itself — callers act on the result.
public enum UndoChecker {
    /// `activeRules`/`watchedRoot` are the enabled rules and watched-folder
    /// root currently covering `entry.originalPath`, if watching is active
    /// there — pass empty/`nil` when paused or the folder is disabled.
    /// Without this check, undoing a move back into a folder an active rule
    /// still watches would just have the watcher immediately redo what the
    /// user asked to undo.
    public static func evaluate(_ entry: HistoryEntry, activeRules: [Rule] = [], watchedRoot: String? = nil) -> UndoSafety {
        guard entry.reversible else {
            return .unsafe(reason: "This action cannot be undone.")
        }
        guard entry.status == .applied else {
            return .unsafe(reason: "This action is not currently applied.")
        }

        let undo = Undo.fromJSON(entry.undo)
        switch undo {
        case .none:
            return .unsafe(reason: "This action cannot be undone.")
        case .move(let from, let to):
            guard FileManager.default.fileExists(atPath: to) else {
                return .unsafe(reason: "The file Forel moved no longer exists at \((to as NSString).lastPathComponent).")
            }
            guard !FileManager.default.fileExists(atPath: from) else {
                return .unsafe(reason: "A file already exists at the original location.")
            }
            if let mismatch = identityMismatchReason(entry, currentPath: to) {
                return .unsafe(reason: mismatch)
            }
        case .copy(let copy):
            guard FileManager.default.fileExists(atPath: copy) else {
                return .unsafe(reason: "The copy Forel created no longer exists.")
            }
        case .addTags, .removeTags, .color:
            guard FileManager.default.fileExists(atPath: entry.resultPath) else {
                return .unsafe(reason: "The file no longer exists at its expected location.")
            }
        }

        // Copy-undo only deletes the copy — the original is never restored
        // anywhere, so there's nothing for a rule to reprocess.
        if !isCopyUndo(undo), let ruleName = ruleThatWouldReprocess(entry, activeRules: activeRules, watchedRoot: watchedRoot) {
            return .unsafe(reason: "The rule \"\(ruleName)\" would immediately reprocess this file once it's restored.")
        }

        return .safe
    }

    /// Entries (already filtered to reversible+applied) whose undo would
    /// restore two different files to the same path — undoing both would
    /// have the second clobber the first. Returns the ids to leave alone.
    public static func collidingRestoreTargets(_ entries: [HistoryEntry]) -> Set<String> {
        var idsByTarget: [String: [String]] = [:]
        for entry in entries {
            guard let target = restoreTarget(entry) else { continue }
            idsByTarget[target, default: []].append(entry.id)
        }
        var colliding: Set<String> = []
        for ids in idsByTarget.values where ids.count > 1 {
            colliding.formUnion(ids)
        }
        return colliding
    }

    private static func restoreTarget(_ entry: HistoryEntry) -> String? {
        switch Undo.fromJSON(entry.undo) {
        case .move(let from, _): return from
        case .addTags(let path, _), .removeTags(let path, _), .color(let path, _): return path
        case .copy, .none: return nil
        }
    }

    private static func isCopyUndo(_ undo: Undo) -> Bool {
        if case .copy = undo { return true }
        return false
    }

    private static func identityMismatchReason(_ entry: HistoryEntry, currentPath: String) -> String? {
        guard let expectedVolume = entry.resultVolumeId, let expectedFile = entry.resultFileId else { return nil }
        guard let actual = FileFingerprint.identity(currentPath) else { return nil }
        guard actual.volumeId != expectedVolume || actual.fileId != expectedFile else { return nil }
        return "The file at this location is no longer the same file Forel moved."
    }

    /// Name of the first active rule that would plan a `wouldRun` action
    /// against `entry.originalPath` if the file were there right now.
    /// `name`/`extension` conditions work from the path string alone, so
    /// this is accurate for them even though the file doesn't physically
    /// exist there yet; conditions that read the file itself (size, tags,
    /// dates, contents) just won't match before the restore actually
    /// happens, which only means a rule keyed on those won't be caught here.
    private static func ruleThatWouldReprocess(_ entry: HistoryEntry, activeRules: [Rule], watchedRoot: String?) -> String? {
        guard let watchedRoot, !activeRules.isEmpty else { return nil }
        guard let depth = RuleEngine.pathDepth(root: watchedRoot, path: entry.originalPath) else { return nil }
        guard let preview = RuleEngine.previewFile(path: entry.originalPath, depth: depth, rules: activeRules) else { return nil }
        return preview.rules.first { $0.actions.contains { $0.status == .wouldRun } }?.ruleName
    }
}
