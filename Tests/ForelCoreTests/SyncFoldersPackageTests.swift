import Foundation
import Testing
@testable import ForelCore

@Suite struct SyncFoldersPackageTests {
    private func setup(recursionDepth: Int64? = 0) throws -> (TempDir, Database, WatchedFolder, String) {
        let dir = TempDir()
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: dir.dir("Source"))
        let target = dir.dir("Target")
        try db.insertFolder(folder)
        var sync = makeRule(folderId: folder.id, name: "Sync", recursionDepth: recursionDepth)
        sync.actions = [makeAction(.syncFolders, .object([ActionParam.destination: .string(target)]), ruleId: sync.id)]
        try db.insertRule(sync)
        return (dir, db, folder, target)
    }

    @Test(arguments: [Int64(0), nil] as [Int64?])
    func aChangeDeepInsideAPackageUpdatesItsWholeCopy(depth: Int64?) throws {
        let (dir, db, _, target) = try setup(recursionDepth: depth)
        let package = dir.dir("Source/Notes.rtfd")
        _ = dir.dir("Source/Notes.rtfd/Contents")
        let inner = dir.file("Source/Notes.rtfd/Contents/TXT.rtf", contents: "v1")
        let coordinator = WatcherCoordinator(db: db, settleInterval: 0.01)
        coordinator.enqueue(event: .pathArrived(package))
        coordinator.waitForPendingEvents()
        #expect(try String(contentsOfFile: target + "/Notes.rtfd/Contents/TXT.rtf", encoding: .utf8) == "v1")

        // Edited in place: the package's own size and date stay the same.
        try "v2 longer".write(toFile: inner, atomically: false, encoding: .utf8)
        coordinator.enqueue(event: .pathModified(inner))
        coordinator.waitForPendingEvents()
        #expect(try String(contentsOfFile: target + "/Notes.rtfd/Contents/TXT.rtf", encoding: .utf8) == "v2 longer")

        let added = dir.file("Source/Notes.rtfd/Contents/image.png", contents: "png")
        coordinator.enqueue(event: .pathArrived(added))
        coordinator.waitForPendingEvents()
        #expect(try String(contentsOfFile: target + "/Notes.rtfd/Contents/image.png", encoding: .utf8) == "png")

        // Only the package is ever synced, never a file inside it.
        let applied = try db.listHistory().filter { $0.status == .applied && $0.actionKind == .syncFolders }
        #expect(applied.allSatisfy { $0.originalPath == package })
        #expect(applied.count == 3)
    }

    @Test func filesInsideAPackageAreNeverSyncedOneByOne() throws {
        let (dir, db, folder, _) = try setup(recursionDepth: nil)
        _ = dir.dir("Source/Notes.rtfd")
        let inner = dir.file("Source/Notes.rtfd/TXT.rtf", contents: "v1")
        let rules = try db.listRules(folderId: folder.id)
        let preview = try #require(RuleEngine.previewFile(path: inner, depth: 1, rules: rules, root: folder.path))
        #expect(preview.rules.first?.actions.first?.status == .wouldSkip)
        let result = RuleEngine.run(path: inner, depth: 1, rules: rules, batchId: "run", root: folder.path)
        #expect(result.history.allSatisfy { $0.status == .skipped })
    }
}
