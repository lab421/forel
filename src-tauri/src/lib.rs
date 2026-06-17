#![deny(clippy::all)]
#![warn(clippy::pedantic)]
// Pedantic lints that are too noisy for this codebase:
#![allow(clippy::module_name_repetitions)]
#![allow(clippy::missing_errors_doc)]
#![allow(clippy::missing_panics_doc)]
#![allow(clippy::must_use_candidate)]

mod commands;
pub mod db;
pub mod rules;
mod state;
mod tray;
pub mod watcher;

use std::sync::{atomic::AtomicBool, Arc, Mutex};

use state::AppState;
use tauri::Manager;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            Some(vec!["--minimized"]),
        ))
        .setup(|app| {
            let data_dir = app.path().app_data_dir().expect("app data dir unavailable");
            std::fs::create_dir_all(&data_dir)?;

            let db_path = data_dir.join("forel.db");
            let first_run = !db_path.exists();
            let conn = rusqlite::Connection::open(&db_path)?;
            db::init(&conn)?;
            if first_run && db::get_setting(&conn, "paused")?.is_none() {
                db::set_setting(&conn, "paused", "1")?;
            }

            let db = Arc::new(Mutex::new(conn));

            let watcher_handle = watcher::start(Arc::clone(&db)).expect("watcher failed to start");

            // Restore paused state and start watching enabled folders
            let was_paused = {
                let conn = db.lock().unwrap();
                let paused = db::get_setting(&conn, "paused")
                    .unwrap_or_default()
                    .is_some_and(|v| v == "1");
                if !paused {
                    if let Ok(folders) = db::list_folders(&conn) {
                        for folder in folders.iter().filter(|f| f.enabled) {
                            let _ = watcher_handle
                                .tx
                                .send(watcher::WatcherCmd::Add(folder.path.clone().into()));
                        }
                    }
                }
                paused
            };

            app.manage(AppState {
                db,
                watcher: Mutex::new(Some(watcher_handle)),
                paused: Arc::new(AtomicBool::new(was_paused)),
            });

            // System tray icon
            tray::setup(app.handle())?;

            // Show the window unless launched at login (LaunchAgent passes --minimized),
            // in which case Forel stays silently in the menu bar.
            let launched_at_login = std::env::args().any(|a| a == "--minimized");
            let win = app.get_webview_window("main").unwrap();
            if !launched_at_login {
                let _ = win.show();
            }

            // Hide window on close instead of quitting; rebuild the tray icon when
            // the system appearance flips so the glyph stays legible (white/black).
            let win_clone = win.clone();
            win.on_window_event(move |event| match event {
                tauri::WindowEvent::CloseRequested { api, .. } => {
                    api.prevent_close();
                    let _ = win_clone.hide();
                },
                tauri::WindowEvent::ThemeChanged(_) => {
                    tray::rebuild(win_clone.app_handle());
                },
                _ => {},
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
            commands::reorder_rules,
            commands::run_rule,
            commands::run_rules_now,
            commands::preview_rules,
            commands::get_macos_tags,
            commands::add_custom_tag,
            commands::get_history,
            commands::undo_entry,
            commands::undo_batch,
            commands::clear_history,
        ])
        .run(tauri::generate_context!())
        .expect("error while running forel");
}
