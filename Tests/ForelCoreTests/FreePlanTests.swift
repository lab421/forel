import Foundation
import Testing
@testable import ForelCore

@Suite struct FreePlanTests {
    @Test func persistenceRejectsExcessFoldersAndRulesButAllowsPro() throws {
        let db = try Database(path: ":memory:")
        let first = WatchedFolder(path: "/tmp/first")
        try db.insertFolder(first, isPro: false)
        try db.insertFolder(WatchedFolder(path: "/tmp/second"), isPro: false)
        #expect(throws: FreePlanError.folderLimit) {
            try db.insertFolder(WatchedFolder(path: "/tmp/third"), isPro: false)
        }
        for index in 0..<5 {
            try db.insertRule(makeRule(folderId: first.id, name: "Disabled \(index)", enabled: false), isPro: false)
        }
        #expect(throws: FreePlanError.ruleLimit) {
            try db.insertRule(makeRule(folderId: first.id, name: "Sixth"), isPro: false)
        }
        var edited = try #require(db.listRules(folderId: first.id).first)
        edited.name = "Edited at the limit"
        try db.updateRule(edited)
        #expect(try db.listRules(folderId: first.id).count == 5)
        try db.insertRule(makeRule(folderId: first.id, name: "Pro sixth"), isPro: true)
        let third = WatchedFolder(path: "/tmp/third", priority: 3)
        try db.insertFolder(third, isPro: true)
        #expect(throws: FreePlanError.proFolder) {
            try db.insertRule(makeRule(folderId: third.id, name: "Blocked"), isPro: false)
        }
        #expect(try db.listFolders().count == 3)
        #expect(try db.listRules(folderId: first.id).count == 6)
    }
    @Test func limitsCountDisabledEntriesAndProRemovesLimits() {
        #expect(FreePlan.canAddFolder(count: 1, isPro: false))
        #expect(!FreePlan.canAddFolder(count: 2, isPro: false))
        #expect(FreePlan.canAddRule(count: 4, isPro: false))
        #expect(!FreePlan.canAddRule(count: 5, isPro: false))
        #expect(FreePlan.canAddFolder(count: 20, isPro: true))
        #expect(FreePlan.canAddRule(count: 50, isPro: true))
    }

    @Test(arguments: [false, true])
    func ruleAllowanceIsConsistentAcrossPreviewManualRunAndWatcher(isPro: Bool) throws {
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
            try db.insertRule(rule)
        }
        let allowed = try db.executionRules(folderID: folder.id, isPro: isPro)
        #expect((RuleEngine.previewFile(path: file, depth: 0, rules: allowed) != nil) == isPro)
        let (_, history) = RuleEngine.run(path: file, depth: 0, rules: allowed, batchId: "manual", root: dir.path)
        #expect(!history.isEmpty == isPro)
        if isPro { _ = dir.file("input.txt") }
        let watcher = WatcherCoordinator(db: db)
        watcher.setProAccess(isPro)
        watcher.handle(event: .rescanSubtree(dir.path))
        #expect(!(try db.listHistory()).isEmpty == isPro)
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
}
