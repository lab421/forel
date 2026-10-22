import Foundation
import Testing
@testable import ForelCore

@Suite struct RuleCopyingTests {
    @Test func copiesKeepConfigurationAndOrderButHaveIndependentIdentities() throws {
        let dir = TempDir()
        let databasePath = dir.path + "/rules.db"
        let source = WatchedFolder(path: dir.dir("Source"))
        let destination = WatchedFolder(path: dir.dir("Destination"), enabled: false)
        var copiedRules: [Rule] = []
        var originals: [Rule] = []
        do {
            let db = try Database(path: databasePath)
            try db.insertFolder(source)
            try db.insertFolder(destination)
            for index in 0..<3 {
                var rule = makeRule(
                    folderId: source.id, name: "Rule \(index)", enabled: index != 2,
                    conditionMatch: .any, recursionDepth: index == 0 ? nil : 2
                )
                rule.conditions = [
                    makeCondition(.extension_, .is, "txt", ruleId: rule.id),
                    makeCondition(.dateAdded, .olderThan, "2 hours", ruleId: rule.id),
                ]
                rule.actions = [
                    makeAction(.rename, .object([ActionParam.pattern: .string("{name}-sorted")]), position: 1, ruleId: rule.id),
                    makeAction(.moveToFolder, .object([
                        ActionParam.destination: .string(dir.path + "/Archive"),
                        ActionParam.onConflict: .string("rename"),
                    ]), position: 4, ruleId: rule.id),
                ]
                try db.insertRule(rule)
            }
            originals = try db.listRules(folderId: source.id)
            try db.insertRule(makeRule(folderId: destination.id, name: originals[0].name))
            copiedRules = try db.copyRules(
                [originals[2].id, originals[0].id], fromFolderID: source.id, toFolderID: destination.id, isPro: false
            )
            let selected = [originals[0], originals[2]]
            #expect(copiedRules.map(\.name) == selected.map(\.name))
            #expect(copiedRules.map(\.priority) == [1, 2])
            #expect(try db.listRules(folderId: destination.id).count == 3)
            #expect(try db.listHistory().isEmpty)
            for (original, copy) in zip(selected, copiedRules) {
                #expect(copy.id != original.id)
                #expect(copy.folderId == destination.id)
                #expect(copy.enabled == original.enabled)
                #expect(copy.conditionMatch == original.conditionMatch)
                #expect(copy.recursionDepth == original.recursionDepth)
                #expect(Set(copy.conditions.map(\.id)).isDisjoint(with: original.conditions.map(\.id)))
                #expect(copy.conditions.allSatisfy { $0.ruleId == copy.id })
                #expect(copy.conditions.map(\.kind) == original.conditions.map(\.kind))
                #expect(copy.conditions.map(\.operator) == original.conditions.map(\.operator))
                #expect(copy.conditions.map(\.value) == original.conditions.map(\.value))
                #expect(Set(copy.actions.map(\.id)).isDisjoint(with: original.actions.map(\.id)))
                #expect(copy.actions.allSatisfy { $0.ruleId == copy.id })
                #expect(copy.actions.map(\.kind) == original.actions.map(\.kind))
                #expect(copy.actions.map(\.params) == original.actions.map(\.params))
                #expect(copy.actions.map(\.position) == original.actions.map(\.position))
            }
            #expect(try db.listRules(folderId: source.id) == originals)
        }

        // Reopen the saved database, edit a copy and delete an original.
        let reopened = try Database(path: databasePath)
        #expect(try reopened.listRules(folderId: destination.id).dropFirst().map { $0 } == copiedRules)
        var edited = copiedRules[0]
        edited.name = "Changed copy"
        edited.conditions[0].value = "pdf"
        edited.actions[1].params = .object([ActionParam.destination: .string("/different/path")])
        try reopened.updateRule(edited)
        #expect(try reopened.listRules(folderId: source.id) == originals)
        try reopened.deleteRule(originals[0].id)
        #expect(try reopened.listRules(folderId: destination.id).dropFirst().map { $0 } == [edited, copiedRules[1]])
    }

    @Test func freeRestrictionsAndFailuresNeverLeavePartialCopies() throws {
        let dir = TempDir()
        let db = try Database(path: ":memory:")
        let folders = (0..<3).map { WatchedFolder(path: dir.dir("Folder\($0)")) }
        for folder in folders { try db.insertFolder(folder) }
        let normal = makeRule(folderId: folders[0].id, name: "Normal")
        var paid = makeRule(folderId: folders[0].id, name: "Media import")
        paid.actions = [makeAction(.importToLibrary, .object([ActionParam.libraryType: .string("photos")]), ruleId: paid.id)]
        try db.insertRule(normal)
        try db.insertRule(paid)
        let selection: Set<String> = [normal.id, paid.id]

        #expect(throws: FreePlanError.proFolder) {
            try db.copyRules([normal.id], fromFolderID: folders[0].id, toFolderID: folders[2].id, isPro: false)
        }
        #expect(throws: FreePlanError.feature(.libraryImports)) {
            try db.copyRules(selection, fromFolderID: folders[0].id, toFolderID: folders[1].id, isPro: false)
        }
        #expect(try db.listRules(folderId: folders[1].id).isEmpty)
        #expect(throws: RuleCopyError.self) {
            try db.copyRules([normal.id, "missing-rule"], fromFolderID: folders[0].id, toFolderID: folders[1].id, isPro: true)
        }
        #expect(throws: RuleCopyError.self) {
            try db.copyRules([normal.id], fromFolderID: folders[0].id, toFolderID: "removed-folder", isPro: true)
        }
        #expect(throws: RuleCopyError.self) {
            try db.copyRules([normal.id], fromFolderID: folders[0].id, toFolderID: folders[0].id, isPro: true)
        }
        #expect(throws: RuleCopyError.self) {
            try db.copyRules([], fromFolderID: folders[0].id, toFolderID: folders[1].id, isPro: true)
        }
        #expect(try db.listRules(folderId: folders[1].id).isEmpty)
        #expect(try db.listRules(folderId: folders[2].id).isEmpty)

        // Pro can copy enabled premium rules, including to the third folder.
        let proCopies = try db.copyRules(selection, fromFolderID: folders[0].id, toFolderID: folders[2].id, isPro: true)
        #expect(proCopies.count == 2)
        #expect(proCopies.allSatisfy { $0.enabled })
        // Free may recover ordinary rules from a folder retained after Pro.
        let recovered = try db.copyRules([proCopies[0].id], fromFolderID: folders[2].id, toFolderID: folders[1].id, isPro: false)
        #expect(recovered.first?.name == normal.name)
        paid.enabled = false
        try db.updateRule(paid)
        let disabledCopy = try db.copyRules([paid.id], fromFolderID: folders[0].id, toFolderID: folders[1].id, isPro: false)
        #expect(disabledCopy.first?.enabled == false)
        #expect(disabledCopy.first?.actions.first?.kind == .importToLibrary)
    }

    @Test(arguments: ["preview", "manual", "watcher"])
    func copiedRulesRunInDestinationAcrossAllExecutionPaths(execution: String) throws {
        let dir = TempDir()
        let db = try Database(path: ":memory:")
        let source = WatchedFolder(path: dir.dir("Source"))
        let destination = WatchedFolder(path: dir.dir("Destination"))
        _ = dir.dir("Destination/Nested")
        let archive = dir.dir("Archive")
        let sourceFile = dir.file("Source/report.txt")
        let file = dir.file("Destination/Nested/report.txt")
        for folder in [source, destination] { try db.insertFolder(folder) }
        var rename = makeRule(folderId: source.id, name: "Rename", recursionDepth: 1)
        rename.conditions = [makeCondition(.extension_, .is, "txt", ruleId: rename.id)]
        rename.actions = [makeAction(.rename, .object([ActionParam.pattern: .string("processed-{name}")]), ruleId: rename.id)]
        var move = makeRule(folderId: source.id, name: "Move", recursionDepth: 1)
        move.conditions = [makeCondition(.extension_, .is, "txt", ruleId: move.id)]
        move.actions = [makeAction(.moveToFolder, .object([ActionParam.destination: .string(archive)]), ruleId: move.id)]
        try db.insertRule(rename)
        try db.insertRule(move)
        let copies = try db.copyRules([move.id, rename.id], fromFolderID: source.id, toFolderID: destination.id, isPro: false)
        #expect(FileManager.default.fileExists(atPath: file))
        #expect(try db.listHistory().isEmpty)
        let rules = try db.executionRules(folderID: destination.id, isPro: false)
        let resultPath = archive + "/processed-report.txt"
        if execution == "preview" {
            let preview = try #require(RuleEngine.previewFile(path: file, depth: 1, rules: rules, isPro: false))
            #expect(preview.rules.map(\.ruleId) == copies.map(\.id))
            #expect(preview.rules.last?.actions.last?.targetPath == resultPath)
            #expect(FileManager.default.fileExists(atPath: file))
            #expect(!FileManager.default.fileExists(atPath: resultPath))
        } else {
            let history: [HistoryEntry]
            if execution == "manual" {
                history = RuleEngine.walkEntries(root: destination.path, maxDepth: 1).flatMap { entry in
                    RuleEngine.run(path: entry.path, depth: entry.depth, rules: rules, batchId: "manual", root: destination.path, isPro: false).history
                }
            } else {
                let watcher = WatcherCoordinator(db: db, settleInterval: 0.01)
                watcher.enqueue(event: .pathArrived(file))
                watcher.waitForPendingEvents()
                history = try db.listHistory()
            }
            #expect(history.count == 2)
            #expect(history.allSatisfy { $0.status == .applied })
            #expect(Set(history.compactMap(\.ruleId)) == Set(copies.map(\.id)))
            #expect(FileManager.default.fileExists(atPath: resultPath))
            #expect(!FileManager.default.fileExists(atPath: file))
        }
        #expect(FileManager.default.fileExists(atPath: sourceFile))
        #expect(try db.listRules(folderId: source.id).map(\.id) == [rename.id, move.id])
    }
}
