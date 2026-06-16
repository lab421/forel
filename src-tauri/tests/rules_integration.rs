use std::{
    fs,
    path::PathBuf,
    sync::{Arc, Mutex},
    thread,
    time::{Duration, Instant},
};

use forel_lib::{
    db,
    rules::{
        action::{self, Undo},
        engine,
        model::{
            Action, ActionKind, Condition, ConditionKind, ConditionMatch, Operator, Rule,
            WatchedFolder,
        },
    },
    watcher,
};
use rusqlite::Connection;
use serde_json::json;
use uuid::Uuid;

// ── Helpers ───────────────────────────────────────────────────────────────────

fn test_conn() -> Connection {
    let conn = Connection::open_in_memory().expect("in-memory db");
    db::init(&conn).expect("schema init");
    conn
}

struct TempDir {
    pub path: PathBuf,
}

impl TempDir {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!("forel-int-{}", Uuid::new_v4()));
        fs::create_dir_all(&path).expect("create temp dir");
        Self { path }
    }

    fn file(&self, name: &str) -> PathBuf {
        let p = self.path.join(name);
        fs::write(&p, b"test content").expect("write test file");
        p
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

fn make_condition(rule_id: &str, kind: ConditionKind, operator: Operator, value: &str) -> Condition {
    Condition {
        id: Uuid::new_v4().to_string(),
        rule_id: rule_id.to_string(),
        kind,
        operator,
        value: value.to_string(),
    }
}

fn make_action(rule_id: &str, kind: ActionKind, params: serde_json::Value, position: i64) -> Action {
    Action {
        id: Uuid::new_v4().to_string(),
        rule_id: rule_id.to_string(),
        kind,
        params,
        position,
    }
}

fn make_rule(folder_id: &str, name: &str, conditions: Vec<Condition>, actions: Vec<Action>) -> Rule {
    let id = Uuid::new_v4().to_string();
    // Rebind condition/action rule_ids to match the generated rule id
    let conditions = conditions
        .into_iter()
        .map(|mut c| { c.rule_id = id.clone(); c })
        .collect();
    let actions = actions
        .into_iter()
        .map(|mut a| { a.rule_id = id.clone(); a })
        .collect();
    Rule {
        id,
        folder_id: folder_id.to_string(),
        name: name.to_string(),
        enabled: true,
        condition_match: ConditionMatch::All,
        recursion_depth: Some(0),
        conditions,
        actions,
        priority: 0,
        created_at: chrono::Utc::now().to_rfc3339(),
    }
}

/// Polls `list_history` until at least one entry appears or the timeout elapses.
fn wait_for_history(
    db: &Arc<Mutex<Connection>>,
    timeout: Duration,
) -> Vec<forel_lib::rules::model::HistoryEntry> {
    let start = Instant::now();
    loop {
        {
            let conn = db.lock().expect("db lock");
            let entries = db::list_history(&conn).unwrap_or_default();
            if !entries.is_empty() {
                return entries;
            }
        }
        assert!(
            start.elapsed() <= timeout,
            "timeout: no history entry appeared after {:?}",
            timeout,
        );
        thread::sleep(Duration::from_millis(50));
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

/// A matching PDF is physically moved into the destination folder.
#[test]
fn move_rule_moves_matching_pdf() {
    let src = TempDir::new();
    let dst = TempDir::new();
    let file = src.file("invoice.pdf");

    let rule = make_rule(
        "folder",
        "move pdfs",
        vec![make_condition("", ConditionKind::Extension, Operator::Is, "pdf")],
        vec![make_action(
            "",
            ActionKind::MoveToFolder,
            json!({ "destination": dst.path.to_string_lossy() }),
            0,
        )],
    );

    let (matched, history) = engine::evaluate_file(&file, 0, &[rule], "batch-1");

    assert_eq!(matched, vec!["move pdfs"]);
    assert_eq!(history.len(), 1);
    assert_eq!(history[0].action_kind, ActionKind::MoveToFolder);
    assert!(history[0].reversible);
    assert!(!file.exists(), "original must be gone after move");
    assert!(dst.path.join("invoice.pdf").exists(), "file must land in destination");
}

/// A file that does not match the condition is left untouched.
#[test]
fn move_rule_ignores_non_matching_extension() {
    let src = TempDir::new();
    let dst = TempDir::new();
    let file = src.file("notes.txt");

    let rule = make_rule(
        "folder",
        "move pdfs",
        vec![make_condition("", ConditionKind::Extension, Operator::Is, "pdf")],
        vec![make_action(
            "",
            ActionKind::MoveToFolder,
            json!({ "destination": dst.path.to_string_lossy() }),
            0,
        )],
    );

    let (matched, history) = engine::evaluate_file(&file, 0, &[rule], "batch-2");

    assert!(matched.is_empty());
    assert!(history.is_empty());
    assert!(file.exists(), "non-matching file must not be touched");
}

/// A rename action with a `{name}` pattern changes the filename in place.
#[test]
fn rename_rule_renames_file() {
    let dir = TempDir::new();
    let file = dir.file("report.pdf");

    let rule = make_rule(
        "folder",
        "archive pdfs",
        vec![make_condition("", ConditionKind::Extension, Operator::Is, "pdf")],
        vec![make_action(
            "",
            ActionKind::Rename,
            json!({ "pattern": "archived_{name}" }),
            0,
        )],
    );

    let (matched, history) = engine::evaluate_file(&file, 0, &[rule], "batch-3");

    assert_eq!(matched, vec!["archive pdfs"]);
    assert_eq!(history.len(), 1);
    assert!(!file.exists(), "original path must be gone after rename");
    assert!(
        dir.path.join("archived_report.pdf").exists(),
        "renamed file must exist",
    );
}

/// A freshly created file matches a "created within the last N days" rule and the
/// action runs; the same file does not match "older than N years".
#[test]
fn created_at_rule_matches_recent_file_and_skips_old_window() {
    let src = TempDir::new();
    let dst = TempDir::new();
    let file = src.file("recent.pdf"); // created ~now

    let recent_rule = make_rule(
        "folder",
        "archive recent",
        vec![make_condition(
            "",
            ConditionKind::CreatedAt,
            Operator::WithinLast,
            "7 days",
        )],
        vec![make_action(
            "",
            ActionKind::MoveToFolder,
            json!({ "destination": dst.path.to_string_lossy() }),
            0,
        )],
    );

    let (matched, history) =
        engine::evaluate_file(&file, 0, &[recent_rule], "batch-date-1");

    assert_eq!(matched, vec!["archive recent"]);
    assert_eq!(history.len(), 1);
    assert!(!file.exists(), "recent file must be moved");
    assert!(dst.path.join("recent.pdf").exists());

    // A fresh file is not "older than 1 year", so this rule must not touch it.
    let kept = src.file("kept.pdf");
    let old_rule = make_rule(
        "folder",
        "archive old",
        vec![make_condition(
            "",
            ConditionKind::CreatedAt,
            Operator::OlderThan,
            "1 years",
        )],
        vec![make_action(
            "",
            ActionKind::MoveToFolder,
            json!({ "destination": dst.path.to_string_lossy() }),
            0,
        )],
    );

    let (matched, history) = engine::evaluate_file(&kept, 0, &[old_rule], "batch-date-2");

    assert!(matched.is_empty());
    assert!(history.is_empty());
    assert!(kept.exists(), "fresh file must not match older-than-1-year");
}

/// Date-modified and date-added conditions match a freshly created file through
/// the full engine pipeline (they reuse the same date operators as created_at).
#[test]
fn date_modified_and_date_added_rules_match_recent_file() {
    for kind in [ConditionKind::DateModified, ConditionKind::DateAdded] {
        let src = TempDir::new();
        let dst = TempDir::new();
        let file = src.file("recent.pdf"); // modified & added ~now

        let rule = make_rule(
            "folder",
            "archive recent",
            vec![make_condition("", kind.clone(), Operator::WithinLast, "7 days")],
            vec![make_action(
                "",
                ActionKind::MoveToFolder,
                json!({ "destination": dst.path.to_string_lossy() }),
                0,
            )],
        );

        let (matched, history) = engine::evaluate_file(&file, 0, &[rule], "batch-date-recent");

        assert_eq!(matched, vec!["archive recent"], "kind {kind:?} should match");
        assert_eq!(history.len(), 1);
        assert!(!file.exists(), "kind {kind:?}: file must be moved");
        assert!(dst.path.join("recent.pdf").exists());
    }
}

/// A `before`/`after` rule sorts a fresh file using calendar-date boundaries.
#[test]
fn created_at_rule_handles_absolute_before_and_after() {
    use chrono::{Duration, Local};

    let src = TempDir::new();
    let dst = TempDir::new();
    let file = src.file("today.pdf"); // created ~now

    let tomorrow = (Local::now() + Duration::days(1))
        .format("%Y-%m-%d")
        .to_string();

    // "is before tomorrow" must match a file created today.
    let before_rule = make_rule(
        "folder",
        "before tomorrow",
        vec![make_condition(
            "",
            ConditionKind::CreatedAt,
            Operator::Before,
            &tomorrow,
        )],
        vec![make_action(
            "",
            ActionKind::MoveToFolder,
            json!({ "destination": dst.path.to_string_lossy() }),
            0,
        )],
    );

    let (matched, _) = engine::evaluate_file(&file, 0, &[before_rule], "batch-date-3");
    assert_eq!(matched, vec!["before tomorrow"]);
    assert!(dst.path.join("today.pdf").exists());

    // "is after tomorrow" must not match a file created today.
    let kept = src.file("kept.pdf");
    let after_rule = make_rule(
        "folder",
        "after tomorrow",
        vec![make_condition(
            "",
            ConditionKind::CreatedAt,
            Operator::After,
            &tomorrow,
        )],
        vec![make_action(
            "",
            ActionKind::MoveToFolder,
            json!({ "destination": dst.path.to_string_lossy() }),
            0,
        )],
    );

    let (matched, history) = engine::evaluate_file(&kept, 0, &[after_rule], "batch-date-4");
    assert!(matched.is_empty());
    assert!(history.is_empty());
    assert!(kept.exists());
}

/// After a move, deserialising the stored Undo and calling `revert` puts the
/// file back at its original path.
#[test]
fn undo_reverts_move_to_folder() {
    let src = TempDir::new();
    let dst = TempDir::new();
    let file = src.file("contract.pdf");
    let original = file.clone();

    let rule = make_rule(
        "folder",
        "move pdfs",
        vec![make_condition("", ConditionKind::Extension, Operator::Is, "pdf")],
        vec![make_action(
            "",
            ActionKind::MoveToFolder,
            json!({ "destination": dst.path.to_string_lossy() }),
            0,
        )],
    );

    let (_, history) = engine::evaluate_file(&file, 0, &[rule], "batch-4");

    assert!(!original.exists(), "file should be moved");
    assert!(dst.path.join("contract.pdf").exists());

    let undo: Undo =
        serde_json::from_value(history[0].undo.clone()).expect("undo must deserialise");
    action::revert(&undo).expect("revert must succeed");

    assert!(original.exists(), "file must be back at original path after undo");
    assert!(!dst.path.join("contract.pdf").exists(), "destination must be empty after undo");
}

/// The watcher detects a new file, looks up the matching rule from the DB, and
/// executes the action — recording a history entry.
#[test]
fn watcher_applies_rule_when_file_appears() {
    let src = TempDir::new();
    let dst = TempDir::new();

    let conn = test_conn();

    // Insert watched folder — canonicalise so FSEvents paths match (macOS: /tmp → /private/tmp)
    let canonical = src.path.canonicalize().expect("canonicalize src path");
    let folder = WatchedFolder::new(canonical.to_string_lossy().to_string());
    db::insert_folder(&conn, &folder).expect("insert folder");

    // Build and persist the rule (insert row, then update to write conditions + actions)
    let rule = make_rule(
        &folder.id,
        "move pdfs",
        vec![make_condition("", ConditionKind::Extension, Operator::Is, "pdf")],
        vec![make_action(
            "",
            ActionKind::MoveToFolder,
            json!({ "destination": dst.path.to_string_lossy() }),
            0,
        )],
    );
    db::insert_rule(&conn, &rule).expect("insert rule row");
    db::update_rule(&conn, &rule).expect("persist conditions + actions");

    let db = Arc::new(Mutex::new(conn));
    let handle = watcher::start(Arc::clone(&db)).expect("start watcher");

    // Tell the watcher which path to watch (use the same canonical path)
    handle
        .tx
        .send(watcher::WatcherCmd::Add(canonical.clone()))
        .expect("send Add command");

    // Give the watcher thread time to register the watch
    thread::sleep(Duration::from_millis(300));

    // Drop a PDF into the watched folder — this is the event trigger
    let file = canonical.join("watch_test.pdf");
    fs::write(&file, b"pdf content").expect("write trigger file");

    // Wait up to 3 s for the watcher to process the FS event and persist history
    let history = wait_for_history(&db, Duration::from_secs(3));

    assert!(!history.is_empty(), "a history entry must have been recorded");
    assert_eq!(history[0].action_kind, ActionKind::MoveToFolder);
    assert!(!file.exists(), "file must have been moved out of the watched folder");
    assert!(
        dst.path.join("watch_test.pdf").exists(),
        "file must be in the destination folder",
    );
}
