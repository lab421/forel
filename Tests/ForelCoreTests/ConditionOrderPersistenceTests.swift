import Foundation
import SQLite3
import Testing
@testable import ForelCore

@Suite struct ConditionOrderPersistenceTests {
    @Test func orderedScriptAndCaptureConditionsSurviveReopenAndUpdate() throws {
        let dir = TempDir()
        let databasePath = (dir.path as NSString).appendingPathComponent("rules.sqlite")
        let folder = WatchedFolder(path: dir.path)
        var capture = CustomTextCondition()
        capture.names = "Person"
        capture.pattern = "invoice-(\\w+)"
        let check = SpotlightCondition(key: "Person", type: .text, operand: "Ada")
        let script = HazelScriptCondition(source: "exit 0")
        var rule = makeRule(folderId: folder.id, name: "ordered")
        rule.conditions = [
            Condition(id: "z-script", ruleId: rule.id, kind: .hazelScriptCondition, operator: .is, value: script.encoded),
            Condition(id: "m-capture", ruleId: rule.id, kind: .customTextMatch, operator: .is, value: capture.encoded),
            Condition(id: "a-consumer", ruleId: rule.id, kind: .scriptAttribute, operator: .is, value: check.encoded)
        ]
        rule.actions = [makeAction(.rename, .object([ActionParam.pattern: .string("done.txt")]), ruleId: rule.id)]
        do {
            let db = try Database(path: databasePath)
            try db.insertFolder(folder)
            try db.insertRule(rule)
        }
        let db = try Database(path: databasePath)
        var loaded = try #require(db.listRules(folderId: folder.id).first)
        #expect(loaded.conditions.map(\.id) == ["z-script", "m-capture", "a-consumer"])
        loaded.conditions.swapAt(0, 2)
        try db.updateRule(loaded)
        let reversed = try #require(db.listRules(folderId: folder.id).first)
        #expect(reversed.conditions.map(\.id) == ["a-consumer", "m-capture", "z-script"])
        let ignored = dir.file("invoice-Ada.txt")
        WatcherCoordinator(db: db).handle(path: ignored)
        #expect(FileManager.default.fileExists(atPath: ignored))
        loaded.conditions.swapAt(0, 2)
        try db.updateRule(loaded)
        let fresh = dir.file("invoice-Ada-new.txt")
        WatcherCoordinator(db: db).handle(path: fresh)
        #expect(FileManager.default.fileExists(atPath: (dir.path as NSString).appendingPathComponent("done.txt")))
        #expect(!FileManager.default.fileExists(atPath: fresh))
        let reopened = try Database(path: databasePath)
        #expect(try reopened.listRules(folderId: folder.id).first?.conditions.map(\.id) == ["z-script", "m-capture", "a-consumer"])
    }

    @Test func legacyMigrationPreservesRowOrderWithinEachRule() throws {
        let dir = TempDir()
        let databasePath = (dir.path as NSString).appendingPathComponent("legacy.sqlite")
        let folder = WatchedFolder(path: dir.path)
        do {
            let db = try Database(path: databasePath)
            try db.insertFolder(folder)
            for name in ["first", "second"] {
                var rule = makeRule(folderId: folder.id, name: name)
                rule.conditions = [Condition(id: "\(name)-z", ruleId: rule.id, kind: .name, operator: .contains, value: "a"),
                                   Condition(id: "\(name)-a", ruleId: rule.id, kind: .extension_, operator: .is, value: "txt")]
                try db.insertRule(rule)
            }
        }
        var raw: OpaquePointer?
        #expect(sqlite3_open(databasePath, &raw) == SQLITE_OK)
        let sql = """
            DROP INDEX IF EXISTS idx_conditions_rule_position;
            ALTER TABLE conditions RENAME TO conditions_v15;
            CREATE TABLE conditions (id TEXT PRIMARY KEY, rule_id TEXT NOT NULL REFERENCES rules(id) ON DELETE CASCADE,
                                     kind TEXT NOT NULL, operator TEXT NOT NULL, value TEXT NOT NULL);
            INSERT INTO conditions (id,rule_id,kind,operator,value)
                SELECT id,rule_id,kind,operator,value FROM conditions_v15 ORDER BY rowid;
            DROP TABLE conditions_v15;
            PRAGMA user_version=14;
            """
        #expect(sqlite3_exec(raw, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)
        let migrated = try Database(path: databasePath)
        for rule in try migrated.listRules(folderId: folder.id) {
            #expect(rule.conditions.map(\.id) == ["\(rule.name)-z", "\(rule.name)-a"])
        }
    }
}
