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

public enum SyncDeletePolicy: String, CaseIterable, Sendable {
    case keepOtherSide = "keep_other_side"
    case moveToTrash = "move_to_trash"
    case delete

    public var label: String {
        switch self {
        case .keepOtherSide: return "Keep counterpart"
        case .moveToTrash: return "Move counterpart to Trash"
        case .delete: return "Delete counterpart permanently"
        }
    }
}

/// Sync Folders mirrors each file of the watched folder at the same relative
/// path in the destination. Folders are created empty, their files being
/// synced one by one; packages (.app, .rtfd…) are copied whole, like files.
extension ActionExecutor {
    public static func syncDeletePolicy(_ action: Action) -> SyncDeletePolicy {
        guard let raw = action.params[ActionParam.syncDeletePolicy]?.stringValue else { return .keepOtherSide }
        return SyncDeletePolicy(rawValue: raw) ?? .keepOtherSide
    }

    static func planSyncFolders(_ action: Action, path: String, root: String?) throws -> ActionPlan {
        let sourceRoot = root ?? (path as NSString).deletingLastPathComponent
        if try isSyncDestinationPath(action, path: path) {
            return ActionPlan(kind: action.kind, description: "Already synced", sourcePath: path,
                              targetPath: nil, status: .wouldSkip, finalPath: path, copiedPath: nil, isTerminal: false)
        }
        let naiveTarget = try syncCounterpartPath(action, path: path, root: sourceRoot)
        let conflicts = FileManager.default.fileExists(atPath: naiveTarget)

        if isAlreadySynced(path, naiveTarget) {
            return ActionPlan(
                kind: action.kind,
                description: "Already synced",
                sourcePath: path,
                targetPath: naiveTarget,
                status: .wouldSkip,
                finalPath: path,
                copiedPath: nil,
                isTerminal: false
            )
        }

        let description: String
        if isSyncedAsFolder(path) {
            description = conflicts ? "Sync folder at \(naiveTarget)" : "Create synced folder at \(naiveTarget)"
        } else {
            description = conflicts ? "Sync to \(naiveTarget), updating existing file" : "Sync to \(naiveTarget)"
        }
        return ActionPlan(
            kind: action.kind,
            description: description,
            sourcePath: path,
            targetPath: naiveTarget,
            status: .wouldRun,
            finalPath: path,
            copiedPath: naiveTarget,
            isTerminal: false,
            warning: destinationWarning(try syncDestinationRoot(action))
        )
    }

    static func syncFolders(_ action: Action, path: String, root: String?) throws -> Applied {
        guard try !isSyncDestinationPath(action, path: path) else { return Applied(newPath: path, undo: .none) }
        let sourceRoot = root ?? (path as NSString).deletingLastPathComponent
        let syncTarget = try syncCounterpartPath(action, path: path, root: sourceRoot)
        let syncSource = syncSourcePath(root: sourceRoot, path: path)
        return try explainingDisconnectedVolume(syncTarget) {
            // Throws before touching the mirror when the source is gone.
            let source = try FileManager.default.attributesOfItem(atPath: path)
            if (source[.type] as? FileAttributeType) == .typeDirectory, !RuleEngine.isPackage(path) {
                let target = try? FileManager.default.attributesOfItem(atPath: syncTarget)
                if let type = target?[.type] as? FileAttributeType, type != .typeDirectory {
                    try clearSyncTarget(syncTarget)
                }
                // A folder that was already there isn't Forel's to remove.
                if !isSyncedAsFolder(syncTarget) {
                    try FileManager.default.createDirectory(atPath: syncTarget, withIntermediateDirectories: true)
                    markSyncCopy(syncTarget, of: syncSource)
                }
                return Applied(newPath: path, undo: .none, copiedPath: syncTarget)
            }

            // copyItem copies a symbolic link itself, without traversing the
            // directory it may point to.
            try clearSyncTarget(syncTarget)
            let parent = (syncTarget as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: path, toPath: syncTarget)
            markSyncCopy(syncTarget, of: syncSource)
            return Applied(newPath: path, undo: .none, copiedPath: syncTarget)
        }
    }

    /// Where `path`, inside the watched `root`, is mirrored in the target.
    public static func syncCounterpartPath(_ action: Action, path: String, root: String) throws -> String {
        let targetRoot = try syncDestinationRoot(action)
        guard let relative = relativePath(root: root, path: path) else {
            throw ActionError("Sync folders can only sync files inside the watched folder")
        }
        let counterpart = relative.isEmpty ? targetRoot : (targetRoot as NSString).appendingPathComponent(relative)
        // The configured root may be an alias selected by the user. Below
        // that root, never follow parent symlinks, even ones pointing to a
        // different counterpart within the same destination.
        var parent = targetRoot
        for part in (relative as NSString).pathComponents.dropLast() {
            parent = (parent as NSString).appendingPathComponent(part)
            let attributes = try? FileManager.default.attributesOfItem(atPath: parent)
            if (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink {
                throw ActionError("The sync destination contains a symbolic link in a parent folder. No file was changed.")
            }
        }
        return counterpart
    }

    /// The mirror itself is never an input, including for removal events.
    static func isSyncDestinationPath(_ action: Action, path: String) throws -> Bool {
        let target = try syncDestinationRoot(action)
        if relativePath(root: target, path: path) != nil { return true }
        // Compare the item's containing directory, not the destination of a
        // leaf symlink: the symlink itself is an input we can safely copy.
        let parent = try resolvedSyncPath((path as NSString).deletingLastPathComponent)
        let source = parent.appendingPathComponent((path as NSString).lastPathComponent).pathComponents
        return try source.starts(with: resolvedSyncPath(target).pathComponents)
    }

    static func syncDestinationRoot(_ action: Action) throws -> String {
        let value = normalizedPath(try stringParam(action, ActionParam.destination, "SyncFolders"))
        guard value.hasPrefix("/"), !value.contains("\0") else {
            throw ActionError("Choose an absolute destination folder for Sync Folders.")
        }
        return value
    }

    /// A real folder, whose files are synced one by one. A package is a
    /// folder too, but folder scans don't look inside it.
    static func isSyncedAsFolder(_ path: String) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.type] as? FileAttributeType) == .typeDirectory && !RuleEngine.isPackage(path)
    }

    /// The package inside `root` that contains `path`, if any. A package is
    /// synced whole, so a change inside it updates the whole copy.
    static func syncPackage(containing path: String, root: String) -> String? {
        guard let relative = relativePath(root: root, path: path) else { return nil }
        var current = normalizedPath(root)
        for part in (relative as NSString).pathComponents.dropLast() {
            current = (current as NSString).appendingPathComponent(part)
            if RuleEngine.isPackage(current) { return current }
        }
        return nil
    }

    /// `path` relative to `root`: "" for `root` itself, nil when `path`
    /// isn't inside it.
    static func relativePath(root: String, path: String) -> String? {
        let rootComponents = (normalizedPath(root) as NSString).pathComponents
        let pathComponents = (normalizedPath(path) as NSString).pathComponents
        guard pathComponents.count >= rootComponents.count else { return nil }
        guard Array(pathComponents.prefix(rootComponents.count)) == rootComponents else { return nil }
        let suffix = pathComponents.dropFirst(rootComponents.count)
        guard !suffix.isEmpty else { return "" }
        return NSString.path(withComponents: Array(suffix))
    }

    /// Moves `path` to the Trash of its own disk, so a mirror on an external
    /// disk isn't copied back onto the Mac. Returns where it ended up.
    static func moveToTrashOnItsVolume(_ path: String) throws -> String {
        var trashed: NSURL?
        if (try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &trashed)) != nil,
           let url = trashed as URL? {
            return url.path
        }
        // Some network shares have no Trash: use the user's.
        let target = uniqueDest(dir: try trashDir(), fileName: (path as NSString).lastPathComponent)
        try FileManager.default.moveItem(atPath: path, toPath: target)
        return target
    }

    private static func resolvedSyncPath(_ path: String) throws -> URL {
        // Resolve the existing prefix first: destinations may contain parent
        // directories that have not been created yet.
        var existing = URL(fileURLWithPath: normalizedPath(path)).standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            let attributes = try? FileManager.default.attributesOfItem(atPath: existing.path)
            if (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink {
                throw ActionError("The sync path contains a broken symbolic link. Choose a reachable destination folder.")
            }
            missing.append(existing.lastPathComponent)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for part in missing.reversed() { resolved.appendPathComponent(part) }
        return resolved
    }

    /// A folder is synced once it exists on the other side, its files being
    /// synced one by one. A file is when its size and modification date match,
    /// which a copy keeps. A package, copied whole, is when everything in it is.
    private static func isAlreadySynced(_ path: String, _ counterpart: String) -> Bool {
        guard let source = try? FileManager.default.attributesOfItem(atPath: path),
              let other = try? FileManager.default.attributesOfItem(atPath: counterpart),
              let type = source[.type] as? FileAttributeType, type == other[.type] as? FileAttributeType
        else { return false }
        if type == .typeDirectory {
            guard RuleEngine.isPackage(path) else { return true }
            guard let items = FileManager.default.subpaths(atPath: path),
                  let others = FileManager.default.subpaths(atPath: counterpart),
                  Set(items) == Set(others) else { return false }
            return items.allSatisfy { item in
                isAlreadySynced((path as NSString).appendingPathComponent(item),
                                (counterpart as NSString).appendingPathComponent(item))
            }
        }
        if type == .typeSymbolicLink {
            guard let source = try? FileManager.default.destinationOfSymbolicLink(atPath: path),
                  let target = try? FileManager.default.destinationOfSymbolicLink(atPath: counterpart) else { return false }
            return source == target
        }
        return source[.size] as? UInt64 == other[.size] as? UInt64
            && source[.modificationDate] as? Date == other[.modificationDate] as? Date
    }

    /// Makes room for a new copy: whatever is at `target`, a dangling link
    /// included (which `fileExists` ignores), goes to the Trash.
    private static func clearSyncTarget(_ target: String) throws {
        guard (try? FileManager.default.attributesOfItem(atPath: target)) != nil else { return }
        _ = try moveToTrashOnItsVolume(target)
    }

    /// Every item Forel creates in the destination records the source it was
    /// copied from, so that removals only touch the copy of what is gone:
    /// never what the user put there, a copy of another watched folder
    /// syncing to the same place, or a duplicate the user made (the Finder
    /// keeps the marker). It stays with the item, unlike history, which is
    /// purged after a while. Without it (a disk that can't store it), the
    /// item is simply kept.
    private static let syncCopyMarker = "app.forel.sync-copy"

    static func markSyncCopy(_ path: String, of source: String) {
        let value = Array(source.utf8)
        _ = setxattr(path, syncCopyMarker, value, value.count, 0, XATTR_NOFOLLOW)
    }

    static func isSyncCopy(_ path: String, of source: String) -> Bool {
        let size = getxattr(path, syncCopyMarker, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return false }
        var value = [UInt8](repeating: 0, count: size)
        guard getxattr(path, syncCopyMarker, &value, size, 0, XATTR_NOFOLLOW) == size else { return false }
        return String(decoding: value, as: UTF8.self) == source
    }

    /// `path` spelled from the watched folder's own path, the same way
    /// whether it comes from FSEvents, Run Now or a removal.
    static func syncSourcePath(root: String, path: String) -> String {
        guard let relative = relativePath(root: root, path: path), !relative.isEmpty else { return normalizedPath(path) }
        return (normalizedPath(root) as NSString).appendingPathComponent(relative)
    }
}

/// Removals compare the watched folder with the destination instead of
/// relying on FSEvents, which may be coalesced, dropped, or missed while
/// Forel isn't running. Dry Run, Run Now and the watcher all use them.
extension RuleEngine {
    public static func previewSyncRemovals(rules: [Rule], root: String, path: String, isPro: Bool) -> [FilePreview] {
        var previews: [FilePreview] = []
        for (rule, action) in syncActions(rules) {
            let policy = ActionExecutor.syncDeletePolicy(action)
            let description = policy == .delete
                ? "Delete permanently, removed from the watched folder"
                : "Move to Trash, removed from the watched folder"
            let items: [String]
            do {
                items = try syncRemovals(rule: rule, action: action, root: root, path: path, allowOCR: isPro)
            } catch {
                previews.append(FilePreview(path: path, name: (path as NSString).lastPathComponent, rules: [
                    RulePreview(ruleId: rule.id, ruleName: rule.name, conditions: [], actions: [
                        ActionPreview(kind: action.kind, description: "Preview unavailable: \(error)", sourcePath: path, targetPath: nil, status: .wouldSkip),
                    ]),
                ]))
                continue
            }
            for item in items {
                previews.append(FilePreview(path: item, name: (item as NSString).lastPathComponent, rules: [
                    RulePreview(ruleId: rule.id, ruleName: rule.name, conditions: [], actions: [
                        ActionPreview(kind: action.kind, description: description, sourcePath: item, targetPath: nil, status: .wouldRun),
                    ]),
                ]))
            }
        }
        return previews
    }

    public static func runSyncRemovals(rules: [Rule], root: String, path: String, batchId: String, isPro: Bool) -> [HistoryEntry] {
        var history: [HistoryEntry] = []
        for (rule, action) in syncActions(rules) {
            func entry(_ originalPath: String, _ resultPath: String, undo: Undo = .none,
                       status: HistoryStatus = .applied, message: String) -> HistoryEntry {
                let identity = FileFingerprint.identity(resultPath)
                return HistoryEntry(batchId: batchId, ruleId: rule.id, ruleName: rule.name, actionKind: action.kind,
                                    originalPath: originalPath, resultPath: resultPath, undo: undo.toJSON(),
                                    reversible: undo.isReversible, status: status, message: message,
                                    resultVolumeId: identity?.volumeId, resultFileId: identity?.fileId)
            }
            let items: [String]
            do {
                items = try syncRemovals(rule: rule, action: action, root: root, path: path, allowOCR: isPro)
            } catch {
                history.append(entry(path, path, status: .failed, message: String(describing: error)))
                continue
            }
            // The copy is what gets removed and restored, so it is the
            // entry's original path, for Undo too.
            for item in items {
                do {
                    if ActionExecutor.syncDeletePolicy(action) == .delete {
                        try FileManager.default.removeItem(atPath: item)
                        history.append(entry(item, item, message: "Removed from the watched folder, so its copy was deleted permanently."))
                    } else {
                        let trashed = try ActionExecutor.moveToTrashOnItsVolume(item)
                        history.append(entry(item, trashed, undo: .move(from: item, to: trashed),
                                             message: "Removed from the watched folder, so its copy was moved to the Trash."))
                    }
                } catch {
                    history.append(entry(item, item, status: .failed, message: String(describing: error)))
                }
            }
        }
        return history
    }

    private static func syncActions(_ rules: [Rule]) -> [(Rule, Action)] {
        rules.flatMap { rule in
            rule.actions
                .filter { $0.kind == .syncFolders && ActionExecutor.syncDeletePolicy($0) != .keepOtherSide }
                .map { (rule, $0) }
        }
    }

    /// The copies in the destination that `action` should remove because
    /// their original is gone from the watched `root`: at `path` itself
    /// when it no longer exists, otherwise anywhere below it. A copy goes
    /// only if Forel made it and the rule still covers it; a folder goes as
    /// one item only when everything in it does.
    private static func syncRemovals(rule: Rule, action: Action, root: String, path: String, allowOCR: Bool) throws -> [String] {
        // The watched folder itself gone (renamed, moved to the Trash, its
        // disk ejected) is not a deletion inside it: the mirror stays.
        guard FileManager.default.fileExists(atPath: root),
              ActionExecutor.syncPackage(containing: path, root: root) == nil,
              try !ActionExecutor.isSyncDestinationPath(action, path: path) else { return [] }
        let targetRoot = try ActionExecutor.syncDestinationRoot(action)
        let counterpart = try ActionExecutor.syncCounterpartPath(action, path: path, root: root)
        var removals: [String] = []

        func exists(_ path: String) -> Bool {
            // Also true for dangling links, which fileExists ignores.
            (try? FileManager.default.attributesOfItem(atPath: path)) != nil
        }

        func children(_ folder: String) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
                .filter { !SystemFileFilter.isExcluded($0) }
                .sorted()
        }

        /// Whether the whole of `item`, whose original `source` is gone, can go.
        /// When only part of it can, that part is added to `removals`.
        func collectOrphan(_ item: String, of source: String) -> Bool {
            var removable: [String] = []
            var whole = true
            if ActionExecutor.isSyncedAsFolder(item) {
                for name in children(item) {
                    let child = (item as NSString).appendingPathComponent(name)
                    if collectOrphan(child, of: (source as NSString).appendingPathComponent(name)) {
                        removable.append(child)
                    } else {
                        whole = false
                    }
                }
            }
            if whole, ActionExecutor.isSyncCopy(item, of: ActionExecutor.syncSourcePath(root: root, path: source)),
               let depth = pathDepth(root: targetRoot, path: item),
               ruleMatches(rule, path: item, depth: depth, allowOCR: allowOCR) {
                return true
            }
            removals += removable
            return false
        }

        func compare(source: String, copy: String) throws {
            guard ActionExecutor.isSyncedAsFolder(copy) else { return }
            for name in children(copy) {
                let sourceChild = (source as NSString).appendingPathComponent(name)
                let copyChild = (copy as NSString).appendingPathComponent(name)
                if !exists(sourceChild) {
                    if collectOrphan(copyChild, of: sourceChild) { removals.append(copyChild) }
                } else if ActionExecutor.isSyncedAsFolder(sourceChild),
                          try !ActionExecutor.isSyncDestinationPath(action, path: sourceChild) {
                    try compare(source: sourceChild, copy: copyChild)
                }
            }
        }

        if !exists(path) {
            if exists(counterpart), collectOrphan(counterpart, of: path) { removals.append(counterpart) }
        } else if ActionExecutor.isSyncedAsFolder(path) {
            try compare(source: path, copy: counterpart)
        }
        return removals
    }
}
