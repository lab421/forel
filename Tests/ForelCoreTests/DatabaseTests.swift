// Forel - A native macOS file-automation app
// Copyright (C) 2026  Lab421
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

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

    @Test func openApplicationActionSurvivesDatabaseRoundTrip() throws {
        let db = try makeDB()
        let folder = WatchedFolder(path: "/tmp/forel-test-\(UUID().uuidString)")
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "open in app")
        rule.actions = [
            makeAction(.openApplication, .object([
                ActionParam.applicationPath: .string("/Applications/TextEdit.app"),
                ActionParam.passFileToApplication: .bool(true),
            ]), position: 0, ruleId: rule.id),
        ]

        try db.insertRule(rule)

        let loaded = try #require(db.listRules(folderId: folder.id).first)
        let action = try #require(loaded.actions.first)
        #expect(action.kind == .openApplication)
        #expect(action.params[ActionParam.applicationPath]?.stringValue == "/Applications/TextEdit.app")
        #expect(action.params[ActionParam.passFileToApplication]?.boolValue == true)
    }

    @Test func insertFolderAppendsToOrder() throws {
        let db = try makeDB()
        try db.insertFolder(WatchedFolder(path: "/tmp/forel-test-\(UUID().uuidString)-first"))
        try db.insertFolder(WatchedFolder(path: "/tmp/forel-test-\(UUID().uuidString)-second"))
        try db.insertFolder(WatchedFolder(path: "/tmp/forel-test-\(UUID().uuidString)-third"))

        let loaded = try db.listFolders()
        #expect(loaded.map(\.priority) == [0, 1, 2])
    }

    @Test func reorderFoldersPersistsRequestedOrder() throws {
        let db = try makeDB()
        let first = WatchedFolder(path: "/tmp/forel-test-\(UUID().uuidString)-first")
        let second = WatchedFolder(path: "/tmp/forel-test-\(UUID().uuidString)-second")
        let third = WatchedFolder(path: "/tmp/forel-test-\(UUID().uuidString)-third")
        try db.insertFolder(first)
        try db.insertFolder(second)
        try db.insertFolder(third)

        try db.reorderFolders([third.id, first.id, second.id])

        let loaded = try db.listFolders()
        #expect(loaded.map(\.path) == [third.path, first.path, second.path])
        #expect(loaded.map(\.priority) == [0, 1, 2])
    }

    @Test func reorderFoldersRejectsInvalidFolderSets() throws {
        let db = try makeDB()
        let first = WatchedFolder(path: "/tmp/forel-test-\(UUID().uuidString)-first")
        let second = WatchedFolder(path: "/tmp/forel-test-\(UUID().uuidString)-second")
        try db.insertFolder(first)
        try db.insertFolder(second)

        #expect(throws: (any Error).self) {
            try db.reorderFolders([first.id])
        }
        #expect(throws: (any Error).self) {
            try db.reorderFolders([first.id, first.id])
        }
        #expect(throws: (any Error).self) {
            try db.reorderFolders([first.id, UUID().uuidString])
        }
    }

    @Test func updateFolderPathPreservesFolderRulesAndOrder() throws {
        let db = try makeDB()
        let first = WatchedFolder(path: "/tmp/forel-test-\(UUID().uuidString)-first")
        let second = WatchedFolder(path: "/tmp/forel-test-\(UUID().uuidString)-second")
        try db.insertFolder(first)
        try db.insertFolder(second)
        try db.insertRule(makeRule(folderId: first.id, name: "kept rule"))

        let updatedPath = "/tmp/forel-test-\(UUID().uuidString)-updated"
        try db.updateFolderPath(first.id, path: updatedPath)

        let folders = try db.listFolders()
        #expect(folders.map(\.id) == [first.id, second.id])
        #expect(folders.map(\.path) == [updatedPath, second.path])
        #expect(folders.map(\.priority) == [0, 1])

        let rules = try db.listRules(folderId: first.id)
        #expect(rules.map(\.name) == ["kept rule"])
    }

    @Test func updateFolderPathRejectsDuplicatePath() throws {
        let db = try makeDB()
        let first = WatchedFolder(path: "/tmp/forel-test-\(UUID().uuidString)-first")
        let second = WatchedFolder(path: "/tmp/forel-test-\(UUID().uuidString)-second")
        try db.insertFolder(first)
        try db.insertFolder(second)

        #expect(throws: (any Error).self) {
            try db.updateFolderPath(first.id, path: second.path)
        }

        let folders = try db.listFolders()
        #expect(folders.map(\.path) == [first.path, second.path])
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
            HistoryEntry(
                batchId: "batch-1", ruleId: "rule", ruleName: "demo", actionKind: .runScript,
                originalPath: "/from", resultPath: "/to", undo: .object(["kind": .string("none")]),
                reversible: false, status: .failed, message: "script exited with status 1"
            ),
        ]
        try db.insertHistoryEntries(entries)

        #expect(try db.listHistory().count == 2)
        #expect(try db.listHistoryBatch("batch-1").count == 2)

        try db.markHistoryUndone(entries[0].id)
        let reloaded = try db.getHistoryEntry(entries[0].id)
        #expect(reloaded?.status == .undone)
        #expect(reloaded?.reversible == true)
        let failed = try db.getHistoryEntry(entries[1].id)
        #expect(failed?.status == .failed)
        #expect(failed?.message == "script exited with status 1")

        try db.clearHistory()
        #expect(try db.listHistory().isEmpty)
    }

    @Test func historyCanBePagedAndFilteredByDirectory() throws {
        let db = try makeDB()
        let entries = [
            HistoryEntry(
                id: "older",
                batchId: "batch-1",
                ruleId: "rule",
                ruleName: "demo",
                actionKind: .moveToFolder,
                originalPath: "/tmp/inbox/a.txt",
                resultPath: "/tmp/archive/a.txt",
                undo: .object(["kind": .string("none")]),
                reversible: true,
                createdAt: "2026-06-20T10:00:00Z"
            ),
            HistoryEntry(
                id: "newer",
                batchId: "batch-2",
                ruleId: "rule",
                ruleName: "demo",
                actionKind: .moveToFolder,
                originalPath: "/tmp/inbox/sub/b.txt",
                resultPath: "/tmp/archive/b.txt",
                undo: .object(["kind": .string("none")]),
                reversible: true,
                createdAt: "2026-06-20T11:00:00Z"
            ),
            HistoryEntry(
                id: "prefix-neighbor",
                batchId: "batch-3",
                ruleId: "rule",
                ruleName: "demo",
                actionKind: .moveToFolder,
                originalPath: "/tmp/inbox-other/c.txt",
                resultPath: "/tmp/archive/c.txt",
                undo: .object(["kind": .string("none")]),
                reversible: true,
                createdAt: "2026-06-20T12:00:00Z"
            ),
        ]
        try db.insertHistoryEntries(entries)

        #expect(try db.countHistory() == 3)
        #expect(try db.listHistory(limit: 1).map(\.id) == ["prefix-neighbor"])
        #expect(try db.listHistory(limit: 1, offset: 1).map(\.id) == ["newer"])

        let filtered = try db.listHistory(limit: 10, directoryPath: "/tmp/inbox")
        #expect(try db.countHistory(directoryPath: "/tmp/inbox") == 2)
        #expect(filtered.map(\.id) == ["newer", "older"])
    }

    @Test func ruleRunStatsCountsSuccessAndFailedWithinWindowPerRule() throws {
        let db = try makeDB()
        let now = ISO8601DateFormatter.forelUTC.string(from: Date())
        let tooOld = ISO8601DateFormatter.forelUTC.string(from: Date().addingTimeInterval(-40 * 86400))
        let entries = [
            HistoryEntry(
                batchId: "b1", ruleId: "rule-a", ruleName: "Archive PDFs", actionKind: .moveToFolder,
                originalPath: "/a1", resultPath: "/a1-out", undo: .object(["kind": .string("none")]),
                reversible: true, status: .applied, createdAt: now
            ),
            HistoryEntry(
                batchId: "b1", ruleId: "rule-a", ruleName: "Archive PDFs", actionKind: .moveToFolder,
                originalPath: "/a2", resultPath: "/a2-out", undo: .object(["kind": .string("none")]),
                reversible: true, status: .undone, createdAt: now
            ),
            HistoryEntry(
                batchId: "b1", ruleId: "rule-a", ruleName: "Archive PDFs", actionKind: .moveToFolder,
                originalPath: "/a3", resultPath: "/a3-out", undo: .object(["kind": .string("none")]),
                reversible: false, status: .failed, createdAt: now
            ),
            HistoryEntry(
                batchId: "b2", ruleId: "rule-b", ruleName: "Run Script", actionKind: .runScript,
                originalPath: "/b1", resultPath: "/b1", undo: .object(["kind": .string("none")]),
                reversible: false, status: .failed, createdAt: now
            ),
            // Older than the 30-day window: must not be counted.
            HistoryEntry(
                batchId: "b3", ruleId: "rule-a", ruleName: "Archive PDFs", actionKind: .moveToFolder,
                originalPath: "/old", resultPath: "/old-out", undo: .object(["kind": .string("none")]),
                reversible: true, status: .applied, createdAt: tooOld
            ),
        ]
        try db.insertHistoryEntries(entries)

        let stats = try db.ruleRunStats(sinceDays: 30).sorted { $0.ruleName < $1.ruleName }
        #expect(stats.count == 2)
        #expect(stats[0].ruleName == "Archive PDFs")
        #expect(stats[0].successCount == 2)
        #expect(stats[0].failedCount == 1)
        #expect(stats[1].ruleName == "Run Script")
        #expect(stats[1].successCount == 0)
        #expect(stats[1].failedCount == 1)
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
