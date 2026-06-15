use anyhow::{Context, Result};
use rusqlite::{params, Connection};

use crate::rules::model::{
    Action, ActionKind, Condition, ConditionKind, ConditionMatch, Operator, Rule, WatchedFolder,
};

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
         );",
    )
    .context("schema init")
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
        "SELECT id, folder_id, name, enabled, condition_match, priority, created_at
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
            conditions: vec![],
            actions: vec![],
            priority: row.get(5)?,
            created_at: row.get(6)?,
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
    conn.execute(
        "INSERT INTO rules (id, folder_id, name, enabled, condition_match, priority, created_at)
         VALUES (?1,?2,?3,?4,?5,?6,?7)",
        params![
            rule.id,
            rule.folder_id,
            rule.name,
            i64::from(rule.enabled),
            match_str,
            rule.priority,
            rule.created_at
        ],
    )?;
    Ok(())
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
            "UPDATE rules SET name=?1, enabled=?2, condition_match=?3, priority=?4 WHERE id=?5",
            params![
                rule.name,
                i64::from(rule.enabled),
                match_str,
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
