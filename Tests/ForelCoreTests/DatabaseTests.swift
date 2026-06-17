import Testing
import Foundation
import SQLite3
@testable import ForelCore

@Suite struct DatabaseTests {
    func makeDB() throws -> Database {
        try Database(path: ":memory:")
    }

    @Test func ruleRoundTripPreservesTagAndColorVariants() throws {
        let db = try makeDB()
        let folder = WatchedFolder(path: "/tmp/forel-test-\(UUID().uuidString)")
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "tagged images")
        try db.insertRule(rule)

        rule.conditionMatch = .any
        rule.conditions = [
            makeCondition(.tags, .is, "Project", ruleId: rule.id),
            makeCondition(.sizeBytes, .greaterThan, "1 MB", ruleId: rule.id),
        ]
        rule.actions = [
            makeAction(.setColorLabel, .object(["color": .string("Blue")]), position: 2, ruleId: rule.id),
            makeAction(.addTag, .object(["tag": .string("Reviewed")]), position: 1, ruleId: rule.id),
        ]
        try db.updateRule(rule)

        let rules = try db.listRules(folderId: folder.id)
        #expect(rules.count == 1)
        let loaded = rules[0]
        #expect(loaded.conditionMatch == .any)
        #expect(loaded.conditions[0].kind == .tags)
        #expect(loaded.conditions[1].kind == .sizeBytes)
        #expect(loaded.actions[0].kind == .addTag)
        #expect(loaded.actions[0].params == .object(["tag": .string("Reviewed")]))
        #expect(loaded.actions[1].kind == .setColorLabel)
        #expect(loaded.recursionDepth == 0)
    }

    @Test func insertRulePersistsInitialConditionsAndActions() throws {
        let db = try makeDB()
        let folder = WatchedFolder(path: "/tmp/forel-test-\(UUID().uuidString)")
        try db.insertFolder(folder)
        var saved = makeRule(folderId: folder.id, name: "new complete rule", conditionMatch: .any)
        saved.conditions = [
            makeCondition(.name, .contains, "(1)", ruleId: saved.id),
            makeCondition(.name, .contains, "(2)", ruleId: saved.id),
        ]
        saved.actions = [
            makeAction(.delete, .object([:]), position: 0, ruleId: saved.id),
        ]

        try db.insertRule(saved)

        let loaded = try #require(db.listRules(folderId: folder.id).first)
        #expect(loaded.name == "new complete rule")
        #expect(loaded.conditionMatch == .any)
        #expect(loaded.conditions.map(\.value) == ["(1)", "(2)"])
        #expect(loaded.conditions.allSatisfy { $0.ruleId == saved.id })
        #expect(loaded.actions.count == 1)
        #expect(loaded.actions[0].kind == .delete)
        #expect(loaded.actions[0].ruleId == saved.id)
    }

    @Test func ruleRoundTripPreservesEditorConditionFormatsAndScope() throws {
        let db = try makeDB()
        let folder = WatchedFolder(path: "/tmp/forel-test-\(UUID().uuidString)")
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "editor formats", recursionDepth: 3)
        try db.insertRule(rule)

        rule.conditions = [
            makeCondition(.createdAt, .withinLast, "7 weeks", ruleId: rule.id),
            makeCondition(.dateModified, .before, "2026-06-17", ruleId: rule.id),
            makeCondition(.sizeBytes, .greaterThan, "12 MB", ruleId: rule.id),
            makeCondition(.kind, .isNot, "archive", ruleId: rule.id),
        ]
        try db.updateRule(rule)

        let loaded = try #require(db.listRules(folderId: folder.id).first)
        #expect(loaded.recursionDepth == 3)
        #expect(loaded.conditions.map(\.kind) == [.createdAt, .dateModified, .sizeBytes, .kind])
        #expect(loaded.conditions.map(\.operator) == [.withinLast, .before, .greaterThan, .isNot])
        #expect(loaded.conditions.map(\.value) == ["7 weeks", "2026-06-17", "12 MB", "archive"])

        loaded.conditions.forEach { condition in
            #expect(condition.ruleId == rule.id)
        }
    }

    @Test func ruleRoundTripPreservesAllLevelsScope() throws {
        let db = try makeDB()
        let folder = WatchedFolder(path: "/tmp/forel-test-\(UUID().uuidString)")
        try db.insertFolder(folder)
        let rule = makeRule(folderId: folder.id, name: "all levels", recursionDepth: nil)

        try db.insertRule(rule)

        let loaded = try #require(db.listRules(folderId: folder.id).first)
        #expect(loaded.recursionDepth == nil)
    }

    @Test func insertRuleAppendsToFolderOrder() throws {
        let db = try makeDB()
        let folder = WatchedFolder(path: "/tmp/forel-test-\(UUID().uuidString)")
        try db.insertFolder(folder)

        try db.insertRule(makeRule(folderId: folder.id, name: "first"))
        try db.insertRule(makeRule(folderId: folder.id, name: "second"))
        try db.insertRule(makeRule(folderId: folder.id, name: "third"))

        let loaded = try db.listRules(folderId: folder.id)
        #expect(loaded.map(\.priority) == [0, 1, 2])
    }

    @Test func reorderRulesPersistsRequestedOrder() throws {
        let db = try makeDB()
        let folder = WatchedFolder(path: "/tmp/forel-test-\(UUID().uuidString)")
        try db.insertFolder(folder)

        let first = makeRule(folderId: folder.id, name: "first")
        let second = makeRule(folderId: folder.id, name: "second")
        let third = makeRule(folderId: folder.id, name: "third")
        try db.insertRule(first)
        try db.insertRule(second)
        try db.insertRule(third)

        try db.reorderRules(folderId: folder.id, ruleIds: [third.id, first.id, second.id])

        let loaded = try db.listRules(folderId: folder.id)
        #expect(loaded.map(\.name) == ["third", "first", "second"])
        #expect(loaded.map(\.priority) == [0, 1, 2])
    }

    @Test func reorderRulesRejectsInvalidRuleSets() throws {
        let db = try makeDB()
        let folder = WatchedFolder(path: "/tmp/forel-test-\(UUID().uuidString)")
        let other = WatchedFolder(path: "/tmp/forel-test-\(UUID().uuidString)")
        try db.insertFolder(folder)
        try db.insertFolder(other)

        let first = makeRule(folderId: folder.id, name: "first")
        let second = makeRule(folderId: folder.id, name: "second")
        let otherRule = makeRule(folderId: other.id, name: "other")
        try db.insertRule(first)
        try db.insertRule(second)
        try db.insertRule(otherRule)

        #expect(throws: (any Error).self) {
            try db.reorderRules(folderId: folder.id, ruleIds: [first.id])
        }
        #expect(throws: (any Error).self) {
            try db.reorderRules(folderId: folder.id, ruleIds: [first.id, first.id])
        }
        #expect(throws: (any Error).self) {
            try db.reorderRules(folderId: folder.id, ruleIds: [first.id, otherRule.id])
        }
    }

    @Test func updateRuleRollsBackWhenReplacingChildrenFails() throws {
        let db = try makeDB()
        let folder = WatchedFolder(path: "/tmp/forel-test-\(UUID().uuidString)")
        try db.insertFolder(folder)
        var original = makeRule(folderId: folder.id, name: "original")
        try db.insertRule(original)

        original.conditions = [makeCondition(.name, .contains, "invoice", ruleId: original.id)]
        try db.updateRule(original)

        var invalid = original
        invalid.name = "updated"
        invalid.conditions = [makeCondition(.extension_, .is, "pdf", ruleId: "missing-rule-id")]

        #expect(throws: (any Error).self) {
            try db.updateRule(invalid)
        }

        let rules = try db.listRules(folderId: folder.id)
        #expect(rules.count == 1)
        #expect(rules[0].name == "original")
        #expect(rules[0].conditions.count == 1)
        #expect(rules[0].conditions[0].value == "invoice")
    }

    @Test func historyRoundTripInsertListMarkAndClear() throws {
        let db = try makeDB()
        let entries = [
            HistoryEntry(batchId: "batch-1", ruleId: "rule", ruleName: "demo", actionKind: .moveToFolder, originalPath: "/from", resultPath: "/to", undo: .object(["kind": .string("none")]), reversible: true),
            HistoryEntry(batchId: "batch-1", ruleId: "rule", ruleName: "demo", actionKind: .runScript, originalPath: "/from", resultPath: "/to", undo: .object(["kind": .string("none")]), reversible: false),
        ]
        try db.insertHistoryEntries(entries)

        #expect(try db.listHistory().count == 2)
        #expect(try db.listHistoryBatch("batch-1").count == 2)

        try db.markHistoryUndone(entries[0].id)
        let reloaded = try db.getHistoryEntry(entries[0].id)
        #expect(reloaded?.status == .undone)
        #expect(reloaded?.reversible == true)

        try db.clearHistory()
        #expect(try db.listHistory().isEmpty)
    }

    @Test func migrationRejectsNewerSchemaVersions() throws {
        let path = NSTemporaryDirectory().appending("forel-db-test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(atPath: path) }

        var raw: OpaquePointer?
        #expect(sqlite3_open(path, &raw) == SQLITE_OK)
        #expect(sqlite3_exec(raw, "PRAGMA user_version = 99;", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)

        #expect(throws: (any Error).self) {
            _ = try Database(path: path)
        }
    }
}
