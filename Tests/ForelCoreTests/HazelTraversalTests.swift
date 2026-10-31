import Foundation
import Testing
@testable import ForelCore

@Suite struct HazelTraversalTests {
    private func hazel(_ name: String, conditions: [Condition] = [], actions: [Action] = []) -> Rule {
        var rule = makeRule(name: name, conditions: conditions, actions: actions)
        rule.isHazelImported = true
        for index in rule.conditions.indices { rule.conditions[index].ruleId = rule.id }
        for index in rule.actions.indices { rule.actions[index].ruleId = rule.id }
        return rule
    }

    @Test func hazelModePersistsAndOldNativeExportsDecode() throws {
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: TempDir().path)
        try db.insertFolder(folder)
        var rule = hazel("imported")
        rule.folderId = folder.id
        try db.insertRule(rule)
        #expect(try db.listRules(folderId: folder.id).first?.isHazelImported == true)
        let encoded = try JSONEncoder().encode(rule)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "isHazelImported")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(Rule.self, from: legacy).isHazelImported == false)
    }

    @Test func firstMatchStopsUnlessContinueWasReached() {
        let dir = TempDir()
        let file = dir.file("a.txt")
        let first = hazel("first")
        let second = hazel("second")
        #expect(RuleEngine.run(path: file, depth: 0, rules: [first, second], batchId: "test").matched == ["first"])
        #expect(RuleEngine.previewFile(path: file, depth: 0, rules: [first, second])?.rules.map(\.ruleName) == ["first"])
        var continuing = first
        continuing.actions = [makeAction(.hazelContinue, .object([:]))]
        #expect(RuleEngine.run(path: file, depth: 0, rules: [continuing, second], batchId: "test").matched == ["first", "second"])
        #expect(RuleEngine.previewFile(path: file, depth: 0, rules: [continuing, second])?.rules.map(\.ruleName) == ["first", "second"])
    }

    @Test func traversalRequiresEachFolderToMatchRecurseAndSkipsSymlinks() throws {
        let dir = TempDir()
        let allowed = dir.dir("allowed")
        _ = dir.dir("allowed/blocked")
        _ = dir.dir("allowed/allowed")
        let inside = dir.file("allowed/allowed/yes.txt")
        let blocked = dir.file("allowed/blocked/no.txt")
        try FileManager.default.createSymbolicLink(atPath: (dir.path as NSString).appendingPathComponent("link"), withDestinationPath: allowed)
        let recurse = hazel("recurse", conditions: [makeCondition(.name, .is, "allowed")], actions: [makeAction(.hazelRecurse, .object([:]))])
        let other = hazel("other")
        var visited: [String] = []
        RuleEngine.forEachRuleEntry(root: dir.path, rules: [recurse, other]) { entry, _ in visited.append(entry.path) }
        #expect(visited.contains(inside))
        #expect(!visited.contains(blocked))
        #expect(!visited.contains((dir.path as NSString).appendingPathComponent("link/allowed/yes.txt")))
        #expect(RuleEngine.rulesForPath(root: dir.path, path: inside, rules: [recurse, other]).count == 2)
        #expect(RuleEngine.rulesForPath(root: dir.path, path: blocked, rules: [recurse, other]).isEmpty)
        #expect(RuleEngine.rulesForPath(root: dir.path, path: (dir.path as NSString).appendingPathComponent("link/allowed/yes.txt"), rules: [recurse]).isEmpty)
    }

    @Test func earlierMatchCanPreventOrPermitRecursion() {
        let dir = TempDir()
        _ = dir.dir("folder")
        let child = dir.file("folder/file")
        let first = hazel("first")
        let recurse = hazel("recurse", actions: [makeAction(.hazelRecurse, .object([:]))])
        var visited: [String] = []
        RuleEngine.forEachRuleEntry(root: dir.path, rules: [first, recurse]) { entry, _ in visited.append(entry.path) }
        #expect(!visited.contains(child))
        var continuing = first
        continuing.actions = [makeAction(.hazelContinue, .object([:]))]
        visited.removeAll()
        RuleEngine.forEachRuleEntry(root: dir.path, rules: [continuing, recurse]) { entry, _ in visited.append(entry.path) }
        #expect(visited.contains(child))
    }

    @Test func nativeDepthDoesNotGiveHazelAccessToBlockedDescendants() {
        let dir = TempDir()
        _ = dir.dir("folder")
        let child = dir.file("folder/file")
        let imported = hazel("imported")
        let native = makeRule(name: "native", recursionDepth: 1)
        var active: [Rule] = []
        RuleEngine.forEachRuleEntry(root: dir.path, rules: [imported, native]) { entry, rules in
            if entry.path == child { active = rules }
        }
        #expect(active.map(\.name) == ["native"])
    }

    @Test func hazelCopyRunsFollowingActionsOnCopyWhileNativeCopyKeepsSource() {
        let dir = TempDir()
        let destination = TempDir()
        let original = dir.file("source.txt")
        let actions = [makeAction(.copyToFolder, .object(["destination": .string(destination.path)]), position: 0),
                       makeAction(.rename, .object(["pattern": .string("renamed.txt")]), position: 1)]
        let imported = hazel("copy", actions: actions)
        let preview = RuleEngine.previewFile(path: original, depth: 0, rules: [imported])
        #expect(preview?.rules.first?.actions.last?.sourcePath == (destination.path as NSString).appendingPathComponent("source.txt"))
        let result = RuleEngine.run(path: original, depth: 0, rules: [imported], batchId: "test")
        #expect(result.history.count == 2)
        #expect(FileManager.default.fileExists(atPath: original))
        #expect(FileManager.default.fileExists(atPath: (destination.path as NSString).appendingPathComponent("renamed.txt")))

        let nativeSource = dir.file("native.txt")
        let nativeDestination = TempDir()
        let native = makeRule(name: "native", actions: [
            makeAction(.copyToFolder, .object(["destination": .string(nativeDestination.path)]), position: 0),
            makeAction(.rename, .object(["pattern": .string("native-renamed.txt")]), position: 1),
        ])
        _ = RuleEngine.run(path: nativeSource, depth: 0, rules: [native], batchId: "test")
        #expect(FileManager.default.fileExists(atPath: (dir.path as NSString).appendingPathComponent("native-renamed.txt")))
        #expect(FileManager.default.fileExists(atPath: (nativeDestination.path as NSString).appendingPathComponent("native.txt")))
    }

    @Test func watcherAppliesSameFolderGateForEventsAndRescans() throws {
        let dir = TempDir()
        _ = dir.dir("open")
        _ = dir.dir("closed")
        let allowed = dir.file("open/a.txt")
        let blocked = dir.file("closed/b.txt")
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var recurse = hazel("recurse", conditions: [makeCondition(.name, .is, "open")], actions: [makeAction(.hazelRecurse, .object([:]))])
        recurse.folderId = folder.id
        try db.insertRule(recurse)
        var target = hazel("target", conditions: [makeCondition(.extension_, .is, "txt")], actions: [makeAction(.rename, .object(["pattern": .string("done-{name}")]))])
        target.folderId = folder.id
        try db.insertRule(target)
        let watcher = WatcherCoordinator(db: db)
        watcher.handle(path: blocked)
        watcher.handle(event: .rescanSubtree(dir.path))
        #expect(FileManager.default.fileExists(atPath: blocked))
        #expect(!FileManager.default.fileExists(atPath: allowed))
        #expect(try db.listHistory().count == 1)
        watcher.handle(event: .rescanSubtree(dir.path))
        #expect(try db.listHistory().count == 1)
    }

    @Test func failedActionBeforeRecursionStopsActualManualAndWatcherTraversal() throws {
        let dir = TempDir()
        let folderPath = dir.dir("folder")
        let child = dir.file("folder/file.txt")
        let fail = makeAction(.runHazelShellScript, .object([ActionParam.script: .string("exit 1"), ActionParam.shell: .string("/bin/sh")]), position: 0)
        let recurse = makeAction(.hazelRecurse, .object([:]), position: 1)
        let rule = hazel("fail then recurse", conditions: [makeCondition(.name, .is, "folder")], actions: [fail, recurse])
        var visited: [String] = []
        RuleEngine.forEachRuleEntryExecuting(root: dir.path, rules: [rule]) { entry, active, recurse in
            visited.append(entry.path)
            return RuleEngine.runWithTraversal(path: entry.path, depth: entry.depth, rules: active, batchId: "test", onRecurse: recurse).recurses
        }
        #expect(visited.contains(folderPath))
        #expect(!visited.contains(child))
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var stored = rule
        stored.folderId = folder.id
        try db.insertRule(stored)
        var target = hazel("rename child", conditions: [makeCondition(.extension_, .is, "txt")], actions: [makeAction(.rename, .object(["pattern": .string("changed.txt")]))])
        target.folderId = folder.id
        try db.insertRule(target)
        let watcher = WatcherCoordinator(db: db)
        watcher.handle(event: .rescanSubtree(dir.path))
        #expect(try db.listHistory().count == 1)
        watcher.handle(path: child)
        #expect(try db.listHistory().count == 1)
        #expect(FileManager.default.fileExists(atPath: child))
        try "changed".write(toFile: child, atomically: false, encoding: .utf8)
        let restarted = WatcherCoordinator(db: db)
        restarted.handle(path: child)
        #expect(try db.listHistory().count == 2)
        restarted.handle(path: child)
        #expect(try db.listHistory().count == 2)
        #expect(FileManager.default.fileExists(atPath: child))
    }

    @Test func recursionRunsBeforeFollowingMove() {
        let dir = TempDir()
        let destination = TempDir()
        _ = dir.dir("folder")
        let child = dir.file("folder/file.txt")
        let folderRule = hazel("folder", conditions: [makeCondition(.name, .is, "folder")], actions: [
            makeAction(.hazelRecurse, .object([:]), position: 0),
            makeAction(.moveToFolder, .object(["destination": .string(destination.path)]), position: 1),
        ])
        let fileRule = hazel("child", conditions: [makeCondition(.extension_, .is, "txt")], actions: [makeAction(.rename, .object(["pattern": .string("done.txt")]))])
        let direct = RuleEngine.run(path: (dir.path as NSString).appendingPathComponent("folder"), depth: 0, rules: [folderRule, fileRule], batchId: "direct")
        #expect(direct.history.first?.status == .failed)
        #expect(FileManager.default.fileExists(atPath: child))
        var previewed: [String] = []
        RuleEngine.forEachRuleEntryExecuting(root: dir.path, rules: [folderRule, fileRule]) { entry, rules, recurse in
            previewed.append(entry.path)
            var didRecurse = false
            _ = RuleEngine.previewFile(path: entry.path, depth: entry.depth, rules: rules, onRecurse: { path in didRecurse = true; recurse(path) })
            return didRecurse
        }
        #expect(previewed.contains(child))
        RuleEngine.forEachRuleEntryExecuting(root: dir.path, rules: [folderRule, fileRule]) { entry, rules, recurse in
            RuleEngine.runWithTraversal(path: entry.path, depth: entry.depth, rules: rules, batchId: "test", onRecurse: recurse).recurses
        }
        #expect(FileManager.default.fileExists(atPath: (destination.path as NSString).appendingPathComponent("folder/done.txt")))
    }

    @Test func recurseOnFileFailsAndMoveOutsideRootStopsContinuedRules() throws {
        let dir = TempDir()
        let destination = TempDir()
        let file = dir.file("file.txt")
        let recurse = hazel("recurse", actions: [makeAction(.hazelRecurse, .object([:])), makeAction(.rename, .object(["pattern": .string("wrong.txt")]), position: 1)])
        #expect(RuleEngine.previewFile(path: file, depth: 0, rules: [recurse])?.rules.first?.actions.first?.status == .blocked)
        let failed = RuleEngine.run(path: file, depth: 0, rules: [recurse], batchId: "test")
        #expect(failed.history.first?.status == .failed)
        #expect(FileManager.default.fileExists(atPath: file))
        let move = hazel("move", actions: [makeAction(.moveToFolder, .object(["destination": .string(destination.path)])), makeAction(.hazelContinue, .object([:]), position: 1)])
        let next = hazel("next")
        #expect(RuleEngine.previewFile(path: file, depth: 0, rules: [move, next], root: dir.path)?.rules.map(\.ruleName) == ["move"])
        #expect(RuleEngine.run(path: file, depth: 0, rules: [move, next], batchId: "test", root: dir.path).matched == ["move"])
    }

    @Test func folderArrivalProcessesExistingChildrenOnce() throws {
        let dir = TempDir()
        let folderPath = dir.dir("folder")
        let child = dir.file("folder/file.txt")
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var recurse = hazel("recurse", conditions: [makeCondition(.name, .is, "folder")], actions: [makeAction(.hazelRecurse, .object([:]))])
        recurse.folderId = folder.id
        try db.insertRule(recurse)
        var rename = hazel("rename", conditions: [makeCondition(.extension_, .is, "txt")], actions: [makeAction(.rename, .object(["pattern": .string("done.txt")]))])
        rename.folderId = folder.id
        try db.insertRule(rename)
        let watcher = WatcherCoordinator(db: db)
        watcher.handle(event: .pathArrived(folderPath))
        let renamed = (folderPath as NSString).appendingPathComponent("done.txt")
        #expect(!FileManager.default.fileExists(atPath: child))
        #expect(FileManager.default.fileExists(atPath: renamed))
        #expect(try db.listHistory().count == 1)
        watcher.handle(event: .pathArrived(renamed))
        #expect(try db.listHistory().count == 1)
    }
}
