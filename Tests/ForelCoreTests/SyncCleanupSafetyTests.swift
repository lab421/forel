import Darwin
import Foundation
import Testing
@testable import ForelCore

@Suite struct SyncCleanupSafetyTests {
    private func setup(_ dir: TempDir, policy: SyncDeletePolicy = .delete) throws -> (Database, WatchedFolder, String, Action) {
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: dir.dir("Source"))
        let target = dir.dir("Target")
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "Sync", recursionDepth: nil)
        let action = makeAction(.syncFolders, .object([
            ActionParam.destination: .string(target),
            ActionParam.syncDeletePolicy: .string(policy.rawValue),
        ]), ruleId: rule.id)
        rule.actions = [action]
        try db.insertRule(rule)
        return (db, folder, target, action)
    }

    private func cleanup(_ execution: String, db: Database, folder: WatchedFolder) throws -> ([FilePreview], [HistoryEntry]) {
        let rules = try db.executionRules(folderID: folder.id, isPro: true)
        switch execution {
        case "preview":
            return (RuleEngine.previewSyncRemovals(rules: rules, root: folder.path, path: folder.path, isPro: true), [])
        case "manual":
            let history = RuleEngine.runSyncRemovals(rules: rules, root: folder.path, path: folder.path, batchId: "cleanup", isPro: true)
            try db.insertHistoryEntries(history)
            return ([], history)
        default:
            let coordinator = WatcherCoordinator(db: db)
            coordinator.handle(event: .rescanSubtree(folder.path))
            return ([], try db.listHistory())
        }
    }

    @Test(arguments: ["preview", "manual", "watcher"], [SyncDeletePolicy.delete, .moveToTrash])
    func ignoredPersonalFilesProtectTheirContainingFolder(execution: String, policy: SyncDeletePolicy) throws {
        for ignoredName in ["in-progress.part", ".personal.pdf.icloud", "~$Draft.docx"] {
            let dir = TempDir()
            let (db, folder, target, action) = try setup(dir, policy: policy)
            defer {
                for entry in (try? db.listHistory()) ?? [] where entry.reversible {
                    try? ActionExecutor.revert(Undo.fromJSON(entry.undo))
                }
            }
            let sourceSub = dir.dir("Source/Sub")
            let sourceFile = dir.file("Source/Sub/copied.txt", contents: "synced")
            _ = try ActionExecutor.execute(action, path: sourceSub, root: folder.path)
            _ = try ActionExecutor.execute(action, path: sourceFile, root: folder.path)
            let personal = dir.file("Target/Sub/" + ignoredName, contents: "personal data")
            try FileManager.default.removeItem(atPath: sourceSub)

            let (previews, history) = try cleanup(execution, db: db, folder: folder)
            let copied = target + "/Sub/copied.txt"
            if execution == "preview" {
                #expect(previews.map(\.path) == [copied])
                #expect(previews[0].rules[0].actions[0].status == .wouldRun)
                #expect(FileManager.default.fileExists(atPath: copied))
            } else {
                #expect(history.map(\.originalPath) == [copied])
                #expect(history.map(\.status) == [.applied])
                #expect(!FileManager.default.fileExists(atPath: copied))
            }
            #expect(FileManager.default.fileExists(atPath: target + "/Sub"))
            #expect(try String(contentsOfFile: personal, encoding: .utf8) == "personal data")
        }
    }

    @Test(arguments: ["preview", "manual", "watcher"], [".DS_Store", "Icon\r"])
    func finderMetadataLeavesWithItsFolder(execution: String, metadata: String) throws {
        let dir = TempDir()
        let (db, folder, target, action) = try setup(dir)
        let sourceSub = dir.dir("Source/Sub")
        let sourceFile = dir.file("Source/Sub/copied.txt", contents: "synced")
        _ = try ActionExecutor.execute(action, path: sourceSub, root: folder.path)
        _ = try ActionExecutor.execute(action, path: sourceFile, root: folder.path)
        _ = dir.file("Target/Sub/" + metadata, contents: "finder")
        try FileManager.default.removeItem(atPath: sourceSub)

        let (previews, history) = try cleanup(execution, db: db, folder: folder)
        let copy = target + "/Sub"
        if execution == "preview" {
            #expect(previews.map(\.path) == [copy])
            #expect(FileManager.default.fileExists(atPath: copy))
        } else {
            #expect(history.map(\.originalPath) == [copy])
            #expect(history.map(\.status) == [.applied])
            #expect(!FileManager.default.fileExists(atPath: copy))
        }
    }

    @Test func onlyAppleDoubleCompanionsOfASiblingAreDisposable() {
        let siblings: Set<String> = ["copied.txt", "._copied.txt", "._personal", "in-progress.part", ".report.pdf.icloud"]
        #expect(RuleEngine.isDisposableSyncMetadata(".DS_Store", siblings: siblings))
        #expect(RuleEngine.isDisposableSyncMetadata("Icon\r", siblings: siblings))
        #expect(RuleEngine.isDisposableSyncMetadata("._copied.txt", siblings: siblings))
        #expect(!RuleEngine.isDisposableSyncMetadata("._personal", siblings: siblings))
        #expect(!RuleEngine.isDisposableSyncMetadata("in-progress.part", siblings: siblings))
        #expect(!RuleEngine.isDisposableSyncMetadata(".report.pdf.icloud", siblings: siblings))
        #expect(!RuleEngine.isDisposableSyncMetadata("copied.txt", siblings: siblings))
    }

    @Test(.enabled(if: geteuid() != 0), arguments: ["preview", "manual", "watcher"], ["source", "destination"])
    func unreadablePathsNeverCauseCleanup(execution: String, side: String) throws {
        let dir = TempDir()
        let (db, folder, target, action) = try setup(dir)
        let sourceSub = dir.dir("Source/Sub")
        let sourceFile = dir.file("Source/Sub/a.txt", contents: "keep")
        _ = try ActionExecutor.execute(action, path: sourceSub, root: folder.path)
        _ = try ActionExecutor.execute(action, path: sourceFile, root: folder.path)
        let restricted = side == "source" ? sourceSub : target + "/Sub"
        if side == "destination" { try FileManager.default.removeItem(atPath: sourceSub) }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted) }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: restricted)

        let (previews, history) = try cleanup(execution, db: db, folder: folder)
        if execution == "preview" {
            let preview = try #require(previews.first)
            #expect(preview.rules[0].actions[0].status == .wouldSkip)
            #expect(preview.rules[0].actions[0].description.hasPrefix("Preview unavailable:"))
        } else {
            #expect(history.contains { $0.status == .failed && $0.actionKind == .syncFolders })
            #expect(!history.contains { $0.status == .applied })
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted)
        #expect(try String(contentsOfFile: target + "/Sub/a.txt", encoding: .utf8) == "keep")
        if side == "source" {
            #expect(try String(contentsOfFile: sourceFile, encoding: .utf8) == "keep")
        }
    }
}
