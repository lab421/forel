import Foundation
import CoreServices
import Testing
@testable import ForelCore

@Suite struct SyncFoldersRegressionTests {
    private func setup(destinations: Int = 1) throws -> (TempDir, Database, WatchedFolder, [String]) {
        let dir = TempDir()
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: dir.dir("Source"))
        let targets = (0..<destinations).map { dir.dir("Target\($0)") }
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "Sync", recursionDepth: nil)
        rule.actions = targets.enumerated().map { index, target in
            makeAction(.syncFolders, .object([
                ActionParam.destination: .string(target),
                ActionParam.syncDeletePolicy: .string("delete"),
            ]), position: Int64(index), ruleId: rule.id)
        }
        try db.insertRule(rule)
        return (dir, db, folder, targets)
    }

    @Test func modificationsUpdateEveryMirrorWithoutReplayingOtherActions() throws {
        let (dir, db, folder, targets) = try setup(destinations: 2)
        var rules = try db.listRules(folderId: folder.id)
        rules[0].actions.append(makeAction(.addTag, .object([ActionParam.tags: .stringArray(["Arrival"])]), position: 2, ruleId: rules[0].id))
        try db.updateRule(rules[0])
        let file = dir.file("Source/report.txt", contents: "original")
        let coordinator = WatcherCoordinator(db: db, settleInterval: 0.01)
        coordinator.enqueue(event: .pathArrived(file))
        coordinator.waitForPendingEvents()
        #expect(FinderTags.read(file) == ["Arrival"])
        try FinderTags.write(file, [])
        try "updated content".write(toFile: file, atomically: false, encoding: .utf8)
        let event = try #require(FileWatcher.reportedEvent(path: file, flags: UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)))
        #expect(event == .pathModified(file))
        coordinator.enqueue(event: event)
        coordinator.waitForPendingEvents()
        for target in targets {
            #expect(try String(contentsOfFile: target + "/report.txt", encoding: .utf8) == "updated content")
        }
        #expect(FinderTags.read(file).isEmpty)
        #expect(try db.listHistory().filter { $0.actionKind == .addTag }.count == 1)
    }

    @Test func modificationsWithoutSyncRulesDoNotReplayArrivalActions() throws {
        let dir = TempDir()
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "Arrival tag")
        rule.actions = [makeAction(.addTag, .object([ActionParam.tags: .stringArray(["Arrival"])]), ruleId: rule.id)]
        try db.insertRule(rule)
        let file = dir.file("report.txt", contents: "updated")
        let coordinator = WatcherCoordinator(db: db, settleInterval: 0.01)
        coordinator.enqueue(event: .pathModified(file))
        coordinator.waitForPendingEvents()
        #expect(FinderTags.read(file).isEmpty)
        #expect(try db.listHistory().isEmpty)
    }

    @Test func modifiedFilesWaitUntilTheWriterReleasesThem() throws {
        let (dir, db, _, targets) = try setup()
        let file = dir.file("Source/report.txt", contents: "original")
        let coordinator = WatcherCoordinator(db: db, settleInterval: 0.01)
        coordinator.enqueue(event: .pathArrived(file))
        coordinator.waitForPendingEvents()
        try FileManager.default.setAttributes([.creationDate: FileReadiness.busyCreationDate], ofItemAtPath: file)
        try "updated content".write(toFile: file, atomically: false, encoding: .utf8)
        coordinator.enqueue(event: .pathModified(file))
        Thread.sleep(forTimeInterval: 0.08)
        #expect(try String(contentsOfFile: targets[0] + "/report.txt", encoding: .utf8) == "original")
        try FileManager.default.setAttributes([.creationDate: Date()], ofItemAtPath: file)
        coordinator.waitForPendingEvents()
        #expect(try String(contentsOfFile: targets[0] + "/report.txt", encoding: .utf8) == "updated content")
    }

    @Test(arguments: [false, true])
    func renamedFoldersMirrorDescendantsWithoutRepeatingCopies(deferredModification: Bool) throws {
        let (dir, db, folder, targets) = try setup()
        let extras = dir.dir("Extras")
        var copy = makeRule(folderId: folder.id, name: "Copy on arrival", recursionDepth: nil)
        copy.conditions = [makeCondition(.extension_, .is, "txt", ruleId: copy.id)]
        copy.actions = [makeAction(.copyToFolder, .object([ActionParam.destination: .string(extras)]), ruleId: copy.id)]
        try db.insertRule(copy)
        let old = dir.dir("Source/Old")
        _ = dir.dir("Source/Old/Nested")
        _ = dir.file("Source/Old/Nested/report.txt", contents: "original")
        let coordinator = WatcherCoordinator(db: db, settleInterval: 0.03)
        coordinator.enqueue(event: .pathArrived(old))
        coordinator.waitForPendingEvents()
        #expect(FileManager.default.fileExists(atPath: targets[0] + "/Old/Nested/report.txt"))
        let renamed = folder.path + "/New"
        try FileManager.default.moveItem(atPath: old, toPath: renamed)
        coordinator.enqueue(event: .pathArrived(old))
        coordinator.enqueue(event: .pathArrived(renamed))
        if deferredModification {
            let file = renamed + "/Nested/report.txt"
            try "updated content".write(toFile: file, atomically: false, encoding: .utf8)
            coordinator.enqueue(event: .pathModified(file))
        }
        coordinator.waitForPendingEvents()
        #expect(try String(contentsOfFile: targets[0] + "/New/Nested/report.txt", encoding: .utf8) == (deferredModification ? "updated content" : "original"))
        #expect(!FileManager.default.fileExists(atPath: targets[0] + "/Old"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: extras) == ["report.txt"])
    }

    @Test func removalsPropagateToEveryActionAndRule() throws {
        let (dir, db, folder, targets) = try setup(destinations: 2)
        let third = dir.dir("Third")
        var rule = makeRule(folderId: folder.id, name: "Third sync", recursionDepth: nil)
        rule.actions = [makeAction(.syncFolders, .object([
            ActionParam.destination: .string(third), ActionParam.syncDeletePolicy: .string("delete"),
        ]), ruleId: rule.id)]
        try db.insertRule(rule)
        let file = dir.file("Source/report.txt", contents: "original")
        let coordinator = WatcherCoordinator(db: db, settleInterval: 0.01)
        coordinator.enqueue(event: .pathArrived(file))
        coordinator.waitForPendingEvents()
        for target in targets + [third] { #expect(FileManager.default.fileExists(atPath: target + "/report.txt")) }
        try FileManager.default.removeItem(atPath: file)
        coordinator.enqueue(event: .pathRemoved(file))
        coordinator.waitForPendingEvents()
        for target in targets + [third] { #expect(!FileManager.default.fileExists(atPath: target + "/report.txt")) }
        #expect(try db.listHistory().filter { $0.status == .failed }.isEmpty)
    }

    @Test func destinationRemovalsDoNotAffectUnrelatedNestedFiles() throws {
        let dir = TempDir()
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: dir.dir("Source"))
        let target = dir.dir("Source/Backup")
        _ = dir.dir("Source/Backup/Backup")
        let unrelated = dir.file("Source/Backup/Backup/report.txt", contents: "unrelated")
        let file = dir.file("Source/report.txt", contents: "original")
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "Sync", recursionDepth: nil)
        rule.actions = [makeAction(.syncFolders, .object([
            ActionParam.destination: .string(target), ActionParam.syncDeletePolicy: .string("delete"),
        ]), ruleId: rule.id)]
        try db.insertRule(rule)
        let coordinator = WatcherCoordinator(db: db, settleInterval: 0.01)
        coordinator.enqueue(event: .pathArrived(file))
        coordinator.waitForPendingEvents()
        let mirror = target + "/report.txt"
        let historyCount = try db.listHistory().count
        try FileManager.default.removeItem(atPath: mirror)
        coordinator.enqueue(event: .pathRemoved(mirror))
        coordinator.waitForPendingEvents()
        #expect(try String(contentsOfFile: unrelated, encoding: .utf8) == "unrelated")
        #expect(try db.listHistory().count == historyCount)
        #expect(try ActionExecutor.plan(rule.actions[0], path: unrelated, root: folder.path).status == .wouldSkip)
    }

    @Test(arguments: ["preview", "manual", "watcher", "deletion"])
    func destinationLinksCannotWriteOrDeleteOutsideTheMirror(execution: String) throws {
        let (dir, db, folder, targets) = try setup()
        _ = dir.dir("Source/Linked")
        let file = dir.file("Source/Linked/report.txt", contents: "source content")
        let outside = dir.dir("Outside")
        let external = dir.file("Outside/report.txt", contents: "unrelated private data")
        try FileManager.default.createSymbolicLink(atPath: targets[0] + "/Linked", withDestinationPath: outside)
        let rules = try db.listRules(folderId: folder.id)
        if execution == "preview" {
            let preview = try #require(RuleEngine.previewFile(path: file, depth: 1, rules: rules, root: folder.path))
            #expect(preview.rules[0].actions[0].status == .wouldSkip)
            #expect(preview.rules[0].actions[0].description.contains("symbolic link"))
        } else {
            let history: [HistoryEntry]
            if execution == "manual" {
                history = RuleEngine.run(path: file, depth: 1, rules: rules, batchId: "manual", root: folder.path).history
            } else {
                let coordinator = WatcherCoordinator(db: db, settleInterval: 0.01)
                if execution == "deletion" {
                    try FileManager.default.removeItem(atPath: file)
                    coordinator.enqueue(event: .pathRemoved(file))
                } else {
                    coordinator.enqueue(event: .pathArrived(file))
                }
                coordinator.waitForPendingEvents()
                history = try db.listHistory()
            }
            #expect(history.count == 1)
            #expect(history.first?.status == .failed)
            #expect(history.first?.message?.contains("symbolic link") == true)
        }
        #expect(try String(contentsOfFile: external, encoding: .utf8) == "unrelated private data")
    }

    @Test func linkChecksResolveMissingDirectoriesAndAllowAnExplicitDestinationAlias() throws {
        let (dir, db, folder, targets) = try setup()
        let outside = dir.dir("Outside")
        try FileManager.default.createSymbolicLink(atPath: targets[0] + "/Linked", withDestinationPath: outside)
        let rule = try #require(db.listRules(folderId: folder.id).first)
        let action = try #require(rule.actions.first)
        #expect(throws: ActionError.self) {
            try ActionExecutor.syncCounterpartPath(action, path: folder.path + "/Linked/New/report.txt", root: folder.path)
        }
        let alias = dir.path + "/Alias"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: targets[0])
        let file = dir.file("Source/report.txt", contents: "original")
        let aliased = makeAction(.syncFolders, .object([ActionParam.destination: .string(alias)]))
        let result = try ActionExecutor.execute(aliased, path: file, root: folder.path)
        #expect(result.copiedPath == alias + "/report.txt")
        #expect(try String(contentsOfFile: targets[0] + "/report.txt", encoding: .utf8) == "original")
    }

    @Test func danglingDestinationLinksAreRejectedBeforeCreatingDirectories() throws {
        let (dir, db, folder, targets) = try setup()
        let outside = dir.path + "/OutsideNotCreated"
        try FileManager.default.createSymbolicLink(atPath: targets[0] + "/Linked", withDestinationPath: outside)
        let rule = try #require(db.listRules(folderId: folder.id).first)
        let action = try #require(rule.actions.first)
        #expect(throws: ActionError.self) {
            try ActionExecutor.syncCounterpartPath(action, path: folder.path + "/Linked/New/report.txt", root: folder.path)
        }
        #expect(!FileManager.default.fileExists(atPath: outside))
    }

    @Test func syncOnlyRescansAndModificationsRespectRecursionDepth() throws {
        let (dir, db, folder, targets) = try setup()
        var rule = try #require(db.listRules(folderId: folder.id).first)
        rule.recursionDepth = 1
        try db.updateRule(rule)
        let old = dir.dir("Source/Old")
        _ = dir.dir("Source/Old/Nested")
        _ = dir.file("Source/Old/report.txt", contents: "in scope")
        _ = dir.file("Source/Old/Nested/deep.txt", contents: "out of scope")
        let coordinator = WatcherCoordinator(db: db, settleInterval: 0.01)
        coordinator.enqueue(event: .pathArrived(old))
        coordinator.waitForPendingEvents()
        let renamed = folder.path + "/New"
        try FileManager.default.moveItem(atPath: old, toPath: renamed)
        coordinator.enqueue(event: .pathArrived(old))
        coordinator.enqueue(event: .pathArrived(renamed))
        coordinator.waitForPendingEvents()
        #expect(try String(contentsOfFile: targets[0] + "/New/report.txt", encoding: .utf8) == "in scope")
        let deep = renamed + "/Nested/deep.txt"
        try "updated deep content".write(toFile: deep, atomically: false, encoding: .utf8)
        coordinator.enqueue(event: .pathModified(deep))
        coordinator.waitForPendingEvents()
        #expect(!FileManager.default.fileExists(atPath: targets[0] + "/New/Nested/deep.txt"))
        #expect(!FileManager.default.fileExists(atPath: targets[0] + "/Old"))
    }
}
