use std::{
    convert::TryFrom,
    path::{Path, PathBuf},
};

use super::{
    action, condition,
    model::{ActionKind, ConditionMatch, HistoryEntry, HistoryStatus, Rule},
};
use anyhow::Result;
use serde::Serialize;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize)]
pub struct ScopedPath {
    pub path: String,
    pub depth: usize,
}
#[derive(Debug, Clone, Serialize)]
pub struct RulePreview {
    pub rule_id: String,
    pub rule_name: String,
    pub actions: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct FilePreview {
    pub path: String,
    pub name: String,
    pub rules: Vec<RulePreview>,
}

#[derive(Debug, Clone, Serialize)]
pub struct PreviewResult {
    pub files_scanned: usize,
    pub matches: Vec<FilePreview>,
}

/// Evaluates all enabled rules against `path` and executes matching ones.
/// Returns the names of rules that matched and the history entries produced by
/// their actions (grouped under `batch_id`).
pub fn evaluate_file(
    path: &Path,
    depth: usize,
    rules: &[Rule],
    batch_id: &str,
) -> (Vec<String>, Vec<HistoryEntry>) {
    let mut matched = Vec::new();
    let mut history = Vec::new();

    for rule in rules.iter().filter(|r| r.enabled) {
        if rule_matches_at_depth(rule, path, depth) {
            history.extend(execute_actions(rule, path, batch_id));
            matched.push(rule.name.clone());
        }
    }

    (matched, history)
}

pub fn preview_file(path: &Path, depth: usize, rules: &[Rule]) -> Option<FilePreview> {
    let mut matched_rules = Vec::new();

    for rule in rules.iter().filter(|r| r.enabled) {
        if rule_matches_at_depth(rule, path, depth) {
            let mut sorted = rule.actions.clone();
            sorted.sort_by_key(|a| a.position);
            let actions: Vec<String> = sorted
                .iter()
                .filter(|act| action::would_change(act, path))
                .map(|act| action::preview(act, path).unwrap_or_else(|e| e.to_string()))
                .collect();
            if actions.is_empty() {
                continue;
            }

            matched_rules.push(RulePreview {
                rule_id: rule.id.clone(),
                rule_name: rule.name.clone(),
                actions,
            });
        }
    }

    if matched_rules.is_empty() {
        return None;
    }

    Some(FilePreview {
        path: path.to_string_lossy().to_string(),
        name: path
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("")
            .to_string(),
        rules: matched_rules,
    })
}

fn rule_matches_at_depth(rule: &Rule, path: &Path, depth: usize) -> bool {
    if rule.conditions.is_empty() {
        return rule_in_scope(rule, depth);
    }

    let results: Vec<bool> = rule
        .conditions
        .iter()
        .map(|c| condition::evaluate(c, path).unwrap_or(false))
        .collect();

    rule_in_scope(rule, depth)
        && match rule.condition_match {
            ConditionMatch::All => results.iter().all(|&v| v),
            ConditionMatch::Any => results.iter().any(|&v| v),
        }
}

fn rule_in_scope(rule: &Rule, depth: usize) -> bool {
    match rule.recursion_depth {
        Some(limit) if limit >= 0 => usize::try_from(limit).is_ok_and(|limit| depth <= limit),
        Some(_) => depth == 0,
        None => true,
    }
}

pub fn path_depth(root: &Path, path: &Path) -> Option<usize> {
    let rel = path.strip_prefix(root).ok()?;
    Some(rel.components().count().saturating_sub(1))
}

pub fn walk_entries(root: &Path, max_depth: Option<usize>) -> Result<Vec<ScopedPath>> {
    let mut entries = Vec::new();
    if !root.is_dir() {
        return Ok(entries);
    }

    walk_entries_inner(root, max_depth, 0, &mut entries)?;
    Ok(entries)
}

fn walk_entries_inner(
    root: &Path,
    max_depth: Option<usize>,
    depth: usize,
    entries: &mut Vec<ScopedPath>,
) -> Result<()> {
    let mut children: Vec<PathBuf> = std::fs::read_dir(root)?
        .flatten()
        .map(|entry| entry.path())
        .collect();
    children.sort();

    for child in children {
        entries.push(ScopedPath {
            path: child.to_string_lossy().to_string(),
            depth,
        });

        let Ok(meta) = std::fs::symlink_metadata(&child) else {
            continue;
        };
        if !meta.file_type().is_dir() || meta.file_type().is_symlink() {
            continue;
        }
        if max_depth.is_some_and(|limit| depth >= limit) {
            continue;
        }

        walk_entries_inner(&child, max_depth, depth + 1, entries)?;
    }

    Ok(())
}

pub fn max_rule_depth(rules: &[Rule]) -> Option<usize> {
    if rules.iter().any(|rule| rule.recursion_depth.is_none()) {
        return None;
    }

    rules
        .iter()
        .filter_map(|rule| {
            rule.recursion_depth
                .and_then(|depth| usize::try_from(depth.max(0)).ok())
        })
        .max()
}

fn execute_actions(rule: &Rule, path: &Path, batch_id: &str) -> Vec<HistoryEntry> {
    let mut sorted = rule.actions.clone();
    sorted.sort_by_key(|a| a.position);

    let mut history = Vec::new();
    let mut current: PathBuf = path.to_path_buf();
    for act in &sorted {
        let is_terminal = matches!(
            act.kind,
            ActionKind::MoveToFolder | ActionKind::MoveToTrash | ActionKind::Delete
        );
        let original = current.clone();
        match action::execute(act, &current) {
            Ok(applied) => {
                let undo = serde_json::to_value(&applied.undo).unwrap_or(serde_json::Value::Null);
                history.push(HistoryEntry {
                    id: Uuid::new_v4().to_string(),
                    batch_id: batch_id.to_string(),
                    rule_id: Some(rule.id.clone()),
                    rule_name: rule.name.clone(),
                    action_kind: act.kind.clone(),
                    original_path: original.to_string_lossy().to_string(),
                    result_path: applied.new_path.to_string_lossy().to_string(),
                    reversible: applied.undo.is_reversible(),
                    undo,
                    status: HistoryStatus::Applied,
                    created_at: chrono::Utc::now().to_rfc3339(),
                });
                current = applied.new_path;
            },
            Err(e) => log::error!(
                "action '{:?}' in rule '{}' failed on {}: {}",
                act.kind,
                rule.name,
                current.display(),
                e
            ),
        }
        if is_terminal {
            break;
        }
    }

    history
}

#[cfg(test)]
mod tests {
    use std::{fs, path::PathBuf};

    use serde_json::json;
    use uuid::Uuid;

    use super::*;
    use crate::rules::model::{Action, ActionKind, Condition, ConditionKind, Operator};

    struct TestDir {
        path: PathBuf,
    }

    impl TestDir {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!("forel-engine-test-{}", Uuid::new_v4()));
            fs::create_dir(&path).expect("create temp test directory");
            Self { path }
        }

        fn file(&self, name: &str, contents: &str) -> PathBuf {
            let path = self.path.join(name);
            fs::write(&path, contents).expect("write temp test file");
            path
        }
    }

    impl Drop for TestDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }

    fn condition(kind: ConditionKind, operator: Operator, value: &str) -> Condition {
        Condition {
            id: Uuid::new_v4().to_string(),
            rule_id: "rule".to_string(),
            kind,
            operator,
            value: value.to_string(),
        }
    }

    fn rule(
        name: &str,
        enabled: bool,
        condition_match: ConditionMatch,
        conditions: Vec<Condition>,
    ) -> Rule {
        Rule {
            id: Uuid::new_v4().to_string(),
            folder_id: "folder".to_string(),
            name: name.to_string(),
            enabled,
            condition_match,
            recursion_depth: Some(0),
            conditions,
            actions: Vec::new(),
            priority: 0,
            created_at: "2026-01-01T00:00:00Z".to_string(),
        }
    }

    fn action(kind: ActionKind, params: serde_json::Value, position: i64) -> Action {
        Action {
            id: Uuid::new_v4().to_string(),
            rule_id: "rule".to_string(),
            kind,
            params,
            position,
        }
    }

    #[test]
    fn evaluate_file_matches_enabled_rules_with_all_or_any_conditions() {
        let dir = TestDir::new();
        let file = dir.file("invoice.pdf", "paid");
        let rules = vec![
            rule(
                "all matched",
                true,
                ConditionMatch::All,
                vec![
                    condition(ConditionKind::Name, Operator::Contains, "invoice"),
                    condition(ConditionKind::Extension, Operator::Is, "pdf"),
                ],
            ),
            rule(
                "any matched",
                true,
                ConditionMatch::Any,
                vec![
                    condition(ConditionKind::Name, Operator::Contains, "receipt"),
                    condition(ConditionKind::Contents, Operator::Contains, "paid"),
                ],
            ),
            rule(
                "disabled",
                false,
                ConditionMatch::All,
                vec![condition(ConditionKind::Extension, Operator::Is, "pdf")],
            ),
            rule("empty", true, ConditionMatch::All, Vec::new()),
        ];

        let (matched, history) = evaluate_file(&file, 0, &rules, "batch");
        assert_eq!(
            matched,
            vec![
                "all matched".to_string(),
                "any matched".to_string(),
                "empty".to_string(),
            ]
        );
        // No actions configured on these rules, so no history is produced.
        assert!(history.is_empty());
    }

    #[test]
    fn preview_file_hides_already_applied_actions() {
        let dir = TestDir::new();
        let file = dir.file("photo.jpg", "img");
        let mut matching_rule = rule(
            "label jpgs",
            true,
            ConditionMatch::All,
            vec![condition(ConditionKind::Extension, Operator::Is, "jpg")],
        );
        matching_rule.actions = vec![
            action(ActionKind::SetColorLabel, json!({ "color": "Yellow" }), 1),
            action(ActionKind::AddTag, json!({ "tags": ["Sorted"] }), 2),
        ];

        let before =
            preview_file(&file, 0, &[matching_rule.clone()]).expect("preview before apply");
        assert_eq!(before.rules[0].actions.len(), 2);

        let (_, history) = evaluate_file(&file, 0, &[matching_rule.clone()], "batch");
        assert_eq!(history.len(), 2);
        assert!(history.iter().all(|entry| entry.reversible));
        assert!(preview_file(&file, 0, &[matching_rule]).is_none());
    }

    #[test]
    fn preview_file_returns_ordered_actions_without_executing_them() {
        let dir = TestDir::new();
        let file = dir.file("invoice.pdf", "paid");
        let destination = dir.path.join("Processed");
        fs::create_dir(&destination).expect("create destination");
        let mut matching_rule = rule(
            "archive invoice",
            true,
            ConditionMatch::All,
            vec![condition(ConditionKind::Extension, Operator::Is, "pdf")],
        );
        matching_rule.actions = vec![
            action(ActionKind::AddTag, json!({ "tag": "Reviewed" }), 2),
            action(
                ActionKind::MoveToFolder,
                json!({ "destination": destination.to_string_lossy() }),
                1,
            ),
        ];

        let preview = preview_file(&file, 0, &[matching_rule]).expect("preview should match");

        assert!(file.exists());
        assert!(!destination.join("invoice.pdf").exists());
        assert_eq!(preview.name, "invoice.pdf");
        assert_eq!(preview.rules[0].rule_name, "archive invoice");
        assert_eq!(
            preview.rules[0].actions,
            vec![
                format!("Move to {}", destination.join("invoice.pdf").display()),
                "Add tag 'Reviewed'".to_string(),
            ]
        );
    }

    #[test]
    fn recursion_depth_blocks_nested_matches_but_allows_direct_children() {
        let dir = TestDir::new();
        let direct = dir.file("direct.txt", "direct");
        let nested_dir = dir.path.join("Nested");
        fs::create_dir(&nested_dir).expect("create nested dir");
        let nested = nested_dir.join("inside.txt");
        fs::write(&nested, "nested").expect("write nested file");

        let mut shallow_rule = rule(
            "shallow",
            true,
            ConditionMatch::All,
            vec![condition(ConditionKind::Name, Operator::Contains, "direct")],
        );
        shallow_rule.recursion_depth = Some(0);

        assert_eq!(
            evaluate_file(&direct, 0, &[shallow_rule.clone()], "batch").0,
            vec!["shallow".to_string()]
        );
        assert_eq!(
            evaluate_file(&nested, 1, &[shallow_rule], "batch").0,
            Vec::<String>::new()
        );
    }
}
