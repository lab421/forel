use anyhow::{Context, Result};
use rusqlite::{params, Connection};
use std::path::Path;

mod migrations;

use crate::rules::model::{
    Action, ActionKind, Condition, ConditionKind, ConditionMatch, HistoryEntry, HistoryStatus,
    Operator, Rule, WatchedFolder,
};

pub(crate) fn table_has_column(conn: &Connection, table: &str, column: &str) -> Result<bool> {
    let mut stmt = conn.prepare(&format!("PRAGMA table_info({table})"))?;
    let rows = stmt.query_map([], |row| row.get::<_, String>(1))?;
    Ok(rows
        .collect::<rusqlite::Result<Vec<_>>>()?
        .iter()
        .any(|name| name == column))
}

pub fn init(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        "PRAGMA journal_mode=WAL;
         PRAGMA foreign_keys=ON;

         CREATE TABLE IF NOT EXISTS watched_folders (
             id          TEXT PRIMARY KEY,
             path        TEXT NOT NULL UNIQUE,
             enabled     INTEGER NOT NULL DEFAULT 1,
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
             created_at    TEXT NOT NULL
         );
         CREATE INDEX IF NOT EXISTS idx_action_history_batch ON action_history(batch_id);
         CREATE INDEX IF NOT EXISTS idx_action_history_created ON action_history(created_at);

         CREATE TABLE IF NOT EXISTS app_settings (
             key   TEXT PRIMARY KEY,
             value TEXT NOT NULL
         );",
    )
    .context("schema init")?;

    migrations::run(conn)?;
    Ok(())
}

// ---------- App settings ----------

pub fn get_setting(conn: &Connection, key: &str) -> Result<Option<String>> {
    let mut stmt = conn.prepare("SELECT value FROM app_settings WHERE key = ?1")?;
    match stmt.query_row([key], |row| row.get(0)) {
        Ok(v) => Ok(Some(v)),
        Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
        Err(e) => Err(e.into()),
    }
}

pub fn set_setting(conn: &Connection, key: &str, value: &str) -> Result<()> {
    conn.execute(
        "INSERT INTO app_settings (key, value) VALUES (?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![key, value],
    )?;
    Ok(())
}

// ---------- Custom tags ----------

pub fn list_custom_tags(conn: &Connection) -> Result<Vec<String>> {
    let mut stmt = conn.prepare("SELECT name FROM custom_tags ORDER BY name")?;
    let rows = stmt.query_map([], |row| row.get(0))?;
    rows.collect::<rusqlite::Result<_>>()
        .context("list custom tags")
}

pub fn insert_custom_tag(conn: &Connection, name: &str) -> Result<()> {
    conn.execute(
        "INSERT OR IGNORE INTO custom_tags (name) VALUES (?1)",
        params![name],
    )?;
    Ok(())
}

// ---------- Action history ----------

fn history_status_to_str(status: HistoryStatus) -> &'static str {
    match status {
        HistoryStatus::Applied => "applied",
        HistoryStatus::Undone => "undone",
    }
}

fn parse_history_status(s: &str) -> HistoryStatus {
    match s {
        "undone" => HistoryStatus::Undone,
        _ => HistoryStatus::Applied,
    }
}

fn row_to_history_entry(row: &rusqlite::Row) -> rusqlite::Result<HistoryEntry> {
    let undo_str: String = row.get(7)?;
    Ok(HistoryEntry {
        id: row.get(0)?,
        batch_id: row.get(1)?,
        rule_id: row.get(2)?,
        rule_name: row.get(3)?,
        action_kind: parse_action_kind(row.get::<_, String>(4)?.as_str()),
        original_path: row.get(5)?,
        result_path: row.get(6)?,
        undo: serde_json::from_str(&undo_str).unwrap_or(serde_json::Value::Null),
        reversible: row.get::<_, i64>(8)? != 0,
        status: parse_history_status(row.get::<_, String>(9)?.as_str()),
        created_at: row.get(10)?,
    })
}

const HISTORY_COLUMNS: &str = "id, batch_id, rule_id, rule_name, action_kind, original_path, \
     result_path, undo, reversible, status, created_at";

pub fn insert_history_entries(conn: &Connection, entries: &[HistoryEntry]) -> Result<()> {
    for entry in entries {
        conn.execute(
            "INSERT INTO action_history
             (id, batch_id, rule_id, rule_name, action_kind, original_path, result_path, undo, reversible, status, created_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)",
            params![
                entry.id,
                entry.batch_id,
                entry.rule_id,
                entry.rule_name,
                action_kind_to_str(&entry.action_kind),
                entry.original_path,
                entry.result_path,
                entry.undo.to_string(),
                i64::from(entry.reversible),
                history_status_to_str(entry.status),
                entry.created_at
            ],
        )?;
    }
    Ok(())
}

pub fn list_history(conn: &Connection) -> Result<Vec<HistoryEntry>> {
    let mut stmt = conn.prepare(&format!(
        "SELECT {HISTORY_COLUMNS} FROM action_history ORDER BY created_at DESC"
    ))?;
    let rows = stmt.query_map([], row_to_history_entry)?;
    rows.collect::<rusqlite::Result<_>>()
        .context("list history")
}

pub fn get_history_entry(conn: &Connection, id: &str) -> Result<HistoryEntry> {
    conn.query_row(
        &format!("SELECT {HISTORY_COLUMNS} FROM action_history WHERE id=?1"),
        params![id],
        row_to_history_entry,
    )
    .context("get history entry")
}

pub fn list_history_batch(conn: &Connection, batch_id: &str) -> Result<Vec<HistoryEntry>> {
    let mut stmt = conn.prepare(&format!(
        "SELECT {HISTORY_COLUMNS} FROM action_history WHERE batch_id=?1 ORDER BY created_at"
    ))?;
    let rows = stmt.query_map(params![batch_id], row_to_history_entry)?;
    rows.collect::<rusqlite::Result<_>>()
        .context("list history batch")
}

pub fn mark_history_undone(conn: &Connection, id: &str) -> Result<()> {
    conn.execute(
        "UPDATE action_history SET status='undone' WHERE id=?1",
        params![id],
    )?;
    Ok(())
}

pub fn clear_history(conn: &Connection) -> Result<()> {
    conn.execute("DELETE FROM action_history", [])?;
    Ok(())
}

// ---------- WatchedFolder ----------

pub fn list_folders(conn: &Connection) -> Result<Vec<WatchedFolder>> {
    let mut stmt = conn
        .prepare("SELECT id, path, enabled, created_at FROM watched_folders ORDER BY created_at")?;
    let rows = stmt.query_map([], |row| {
        Ok(WatchedFolder {
            id: row.get(0)?,
            path: row.get(1)?,
            enabled: row.get::<_, i64>(2)? != 0,
            created_at: row.get(3)?,
        })
    })?;
    rows.collect::<rusqlite::Result<_>>()
        .context("list folders")
}

pub fn folder_for_path(conn: &Connection, path: &Path) -> Result<Option<WatchedFolder>> {
    let folders = list_folders(conn)?;
    Ok(folders
        .into_iter()
        .filter(|folder| folder.enabled)
        .filter(|folder| path.starts_with(Path::new(&folder.path)))
        .max_by_key(|folder| folder.path.len()))
}

pub fn insert_folder(conn: &Connection, folder: &WatchedFolder) -> Result<()> {
    conn.execute(
        "INSERT INTO watched_folders (id, path, enabled, created_at) VALUES (?1,?2,?3,?4)",
        params![
            folder.id,
            folder.path,
            i64::from(folder.enabled),
            folder.created_at
        ],
    )?;
    Ok(())
}

pub fn delete_folder(conn: &Connection, id: &str) -> Result<()> {
    conn.execute("DELETE FROM watched_folders WHERE id=?1", params![id])?;
    Ok(())
}

pub fn toggle_folder(conn: &Connection, id: &str, enabled: bool) -> Result<()> {
    conn.execute(
        "UPDATE watched_folders SET enabled=?1 WHERE id=?2",
        params![i64::from(enabled), id],
    )?;
    Ok(())
}

// ---------- Rules ----------

pub fn list_rules(conn: &Connection, folder_id: &str) -> Result<Vec<Rule>> {
    let mut stmt = conn.prepare(
        "SELECT id, folder_id, name, enabled, condition_match, recursion_depth, priority, created_at
         FROM rules WHERE folder_id=?1 ORDER BY priority, created_at",
    )?;
    let rule_rows = stmt.query_map(params![folder_id], |row| {
        Ok(Rule {
            id: row.get(0)?,
            folder_id: row.get(1)?,
            name: row.get(2)?,
            enabled: row.get::<_, i64>(3)? != 0,
            condition_match: if row.get::<_, String>(4)? == "any" {
                ConditionMatch::Any
            } else {
                ConditionMatch::All
            },
            recursion_depth: match row.get::<_, Option<i64>>(5)? {
                Some(depth) if depth >= 0 => Some(depth),
                _ => None,
            },
            conditions: vec![],
            actions: vec![],
            priority: row.get(6)?,
            created_at: row.get(7)?,
        })
    })?;

    let mut rules: Vec<Rule> = rule_rows
        .collect::<rusqlite::Result<_>>()
        .context("list rules")?;

    for rule in &mut rules {
        rule.conditions = list_conditions(conn, &rule.id)?;
        rule.actions = list_actions(conn, &rule.id)?;
    }

    Ok(rules)
}

pub fn rule_folder_id(conn: &Connection, rule_id: &str) -> Result<String> {
    conn.query_row(
        "SELECT folder_id FROM rules WHERE id=?1",
        params![rule_id],
        |row| row.get(0),
    )
    .context("find rule folder")
}

pub fn insert_rule(conn: &Connection, rule: &Rule) -> Result<()> {
    let match_str = if rule.condition_match == ConditionMatch::Any {
        "any"
    } else {
        "all"
    };
    let priority = next_rule_priority(conn, &rule.folder_id)?;
    conn.execute(
        "INSERT INTO rules (id, folder_id, name, enabled, condition_match, recursion_depth, priority, created_at)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8)",
        params![
            rule.id,
            rule.folder_id,
            rule.name,
            i64::from(rule.enabled),
            match_str,
            rule.recursion_depth.unwrap_or(-1),
            priority,
            rule.created_at
        ],
    )?;
    Ok(())
}

fn next_rule_priority(conn: &Connection, folder_id: &str) -> Result<i64> {
    conn.query_row(
        "SELECT COALESCE(MAX(priority) + 1, 0) FROM rules WHERE folder_id=?1",
        params![folder_id],
        |row| row.get(0),
    )
    .context("next rule priority")
}

pub fn update_rule(conn: &Connection, rule: &Rule) -> Result<()> {
    conn.execute_batch("BEGIN IMMEDIATE")?;

    let result = (|| -> Result<()> {
        let match_str = if rule.condition_match == ConditionMatch::Any {
            "any"
        } else {
            "all"
        };
        conn.execute(
            "UPDATE rules SET name=?1, enabled=?2, condition_match=?3, recursion_depth=?4, priority=?5 WHERE id=?6",
            params![
                rule.name,
                i64::from(rule.enabled),
                match_str,
                rule.recursion_depth.unwrap_or(-1),
                rule.priority,
                rule.id
            ],
        )?;

        conn.execute("DELETE FROM conditions WHERE rule_id=?1", params![rule.id])?;
        conn.execute("DELETE FROM actions WHERE rule_id=?1", params![rule.id])?;

        for cond in &rule.conditions {
            insert_condition(conn, cond)?;
        }
        for act in &rule.actions {
            insert_action(conn, act)?;
        }

        Ok(())
    })();

    if let Err(err) = result {
        let _ = conn.execute_batch("ROLLBACK");
        return Err(err);
    }

    conn.execute_batch("COMMIT")?;
    Ok(())
}

pub fn delete_rule(conn: &Connection, id: &str) -> Result<()> {
    conn.execute("DELETE FROM rules WHERE id=?1", params![id])?;
    Ok(())
}

pub fn toggle_rule(conn: &Connection, id: &str, enabled: bool) -> Result<()> {
    conn.execute(
        "UPDATE rules SET enabled=?1 WHERE id=?2",
        params![i64::from(enabled), id],
    )?;
    Ok(())
}

pub fn reorder_rules(conn: &Connection, folder_id: &str, rule_ids: &[String]) -> Result<()> {
    let current_rules = list_rules(conn, folder_id)?;
    if current_rules.len() != rule_ids.len() {
        anyhow::bail!("reorder must include every rule in the folder");
    }

    let current: std::collections::HashSet<&str> =
        current_rules.iter().map(|rule| rule.id.as_str()).collect();
    let requested: std::collections::HashSet<&str> = rule_ids.iter().map(String::as_str).collect();

    if requested.len() != rule_ids.len() {
        anyhow::bail!("reorder contains duplicate rule ids");
    }
    if requested != current {
        anyhow::bail!("reorder contains unknown or missing rule ids");
    }

    conn.execute_batch("BEGIN IMMEDIATE")?;

    let result = (|| -> Result<()> {
        for (index, rule_id) in rule_ids.iter().enumerate() {
            conn.execute(
                "UPDATE rules SET priority=?1 WHERE id=?2 AND folder_id=?3",
                params![i64::try_from(index)?, rule_id, folder_id],
            )?;
        }
        Ok(())
    })();

    if let Err(err) = result {
        let _ = conn.execute_batch("ROLLBACK");
        return Err(err);
    }

    conn.execute_batch("COMMIT")?;
    Ok(())
}

// ---------- Conditions ----------

fn list_conditions(conn: &Connection, rule_id: &str) -> Result<Vec<Condition>> {
    let mut stmt =
        conn.prepare("SELECT id, rule_id, kind, operator, value FROM conditions WHERE rule_id=?1")?;
    let rows = stmt.query_map(params![rule_id], |row| {
        Ok(Condition {
            id: row.get(0)?,
            rule_id: row.get(1)?,
            kind: parse_condition_kind(row.get::<_, String>(2)?.as_str()),
            operator: parse_operator(row.get::<_, String>(3)?.as_str()),
            value: row.get(4)?,
        })
    })?;
    rows.collect::<rusqlite::Result<_>>()
        .context("list conditions")
}

fn insert_condition(conn: &Connection, condition: &Condition) -> Result<()> {
    conn.execute(
        "INSERT INTO conditions (id, rule_id, kind, operator, value) VALUES (?1,?2,?3,?4,?5)",
        params![
            condition.id,
            condition.rule_id,
            condition_kind_to_str(&condition.kind),
            operator_to_str(&condition.operator),
            condition.value
        ],
    )?;
    Ok(())
}

// ---------- Actions ----------

fn list_actions(conn: &Connection, rule_id: &str) -> Result<Vec<Action>> {
    let mut stmt = conn.prepare(
        "SELECT id, rule_id, kind, params, position FROM actions WHERE rule_id=?1 ORDER BY position",
    )?;
    let rows = stmt.query_map(params![rule_id], |row| {
        let params_str: String = row.get(3)?;
        Ok(Action {
            id: row.get(0)?,
            rule_id: row.get(1)?,
            kind: parse_action_kind(row.get::<_, String>(2)?.as_str()),
            params: serde_json::from_str(&params_str).unwrap_or(serde_json::Value::Null),
            position: row.get(4)?,
        })
    })?;
    rows.collect::<rusqlite::Result<_>>()
        .context("list actions")
}

fn insert_action(conn: &Connection, act: &Action) -> Result<()> {
    conn.execute(
        "INSERT INTO actions (id, rule_id, kind, params, position) VALUES (?1,?2,?3,?4,?5)",
        params![
            act.id,
            act.rule_id,
            action_kind_to_str(&act.kind),
            act.params.to_string(),
            act.position
        ],
    )?;
    Ok(())
}

// ---------- String converters ----------

fn condition_kind_to_str(k: &ConditionKind) -> &'static str {
    match k {
        ConditionKind::Name => "name",
        ConditionKind::Extension => "extension",
        ConditionKind::Kind => "kind",
        ConditionKind::SizeBytes => "size_bytes",
        ConditionKind::Tags => "tags",
        ConditionKind::ColorLabel => "color_label",
        ConditionKind::Contents => "contents",
        ConditionKind::CreatedAt => "created_at",
        ConditionKind::DateModified => "date_modified",
        ConditionKind::DateAdded => "date_added",
    }
}

fn parse_condition_kind(s: &str) -> ConditionKind {
    match s {
        "extension" => ConditionKind::Extension,
        "kind" => ConditionKind::Kind,
        "size_bytes" => ConditionKind::SizeBytes,
        "tags" => ConditionKind::Tags,
        "color_label" => ConditionKind::ColorLabel,
        "contents" => ConditionKind::Contents,
        "created_at" => ConditionKind::CreatedAt,
        "date_modified" => ConditionKind::DateModified,
        "date_added" => ConditionKind::DateAdded,
        _ => ConditionKind::Name,
    }
}

fn operator_to_str(op: &Operator) -> &'static str {
    match op {
        Operator::Is => "is",
        Operator::IsNot => "is_not",
        Operator::Contains => "contains",
        Operator::DoesNotContain => "does_not_contain",
        Operator::StartsWith => "starts_with",
        Operator::EndsWith => "ends_with",
        Operator::MatchesRegex => "matches_regex",
        Operator::GreaterThan => "greater_than",
        Operator::LessThan => "less_than",
        Operator::Before => "before",
        Operator::After => "after",
        Operator::OlderThan => "older_than",
        Operator::WithinLast => "within_last",
    }
}

fn parse_operator(s: &str) -> Operator {
    match s {
        "is_not" => Operator::IsNot,
        "contains" => Operator::Contains,
        "does_not_contain" => Operator::DoesNotContain,
        "starts_with" => Operator::StartsWith,
        "ends_with" => Operator::EndsWith,
        "matches_regex" => Operator::MatchesRegex,
        "greater_than" => Operator::GreaterThan,
        "less_than" => Operator::LessThan,
        "before" => Operator::Before,
        "after" => Operator::After,
        "older_than" => Operator::OlderThan,
        "within_last" => Operator::WithinLast,
        _ => Operator::Is,
    }
}

fn action_kind_to_str(k: &ActionKind) -> &'static str {
    match k {
        ActionKind::MoveToFolder => "move_to_folder",
        ActionKind::CopyToFolder => "copy_to_folder",
        ActionKind::Rename => "rename",
        ActionKind::MoveToTrash => "move_to_trash",
        ActionKind::Delete => "delete",
        ActionKind::AddTag => "add_tag",
        ActionKind::RemoveTag => "remove_tag",
        ActionKind::SetColorLabel => "set_color_label",
        ActionKind::RunScript => "run_script",
    }
}

fn parse_action_kind(s: &str) -> ActionKind {
    match s {
        "copy_to_folder" => ActionKind::CopyToFolder,
        "rename" => ActionKind::Rename,
        "move_to_trash" => ActionKind::MoveToTrash,
        "delete" => ActionKind::Delete,
        "add_tag" => ActionKind::AddTag,
        "remove_tag" => ActionKind::RemoveTag,
        "set_color_label" => ActionKind::SetColorLabel,
        "run_script" => ActionKind::RunScript,
        _ => ActionKind::MoveToFolder,
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;
    use uuid::Uuid;

    use super::*;

    fn connection() -> Connection {
        let conn = Connection::open_in_memory().expect("open in-memory database");
        init(&conn).expect("initialize schema");
        conn
    }

    fn folder() -> WatchedFolder {
        WatchedFolder {
            id: Uuid::new_v4().to_string(),
            path: format!("/tmp/forel-test-{}", Uuid::new_v4()),
            enabled: true,
            created_at: "2026-01-01T00:00:00Z".to_string(),
        }
    }

    fn rule(folder_id: &str, name: &str) -> Rule {
        Rule {
            id: Uuid::new_v4().to_string(),
            folder_id: folder_id.to_string(),
            name: name.to_string(),
            enabled: true,
            condition_match: ConditionMatch::All,
            recursion_depth: Some(0),
            conditions: Vec::new(),
            actions: Vec::new(),
            priority: 0,
            created_at: "2026-01-01T00:00:00Z".to_string(),
        }
    }

    fn condition(rule_id: &str, kind: ConditionKind, operator: Operator, value: &str) -> Condition {
        Condition {
            id: Uuid::new_v4().to_string(),
            rule_id: rule_id.to_string(),
            kind,
            operator,
            value: value.to_string(),
        }
    }

    fn action(rule_id: &str, kind: ActionKind, params: serde_json::Value, position: i64) -> Action {
        Action {
            id: Uuid::new_v4().to_string(),
            rule_id: rule_id.to_string(),
            kind,
            params,
            position,
        }
    }

    fn create_schema(conn: &Connection, version: i64, include_recursion_depth: bool) {
        let recursion_depth = if include_recursion_depth {
            "recursion_depth  INTEGER NOT NULL DEFAULT 0,"
        } else {
            ""
        };

        conn.execute_batch(&format!(
            "PRAGMA user_version = {version};
             CREATE TABLE watched_folders (
                 id          TEXT PRIMARY KEY,
                 path        TEXT NOT NULL UNIQUE,
                 enabled     INTEGER NOT NULL DEFAULT 1,
                 created_at  TEXT NOT NULL
             );
             CREATE TABLE rules (
                 id               TEXT PRIMARY KEY,
                 folder_id        TEXT NOT NULL REFERENCES watched_folders(id) ON DELETE CASCADE,
                 name             TEXT NOT NULL,
                 enabled          INTEGER NOT NULL DEFAULT 1,
                 condition_match  TEXT NOT NULL DEFAULT 'all',
                 {recursion_depth}
                 priority         INTEGER NOT NULL DEFAULT 0,
                 created_at       TEXT NOT NULL
             );
             CREATE TABLE conditions (
                 id        TEXT PRIMARY KEY,
                 rule_id   TEXT NOT NULL REFERENCES rules(id) ON DELETE CASCADE,
                 kind      TEXT NOT NULL,
                 operator  TEXT NOT NULL,
                 value     TEXT NOT NULL
             );
             CREATE TABLE actions (
                 id        TEXT PRIMARY KEY,
                 rule_id   TEXT NOT NULL REFERENCES rules(id) ON DELETE CASCADE,
                 kind      TEXT NOT NULL,
                 params    TEXT NOT NULL,
                 position  INTEGER NOT NULL DEFAULT 0
             );
             CREATE TABLE custom_tags (
                 name TEXT PRIMARY KEY
             );",
        ))
        .expect("create schema");
    }

    #[test]
    fn rule_round_trip_preserves_new_tag_and_color_variants() {
        let conn = connection();
        let folder = folder();
        insert_folder(&conn, &folder).expect("insert folder");
        let mut rule = rule(&folder.id, "tagged images");
        insert_rule(&conn, &rule).expect("insert rule");

        rule.condition_match = ConditionMatch::Any;
        rule.conditions = vec![
            condition(&rule.id, ConditionKind::Tags, Operator::Is, "Project"),
            condition(
                &rule.id,
                ConditionKind::SizeBytes,
                Operator::GreaterThan,
                "1 MB",
            ),
        ];
        rule.actions = vec![
            action(
                &rule.id,
                ActionKind::SetColorLabel,
                json!({ "color": "Blue" }),
                2,
            ),
            action(
                &rule.id,
                ActionKind::AddTag,
                json!({ "tag": "Reviewed" }),
                1,
            ),
        ];

        update_rule(&conn, &rule).expect("update rule with children");

        let rules = list_rules(&conn, &folder.id).expect("list rules");
        assert_eq!(rules.len(), 1);
        let loaded = &rules[0];
        assert_eq!(loaded.condition_match, ConditionMatch::Any);
        assert_eq!(loaded.conditions[0].kind, ConditionKind::Tags);
        assert_eq!(loaded.conditions[0].operator, Operator::Is);
        assert_eq!(loaded.conditions[0].value, "Project");
        assert_eq!(loaded.conditions[1].kind, ConditionKind::SizeBytes);
        assert_eq!(loaded.actions[0].kind, ActionKind::AddTag);
        assert_eq!(loaded.actions[0].params, json!({ "tag": "Reviewed" }));
        assert_eq!(loaded.actions[1].kind, ActionKind::SetColorLabel);
        assert_eq!(loaded.actions[1].params, json!({ "color": "Blue" }));
        assert_eq!(loaded.recursion_depth, Some(0));
    }

    #[test]
    fn migrate_recursion_depth_adds_column_to_legacy_schema() {
        let conn = Connection::open_in_memory().expect("open in-memory database");
        create_schema(&conn, 0, false);

        init(&conn).expect("run migration");

        let version: i64 = conn
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .expect("read schema version");
        assert_eq!(version, 3);

        let has_column =
            table_has_column(&conn, "rules", "recursion_depth").expect("inspect migrated schema");
        assert!(has_column);
    }

    #[test]
    fn init_rejects_newer_schema_versions() {
        let conn = Connection::open_in_memory().expect("open in-memory database");
        create_schema(&conn, 4, true);

        let err = init(&conn).expect_err("reject newer schema");
        assert!(err.to_string().contains("newer than supported"));
    }

    fn history_entry(batch: &str, kind: ActionKind, reversible: bool) -> HistoryEntry {
        HistoryEntry {
            id: Uuid::new_v4().to_string(),
            batch_id: batch.to_string(),
            rule_id: Some("rule".to_string()),
            rule_name: "demo".to_string(),
            action_kind: kind,
            original_path: "/from/file.txt".to_string(),
            result_path: "/to/file.txt".to_string(),
            undo: json!({ "kind": "none" }),
            reversible,
            status: HistoryStatus::Applied,
            created_at: "2026-01-01T00:00:00Z".to_string(),
        }
    }

    #[test]
    fn history_round_trip_insert_list_mark_and_clear() {
        let conn = connection();
        let entries = vec![
            history_entry("batch-1", ActionKind::MoveToFolder, true),
            history_entry("batch-1", ActionKind::RunScript, false),
        ];
        insert_history_entries(&conn, &entries).expect("insert history");

        let listed = list_history(&conn).expect("list history");
        assert_eq!(listed.len(), 2);

        let batch = list_history_batch(&conn, "batch-1").expect("list batch");
        assert_eq!(batch.len(), 2);

        let first = &entries[0];
        mark_history_undone(&conn, &first.id).expect("mark undone");
        let reloaded = get_history_entry(&conn, &first.id).expect("get entry");
        assert_eq!(reloaded.status, HistoryStatus::Undone);
        assert_eq!(reloaded.action_kind, ActionKind::MoveToFolder);
        assert!(reloaded.reversible);

        clear_history(&conn).expect("clear history");
        assert!(list_history(&conn).expect("list after clear").is_empty());
    }

    #[test]
    fn migrate_action_history_adds_table_to_legacy_schema() {
        let conn = Connection::open_in_memory().expect("open in-memory database");
        create_schema(&conn, 1, true);

        init(&conn).expect("run migrations");

        let version: i64 = conn
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .expect("read schema version");
        assert_eq!(version, 3);

        // The table is now usable.
        insert_history_entries(&conn, &[history_entry("b", ActionKind::Rename, true)])
            .expect("insert into migrated table");
        assert_eq!(list_history(&conn).expect("list").len(), 1);
    }

    #[test]
    fn insert_rule_appends_to_folder_order() {
        let conn = connection();
        let folder = folder();
        insert_folder(&conn, &folder).expect("insert folder");

        insert_rule(&conn, &rule(&folder.id, "first")).expect("insert first");
        insert_rule(&conn, &rule(&folder.id, "second")).expect("insert second");
        insert_rule(&conn, &rule(&folder.id, "third")).expect("insert third");

        let loaded = list_rules(&conn, &folder.id).expect("list rules");
        let orders: Vec<i64> = loaded.iter().map(|rule| rule.priority).collect();
        assert_eq!(orders, vec![0, 1, 2]);
    }

    #[test]
    fn reorder_rules_persists_requested_order() {
        let conn = connection();
        let folder = folder();
        insert_folder(&conn, &folder).expect("insert folder");

        let first = rule(&folder.id, "first");
        let second = rule(&folder.id, "second");
        let third = rule(&folder.id, "third");
        insert_rule(&conn, &first).expect("insert first");
        insert_rule(&conn, &second).expect("insert second");
        insert_rule(&conn, &third).expect("insert third");

        reorder_rules(
            &conn,
            &folder.id,
            &[third.id.clone(), first.id.clone(), second.id.clone()],
        )
        .expect("reorder rules");

        let loaded = list_rules(&conn, &folder.id).expect("list reordered rules");
        let names: Vec<&str> = loaded.iter().map(|rule| rule.name.as_str()).collect();
        let orders: Vec<i64> = loaded.iter().map(|rule| rule.priority).collect();
        assert_eq!(names, vec!["third", "first", "second"]);
        assert_eq!(orders, vec![0, 1, 2]);
    }

    #[test]
    fn insert_rule_appends_after_reorder() {
        let conn = connection();
        let folder = folder();
        insert_folder(&conn, &folder).expect("insert folder");

        let first = rule(&folder.id, "first");
        let second = rule(&folder.id, "second");
        insert_rule(&conn, &first).expect("insert first");
        insert_rule(&conn, &second).expect("insert second");

        reorder_rules(&conn, &folder.id, &[second.id.clone(), first.id.clone()])
            .expect("reorder rules");
        insert_rule(&conn, &rule(&folder.id, "third")).expect("insert third");

        let loaded = list_rules(&conn, &folder.id).expect("list rules");
        let names: Vec<&str> = loaded.iter().map(|rule| rule.name.as_str()).collect();
        let orders: Vec<i64> = loaded.iter().map(|rule| rule.priority).collect();
        assert_eq!(names, vec!["second", "first", "third"]);
        assert_eq!(orders, vec![0, 1, 2]);
    }

    #[test]
    fn reorder_rules_rejects_invalid_rule_sets() {
        let conn = connection();
        let primary_folder = folder();
        let other_folder = folder();
        insert_folder(&conn, &primary_folder).expect("insert folder");
        insert_folder(&conn, &other_folder).expect("insert other folder");

        let first = rule(&primary_folder.id, "first");
        let second = rule(&primary_folder.id, "second");
        let other = rule(&other_folder.id, "other");
        insert_rule(&conn, &first).expect("insert first");
        insert_rule(&conn, &second).expect("insert second");
        insert_rule(&conn, &other).expect("insert other");

        assert!(reorder_rules(&conn, &primary_folder.id, std::slice::from_ref(&first.id)).is_err());
        assert!(reorder_rules(
            &conn,
            &primary_folder.id,
            &[first.id.clone(), first.id.clone()]
        )
        .is_err());
        assert!(reorder_rules(
            &conn,
            &primary_folder.id,
            &[first.id.clone(), other.id.clone()]
        )
        .is_err());
    }

    #[test]
    fn update_rule_rolls_back_when_replacing_children_fails() {
        let conn = connection();
        let folder = folder();
        insert_folder(&conn, &folder).expect("insert folder");
        let mut original = rule(&folder.id, "original");
        insert_rule(&conn, &original).expect("insert rule");

        original.conditions = vec![condition(
            &original.id,
            ConditionKind::Name,
            Operator::Contains,
            "invoice",
        )];
        update_rule(&conn, &original).expect("insert original children");

        let mut invalid_update = original.clone();
        invalid_update.name = "updated".to_string();
        invalid_update.conditions = vec![condition(
            "missing-rule-id",
            ConditionKind::Extension,
            Operator::Is,
            "pdf",
        )];

        assert!(update_rule(&conn, &invalid_update).is_err());

        let rules = list_rules(&conn, &folder.id).expect("list rules after failed update");
        assert_eq!(rules.len(), 1);
        assert_eq!(rules[0].name, "original");
        assert_eq!(rules[0].conditions.len(), 1);
        assert_eq!(rules[0].conditions[0].kind, ConditionKind::Name);
        assert_eq!(rules[0].conditions[0].value, "invoice");
    }
}
