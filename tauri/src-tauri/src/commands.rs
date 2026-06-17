// Tauri command handlers must accept State<T> and AppHandle by value — the
// macro wraps them and passing by reference is not supported.
#![allow(clippy::needless_pass_by_value)]

use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;

use tauri::{AppHandle, State};

use serde::Serialize;

use crate::{
    db,
    rules::{
        action::{self, Undo},
        engine::{self, PreviewResult},
        model::{HistoryEntry, Rule, WatchedFolder},
    },
    state::AppState,
    tray,
    watcher::WatcherCmd,
};

// ---------- Folders ----------

#[tauri::command]
pub fn get_watched_folders(state: State<AppState>) -> Result<Vec<WatchedFolder>, String> {
    let conn = state.db.lock().map_err(|e| e.to_string())?;
    db::list_folders(&conn).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn add_watched_folder(
    path: String,
    state: State<AppState>,
    app: AppHandle,
) -> Result<WatchedFolder, String> {
    let folder = WatchedFolder::new(path.clone());
    {
        let conn = state.db.lock().map_err(|e| e.to_string())?;
        db::insert_folder(&conn, &folder).map_err(|e| e.to_string())?;
    }
    if !state.paused.load(Ordering::Relaxed) {
        if let Ok(watcher) = state.watcher.lock() {
            if let Some(w) = watcher.as_ref() {
                let _ = w.tx.send(WatcherCmd::Add(path.into()));
            }
        }
    }
    tray::rebuild(&app);
    Ok(folder)
}

#[tauri::command]
pub fn remove_watched_folder(
    id: String,
    state: State<AppState>,
    app: AppHandle,
) -> Result<(), String> {
    let path: Option<String> = {
        let conn = state.db.lock().map_err(|e| e.to_string())?;
        conn.query_row(
            "SELECT path FROM watched_folders WHERE id=?1",
            rusqlite::params![id],
            |r| r.get(0),
        )
        .ok()
    };

    {
        let conn = state.db.lock().map_err(|e| e.to_string())?;
        db::delete_folder(&conn, &id).map_err(|e| e.to_string())?;
    }

    if let Some(p) = path {
        if let Ok(watcher) = state.watcher.lock() {
            if let Some(w) = watcher.as_ref() {
                let _ = w.tx.send(WatcherCmd::Remove(p.into()));
            }
        }
    }

    tray::rebuild(&app);
    Ok(())
}

#[tauri::command]
pub fn toggle_watched_folder(
    id: String,
    enabled: bool,
    state: State<AppState>,
    app: AppHandle,
) -> Result<(), String> {
    let path: Option<String> = {
        let conn = state.db.lock().map_err(|e| e.to_string())?;
        db::toggle_folder(&conn, &id, enabled).map_err(|e| e.to_string())?;
        conn.query_row(
            "SELECT path FROM watched_folders WHERE id=?1",
            rusqlite::params![id],
            |r| r.get(0),
        )
        .ok()
    };

    if let Some(p) = path.filter(|_| !enabled || !state.paused.load(Ordering::Relaxed)) {
        if let Ok(watcher) = state.watcher.lock() {
            if let Some(w) = watcher.as_ref() {
                let cmd = if enabled {
                    WatcherCmd::Add(p.into())
                } else {
                    WatcherCmd::Remove(p.into())
                };
                let _ = w.tx.send(cmd);
            }
        }
    }

    tray::rebuild(&app);
    Ok(())
}

// ---------- Rules ----------

#[tauri::command]
pub fn get_rules(folder_id: String, state: State<AppState>) -> Result<Vec<Rule>, String> {
    let conn = state.db.lock().map_err(|e| e.to_string())?;
    db::list_rules(&conn, &folder_id).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn create_rule(
    folder_id: String,
    name: String,
    state: State<AppState>,
    app: AppHandle,
) -> Result<Rule, String> {
    let rule = Rule::new(folder_id, name);
    {
        let conn = state.db.lock().map_err(|e| e.to_string())?;
        db::insert_rule(&conn, &rule).map_err(|e| e.to_string())?;
    }
    tray::rebuild(&app);
    Ok(rule)
}

#[tauri::command]
pub fn update_rule(rule: Rule, state: State<AppState>, app: AppHandle) -> Result<(), String> {
    let should_run = rule.enabled && !state.paused.load(Ordering::Relaxed);
    let rule_id = rule.id.clone();
    {
        let conn = state.db.lock().map_err(|e| e.to_string())?;
        db::update_rule(&conn, &rule).map_err(|e| e.to_string())?;
    }
    if should_run {
        apply_rule(&rule_id, &state)?;
    }
    tray::rebuild(&app);
    Ok(())
}

#[tauri::command]
pub fn delete_rule(rule_id: String, state: State<AppState>, app: AppHandle) -> Result<(), String> {
    {
        let conn = state.db.lock().map_err(|e| e.to_string())?;
        db::delete_rule(&conn, &rule_id).map_err(|e| e.to_string())?;
    }
    tray::rebuild(&app);
    Ok(())
}

#[tauri::command]
pub fn toggle_rule(
    rule_id: String,
    enabled: bool,
    state: State<AppState>,
    app: AppHandle,
) -> Result<(), String> {
    {
        let conn = state.db.lock().map_err(|e| e.to_string())?;
        db::toggle_rule(&conn, &rule_id, enabled).map_err(|e| e.to_string())?;
    }
    if enabled && !state.paused.load(Ordering::Relaxed) {
        apply_rule(&rule_id, &state)?;
    }
    tray::rebuild(&app);
    Ok(())
}

#[tauri::command]
pub fn reorder_rules(
    folder_id: String,
    rule_ids: Vec<String>,
    state: State<AppState>,
    app: AppHandle,
) -> Result<(), String> {
    {
        let conn = state.db.lock().map_err(|e| e.to_string())?;
        db::reorder_rules(&conn, &folder_id, &rule_ids).map_err(|e| e.to_string())?;
    }
    tray::rebuild(&app);
    Ok(())
}

#[tauri::command]
pub fn run_rule(rule_id: String, state: State<AppState>) -> Result<Vec<String>, String> {
    apply_rule(&rule_id, &state)
}

/// Applies a single enabled rule to all files in its configured scope.
fn apply_rule(rule_id: &str, state: &AppState) -> Result<Vec<String>, String> {
    let (folder_path, rule) = {
        let conn = state.db.lock().map_err(|e| e.to_string())?;
        let folder_id = db::rule_folder_id(&conn, rule_id).map_err(|e| e.to_string())?;
        let path: String = conn
            .query_row(
                "SELECT path FROM watched_folders WHERE id=?1",
                rusqlite::params![folder_id],
                |r| r.get(0),
            )
            .map_err(|e| e.to_string())?;
        let rules = db::list_rules(&conn, &folder_id).map_err(|e| e.to_string())?;
        let rule = rules.into_iter().find(|rule| rule.id == rule_id);
        (path, rule)
    };

    let Some(rule) = rule.filter(|rule| rule.enabled) else {
        return Ok(Vec::new());
    };

    let batch_id = uuid::Uuid::new_v4().to_string();
    let mut matched = Vec::new();
    let mut history = Vec::new();
    let max_depth = engine::max_rule_depth(std::slice::from_ref(&rule));
    let entries = engine::walk_entries(std::path::Path::new(&folder_path), max_depth)
        .map_err(|e| e.to_string())?;
    for entry in entries {
        let path = std::path::Path::new(&entry.path);
        let (names, records) =
            engine::evaluate_file(path, entry.depth, std::slice::from_ref(&rule), &batch_id);
        matched.extend(names);
        history.extend(records);
    }

    if !history.is_empty() {
        let conn = state.db.lock().map_err(|e| e.to_string())?;
        db::insert_history_entries(&conn, &history).map_err(|e| e.to_string())?;
    }

    Ok(matched)
}

/// Manually triggers rule evaluation for all files in the folder scope.
#[tauri::command]
pub fn run_rules_now(folder_id: String, state: State<AppState>) -> Result<usize, String> {
    let (folder_path, rules) = {
        let conn = state.db.lock().map_err(|e| e.to_string())?;
        let path: String = conn
            .query_row(
                "SELECT path FROM watched_folders WHERE id=?1",
                rusqlite::params![folder_id],
                |r| r.get(0),
            )
            .map_err(|e| e.to_string())?;
        let rules = db::list_rules(&conn, &folder_id).map_err(|e| e.to_string())?;
        (path, rules)
    };

    let batch_id = uuid::Uuid::new_v4().to_string();
    let mut files_modified = 0;
    let mut history = Vec::new();
    let max_depth = engine::max_rule_depth(&rules);
    let entries = engine::walk_entries(std::path::Path::new(&folder_path), max_depth)
        .map_err(|e| e.to_string())?;
    for entry in entries {
        let path = std::path::Path::new(&entry.path);
        let (names, records) = engine::evaluate_file(path, entry.depth, &rules, &batch_id);
        if !names.is_empty() {
            files_modified += 1;
        }
        history.extend(records);
    }

    if !history.is_empty() {
        let conn = state.db.lock().map_err(|e| e.to_string())?;
        db::insert_history_entries(&conn, &history).map_err(|e| e.to_string())?;
    }

    Ok(files_modified)
}

/// Simulates rule evaluation for all files in the folder scope without running actions.
#[tauri::command]
pub fn preview_rules(folder_id: String, state: State<AppState>) -> Result<PreviewResult, String> {
    let (folder_path, rules) = {
        let conn = state.db.lock().map_err(|e| e.to_string())?;
        let path: String = conn
            .query_row(
                "SELECT path FROM watched_folders WHERE id=?1",
                rusqlite::params![folder_id],
                |r| r.get(0),
            )
            .map_err(|e| e.to_string())?;
        let rules = db::list_rules(&conn, &folder_id).map_err(|e| e.to_string())?;
        (path, rules)
    };

    let mut result = PreviewResult {
        files_scanned: 0,
        matches: Vec::new(),
    };

    let max_depth = engine::max_rule_depth(&rules);
    let entries = engine::walk_entries(std::path::Path::new(&folder_path), max_depth)
        .map_err(|e| e.to_string())?;
    for entry in entries {
        let path = std::path::Path::new(&entry.path);
        result.files_scanned += 1;
        if let Some(preview) = engine::preview_file(path, entry.depth, &rules) {
            result.matches.push(preview);
        }
    }

    Ok(result)
}

/// Returns the available text tags: Finder favourites + custom tags from the DB.
/// The 7 system colour names are excluded — colours are handled by the
/// colour-label picker, not as text tags.
#[tauri::command]
pub fn get_macos_tags(state: State<AppState>) -> Vec<String> {
    let colors = [
        "red", "orange", "yellow", "green", "blue", "purple", "gray", "grey",
    ];
    let is_color = |name: &str| colors.contains(&name.to_lowercase().as_str());
    let mut tags: Vec<String> = Vec::new();

    // Finder favourite tags (skipping the system colour labels)
    if let Ok(out) = std::process::Command::new("defaults")
        .args(["read", "com.apple.finder", "FavoriteTagNames"])
        .output()
    {
        if let Ok(text) = String::from_utf8(out.stdout) {
            for line in text.lines() {
                let name = line.trim().trim_end_matches(',').trim_matches('"');
                if !name.is_empty() && name != "(" && name != ")" && !is_color(name) {
                    let s = name.to_string();
                    if !tags.contains(&s) {
                        tags.push(s);
                    }
                }
            }
        }
    }

    // User-defined tags stored in our DB
    if let Ok(conn) = state.db.lock() {
        if let Ok(custom) = db::list_custom_tags(&conn) {
            for name in custom {
                if !is_color(&name) && !tags.contains(&name) {
                    tags.push(name);
                }
            }
        }
    }

    tags
}

/// Persists a user-defined tag so it appears in the picker across sessions.
#[tauri::command]
pub fn add_custom_tag(name: String, state: State<AppState>) -> Result<(), String> {
    let name = name.trim().to_string();
    if name.is_empty() {
        return Err("tag name cannot be empty".into());
    }
    let conn = state.db.lock().map_err(|e| e.to_string())?;
    db::insert_custom_tag(&conn, &name).map_err(|e| e.to_string())
}

// ---------- Action history ----------

#[derive(Serialize)]
pub struct UndoSummary {
    pub undone: usize,
    pub failed: Vec<String>,
}

/// Returns the full action history, newest first.
#[tauri::command]
pub fn get_history(state: State<AppState>) -> Result<Vec<HistoryEntry>, String> {
    let conn = state.db.lock().map_err(|e| e.to_string())?;
    db::list_history(&conn).map_err(|e| e.to_string())
}

/// Reverses a single history entry, then marks it as undone.
#[tauri::command]
pub fn undo_entry(id: String, state: State<AppState>) -> Result<(), String> {
    let (entry, history) = {
        let conn = state.db.lock().map_err(|e| e.to_string())?;
        (
            db::get_history_entry(&conn, &id).map_err(|e| e.to_string())?,
            db::list_history(&conn).map_err(|e| e.to_string())?,
        )
    };
    ensure_batch_is_latest_applied(&entry.batch_id, &history)?;

    revert_entry(&entry)?;

    let conn = state.db.lock().map_err(|e| e.to_string())?;
    db::mark_history_undone(&conn, &id).map_err(|e| e.to_string())
}

/// Reverses every still-applied entry of a batch in LIFO order (later actions
/// are undone before earlier ones, since they chain). Best-effort: a failure on
/// one entry does not abort the rest; failures are collected and reported.
#[tauri::command]
pub fn undo_batch(batch_id: String, state: State<AppState>) -> Result<UndoSummary, String> {
    let (entries, history) = {
        let conn = state.db.lock().map_err(|e| e.to_string())?;
        (
            db::list_history_batch(&conn, &batch_id).map_err(|e| e.to_string())?,
            db::list_history(&conn).map_err(|e| e.to_string())?,
        )
    };
    ensure_batch_is_latest_applied(&batch_id, &history)?;

    let mut undone = 0;
    let mut failed = Vec::new();
    for entry in entries
        .into_iter()
        .rev()
        .filter(|e| matches!(e.status, crate::rules::model::HistoryStatus::Applied))
    {
        match revert_entry(&entry) {
            Ok(()) => {
                let conn = state.db.lock().map_err(|e| e.to_string())?;
                db::mark_history_undone(&conn, &entry.id).map_err(|e| e.to_string())?;
                undone += 1;
            },
            Err(e) => failed.push(format!("{}: {e}", entry.original_path)),
        }
    }

    Ok(UndoSummary { undone, failed })
}

/// Deletes the entire history. Does not touch any files.
#[tauri::command]
pub fn clear_history(state: State<AppState>) -> Result<(), String> {
    let conn = state.db.lock().map_err(|e| e.to_string())?;
    db::clear_history(&conn).map_err(|e| e.to_string())
}

fn revert_entry(entry: &HistoryEntry) -> Result<(), String> {
    if !entry.reversible {
        return Err("this action cannot be undone".into());
    }
    if matches!(entry.status, crate::rules::model::HistoryStatus::Undone) {
        return Err("this action was already undone".into());
    }
    let undo: Undo = serde_json::from_value(entry.undo.clone())
        .map_err(|e| format!("corrupt undo data: {e}"))?;
    action::revert(&undo).map_err(|e| e.to_string())
}

fn ensure_batch_is_latest_applied(batch_id: &str, history: &[HistoryEntry]) -> Result<(), String> {
    let target_entries: Vec<&HistoryEntry> = history
        .iter()
        .filter(|entry| entry.batch_id == batch_id)
        .collect();
    if target_entries.is_empty() {
        return Ok(());
    }

    let target_dir = common_history_dir(target_entries.iter().copied());
    let mut seen_target = false;
    for entry in history {
        if entry.batch_id == batch_id {
            seen_target = true;
            continue;
        }
        if seen_target {
            continue;
        }
        if !matches!(entry.status, crate::rules::model::HistoryStatus::Applied) {
            continue;
        }
        let entries = history
            .iter()
            .filter(|candidate| candidate.batch_id == entry.batch_id);
        if common_history_dir(entries) == target_dir {
            return Err("Undo newer activity in this folder first.".into());
        }
    }

    Ok(())
}

fn common_history_dir<'a>(entries: impl Iterator<Item = &'a HistoryEntry>) -> PathBuf {
    let dirs: Vec<Vec<String>> = entries
        .map(|entry| path_components(parent_path(&entry.original_path)))
        .collect();
    let Some(first) = dirs.first() else {
        return PathBuf::new();
    };

    let mut prefix = first.clone();
    for dir in dirs.iter().skip(1) {
        let len = prefix
            .iter()
            .zip(dir)
            .take_while(|(left, right)| left == right)
            .count();
        prefix.truncate(len);
    }

    components_to_path(&prefix)
}

fn parent_path(path: &str) -> &Path {
    Path::new(path).parent().unwrap_or_else(|| Path::new(""))
}

fn path_components(path: &Path) -> Vec<String> {
    path.components()
        .map(|component| component.as_os_str().to_string_lossy().to_string())
        .collect()
}

fn components_to_path(components: &[String]) -> PathBuf {
    let mut path = PathBuf::new();
    for component in components {
        path.push(component);
    }
    path
}
