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

import SQLite3
import Foundation

extension ISO8601DateFormatter {
    public static var forelUTC: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")!
        return f
    }
}

/// SQLite-backed persistence for watched folders, rules, conditions, actions,
/// custom tags, action history and app settings. Mirrors the Rust `db` module
/// schema exactly so the existing alpha database at
/// `~/Library/Application Support/com.lab421.forel/forel.db` (migrated
/// automatically from the legacy `com.forel.app` location) keeps working.
public final class Database: @unchecked Sendable {
    public static let currentSchemaVersion: Int64 = 8

    private let handle: OpaquePointer
    private let lock = NSLock()

    public init(path: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else {
            throw SQLiteError("failed to open database at \(path)")
        }
        self.handle = db
        try initSchema()
    }

    deinit { sqlite3_close(handle) }

    /// Runs `body` while holding the database lock, mirroring the Rust
    /// `Arc<Mutex<Connection>>` access pattern: lock for the shortest possible
    /// scope, then drop before any follow-up side effects (e.g. tray rebuild).
    @discardableResult
    public func withLock<T>(_ body: (Database) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(self)
    }

    func exec(_ sql: String) throws {
        if sqlite3_exec(handle, sql, nil, nil, nil) != SQLITE_OK {
            throw SQLiteError(String(cString: sqlite3_errmsg(handle)))
        }
    }

    func statement(_ sql: String) throws -> SQLiteStatement {
        try SQLiteStatement(handle, sql)
    }

    func tableHasColumn(_ table: String, _ column: String) throws -> Bool {
        let stmt = try statement("PRAGMA table_info(\(table))")
        while try stmt.step() {
            if stmt.columnText(1) == column { return true }
        }
        return false
    }

    func userVersion() throws -> Int64 {
        let stmt = try statement("PRAGMA user_version")
        _ = try stmt.step()
        return stmt.columnInt64(0)
    }

    func setUserVersion(_ version: Int64) throws {
        try exec("PRAGMA user_version = \(version)")
    }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        try exec("COMMIT")
    }

    // MARK: - Schema + migrations

    private func initSchema() throws {
        try exec(
            """
            PRAGMA journal_mode=WAL;
            PRAGMA foreign_keys=ON;

            CREATE TABLE IF NOT EXISTS watched_folders (
                id          TEXT PRIMARY KEY,
                path        TEXT NOT NULL UNIQUE,
                enabled     INTEGER NOT NULL DEFAULT 1,
                priority    INTEGER NOT NULL DEFAULT 0,
                created_at  TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS rules (
                id               TEXT PRIMARY KEY,
                folder_id        TEXT NOT NULL REFERENCES watched_folders(id) ON DELETE CASCADE,
                name             TEXT NOT NULL,
                enabled          INTEGER NOT NULL DEFAULT 1,
                condition_match  TEXT NOT NULL DEFAULT 'all',
                recursion_depth  INTEGER NOT NULL DEFAULT 0,
                priority         INTEGER NOT NULL DEFAULT 0,
                created_at       TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS conditions (
                id        TEXT PRIMARY KEY,
                rule_id   TEXT NOT NULL REFERENCES rules(id) ON DELETE CASCADE,
                kind      TEXT NOT NULL,
                operator  TEXT NOT NULL,
                value     TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS actions (
                id        TEXT PRIMARY KEY,
                rule_id   TEXT NOT NULL REFERENCES rules(id) ON DELETE CASCADE,
                kind      TEXT NOT NULL,
                params    TEXT NOT NULL,
                position  INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS custom_tags (
                name TEXT PRIMARY KEY
            );

            CREATE TABLE IF NOT EXISTS action_history (
                id            TEXT PRIMARY KEY,
                batch_id      TEXT NOT NULL,
                rule_id       TEXT,
                rule_name     TEXT NOT NULL,
                action_kind   TEXT NOT NULL,
                original_path TEXT NOT NULL,
                result_path   TEXT NOT NULL,
                undo          TEXT NOT NULL,
                reversible    INTEGER NOT NULL DEFAULT 0,
                status        TEXT NOT NULL DEFAULT 'applied',
                message       TEXT,
                created_at    TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_action_history_batch ON action_history(batch_id);
            CREATE INDEX IF NOT EXISTS idx_action_history_created ON action_history(created_at);
            CREATE INDEX IF NOT EXISTS idx_action_history_original_path ON action_history(original_path);
            CREATE INDEX IF NOT EXISTS idx_action_history_result_path ON action_history(result_path);

            CREATE TABLE IF NOT EXISTS app_settings (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS watched_path_state (
                path        TEXT PRIMARY KEY,
                volume_id   INTEGER,
                file_id     INTEGER,
                fingerprint TEXT,
                updated_at  TEXT NOT NULL
            );
            """
        )
        try runMigrations()
    }

    // MARK: - App settings

    public func getSetting(_ key: String) throws -> String? {
        let stmt = try statement("SELECT value FROM app_settings WHERE key = ?1")
        stmt.bind(1, key)
        guard try stmt.step() else { return nil }
        return stmt.columnText(0)
    }

    public func setSetting(_ key: String, _ value: String) throws {
        let stmt = try statement(
            "INSERT INTO app_settings (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value"
        )
        stmt.bind(1, key)
        stmt.bind(2, value)
        try stmt.runToCompletion()
    }

    // MARK: - Custom tags

    public func listCustomTags() throws -> [String] {
        let stmt = try statement("SELECT name FROM custom_tags ORDER BY name")
        var tags: [String] = []
        while try stmt.step() { tags.append(stmt.columnText(0)) }
        return tags
    }

    public func insertCustomTag(_ name: String) throws {
        let stmt = try statement("INSERT OR IGNORE INTO custom_tags (name) VALUES (?1)")
        stmt.bind(1, name)
        try stmt.runToCompletion()
    }

    // MARK: - Action history

    private static let historyColumns =
        "id, batch_id, rule_id, rule_name, action_kind, original_path, result_path, undo, reversible, status, message, created_at, result_volume_id, result_file_id"

    private func rowToHistoryEntry(_ stmt: SQLiteStatement) -> HistoryEntry {
        HistoryEntry(
            id: stmt.columnText(0),
            batchId: stmt.columnText(1),
            ruleId: stmt.columnTextOrNil(2),
            ruleName: stmt.columnText(3),
            actionKind: ActionKind(dbValue: stmt.columnText(4)),
            originalPath: stmt.columnText(5),
            resultPath: stmt.columnText(6),
            undo: JSONValue.parse(stmt.columnText(7)),
            reversible: stmt.columnBool(8),
            status: HistoryStatus(rawValue: stmt.columnText(9)) ?? .applied,
            message: stmt.columnTextOrNil(10),
            createdAt: stmt.columnText(11),
            resultVolumeId: stmt.columnInt64OrNil(12),
            resultFileId: stmt.columnInt64OrNil(13)
        )
    }

    public func insertHistoryEntries(_ entries: [HistoryEntry]) throws {
        for entry in entries {
            let stmt = try statement(
                """
                INSERT INTO action_history
                (id, batch_id, rule_id, rule_name, action_kind, original_path, result_path, undo, reversible, status, message, created_at, result_volume_id, result_file_id)
                VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14)
                """
            )
            stmt.bind(1, entry.id)
            stmt.bind(2, entry.batchId)
            stmt.bind(3, entry.ruleId)
            stmt.bind(4, entry.ruleName)
            stmt.bind(5, entry.actionKind.rawValue)
            stmt.bind(6, entry.originalPath)
            stmt.bind(7, entry.resultPath)
            stmt.bind(8, entry.undo.jsonString)
            stmt.bind(9, bool: entry.reversible)
            stmt.bind(10, entry.status.rawValue)
            stmt.bind(11, entry.message)
            stmt.bind(12, entry.createdAt)
            stmt.bind(13, entry.resultVolumeId)
            stmt.bind(14, entry.resultFileId)
            try stmt.runToCompletion()
        }
    }

    public func listHistory(limit: Int? = nil, offset: Int = 0, directoryPath: String? = nil) throws -> [HistoryEntry] {
        let (whereClause, bindings) = Self.historyDirectoryFilter(directoryPath)
        let limitClause = limit.map { " LIMIT \($0) OFFSET \(max(offset, 0))" } ?? ""
        let stmt = try statement("SELECT \(Self.historyColumns) FROM action_history\(whereClause) ORDER BY created_at DESC, id DESC\(limitClause)")
        bindHistoryDirectoryFilter(bindings, to: stmt)
        var entries: [HistoryEntry] = []
        while try stmt.step() { entries.append(rowToHistoryEntry(stmt)) }
        return entries
    }

    public func countHistory(directoryPath: String? = nil) throws -> Int {
        let (whereClause, bindings) = Self.historyDirectoryFilter(directoryPath)
        let stmt = try statement("SELECT COUNT(*) FROM action_history\(whereClause)")
        bindHistoryDirectoryFilter(bindings, to: stmt)
        _ = try stmt.step()
        return Int(stmt.columnInt64(0))
    }

    public func getHistoryEntry(_ id: String) throws -> HistoryEntry? {
        let stmt = try statement("SELECT \(Self.historyColumns) FROM action_history WHERE id=?1")
        stmt.bind(1, id)
        guard try stmt.step() else { return nil }
        return rowToHistoryEntry(stmt)
    }

    public func listHistoryBatch(_ batchId: String) throws -> [HistoryEntry] {
        let stmt = try statement("SELECT \(Self.historyColumns) FROM action_history WHERE batch_id=?1 ORDER BY created_at")
        stmt.bind(1, batchId)
        var entries: [HistoryEntry] = []
        while try stmt.step() { entries.append(rowToHistoryEntry(stmt)) }
        return entries
    }

    public func markHistoryUndone(_ id: String) throws {
        let stmt = try statement("UPDATE action_history SET status='undone' WHERE id=?1")
        stmt.bind(1, id)
        try stmt.runToCompletion()
    }

    public func clearHistory() throws {
        try exec("DELETE FROM action_history")
    }

    public func purgeHistory(before days: Int) throws {
        let cutoff = ISO8601DateFormatter.forelUTC.string(from: Date().addingTimeInterval(-Double(days) * 86400))
        let stmt = try statement("DELETE FROM action_history WHERE datetime(created_at) < datetime(?1)")
        stmt.bind(1, cutoff)
        try stmt.runToCompletion()
    }

    /// Success ("applied"/"undone") vs. failed counts per rule over the last
    /// `days` days, for the rule list's badges and the menu-bar quick panel.
    public func ruleRunStats(sinceDays days: Int) throws -> [RuleRunStats] {
        let cutoff = ISO8601DateFormatter.forelUTC.string(from: Date().addingTimeInterval(-Double(days) * 86400))
        let stmt = try statement(
            """
            SELECT COALESCE(rule_id, '~' || rule_name) AS rule_key, rule_name,
                SUM(CASE WHEN status IN ('applied', 'undone') THEN 1 ELSE 0 END),
                SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END)
            FROM action_history
            WHERE datetime(created_at) >= datetime(?1)
            GROUP BY rule_key
            ORDER BY rule_name COLLATE NOCASE
            """
        )
        stmt.bind(1, cutoff)
        var stats: [RuleRunStats] = []
        while try stmt.step() {
            stats.append(RuleRunStats(
                id: stmt.columnText(0),
                ruleName: stmt.columnText(1),
                successCount: Int(stmt.columnInt64(2)),
                failedCount: Int(stmt.columnInt64(3))
            ))
        }
        return stats
    }

    private static func historyDirectoryFilter(_ directoryPath: String?) -> (String, [String]) {
        guard let directoryPath else { return ("", []) }
        let path = (directoryPath as NSString).standardizingPath
        let childPattern = historyChildPattern(for: path)
        return (
            " WHERE original_path = ?1 OR result_path = ?2 OR original_path LIKE ?3 ESCAPE '\\' OR result_path LIKE ?4 ESCAPE '\\'",
            [path, path, childPattern, childPattern]
        )
    }

    private static func historyChildPattern(for directoryPath: String) -> String {
        let base = directoryPath == "/" || directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        return escapeLikePattern(base) + "%"
    }

    private static func escapeLikePattern(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\", "%", "_":
                escaped.append("\\")
                escaped.append(character)
            default:
                escaped.append(character)
            }
        }
        return escaped
    }

    private func bindHistoryDirectoryFilter(_ bindings: [String], to stmt: SQLiteStatement) {
        for (index, value) in bindings.enumerated() {
            stmt.bind(Int32(index + 1), value)
        }
    }

    // MARK: - Watched folders

    public func listFolders() throws -> [WatchedFolder] {
        let stmt = try statement("SELECT id, path, enabled, priority, created_at FROM watched_folders ORDER BY priority, created_at")
        var folders: [WatchedFolder] = []
        while try stmt.step() {
            folders.append(WatchedFolder(id: stmt.columnText(0), path: stmt.columnText(1), enabled: stmt.columnBool(2), priority: stmt.columnInt64(3), createdAt: stmt.columnText(4)))
        }
        return folders
    }

    public func folderForPath(_ path: String) throws -> WatchedFolder? {
        try listFolders()
            .filter(\.enabled)
            .filter { Self.isPathPrefix($0.path, of: path) }
            .max { $0.path.count < $1.path.count }
    }

    /// Component-wise prefix check, matching Rust's `Path::starts_with` (a plain
    /// string prefix would wrongly match "/foo/bar2" against folder "/foo/bar").
    private static func isPathPrefix(_ prefix: String, of path: String) -> Bool {
        let prefixComponents = (prefix as NSString).pathComponents
        let pathComponents = (path as NSString).pathComponents
        guard pathComponents.count >= prefixComponents.count else { return false }
        return Array(pathComponents.prefix(prefixComponents.count)) == prefixComponents
    }

    private func nextFolderPriority() throws -> Int64 {
        let stmt = try statement("SELECT COALESCE(MAX(priority) + 1, 0) FROM watched_folders")
        _ = try stmt.step()
        return stmt.columnInt64(0)
    }

    public func insertFolder(_ folder: WatchedFolder) throws {
        let priority = try nextFolderPriority()
        let stmt = try statement("INSERT INTO watched_folders (id, path, enabled, priority, created_at) VALUES (?1,?2,?3,?4,?5)")
        stmt.bind(1, folder.id)
        stmt.bind(2, folder.path)
        stmt.bind(3, bool: folder.enabled)
        stmt.bind(4, priority)
        stmt.bind(5, folder.createdAt)
        try stmt.runToCompletion()
    }

    public func deleteFolder(_ id: String) throws {
        let stmt = try statement("DELETE FROM watched_folders WHERE id=?1")
        stmt.bind(1, id)
        try stmt.runToCompletion()
    }

    public func updateFolderPath(_ id: String, path: String) throws {
        let stmt = try statement("UPDATE watched_folders SET path=?1 WHERE id=?2")
        stmt.bind(1, path)
        stmt.bind(2, id)
        try stmt.runToCompletion()
    }

    public func toggleFolder(_ id: String, enabled: Bool) throws {
        let stmt = try statement("UPDATE watched_folders SET enabled=?1 WHERE id=?2")
        stmt.bind(1, bool: enabled)
        stmt.bind(2, id)
        try stmt.runToCompletion()
    }

    public func reorderFolders(_ folderIds: [String]) throws {
        let current = try listFolders()
        guard current.count == folderIds.count else {
            throw SQLiteError("reorder must include every watched folder")
        }
        guard Set(folderIds).count == folderIds.count else {
            throw SQLiteError("reorder contains duplicate folder ids")
        }
        guard Set(folderIds) == Set(current.map(\.id)) else {
            throw SQLiteError("reorder contains unknown or missing folder ids")
        }

        try transaction {
            for (index, folderId) in folderIds.enumerated() {
                let stmt = try statement("UPDATE watched_folders SET priority=?1 WHERE id=?2")
                stmt.bind(1, Int64(index))
                stmt.bind(2, folderId)
                try stmt.runToCompletion()
            }
        }
    }

    // MARK: - Rules

    public func listRules(folderId: String) throws -> [Rule] {
        let stmt = try statement(
            """
            SELECT id, folder_id, name, enabled, condition_match, recursion_depth, priority, created_at
            FROM rules WHERE folder_id=?1 ORDER BY priority, created_at
            """
        )
        stmt.bind(1, folderId)
        var rules: [Rule] = []
        while try stmt.step() {
            let depth = stmt.columnInt64(5)
            rules.append(
                Rule(
                    id: stmt.columnText(0),
                    folderId: stmt.columnText(1),
                    name: stmt.columnText(2),
                    enabled: stmt.columnBool(3),
                    conditionMatch: stmt.columnText(4) == "any" ? .any : .all,
                    recursionDepth: depth >= 0 ? depth : nil,
                    priority: stmt.columnInt64(6),
                    createdAt: stmt.columnText(7)
                )
            )
        }
        for index in rules.indices {
            rules[index].conditions = try listConditions(ruleId: rules[index].id)
            rules[index].actions = try listActions(ruleId: rules[index].id)
        }
        return rules
    }

    public func ruleFolderId(_ ruleId: String) throws -> String? {
        let stmt = try statement("SELECT folder_id FROM rules WHERE id=?1")
        stmt.bind(1, ruleId)
        guard try stmt.step() else { return nil }
        return stmt.columnText(0)
    }

    private func nextRulePriority(folderId: String) throws -> Int64 {
        let stmt = try statement("SELECT COALESCE(MAX(priority) + 1, 0) FROM rules WHERE folder_id=?1")
        stmt.bind(1, folderId)
        _ = try stmt.step()
        return stmt.columnInt64(0)
    }

    public func insertRule(_ rule: Rule) throws {
        let priority = try nextRulePriority(folderId: rule.folderId)
        try transaction {
            let stmt = try statement(
                """
                INSERT INTO rules (id, folder_id, name, enabled, condition_match, recursion_depth, priority, created_at)
                VALUES (?1,?2,?3,?4,?5,?6,?7,?8)
                """
            )
            stmt.bind(1, rule.id)
            stmt.bind(2, rule.folderId)
            stmt.bind(3, rule.name)
            stmt.bind(4, bool: rule.enabled)
            stmt.bind(5, rule.conditionMatch == .any ? "any" : "all")
            stmt.bind(6, rule.recursionDepth ?? -1)
            stmt.bind(7, priority)
            stmt.bind(8, rule.createdAt)
            try stmt.runToCompletion()

            for condition in rule.conditions { try insertCondition(condition) }
            for action in rule.actions { try insertAction(action) }
        }
    }

    public func updateRule(_ rule: Rule) throws {
        try transaction {
            let stmt = try statement(
                "UPDATE rules SET name=?1, enabled=?2, condition_match=?3, recursion_depth=?4, priority=?5 WHERE id=?6"
            )
            stmt.bind(1, rule.name)
            stmt.bind(2, bool: rule.enabled)
            stmt.bind(3, rule.conditionMatch == .any ? "any" : "all")
            stmt.bind(4, rule.recursionDepth ?? -1)
            stmt.bind(5, rule.priority)
            stmt.bind(6, rule.id)
            try stmt.runToCompletion()

            let deleteConditions = try statement("DELETE FROM conditions WHERE rule_id=?1")
            deleteConditions.bind(1, rule.id)
            try deleteConditions.runToCompletion()

            let deleteActions = try statement("DELETE FROM actions WHERE rule_id=?1")
            deleteActions.bind(1, rule.id)
            try deleteActions.runToCompletion()

            for condition in rule.conditions { try insertCondition(condition) }
            for action in rule.actions { try insertAction(action) }
        }
    }

    public func deleteRule(_ id: String) throws {
        let stmt = try statement("DELETE FROM rules WHERE id=?1")
        stmt.bind(1, id)
        try stmt.runToCompletion()
    }

    public func toggleRule(_ id: String, enabled: Bool) throws {
        let stmt = try statement("UPDATE rules SET enabled=?1 WHERE id=?2")
        stmt.bind(1, bool: enabled)
        stmt.bind(2, id)
        try stmt.runToCompletion()
    }

    public func reorderRules(folderId: String, ruleIds: [String]) throws {
        let current = try listRules(folderId: folderId)
        guard current.count == ruleIds.count else {
            throw SQLiteError("reorder must include every rule in the folder")
        }
        guard Set(ruleIds).count == ruleIds.count else {
            throw SQLiteError("reorder contains duplicate rule ids")
        }
        guard Set(ruleIds) == Set(current.map(\.id)) else {
            throw SQLiteError("reorder contains unknown or missing rule ids")
        }

        try transaction {
            for (index, ruleId) in ruleIds.enumerated() {
                let stmt = try statement("UPDATE rules SET priority=?1 WHERE id=?2 AND folder_id=?3")
                stmt.bind(1, Int64(index))
                stmt.bind(2, ruleId)
                stmt.bind(3, folderId)
                try stmt.runToCompletion()
            }
        }
    }

    // MARK: - Conditions

    private func listConditions(ruleId: String) throws -> [Condition] {
        let stmt = try statement("SELECT id, rule_id, kind, operator, value FROM conditions WHERE rule_id=?1")
        stmt.bind(1, ruleId)
        var conditions: [Condition] = []
        while try stmt.step() {
            conditions.append(
                Condition(
                    id: stmt.columnText(0),
                    ruleId: stmt.columnText(1),
                    kind: ConditionKind(dbValue: stmt.columnText(2)),
                    operator: Operator(dbValue: stmt.columnText(3)),
                    value: stmt.columnText(4)
                )
            )
        }
        return conditions
    }

    private func insertCondition(_ condition: Condition) throws {
        let stmt = try statement("INSERT INTO conditions (id, rule_id, kind, operator, value) VALUES (?1,?2,?3,?4,?5)")
        stmt.bind(1, condition.id)
        stmt.bind(2, condition.ruleId)
        stmt.bind(3, condition.kind.rawValue)
        stmt.bind(4, condition.operator.rawValue)
        stmt.bind(5, condition.value)
        try stmt.runToCompletion()
    }

    // MARK: - Actions

    private func listActions(ruleId: String) throws -> [Action] {
        let stmt = try statement("SELECT id, rule_id, kind, params, position FROM actions WHERE rule_id=?1 ORDER BY position")
        stmt.bind(1, ruleId)
        var actions: [Action] = []
        while try stmt.step() {
            actions.append(
                Action(
                    id: stmt.columnText(0),
                    ruleId: stmt.columnText(1),
                    kind: ActionKind(dbValue: stmt.columnText(2)),
                    params: JSONValue.parse(stmt.columnText(3)),
                    position: stmt.columnInt64(4)
                )
            )
        }
        return actions
    }

    private func insertAction(_ action: Action) throws {
        let stmt = try statement("INSERT INTO actions (id, rule_id, kind, params, position) VALUES (?1,?2,?3,?4,?5)")
        stmt.bind(1, action.id)
        stmt.bind(2, action.ruleId)
        stmt.bind(3, action.kind.rawValue)
        stmt.bind(4, action.params.jsonString)
        stmt.bind(5, action.position)
        try stmt.runToCompletion()
    }

    // MARK: - Watched path state
    //
    // Lets the watcher tell whether it already fully evaluated a path at its
    // current fingerprint, to absorb duplicate/coalesced FSEvents without
    // repeating non-self-limiting actions (e.g. `copyToFolder`, which has no
    // `alreadyInDestination`-style no-op). The *only* writer is
    // `WatcherCoordinator`, and only after a path has been evaluated against
    // every rule — never as a side effect of where some action's result
    // happened to land. That contract is what lets a path nothing has
    // evaluated before (e.g. a file a previous rule just moved here) always
    // get its turn.

    public func getWatchedPathState(_ path: String) throws -> WatchedPathState? {
        let stmt = try statement("SELECT path, volume_id, file_id, fingerprint, updated_at FROM watched_path_state WHERE path=?1")
        stmt.bind(1, path)
        guard try stmt.step() else { return nil }
        return WatchedPathState(
            path: stmt.columnText(0),
            volumeId: stmt.columnInt64OrNil(1),
            fileId: stmt.columnInt64OrNil(2),
            fingerprint: stmt.columnTextOrNil(3),
            updatedAt: stmt.columnText(4)
        )
    }

    public func upsertWatchedPathState(_ state: WatchedPathState) throws {
        let stmt = try statement(
            """
            INSERT INTO watched_path_state (path, volume_id, file_id, fingerprint, updated_at)
            VALUES (?1,?2,?3,?4,?5)
            ON CONFLICT(path) DO UPDATE SET
                volume_id = excluded.volume_id,
                file_id = excluded.file_id,
                fingerprint = excluded.fingerprint,
                updated_at = excluded.updated_at
            """
        )
        stmt.bind(1, state.path)
        stmt.bind(2, state.volumeId)
        stmt.bind(3, state.fileId)
        stmt.bind(4, state.fingerprint)
        stmt.bind(5, state.updatedAt)
        try stmt.runToCompletion()
    }
}
