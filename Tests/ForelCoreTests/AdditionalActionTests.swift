import Foundation
import Testing
import ZIPFoundation
@testable import ForelCore

@Suite struct AdditionalActionTests {
    private final class Platform: ActionPlatform, @unchecked Sendable {
        let lock = NSLock()
        let trash: String
        let failTrash: Bool
        private var events: [String] = []
        init(trash: String, failTrash: Bool = false) { self.trash = trash; self.failTrash = failTrash }
        func record(_ event: String) { lock.lock(); defer { lock.unlock() }; events.append(event) }
        func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return events }
        func open(path: String, application: String?, passFile: Bool, bringToFront: Bool) throws { record("open:\(path):\(application ?? "default"):\(bringToFront)") }
        func showInFinder(path: String, bringToFront: Bool) throws { record("finder:\(path):\(bringToFront)") }
        func notify(text: String, sound: Bool) throws { record("notify:\(text):\(sound)") }
        func pause(seconds: TimeInterval) throws { record("pause:\(seconds)") }
        func trash(path: String) throws -> String {
            if failTrash { throw ActionError("Test trash failure") }
            let target = (trash as NSString).appendingPathComponent((path as NSString).lastPathComponent)
            try FileManager.default.moveItem(atPath: path, toPath: target)
            return target
        }
    }

    @Test func sideEffectsAreInjectedAcrossPreviewManualAndWatcher() throws {
        let dir = TempDir()
        let trash = TempDir()
        let platform = Platform(trash: trash.path)
        let actions = [makeAction(.openDefault, .object([ActionParam.bringToFront: .bool(false)]), position: 0),
                       makeAction(.showInFinder, .object([ActionParam.bringToFront: .bool(true)]), position: 1),
                       makeAction(.pause, .object([ActionParam.durationSeconds: .string("2")]), position: 2),
                       makeAction(.displayNotification, .object([ActionParam.notificationText: .string("Done"), ActionParam.notificationSound: .bool(true)]), position: 3)]
        let file = dir.file("manual.txt")
        let rule = makeRule(name: "effects", actions: actions)
        #expect(RuleEngine.previewFile(path: file, depth: 0, rules: [rule])?.rules.first?.actions.count == 4)
        #expect(platform.snapshot().isEmpty)
        let run = RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "test", platform: platform)
        #expect(run.history.count == 4)
        #expect(platform.snapshot().count == 4)
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var stored = rule
        stored.folderId = folder.id
        for index in stored.actions.indices { stored.actions[index].ruleId = stored.id }
        try db.insertRule(stored)
        let watched = dir.file("watched.txt")
        WatcherCoordinator(db: db, actionPlatform: platform).handle(path: watched)
        #expect(platform.snapshot().count == 8)
        #expect(platform.snapshot().contains("open:\(watched):default:false"))
        #expect(platform.snapshot().contains("finder:\(watched):true"))
    }

    @Test func archiveUsesZipForLaterActionsAndCanBeSafelyUndone() throws {
        let dir = TempDir()
        let trash = TempDir()
        let platform = Platform(trash: trash.path)
        let file = dir.file("document.txt", contents: "original")
        let action = makeAction(.archive, .object([:]))
        let plan = try ActionExecutor.plan(action, path: file)
        #expect(plan.finalPath == file + ".zip")
        let applied = try ActionExecutor.execute(action, path: file, platform: platform)
        #expect(applied.newPath == plan.finalPath)
        #expect(!FileManager.default.fileExists(atPath: file))
        #expect(FileManager.default.fileExists(atPath: applied.newPath))
        #expect(Undo.fromJSON(applied.undo.toJSON()) == applied.undo)
        try ActionExecutor.revert(applied.undo)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "original")
        #expect(!FileManager.default.fileExists(atPath: applied.newPath))
        let again = try ActionExecutor.execute(action, path: file, platform: platform)
        try "modified".write(toFile: again.newPath, atomically: false, encoding: .utf8)
        #expect(throws: (any Error).self) { try ActionExecutor.revert(again.undo) }
        #expect(FileManager.default.fileExists(atPath: again.newPath))
    }

    @Test func archiveThenRenameActsOnArchiveAndIgnoreStopsLaterHazelRules() throws {
        let dir = TempDir()
        let trash = TempDir()
        let platform = Platform(trash: trash.path)
        let file = dir.file("source.txt", contents: "data")
        var rule = makeRule(name: "archive", actions: [makeAction(.archive, .object([:])), makeAction(.rename, .object([ActionParam.pattern: .string("result.zip")]), position: 1)])
        rule.isHazelImported = true
        let result = RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "test", platform: platform)
        #expect(result.history.count == 2)
        #expect(FileManager.default.fileExists(atPath: (dir.path as NSString).appendingPathComponent("result.zip")))
        let ignored = dir.file("ignore.txt")
        var first = makeRule(name: "ignore", actions: [makeAction(.ignore, .object([:]))])
        first.isHazelImported = true
        var second = makeRule(name: "later")
        second.isHazelImported = true
        #expect(RuleEngine.run(path: ignored, depth: 0, rules: [first, second], batchId: "test", platform: platform).matched == ["ignore"])
    }

    @Test func archiveWatcherUsesSameConflictFreeTargetAsPreview() throws {
        let dir = TempDir()
        let trash = TempDir()
        let platform = Platform(trash: trash.path)
        let file = dir.file("item.txt", contents: "data")
        _ = dir.file("item.txt.zip", contents: "existing")
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "archive", conditions: [makeCondition(.extension_, .is, "txt")])
        rule.conditions[0].ruleId = rule.id
        rule.actions = [makeAction(.archive, .object([:]), ruleId: rule.id)]
        try db.insertRule(rule)
        let preview = try #require(RuleEngine.previewFile(path: file, depth: 0, rules: [rule]))
        let expected = try #require(preview.rules.first?.actions.first?.targetPath)
        WatcherCoordinator(db: db, actionPlatform: platform).handle(path: file)
        let entry = try #require(db.listHistory().first)
        #expect(entry.resultPath == expected)
        #expect(entry.reversible)
        #expect(UndoChecker.evaluate(entry) == .safe)
        #expect(try String(contentsOfFile: (dir.path as NSString).appendingPathComponent("item.txt.zip"), encoding: .utf8) == "existing")
        try ActionExecutor.revert(Undo.fromJSON(entry.undo))
        #expect(FileManager.default.fileExists(atPath: file))
    }

    @Test func aliasUsesFinderBookmark() throws {
        let dir = TempDir()
        let destination = TempDir()
        let file = dir.file("file.txt")
        let action = makeAction(.makeAlias, .object([ActionParam.destination: .string(destination.path)]))
        let plan = try ActionExecutor.plan(action, path: file)
        _ = try ActionExecutor.execute(action, path: file)
        let alias = try #require(plan.targetPath)
        let bookmark = try URL.bookmarkData(withContentsOf: URL(fileURLWithPath: alias))
        var stale = false
        let resolved = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        #expect(resolved.standardizedFileURL.path == URL(fileURLWithPath: file).standardizedFileURL.path)
    }

    @Test func importsEvidencedHazelDefaultOpenInBackground() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_UNZIP"] else { return }
        let file = URL(fileURLWithPath: root).appendingPathComponent("download.hazelrules")
        let result = try RuleTransfer.importRules(from: Data(contentsOf: file), folderId: "folder")
        let action = try #require(result.rules.flatMap(\.actions).first { $0.kind == .openDefault })
        #expect(action.params[ActionParam.bringToFront]?.boolValue == false)
    }

    @Test func publicRuleNameNotificationUsesVerifiedHazelToken() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_SHELL_CORPUS"] else { return }
        let url = URL(fileURLWithPath: root).appendingPathComponent("hazel-open-url/to-open-url.hazelrules")
        let imported = try RuleTransfer.importRules(from: Data(contentsOf: url), folderId: "folder")
        var rule = try #require(imported.rules.first { $0.name == "Open URL" })
        let notify = try #require(rule.actions.first { $0.kind == .displayNotification })
        #expect(notify.params[HazelPattern.tokensKey]?.arrayValue?.first?["type"]?.stringValue == "rule")
        let dir = TempDir()
        let trash = TempDir()
        let file = dir.file("test.txt")
        let platform = Platform(trash: trash.path)
        rule.enabled = true
        rule.importError = nil
        rule.conditions = []
        rule.actions = [notify]
        rule.name = "Renamed Rule"
        let preview = try #require(RuleEngine.previewFile(path: file, depth: 0, rules: [rule]))
        #expect(preview.rules.first?.actions.first?.description == "Display notification: Renamed Rule")
        #expect(RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "notify", platform: platform).history.first?.status == .applied)
        #expect(platform.snapshot() == ["notify:Renamed Rule:false"])
    }

    @Test func archiveStagingIsExcludedAcrossPathsAndCleanedAfterFailure() throws {
        let dir = TempDir()
        let trash = TempDir()
        let staged = dir.file(".forel-archive-\(UUID().uuidString).zip", contents: "incomplete")
        let ordinary = dir.file("document.txt", contents: "data")
        let rule = makeRule(name: "all", actions: [makeAction(.delete, .object([:]))])
        #expect(RuleEngine.previewFile(path: staged, depth: 0, rules: [rule]) == nil)
        #expect(RuleEngine.run(path: staged, depth: 0, rules: [rule], batchId: "stage").matched.isEmpty)
        var scanned: [String] = []
        RuleEngine.forEachRuleEntry(root: dir.path, rules: [rule]) { entry, _ in scanned.append(entry.path) }
        #expect(!scanned.contains(staged))
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var stored = rule
        stored.folderId = folder.id
        stored.actions[0].ruleId = stored.id
        try db.insertRule(stored)
        WatcherCoordinator(db: db).handle(path: staged)
        #expect(FileManager.default.fileExists(atPath: staged))
        #expect(try db.listHistory().isEmpty)
        let failing = Platform(trash: trash.path, failTrash: true)
        #expect(throws: (any Error).self) { try ActionExecutor.execute(makeAction(.archive, .object([:])), path: ordinary, platform: failing) }
        #expect(FileManager.default.fileExists(atPath: ordinary))
        #expect(!FileManager.default.fileExists(atPath: ordinary + ".zip"))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.filter { $0.hasPrefix(".forel-archive-") }.count == 1)
    }

    @Test func movingOrCopyingFolderIntoItselfOrSymlinkedChildIsBlocked() throws {
        let root = TempDir()
        let folderPath = root.dir("source")
        let child = root.dir("source/child")
        let link = (root.path as NSString).appendingPathComponent("redirect")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: child)
        let destination = (link as NSString).appendingPathComponent("new-destination")
        for kind in [ActionKind.moveToFolder, .copyToFolder] {
            let action = makeAction(kind, .object([ActionParam.destination: .string(destination)]))
            #expect(throws: (any Error).self) { try ActionExecutor.plan(action, path: folderPath) }
            #expect(throws: (any Error).self) { try ActionExecutor.execute(action, path: folderPath) }
            var rule = makeRule(name: "unsafe", actions: [action])
            rule.isHazelImported = true
            #expect(RuleEngine.previewFile(path: folderPath, depth: 0, rules: [rule])?.rules.first?.actions.first?.status == .blocked)
            #expect(RuleEngine.run(path: folderPath, depth: 0, rules: [rule], batchId: "unsafe").history.first?.status == .failed)
            let db = try Database(path: ":memory:")
            let watched = WatchedFolder(path: root.path)
            try db.insertFolder(watched)
            rule.folderId = watched.id
            rule.actions[0].ruleId = rule.id
            try db.insertRule(rule)
            WatcherCoordinator(db: db).handle(path: folderPath)
            #expect(try db.listHistory().first?.status == .failed)
            #expect(!FileManager.default.fileExists(atPath: (child as NSString).appendingPathComponent("new-destination")))
        }
    }

    @Test func moveCollisionCanTrashIncomingFileWithoutOverwritingDestination() throws {
        let source = TempDir()
        let destination = TempDir()
        let trash = TempDir()
        let file = source.file("same.txt", contents: "incoming")
        let existing = destination.file("same.txt", contents: "existing")
        let platform = Platform(trash: trash.path)
        var rule = makeRule(name: "move", actions: [
            makeAction(.moveToFolder, .object([ActionParam.destination: .string(destination.path), ActionParam.onConflict: .string("discard")])),
            makeAction(.delete, .object([:]), position: 1)
        ])
        rule.isHazelImported = true
        let preview = try #require(RuleEngine.previewFile(path: file, depth: 0, rules: [rule]))
        #expect(preview.rules.first?.actions.count == 1)
        #expect(preview.rules.first?.actions.first?.description.contains("Trash") == true)
        let result = RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "collision", platform: platform)
        #expect(result.history.map(\.status) == [.applied])
        #expect(try String(contentsOfFile: existing, encoding: .utf8) == "existing")
        #expect(try String(contentsOfFile: (trash.path as NSString).appendingPathComponent("same.txt"), encoding: .utf8) == "incoming")
    }
}
