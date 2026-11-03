import Foundation
import Testing
@testable import ForelCore

@Suite struct SyncFoldersAdditionalRegressionTests {
    @Test(arguments: [SyncDeletePolicy.delete, .moveToTrash])
    func movingOutFilteredFoldersRemovesOnlyMatchingInScopeFiles(policy: SyncDeletePolicy) throws {
        for limit in [nil, Int64(1)] as [Int64?] {
            let dir = TempDir()
            let db = try Database(path: ":memory:")
            let source = dir.dir("Source")
            let target = dir.dir("Target")
            let project = dir.dir("Source/Project")
            _ = dir.dir("Source/Project/Nested")
            _ = dir.file("Source/Project/one.txt", contents: "one")
            _ = dir.file("Source/Project/Nested/two.txt", contents: "two")
            let folder = WatchedFolder(path: source)
            try db.insertFolder(folder)
            var rule = makeRule(folderId: folder.id, name: "Sync text", recursionDepth: limit)
            rule.conditions = [makeCondition(.extension_, .is, "txt", ruleId: rule.id)]
            rule.actions = [makeAction(.syncFolders, .object([
                ActionParam.destination: .string(target), ActionParam.syncDeletePolicy: .string(policy.rawValue),
            ]), ruleId: rule.id)]
            try db.insertRule(rule)
            // Restore this test's trashed files into its temporary directory.
            defer {
                for entry in (try? db.listHistory()) ?? [] where entry.reversible {
                    try? ActionExecutor.revert(Undo.fromJSON(entry.undo))
                }
            }
            let coordinator = WatcherCoordinator(db: db, settleInterval: 0.01)
            coordinator.enqueue(event: .pathArrived(project))
            coordinator.waitForPendingEvents()
            #expect(FileManager.default.fileExists(atPath: target + "/Project/one.txt"))
            _ = dir.dir("Target/Project/Nested")
            let unselected = dir.file("Target/Project/notes.pdf", contents: "keep PDF")
            let deep = target + "/Project/Nested/two.txt"
            if limit != nil { try "keep deep".write(toFile: deep, atomically: true, encoding: .utf8) }
            try FileManager.default.moveItem(atPath: project, toPath: dir.path + "/Away")
            coordinator.enqueue(event: .pathArrived(project))
            coordinator.waitForPendingEvents()
            #expect(!FileManager.default.fileExists(atPath: target + "/Project/one.txt"))
            #expect(try String(contentsOfFile: unselected, encoding: .utf8) == "keep PDF")
            if limit == nil {
                #expect(!FileManager.default.fileExists(atPath: deep))
            } else {
                #expect(try String(contentsOfFile: deep, encoding: .utf8) == "keep deep")
            }
            let removals = try db.listHistory().filter { $0.originalPath == source + "/Project/one.txt" && ($0.resultPath != target + "/Project/one.txt" || policy == .delete) }
            #expect(!removals.isEmpty)
            #expect(try db.listHistory().allSatisfy { $0.status == .applied })
        }
    }

    @Test(arguments: ["preview", "manual", "watcher", "deletion"])
    func internalParentLinksCannotChangeAnotherCounterpart(execution: String) throws {
        let dir = TempDir()
        let db = try Database(path: ":memory:")
        let source = dir.dir("Source")
        let target = dir.dir("Target")
        _ = dir.dir("Source/A")
        _ = dir.dir("Source/B")
        _ = dir.dir("Target/B")
        let file = dir.file("Source/A/report.txt", contents: "A")
        _ = dir.file("Source/B/report.txt", contents: "B")
        let protected = dir.file("Target/B/report.txt", contents: "B")
        try FileManager.default.createSymbolicLink(atPath: target + "/A", withDestinationPath: target + "/B")
        let folder = WatchedFolder(path: source)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "Sync", recursionDepth: nil)
        rule.actions = [makeAction(.syncFolders, .object([
            ActionParam.destination: .string(target), ActionParam.syncDeletePolicy: .string("delete"),
        ]), ruleId: rule.id)]
        try db.insertRule(rule)
        if execution == "preview" {
            let preview = try #require(RuleEngine.previewFile(path: file, depth: 1, rules: [rule], root: source))
            #expect(preview.rules[0].actions[0].status == .wouldSkip)
            #expect(preview.rules[0].actions[0].description.contains("symbolic link"))
        } else {
            let history: [HistoryEntry]
            if execution == "manual" {
                history = RuleEngine.run(path: file, depth: 1, rules: [rule], batchId: "manual", root: source).history
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
            #expect(history.map(\.status) == [.failed])
            #expect(history.first?.message?.contains("symbolic link") == true)
        }
        #expect(try String(contentsOfFile: protected, encoding: .utf8) == "B")
    }

    @Test(arguments: ["preview", "manual", "watcher"])
    func directorySymlinksAreCopiedAsLinksAndCanBeRemovedSafely(execution: String) throws {
        let dir = TempDir()
        let db = try Database(path: ":memory:")
        let source = dir.dir("Source")
        let target = dir.dir("Target")
        let outside = dir.dir("Outside")
        let external = dir.file("Outside/report.txt", contents: "original")
        let link = source + "/Linked"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside)
        let folder = WatchedFolder(path: source)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "Sync", recursionDepth: nil)
        rule.actions = [makeAction(.syncFolders, .object([
            ActionParam.destination: .string(target), ActionParam.syncDeletePolicy: .string("delete"),
        ]), ruleId: rule.id)]
        try db.insertRule(rule)
        let entries = RuleEngine.walkEntries(root: source, maxDepth: nil)
        #expect(entries.map(\.path) == [link])
        if execution == "preview" {
            let preview = try #require(RuleEngine.previewFile(path: link, depth: 0, rules: [rule], root: source))
            #expect(preview.rules[0].actions[0].status == .wouldRun)
            #expect(preview.rules[0].actions[0].description.hasPrefix("Sync to "))
            #expect(!FileManager.default.fileExists(atPath: target + "/Linked"))
        } else {
            let history: [HistoryEntry]
            if execution == "manual" {
                history = entries.flatMap { RuleEngine.run(path: $0.path, depth: $0.depth, rules: [rule], batchId: "manual", root: source).history }
            } else {
                let coordinator = WatcherCoordinator(db: db, settleInterval: 0.01)
                coordinator.enqueue(event: .pathArrived(link))
                coordinator.waitForPendingEvents()
                history = try db.listHistory()
            }
            #expect(history.map(\.status) == [.applied])
            let attributes = try FileManager.default.attributesOfItem(atPath: target + "/Linked")
            #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target + "/Linked") == outside)
            #expect(try ActionExecutor.plan(rule.actions[0], path: link, root: source).status == .wouldSkip)
            try FileManager.default.removeItem(atPath: link)
            let coordinator = WatcherCoordinator(db: db, settleInterval: 0.01)
            coordinator.enqueue(event: .pathRemoved(link))
            coordinator.waitForPendingEvents()
            #expect((try? FileManager.default.attributesOfItem(atPath: target + "/Linked")) == nil)
        }
        #expect(try String(contentsOfFile: external, encoding: .utf8) == "original")
    }

    @Test(arguments: [false, true])
    func reconnectRetriesSyncWithoutReplayingOtherActions(syncOnly: Bool) throws {
        let dir = TempDir()
        let db = try Database(path: ":memory:")
        let source = dir.dir("Source")
        let file = dir.file("Source/report.txt", contents: "original")
        let folder = WatchedFolder(path: source)
        let volume = "ForelMissingShare-" + UUID().uuidString
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "Sync")
        rule.actions = [makeAction(.syncFolders, .object([
            ActionParam.destination: .string("/Volumes/\(volume)/Backup"),
        ]), ruleId: rule.id)]
        if syncOnly {
            rule.actions.append(makeAction(.addTag, .object([ActionParam.tags: .stringArray(["Arrival"])]), position: 1, ruleId: rule.id))
        }
        try db.insertRule(rule)
        let coordinator = WatcherCoordinator(db: db, settleInterval: 0.01)
        coordinator.enqueue(event: syncOnly ? .pathModified(file) : .pathArrived(file))
        coordinator.waitForPendingEvents()
        #expect(try db.listHistory().map(\.status) == [.failed])
        #expect(try db.listHistory().first?.message?.contains("isn't connected") == true)
        #expect(coordinator.waitingForVolume[volume]?.contains(file) == true)
        #expect(coordinator.waitingForSyncOnlyPaths.contains(file) == syncOnly)
        let target = dir.dir("Target")
        rule.actions[0].params = .object([ActionParam.destination: .string(target)])
        try db.updateRule(rule)
        coordinator.volumeDidMount(atPath: "/Volumes/\(volume)")
        coordinator.waitForPendingEvents()
        #expect(try String(contentsOfFile: target + "/report.txt", encoding: .utf8) == "original")
        let history = try db.listHistory()
        #expect(history.count == 2)
        #expect(history.allSatisfy { $0.actionKind == .syncFolders })
        #expect(history.filter { $0.status == .applied }.count == 1)
        #expect(FinderTags.read(file).isEmpty)
        #expect(coordinator.waitingForVolume.isEmpty)
        #expect(coordinator.waitingForSyncOnlyPaths.isEmpty)
    }

    @Test func aFullySelectedFolderIsTrashedAndRestoredAsOneItem() throws {
        let dir = TempDir()
        let db = try Database(path: ":memory:")
        let source = dir.dir("Source")
        let target = dir.dir("Target")
        let project = dir.dir("Source/Project")
        _ = dir.dir("Source/Project/Nested")
        _ = dir.file("Source/Project/one.txt", contents: "one")
        _ = dir.file("Source/Project/Nested/two.txt", contents: "two")
        let folder = WatchedFolder(path: source)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "Sync", recursionDepth: nil)
        rule.actions = [makeAction(.syncFolders, .object([
            ActionParam.destination: .string(target), ActionParam.syncDeletePolicy: .string("move_to_trash"),
        ]), ruleId: rule.id)]
        try db.insertRule(rule)
        defer {
            for entry in (try? db.listHistory()) ?? [] where entry.reversible {
                try? ActionExecutor.revert(Undo.fromJSON(entry.undo))
            }
        }
        let coordinator = WatcherCoordinator(db: db, settleInterval: 0.01)
        coordinator.enqueue(event: .pathArrived(project))
        coordinator.waitForPendingEvents()
        try FileManager.default.moveItem(atPath: project, toPath: dir.path + "/Away")
        coordinator.enqueue(event: .pathArrived(project))
        coordinator.waitForPendingEvents()
        #expect(!FileManager.default.fileExists(atPath: target + "/Project"))
        let removals = try db.listHistory().filter(\.reversible)
        try #require(removals.count == 1)
        #expect(removals[0].originalPath == project)
        #expect(UndoChecker.evaluate(removals[0]) == .safe)
        try ActionExecutor.revert(Undo.fromJSON(removals[0].undo))
        #expect(try String(contentsOfFile: target + "/Project/one.txt", encoding: .utf8) == "one")
        #expect(try String(contentsOfFile: target + "/Project/Nested/two.txt", encoding: .utf8) == "two")
    }

    @Test func aSecondDestinationReconnectsEvenIfTheFirstSyncAndAnArrivalActionSucceeded() throws {
        let dir = TempDir()
        let db = try Database(path: ":memory:")
        let source = dir.dir("Source")
        let first = dir.dir("First")
        let later = dir.dir("Later")
        let extras = dir.dir("Extras")
        let file = dir.file("Source/report.txt", contents: "original")
        let volume = "ForelMissingShare-" + UUID().uuidString
        let folder = WatchedFolder(path: source)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "Sync twice and copy")
        rule.actions = [
            makeAction(.syncFolders, .object([ActionParam.destination: .string(first)]), position: 0, ruleId: rule.id),
            makeAction(.syncFolders, .object([ActionParam.destination: .string("/Volumes/\(volume)/Backup")]), position: 1, ruleId: rule.id),
            makeAction(.copyToFolder, .object([ActionParam.destination: .string(extras)]), position: 2, ruleId: rule.id),
        ]
        try db.insertRule(rule)
        let coordinator = WatcherCoordinator(db: db, settleInterval: 0.01)
        coordinator.enqueue(event: .pathArrived(file))
        coordinator.waitForPendingEvents()
        #expect(FileManager.default.fileExists(atPath: first + "/report.txt"))
        #expect(coordinator.waitingForSyncOnlyPaths.contains(file))
        rule.actions[1].params = .object([ActionParam.destination: .string(later)])
        try db.updateRule(rule)
        coordinator.volumeDidMount(atPath: "/Volumes/\(volume)")
        coordinator.waitForPendingEvents()
        #expect(try String(contentsOfFile: later + "/report.txt", encoding: .utf8) == "original")
        #expect(try FileManager.default.contentsOfDirectory(atPath: extras) == ["report.txt"])
        #expect(try db.listHistory().filter { $0.actionKind == .copyToFolder }.count == 1)
        #expect(coordinator.waitingForVolume.isEmpty)
    }

    @Test func removingAFolderCounterpartLinkDoesNotRemoveItsTarget() throws {
        let dir = TempDir()
        let db = try Database(path: ":memory:")
        let source = dir.dir("Source")
        let target = dir.dir("Target")
        let removed = dir.dir("Source/A")
        _ = dir.file("Source/A/report.txt", contents: "A")
        _ = dir.dir("Target/B")
        let protected = dir.file("Target/B/report.txt", contents: "B")
        try FileManager.default.createSymbolicLink(atPath: target + "/A", withDestinationPath: target + "/B")
        let folder = WatchedFolder(path: source)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "Sync", recursionDepth: nil)
        rule.actions = [makeAction(.syncFolders, .object([
            ActionParam.destination: .string(target), ActionParam.syncDeletePolicy: .string("delete"),
        ]), ruleId: rule.id)]
        try db.insertRule(rule)
        try FileManager.default.moveItem(atPath: removed, toPath: dir.path + "/Away")
        let coordinator = WatcherCoordinator(db: db, settleInterval: 0.01)
        coordinator.enqueue(event: .pathRemoved(removed))
        coordinator.waitForPendingEvents()
        #expect((try? FileManager.default.attributesOfItem(atPath: target + "/A")) == nil)
        #expect(try String(contentsOfFile: protected, encoding: .utf8) == "B")
        #expect(try db.listHistory().map(\.status) == [.applied])
    }
}
