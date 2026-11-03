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

extension WatcherCoordinator {
    /// Removes, from every Sync Folders mirror covering `path`, the copies of
    /// what is gone at or below it.
    func syncRemovals(at path: String, waitsForSettledFiles: Bool) {
        let (scopes, isPro) = db.withLock { db -> ([(root: String, rules: [Rule])], Bool) in
            let folders = ((try? db.listFolders()) ?? []).filter(\.enabled)
            let scopes = folders.compactMap { folder -> (root: String, rules: [Rule])? in
                guard ActionExecutor.relativePath(root: folder.path, path: path) != nil else { return nil }
                return (folder.path, (try? db.executionRules(folderID: folder.id, isPro: self.isPro)) ?? [])
            }
            return (scopes, self.isPro)
        }
        for scope in scopes {
            if let package = ActionExecutor.syncPackage(containing: path, root: scope.root) {
                // A package is copied whole: what changed inside it updates it.
                syncChange(insidePackage: package, waitsForSettledFiles: waitsForSettledFiles)
                continue
            }
            let history = RuleEngine.runSyncRemovals(rules: scope.rules, root: scope.root, path: path,
                                                     batchId: UUID().uuidString, isPro: isPro)
            guard !history.isEmpty else { continue }
            db.withLock { db in try? db.insertHistoryEntries(history) }
            onHistoryRecorded?()
        }
    }

    /// The package enclosing `path`, when the folder watching it has a
    /// Sync Folders action.
    func syncedPackage(containing path: String) -> String? {
        db.withLock { db in
            guard let folder = try? db.folderForPath(path),
                  let package = ActionExecutor.syncPackage(containing: path, root: folder.path) else { return nil }
            let rules = (try? db.executionRules(folderID: folder.id, isPro: isPro)) ?? []
            return rules.contains { $0.actions.contains { $0.kind == .syncFolders } } ? package : nil
        }
    }

    /// Updates the copy of a package something changed inside. Editing a
    /// file deep inside a package leaves the package's own size and date
    /// unchanged, so its cached state is dropped to evaluate it again.
    func syncChange(insidePackage package: String, waitsForSettledFiles: Bool) {
        db.withLock { db in try? db.deleteWatchedPathState(package) }
        handle(event: .pathModified(package), waitsForSettledFiles: waitsForSettledFiles)
    }

    /// The rules' Sync Folders actions alone, for changes that must not
    /// replay arrival actions.
    static func syncOnlyRules(_ rules: [Rule]) -> [Rule] {
        rules.compactMap { rule in
            var sync = rule
            sync.actions = rule.actions.filter { $0.kind == .syncFolders }
            return sync.actions.isEmpty ? nil : sync
        }
    }
}
