import Foundation
import Testing
@testable import ForelCore

@Suite struct FreePlanTests {
    @Test func persistenceLimitsFoldersButAllowsUnlimitedRulesInFree() throws {
        let db = try Database(path: ":memory:")
        let first = WatchedFolder(path: "/tmp/first")
        try db.insertFolder(first, isPro: false)
        try db.insertFolder(WatchedFolder(path: "/tmp/second"), isPro: false)
        #expect(throws: FreePlanError.folderLimit) {
            try db.insertFolder(WatchedFolder(path: "/tmp/third"), isPro: false)
        }
        for index in 0..<50 {
            try db.insertRule(makeRule(folderId: first.id, name: "Disabled \(index)", enabled: false), isPro: false)
        }
        var edited = try #require(db.listRules(folderId: first.id).first)
        edited.name = "Edited in Free"
        try db.updateRule(edited, isPro: false)
        #expect(try db.listRules(folderId: first.id).first?.name == "Edited in Free")
        let third = WatchedFolder(path: "/tmp/third", priority: 3)
        try db.insertFolder(third, isPro: true)
        #expect(throws: FreePlanError.proFolder) {
            try db.insertRule(makeRule(folderId: third.id, name: "Blocked"), isPro: false)
        }
        #expect(try db.listFolders().count == 3)
        #expect(try db.listRules(folderId: first.id).count == 50)
    }
    @Test func folderLimitIncludesDisabledEntriesAndProRemovesIt() throws {
        #expect(FreePlan.canAddFolder(count: 1, isPro: false))
        #expect(!FreePlan.canAddFolder(count: 2, isPro: false))
        #expect(FreePlan.canAddFolder(count: 20, isPro: true))
        let db = try Database(path: ":memory:")
        try db.insertFolder(WatchedFolder(path: "/tmp/disabled", enabled: false), isPro: false)
        try db.insertFolder(WatchedFolder(path: "/tmp/enabled"), isPro: false)
        #expect(throws: FreePlanError.folderLimit) {
            try db.insertFolder(WatchedFolder(path: "/tmp/third"), isPro: false)
        }
    }

    @Test(arguments: [false, true])
    func sixthRuleRunsInBothPlansAcrossPreviewManualRunAndWatcher(isPro: Bool) throws {
        let dir = TempDir()
        let file = dir.file("input.txt")
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        for index in 0..<6 {
            var rule = makeRule(folderId: folder.id, name: "Rule \(index)", enabled: index == 5)
            rule.priority = Int64(index)
            rule.conditions = [makeCondition(.name, .is, "input.txt", ruleId: rule.id)]
            rule.actions = [makeAction(.rename, .object(["pattern": .string("renamed.txt")]), position: 0, ruleId: rule.id)]
            try db.insertRule(rule, isPro: false)
        }
        let allowed = try db.executionRules(folderID: folder.id, isPro: isPro)
        #expect(allowed.count == 1)
        #expect(RuleEngine.previewFile(path: file, depth: 0, rules: allowed, isPro: isPro) != nil)
        let (_, history) = RuleEngine.run(path: file, depth: 0, rules: allowed, batchId: "manual", root: dir.path, isPro: isPro)
        #expect(history.count == 1)
        #expect(history.first?.status == .applied)
        #expect(!FileManager.default.fileExists(atPath: file))
        try FileManager.default.removeItem(atPath: dir.path + "/renamed.txt")
        _ = dir.file("input.txt")
        let watcher = WatcherCoordinator(db: db)
        watcher.setProAccess(isPro)
        watcher.handle(event: .rescanSubtree(dir.path))
        #expect(try db.listHistory().count == 1)
        #expect(try db.listHistory().first?.status == .applied)
        #expect(!FileManager.default.fileExists(atPath: file))
        #expect(try db.listRules(folderId: folder.id).count == 6)
        #expect(try db.listRules(folderId: folder.id).last?.enabled == true)
    }

    @Test func thirdFolderIsPreservedButCannotRunInFree() throws {
        let db = try Database(path: ":memory:")
        let dir = TempDir()
        let roots = (0..<3).map { dir.dir("Folder\($0)") }
        for (index, path) in roots.enumerated() {
            try db.insertFolder(WatchedFolder(path: path, priority: Int64(index)))
        }
        let folders = try db.listFolders()
        let folder = folders[2]
        let file = dir.file("Folder2/input.txt")
        var rule = makeRule(folderId: folder.id, name: "Rename")
        rule.actions = [makeAction(.rename, .object(["pattern": .string("renamed.txt")]), position: 0, ruleId: rule.id)]
        try db.insertRule(rule)
        #expect(!FreePlan.allows(folderID: folder.id, folders: folders, isPro: false))
        let allowed = try db.executionRules(folderID: folder.id, isPro: false)
        #expect(RuleEngine.previewFile(path: file, depth: 0, rules: allowed) == nil)
        #expect(RuleEngine.run(path: file, depth: 0, rules: allowed, batchId: "free", root: folder.path).1.isEmpty)
        let watcher = WatcherCoordinator(db: db)
        watcher.setProAccess(false)
        watcher.handle(path: file)
        #expect(try db.listHistory().isEmpty)
        #expect(FileManager.default.fileExists(atPath: file))
        watcher.setProAccess(true)
        watcher.handle(path: file)
        #expect(try db.listHistory().count == 1)
        #expect(try db.listFolders().count == 3)
    }

    @Test(arguments: [ActionKind.runScript, .runShortcut, .importToLibrary])
    func proActionsBlockTheWholeRuleAcrossAllPaths(kind: ActionKind) throws {
        let dir = TempDir()
        let file = dir.file("input.txt")
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "Pro action")
        rule.actions = [
            makeAction(.rename, .object(["pattern": .string("renamed.txt")]), position: 0, ruleId: rule.id),
            makeAction(kind, .object([:]), position: 1, ruleId: rule.id),
        ]
        let feature = try #require(FreePlan.requiredFeature(for: kind))
        #expect(throws: FreePlanError.feature(feature)) { try db.insertRule(rule, isPro: false) }
        try db.insertRule(rule, isPro: true)
        #expect(try db.executionRules(folderID: folder.id, isPro: false).isEmpty)
        #expect(RuleEngine.previewFile(path: file, depth: 0, rules: [rule], isPro: false) == nil)
        #expect(RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "free", isPro: false).history.isEmpty)
        let watcher = WatcherCoordinator(db: db)
        watcher.setProAccess(false)
        watcher.handle(path: file)
        watcher.handle(event: .rescanSubtree(dir.path))
        #expect(try db.listHistory().isEmpty)
        #expect(FileManager.default.fileExists(atPath: file))
        #expect(!FileManager.default.fileExists(atPath: dir.path + "/renamed.txt"))
        let restored = try #require(db.listRules(folderId: folder.id).first)
        #expect(restored.actions.map(\.kind) == rule.actions.map(\.kind))
        #expect(restored.enabled)
        #expect(throws: FreePlanError.feature(feature)) { try db.updateRule(restored, isPro: false) }
        var draft = restored
        draft.enabled = false
        try db.updateRule(draft, isPro: false)
        #expect(try db.listRules(folderId: folder.id).first?.actions.count == 2)
    }

    @Test(arguments: [false, true], [4, 12])
    func longActionChainsRunInBothPlansAcrossAllPaths(isPro: Bool, actionCount: Int) throws {
        let dir = TempDir()
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "Action chain")
        rule.conditions = [makeCondition(.name, .is, "input.txt", ruleId: rule.id)]
        rule.actions = (0..<actionCount).map { index in
            makeAction(.rename, .object(["pattern": .string("step\(index).txt")]), position: Int64(index), ruleId: rule.id)
        }
        try db.insertRule(rule, isPro: false)
        #expect(try db.executionRules(folderID: folder.id, isPro: isPro).count == 1)
        let file = dir.file("input.txt")
        let preview = try #require(RuleEngine.previewFile(path: file, depth: 0, rules: [rule], isPro: isPro))
        #expect(preview.rules.first?.actions.count == actionCount)
        #expect(FileManager.default.fileExists(atPath: file))
        let manual = RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "manual", root: dir.path, isPro: isPro)
        #expect(manual.history.count == actionCount)
        #expect(manual.history.allSatisfy { $0.status == .applied })
        try FileManager.default.removeItem(atPath: dir.path + "/step\(actionCount - 1).txt")
        _ = dir.file("input.txt")
        let watcher = WatcherCoordinator(db: db)
        watcher.setProAccess(isPro)
        watcher.handle(event: .rescanSubtree(dir.path))
        #expect(try db.listHistory().count == actionCount)
        #expect(try db.listHistory().allSatisfy { $0.status == .applied })
        #expect(try db.listRules(folderId: folder.id).first?.actions.count == actionCount)
    }

    @Test(arguments: [false, true])
    func scriptActionRequiresProForPreviewManualRunAndWatcher(isPro: Bool) throws {
        let dir = TempDir()
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "Script")
        rule.conditions = [makeCondition(.name, .is, "input.txt", ruleId: rule.id)]
        rule.actions = [makeAction(.runScript, .object(["script": .string("printf done > \"$FOREL_FILE.marker\"")]), ruleId: rule.id)]
        try db.insertRule(rule, isPro: true)
        let file = dir.file("input.txt")
        let marker = file + ".marker"
        #expect((RuleEngine.previewFile(path: file, depth: 0, rules: [rule], isPro: isPro) != nil) == isPro)
        #expect(!FileManager.default.fileExists(atPath: marker))
        let manual = RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "manual", isPro: isPro)
        #expect(manual.history.count == (isPro ? 1 : 0))
        #expect(FileManager.default.fileExists(atPath: marker) == isPro)
        if isPro { try FileManager.default.removeItem(atPath: marker) }
        let watcher = WatcherCoordinator(db: db)
        watcher.setProAccess(isPro)
        watcher.handle(path: file)
        #expect(FileManager.default.fileExists(atPath: marker) == isPro)
        #expect(try db.listHistory().count == (isPro ? 1 : 0))
    }

}
