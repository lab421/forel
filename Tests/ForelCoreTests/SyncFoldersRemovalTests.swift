import Foundation
import Testing
@testable import ForelCore

@Suite struct SyncFoldersRemovalTests {
    private func setup(policy: SyncDeletePolicy = .moveToTrash) throws -> (TempDir, Database, WatchedFolder, String) {
        let dir = TempDir()
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: dir.dir("Source"))
        let target = dir.dir("Target")
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "Sync", recursionDepth: nil)
        rule.actions = [makeAction(.syncFolders, .object([
            ActionParam.destination: .string(target),
            ActionParam.syncDeletePolicy: .string(policy.rawValue),
        ]), ruleId: rule.id)]
        try db.insertRule(rule)
        return (dir, db, folder, target)
    }

    /// Syncs the whole watched folder the way Run Now does.
    private func syncAll(_ db: Database, _ folder: WatchedFolder) throws {
        let rules = try db.listRules(folderId: folder.id)
        for entry in RuleEngine.walkEntries(root: folder.path, maxDepth: nil) {
            _ = RuleEngine.run(path: entry.path, depth: entry.depth, rules: rules, batchId: "sync", root: folder.path)
        }
    }

    /// Puts back what the removals moved to the Trash.
    private func restoreTrashed(_ db: Database) {
        for entry in (try? db.listHistory()) ?? [] where entry.reversible {
            try? ActionExecutor.revert(Undo.fromJSON(entry.undo))
        }
    }

    @Test(arguments: ["preview", "manual", "watcher"])
    func removalsAreTheSameInDryRunRunNowAndTheWatcher(execution: String) throws {
        let (dir, db, folder, target) = try setup()
        defer { restoreTrashed(db) }
        let file = dir.file("Source/a.txt", contents: "a")
        let sub = dir.dir("Source/Sub")
        _ = dir.file("Source/Sub/b.txt", contents: "b")
        _ = dir.file("Source/kept.txt", contents: "kept")
        try syncAll(db, folder)
        try FileManager.default.removeItem(atPath: file)
        try FileManager.default.moveItem(atPath: sub, toPath: dir.path + "/Away")
        let rules = try db.listRules(folderId: folder.id)
        let expected: Set = [target + "/a.txt", target + "/Sub"]

        switch execution {
        case "preview":
            let previews = RuleEngine.previewSyncRemovals(rules: rules, root: folder.path, path: folder.path, isPro: true)
            #expect(Set(previews.map(\.path)) == expected)
            #expect(previews.allSatisfy { $0.rules[0].actions[0].status == .wouldRun })
            #expect(FileManager.default.fileExists(atPath: target + "/a.txt"))
        case "manual":
            let history = RuleEngine.runSyncRemovals(rules: rules, root: folder.path, path: folder.path, batchId: "run", isPro: true)
            #expect(Set(history.map(\.originalPath)) == expected)
        default:
            let coordinator = WatcherCoordinator(db: db, settleInterval: 0.01)
            coordinator.enqueue(event: .pathRemoved(file))
            coordinator.enqueue(event: .pathArrived(sub))
            coordinator.waitForPendingEvents()
            #expect(Set(try db.listHistory().filter(\.reversible).map(\.originalPath)) == expected)
        }
        if execution != "preview" {
            #expect(!FileManager.default.fileExists(atPath: target + "/a.txt"))
            #expect(!FileManager.default.fileExists(atPath: target + "/Sub"))
        }
        #expect(FileManager.default.fileExists(atPath: target + "/kept.txt"))
    }

    @Test func filesForelDidNotCopyAreKept() throws {
        let (dir, db, folder, target) = try setup(policy: .delete)
        defer { withExtendedLifetime(dir) {} }
        let mine = target + "/mine.txt"
        let myFolder = target + "/Mine"
        try "mine".write(toFile: mine, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: myFolder, withIntermediateDirectories: true)
        try writeSyncCopy("copied", to: myFolder + "/copied.txt", from: folder.path + "/Mine/copied.txt")
        let rules = try db.listRules(folderId: folder.id)

        #expect(RuleEngine.previewSyncRemovals(rules: rules, root: folder.path, path: folder.path, isPro: true).map(\.path)
            == [myFolder + "/copied.txt"])
        _ = RuleEngine.runSyncRemovals(rules: rules, root: folder.path, path: folder.path, batchId: "run", isPro: true)

        #expect(try String(contentsOfFile: mine, encoding: .utf8) == "mine")
        #expect(FileManager.default.fileExists(atPath: myFolder))
        #expect(!FileManager.default.fileExists(atPath: myFolder + "/copied.txt"))
    }

    @Test func copiesOfAnotherWatchedFolderSyncingToTheSameDestinationAreKept() throws {
        let (dir, db, folder, target) = try setup(policy: .delete)
        let other = WatchedFolder(path: dir.dir("Other"))
        try db.insertFolder(other)
        var rule = try #require(try db.listRules(folderId: folder.id).first)
        rule.id = UUID().uuidString
        rule.folderId = other.id
        rule.actions = rule.actions.map { action in
            var copy = action
            copy.id = UUID().uuidString
            copy.ruleId = rule.id
            return copy
        }
        try db.insertRule(rule)
        _ = dir.file("Source/a.txt", contents: "a")
        _ = dir.file("Other/b.txt", contents: "b")
        try syncAll(db, folder)
        try syncAll(db, other)
        let rules = try db.listRules(folderId: folder.id)

        #expect(RuleEngine.previewSyncRemovals(rules: rules, root: folder.path, path: folder.path, isPro: true).isEmpty)
        _ = RuleEngine.runSyncRemovals(rules: rules, root: folder.path, path: folder.path, batchId: "run", isPro: true)

        #expect(try String(contentsOfFile: target + "/b.txt", encoding: .utf8) == "b")
    }

    @Test func aDuplicateTheUserMadeOfACopyIsKept() throws {
        let (dir, db, folder, target) = try setup(policy: .delete)
        _ = dir.file("Source/a.txt", contents: "a")
        try syncAll(db, folder)
        // Like the Finder's Duplicate, copyItem keeps the copy's marker.
        try FileManager.default.copyItem(atPath: target + "/a.txt", toPath: target + "/a copy.txt")
        let rules = try db.listRules(folderId: folder.id)

        _ = RuleEngine.runSyncRemovals(rules: rules, root: folder.path, path: folder.path, batchId: "run", isPro: true)

        #expect(FileManager.default.fileExists(atPath: target + "/a copy.txt"))
        #expect(FileManager.default.fileExists(atPath: target + "/a.txt"))
    }

    @Test func aTrashedCopyCanBeUndoneWhileTheRuleIsActive() throws {
        let (dir, db, folder, target) = try setup()
        defer { restoreTrashed(db) }
        let file = dir.file("Source/a.txt", contents: "a")
        try syncAll(db, folder)
        try FileManager.default.removeItem(atPath: file)
        let coordinator = WatcherCoordinator(db: db, settleInterval: 0.01)
        coordinator.enqueue(event: .pathRemoved(file))
        coordinator.waitForPendingEvents()

        let entry = try #require(try db.listHistory().first { $0.reversible })
        #expect(entry.originalPath == target + "/a.txt")
        let rules = try db.listRules(folderId: folder.id)
        #expect(UndoChecker.evaluate(entry, activeRules: rules, watchedRoot: folder.path) == .safe)
    }

    @Test func aRescanAfterDroppedEventsCatchesUpOnRemovals() throws {
        let (dir, db, folder, target) = try setup()
        defer { restoreTrashed(db) }
        _ = dir.dir("Source/Sub")
        let file = dir.file("Source/Sub/a.txt", contents: "a")
        try syncAll(db, folder)
        try FileManager.default.removeItem(atPath: file)

        let coordinator = WatcherCoordinator(db: db, settleInterval: 0.01)
        coordinator.enqueue(event: .rescanSubtree(folder.path))
        coordinator.waitForPendingEvents()

        #expect(!FileManager.default.fileExists(atPath: target + "/Sub/a.txt"))
        #expect(FileManager.default.fileExists(atPath: target + "/Sub"))
    }

    @Test func aRemovalInsideAPackageUpdatesTheWholeCopy() throws {
        let (dir, db, folder, target) = try setup()
        defer { restoreTrashed(db) }
        _ = dir.dir("Source/Notes.rtfd")
        let image = dir.file("Source/Notes.rtfd/image.png", contents: "png")
        _ = dir.file("Source/Notes.rtfd/TXT.rtf", contents: "text")
        try syncAll(db, folder)
        #expect(FileManager.default.fileExists(atPath: target + "/Notes.rtfd/image.png"))
        try FileManager.default.removeItem(atPath: image)

        let coordinator = WatcherCoordinator(db: db, settleInterval: 0.01)
        coordinator.enqueue(event: .pathRemoved(image))
        coordinator.waitForPendingEvents()

        #expect(!FileManager.default.fileExists(atPath: target + "/Notes.rtfd/image.png"))
        #expect(try String(contentsOfFile: target + "/Notes.rtfd/TXT.rtf", encoding: .utf8) == "text")
    }

    @Test func aMissingWatchedFolderRemovesNothing() throws {
        let (dir, db, folder, target) = try setup(policy: .delete)
        _ = dir.file("Source/a.txt", contents: "a")
        try syncAll(db, folder)
        try FileManager.default.moveItem(atPath: folder.path, toPath: dir.path + "/Renamed")
        let rules = try db.listRules(folderId: folder.id)

        #expect(RuleEngine.previewSyncRemovals(rules: rules, root: folder.path, path: folder.path, isPro: true).isEmpty)
        #expect(RuleEngine.runSyncRemovals(rules: rules, root: folder.path, path: folder.path, batchId: "run", isPro: true).isEmpty)
        #expect(FileManager.default.fileExists(atPath: target + "/a.txt"))
    }
}
