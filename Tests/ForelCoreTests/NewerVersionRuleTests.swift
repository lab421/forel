import Testing
import Foundation
@testable import ForelCore

/// Rules saved by a newer Forel that this version doesn't fully know, as
/// after going back to an older version.
@Suite struct NewerVersionRuleTests {
    private struct Setup {
        let db: Database
        let dir: TempDir
        let folder: WatchedFolder
        let rule: Rule
        let file: String
        let destinationDir: TempDir
        var destination: String { destinationDir.path }
    }

    /// A watched folder with a "move PDFs" rule, whose `column` in `table` is
    /// then overwritten with a value only a newer version would know.
    private func setUp(table: String, column: String) throws -> Setup {
        let db = try Database(path: ":memory:")
        let dir = TempDir()
        let destinationDir = TempDir()
        let destination = destinationDir.path
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "move pdf", recursionDepth: 0)
        rule.enabled = true
        rule.conditions = [makeCondition(.extension_, .is, "pdf", ruleId: rule.id)]
        rule.actions = [makeAction(.moveToFolder, .object([ActionParam.destination: .string(destination)]), position: 0, ruleId: rule.id)]
        try db.insertRule(rule)
        try db.exec("UPDATE \(table) SET \(column) = 'from_the_future' WHERE rule_id = '\(rule.id)'")
        let file = dir.file("invoice.pdf", contents: "pdf")
        return Setup(db: db, dir: dir, folder: folder, rule: rule, file: file, destinationDir: destinationDir)
    }

    private static let unknownParts = [("actions", "kind"), ("conditions", "kind"), ("conditions", "operator")]

    @Test(arguments: unknownParts)
    func unknownPartsAreReportedInsteadOfGuessed(table: String, column: String) throws {
        let setup = try setUp(table: table, column: column)

        let loaded = try #require(setup.db.listRules(folderId: setup.folder.id).first)

        #expect(loaded.unsupportedParts == ["from_the_future"])
        #expect(!loaded.isSupported)
    }

    @Test(arguments: unknownParts)
    func unsupportedRulesNeverRun(table: String, column: String) throws {
        let setup = try setUp(table: table, column: column)
        let rules = try setup.db.listRules(folderId: setup.folder.id)

        // Dry Run and Run Now, even if handed the rule directly.
        #expect(RuleEngine.previewFile(path: setup.file, depth: 0, rules: rules) == nil)
        #expect(RuleEngine.run(path: setup.file, depth: 0, rules: rules, batchId: "b").history.isEmpty)
        #expect(try setup.db.executionRules(folderID: setup.folder.id, isPro: true).isEmpty)

        // Automatic watching.
        let coordinator = WatcherCoordinator(db: setup.db, settleInterval: 0.05)
        coordinator.enqueue(event: .pathArrived(setup.file))
        coordinator.waitForPendingEvents()

        #expect(FileManager.default.fileExists(atPath: setup.file))
        #expect(try FileManager.default.contentsOfDirectory(atPath: setup.destination).isEmpty)
        #expect(try setup.db.listHistory().isEmpty)
    }

    @Test func unsupportedRulesCannotBeSavedOrCopiedButKeepWhatTheNewerVersionStored() throws {
        let setup = try setUp(table: "actions", column: "kind")
        let otherDir = TempDir()
        let other = WatchedFolder(path: otherDir.path)
        try setup.db.insertFolder(other)
        var loaded = try #require(setup.db.listRules(folderId: setup.folder.id).first)

        // Even a rule rebuilt without the flag, as an editor could.
        loaded.unsupportedParts = []
        loaded.name = "renamed"
        #expect(throws: UnsupportedRuleError.self) { try setup.db.updateRule(loaded) }
        #expect(throws: UnsupportedRuleError.self) {
            try setup.db.copyRules([setup.rule.id], fromFolderID: setup.folder.id, toFolderID: other.id, isPro: true)
        }
        // Turning it off and on only touches the rule's own switch.
        try setup.db.toggleRule(setup.rule.id, enabled: false)
        try setup.db.toggleRule(setup.rule.id, enabled: true)

        let stored = try #require(setup.db.listRules(folderId: setup.folder.id).first)
        #expect(stored.name == "move pdf")
        #expect(stored.unsupportedParts == ["from_the_future"])
        #expect(try setup.db.listRules(folderId: other.id).isEmpty)

        try setup.db.deleteRule(setup.rule.id)
        #expect(try setup.db.listRules(folderId: setup.folder.id).isEmpty)
    }
}
