#![deny(clippy::all)]
#![warn(clippy::pedantic)]
// Pedantic lints that are too noisy for this codebase:
#![allow(clippy::module_name_repetitions)]
#![allow(clippy::missing_errors_doc)]
#![allow(clippy::missing_panics_doc)]
#![allow(clippy::must_use_candidate)]

mod commands;
mod db;
mod rules;
mod state;
mod tray;
mod watcher;

use std::sync::{atomic::AtomicBool, Arc, Mutex};

use state::AppState;
use tauri::Manager;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            let data_dir = app
                .path()
                .app_data_dir()
                .expect("app data dir unavailable");
            std::fs::create_dir_all(&data_dir)?;

            let db_path = data_dir.join("forel.db");
            let conn = rusqlite::Connection::open(&db_path)?;
            db::init(&conn)?;

            let db = Arc::new(Mutex::new(conn));

            let watcher_handle = watcher::start(Arc::clone(&db), app.handle().clone())
                .expect("watcher failed to start");

            // Start watching all currently enabled folders
            {
                let conn = db.lock().unwrap();
                if let Ok(folders) = db::list_folders(&conn) {
                    for folder in folders.iter().filter(|f| f.enabled) {
                        let _ = watcher_handle
                            .tx
                            .send(watcher::WatcherCmd::Add(folder.path.clone().into()));
                    }
                }
            }

            app.manage(AppState {
                db,
                watcher: Mutex::new(Some(watcher_handle)),
                paused: Arc::new(AtomicBool::new(false)),
            });

            // System tray icon
            tray::setup(app.handle())?;

            // Hide window on close instead of quitting
            let win = app.get_webview_window("main").unwrap();
            let win_clone = win.clone();
            win.on_window_event(move |event| {
                if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                    api.prevent_close();
                    let _ = win_clone.hide();
                }
            });

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::get_watched_folders,
            commands::add_watched_folder,
            commands::remove_watched_folder,
            commands::toggle_watched_folder,
            commands::get_rules,
            commands::create_rule,
            commands::update_rule,
            commands::delete_rule,
            commands::toggle_rule,
            commands::run_rule,
            commands::run_rules_now,
            commands::preview_rules,
            commands::get_macos_tags,
            commands::add_custom_tag,
        ])
        .run(tauri::generate_context!())
        .expect("error while running forel");
}
