use std::{
    collections::HashSet,
    path::PathBuf,
    sync::{Arc, Mutex},
    thread,
};

use anyhow::Result;
use notify::{Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use rusqlite::Connection;

use crate::rules::{engine, model::Rule};

pub enum WatcherCmd {
    Add(PathBuf),
    Remove(PathBuf),
}

pub struct WatcherHandle {
    pub tx: std::sync::mpsc::Sender<WatcherCmd>,
}

pub fn start(db: Arc<Mutex<Connection>>) -> Result<WatcherHandle> {
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
                                let _ = watcher.watch(&path, RecursiveMode::Recursive);
                            }
                        },
                        WatcherCmd::Remove(path) => {
                            let _ = watcher.unwatch(&path);
                            watch_set.remove(&path);
                        },
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
        if path.file_name().is_some_and(|n| n == ".DS_Store") {
            continue;
        }
        let Some((folder, rules)) = load_folder_and_rules_for_path(path, db) else {
            continue;
        };
        let Some(depth) = engine::path_depth(std::path::Path::new(&folder.path), path) else {
            continue;
        };
        let batch_id = uuid::Uuid::new_v4().to_string();
        let (matched, history) = engine::evaluate_file(path, depth, &rules, &batch_id);
        for rule_name in matched {
            log::info!("Rule '{rule_name}' matched {}", path.display());
        }
        if !history.is_empty() {
            if let Ok(conn) = db.lock() {
                if let Err(e) = crate::db::insert_history_entries(&conn, &history) {
                    log::error!("failed to record action history: {e}");
                }
            }
        }
    }
}

fn load_folder_and_rules_for_path(
    path: &std::path::Path,
    db: &Arc<Mutex<Connection>>,
) -> Option<(crate::rules::model::WatchedFolder, Vec<Rule>)> {
    let Ok(conn) = db.lock() else {
        return None;
    };

    let folder = crate::db::folder_for_path(&conn, path).ok().flatten()?;
    let rules = crate::db::list_rules(&conn, &folder.id).unwrap_or_default();
    Some((folder, rules))
}
