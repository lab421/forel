use std::path::Path;

use anyhow::Result;

use super::{
    action, condition,
    model::{ConditionMatch, Rule},
};

/// Evaluates all enabled rules against `path` and executes matching ones.
/// Returns a list of rule names that matched.
pub fn evaluate_file(path: &Path, rules: &[Rule]) -> Vec<String> {
    let mut matched = Vec::new();

    for rule in rules.iter().filter(|r| r.enabled) {
        match rule_matches(rule, path) {
            Ok(true) => {
                execute_actions(rule, path);
                matched.push(rule.name.clone());
            }
            Ok(false) => {}
            Err(e) => {
                log::warn!("error evaluating rule '{}' on {:?}: {}", rule.name, path, e);
            }
        }
    }

    matched
}

fn rule_matches(rule: &Rule, path: &Path) -> Result<bool> {
    if rule.conditions.is_empty() {
        return Ok(false);
    }

    let results: Vec<bool> = rule
        .conditions
        .iter()
        .map(|c| condition::evaluate(c, path).unwrap_or(false))
        .collect();

    Ok(match rule.condition_match {
        ConditionMatch::All => results.iter().all(|&v| v),
        ConditionMatch::Any => results.iter().any(|&v| v),
    })
}

fn execute_actions(rule: &Rule, path: &Path) {
    let mut sorted = rule.actions.clone();
    sorted.sort_by_key(|a| a.position);

    for act in &sorted {
        if let Err(e) = action::execute(act, path) {
            log::error!(
                "action '{:?}' in rule '{}' failed on {:?}: {}",
                act.kind,
                rule.name,
                path,
                e
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use std::{fs, path::PathBuf};

    use uuid::Uuid;

    use super::*;
    use crate::rules::model::{Condition, ConditionKind, Operator};

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
            vec!["all matched".to_string(), "any matched".to_string()]
        );
    }
}
