// Tauri command handlers must accept State<T> and AppHandle by value — the
// macro wraps them and passing by reference is not supported.
#![allow(clippy::needless_pass_by_value)]

use tauri::{AppHandle, State};

use crate::{
    db,
    rules::{
        engine::PreviewResult,
        model::{Rule, WatchedFolder},
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
    if let Ok(watcher) = state.watcher.lock() {
        if let Some(w) = watcher.as_ref() {
            let _ = w.tx.send(WatcherCmd::Add(path.into()));
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
    let conn = state.db.lock().map_err(|e| e.to_string())?;
    db::toggle_folder(&conn, &id, enabled).map_err(|e| e.to_string())?;
    drop(conn);
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
    {
        let conn = state.db.lock().map_err(|e| e.to_string())?;
        db::update_rule(&conn, &rule).map_err(|e| e.to_string())?;
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
    tray::rebuild(&app);
    Ok(())
}

/// Applies a single enabled rule to all files in its folder.
#[tauri::command]
pub fn run_rule(rule_id: String, state: State<AppState>) -> Result<Vec<String>, String> {
    let (folder_path, rule) = {
        let conn = state.db.lock().map_err(|e| e.to_string())?;
        let folder_id = db::rule_folder_id(&conn, &rule_id).map_err(|e| e.to_string())?;
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

    let mut matched = Vec::new();
    if let Ok(entries) = std::fs::read_dir(&folder_path) {
        for entry in entries.flatten() {
            matched.extend(crate::rules::engine::evaluate_file(
                &entry.path(),
                std::slice::from_ref(&rule),
            ));
        }
    }

    Ok(matched)
}

/// Manually triggers rule evaluation for all files in the folder.
#[tauri::command]
pub fn run_rules_now(folder_id: String, state: State<AppState>) -> Result<Vec<String>, String> {
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

    let mut all_matched = Vec::new();
    if let Ok(entries) = std::fs::read_dir(&folder_path) {
        for entry in entries.flatten() {
            let path = entry.path();
            let matched = crate::rules::engine::evaluate_file(&path, &rules);
            all_matched.extend(matched);
        }
    }

    Ok(all_matched)
}

/// Simulates rule evaluation for all files in the folder without running actions.
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

    let entries = std::fs::read_dir(&folder_path).map_err(|e| e.to_string())?;
    for entry in entries.flatten() {
        let path = entry.path();
        result.files_scanned += 1;
        if let Some(preview) = crate::rules::engine::preview_file(&path, &rules) {
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
    let colors = ["red", "orange", "yellow", "green", "blue", "purple", "gray", "grey"];
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
