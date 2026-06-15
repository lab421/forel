use std::{
    collections::HashSet,
    path::PathBuf,
    sync::{Arc, Mutex},
    thread,
};

use anyhow::Result;
use notify::{Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use rusqlite::Connection;
use tauri::AppHandle;

use crate::rules::{engine, model::Rule};

pub enum WatcherCmd {
    Add(PathBuf),
    Remove(PathBuf),
}

pub struct WatcherHandle {
    pub tx: std::sync::mpsc::Sender<WatcherCmd>,
}

pub fn start(db: Arc<Mutex<Connection>>, _app: AppHandle) -> Result<WatcherHandle> {
    let (cmd_tx, cmd_rx) = std::sync::mpsc::channel::<WatcherCmd>();
    let (event_tx, event_rx) = std::sync::mpsc::channel::<notify::Result<Event>>();

    thread::Builder::new()
        .name("forel-watcher".into())
        .spawn(move || {
            let mut watcher: RecommendedWatcher =
                notify::recommended_watcher(event_tx).expect("watcher init");
            let mut watch_set: HashSet<PathBuf> = HashSet::new();

            loop {
                // Drain file-system events
                while let Ok(Ok(event)) = event_rx.try_recv() {
                    on_event(&event, &db);
                }

                // Process all pending commands
                while let Ok(cmd) = cmd_rx.try_recv() {
                    match cmd {
                        WatcherCmd::Add(path) => {
                            if watch_set.insert(path.clone()) {
                                let _ = watcher.watch(&path, RecursiveMode::NonRecursive);
                            }
                        }
                        WatcherCmd::Remove(path) => {
                            let _ = watcher.unwatch(&path);
                            watch_set.remove(&path);
                        }
                    }
                }

                thread::sleep(std::time::Duration::from_millis(200));
            }
        })?;

    Ok(WatcherHandle { tx: cmd_tx })
}

fn on_event(event: &Event, db: &Arc<Mutex<Connection>>) {
    let is_create_or_move = matches!(
        event.kind,
        EventKind::Create(_) | EventKind::Modify(notify::event::ModifyKind::Name(_))
    );
    if !is_create_or_move {
        return;
    }

    for path in &event.paths {
        let rules = load_rules_for_path(path, db);
        let matched = engine::evaluate_file(path, &rules);
        for rule_name in matched {
            log::info!("Rule '{rule_name}' matched {}", path.display());
        }
    }
}

fn load_rules_for_path(path: &std::path::Path, db: &Arc<Mutex<Connection>>) -> Vec<Rule> {
    let Some(parent) = path.parent() else { return vec![] };

    let Ok(conn) = db.lock() else { return vec![] };

    // Find folder record matching this parent directory
    let folder_id: Option<String> = conn
        .query_row(
            "SELECT id FROM watched_folders WHERE path=?1 AND enabled=1",
            rusqlite::params![parent.to_string_lossy().as_ref()],
            |row| row.get(0),
        )
        .ok();

    match folder_id {
        Some(id) => crate::db::list_rules(&conn, &id).unwrap_or_default(),
        None => vec![],
    }
}
