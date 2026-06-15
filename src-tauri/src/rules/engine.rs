use std::path::Path;

use super::{
    action, condition,
    model::{ConditionMatch, Rule},
};
use serde::Serialize;
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
/// Returns a list of rule names that matched.
pub fn evaluate_file(path: &Path, rules: &[Rule]) -> Vec<String> {
    let mut matched = Vec::new();

    for rule in rules.iter().filter(|r| r.enabled) {
        if rule_matches(rule, path) {
            execute_actions(rule, path);
            matched.push(rule.name.clone());
        }
    }

    matched
}

pub fn preview_file(path: &Path, rules: &[Rule]) -> Option<FilePreview> {
    let mut matched_rules = Vec::new();

    for rule in rules.iter().filter(|r| r.enabled) {
        if rule_matches(rule, path) {
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

fn rule_matches(rule: &Rule, path: &Path) -> bool {
    if rule.conditions.is_empty() {
        return true;
    }

    let results: Vec<bool> = rule
        .conditions
        .iter()
        .map(|c| condition::evaluate(c, path).unwrap_or(false))
        .collect();

    match rule.condition_match {
        ConditionMatch::All => results.iter().all(|&v| v),
        ConditionMatch::Any => results.iter().any(|&v| v),
    }
}

fn execute_actions(rule: &Rule, path: &Path) {
    let mut sorted = rule.actions.clone();
    sorted.sort_by_key(|a| a.position);

    for act in &sorted {
        if let Err(e) = action::execute(act, path) {
            log::error!(
                "action '{:?}' in rule '{}' failed on {}: {}",
                act.kind,
                rule.name,
                path.display(),
                e
            );
        }
    }
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

        assert_eq!(
            evaluate_file(&file, &rules),
            vec![
                "all matched".to_string(),
                "any matched".to_string(),
                "empty".to_string(),
            ]
        );
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

        let before = preview_file(&file, &[matching_rule.clone()]).expect("preview before apply");
        assert_eq!(before.rules[0].actions.len(), 2);

        evaluate_file(&file, &[matching_rule.clone()]);
        assert!(preview_file(&file, &[matching_rule]).is_none());
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

        let preview = preview_file(&file, &[matching_rule]).expect("preview should match");

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
}
