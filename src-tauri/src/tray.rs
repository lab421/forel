use std::sync::atomic::Ordering;

use tauri::{
    menu::{IconMenuItem, IconMenuItemBuilder, Menu, MenuItem, PredefinedMenuItem},
    tray::TrayIconBuilder,
    AppHandle, Emitter, Manager,
};

use crate::{db, state::AppState, watcher::WatcherCmd};

const TRAY_ID: &str = "forel_tray";

enum TrayItem {
    Plain(MenuItem<tauri::Wry>),
    Icon(IconMenuItem<tauri::Wry>),
    Sep(PredefinedMenuItem<tauri::Wry>),
}

impl TrayItem {
    fn as_menu_item(&self) -> &dyn tauri::menu::IsMenuItem<tauri::Wry> {
        match self {
            TrayItem::Plain(i) => i,
            TrayItem::Icon(i) => i,
            TrayItem::Sep(i) => i,
        }
    }
}

const STATUS_ICON_SIZE: u32 = 16;

fn tray_icon() -> tauri::image::Image<'static> {
    tauri::include_image!("icons/tray-icon.png")
}

fn status_icon(paused: bool) -> tauri::image::Image<'static> {
    let mut rgba = vec![0u8; (STATUS_ICON_SIZE * STATUS_ICON_SIZE * 4) as usize];
    let color = if paused {
        [255, 69, 58, 255]
    } else {
        [52, 199, 89, 255]
    };
    fill_circle(&mut rgba, STATUS_ICON_SIZE, 8, 8, 4, color);
    tauri::image::Image::new_owned(rgba, STATUS_ICON_SIZE, STATUS_ICON_SIZE)
}

fn fill_circle(rgba: &mut [u8], size: u32, cx: i32, cy: i32, radius: i32, color: [u8; 4]) {
    let r2 = radius * radius;
    for y in (cy - radius).max(0)..=(cy + radius).min(size.cast_signed() - 1) {
        for x in (cx - radius).max(0)..=(cx + radius).min(size.cast_signed() - 1) {
            let dx = x - cx;
            let dy = y - cy;
            if dx * dx + dy * dy <= r2 {
                set_pixel(rgba, size, x.cast_unsigned(), y.cast_unsigned(), color);
            }
        }
    }
}

fn set_pixel(rgba: &mut [u8], size: u32, x: u32, y: u32, color: [u8; 4]) {
    let i = ((y * size + x) * 4) as usize;
    rgba[i..i + 4].copy_from_slice(&color);
}

pub fn setup(app: &AppHandle) -> tauri::Result<()> {
    let menu = build_menu(app)?;
    let icon = tray_icon();

    TrayIconBuilder::with_id(TRAY_ID)
        .icon(icon)
        .icon_as_template(true)
        .menu(&menu)
        .tooltip("Forel")
        .show_menu_on_left_click(true)
        .on_menu_event(handle_menu_event)
        .build(app)?;
    Ok(())
}

pub fn rebuild(app: &AppHandle) {
    if let Ok(menu) = build_menu(app) {
        if let Some(tray) = app.tray_by_id(TRAY_ID) {
            let _ = tray.set_menu(Some(menu));
            let _ = tray.set_icon_with_as_template(Some(tray_icon()), true);
        }
    }
}

#[allow(clippy::needless_pass_by_value)]
fn handle_menu_event(app: &AppHandle, event: tauri::menu::MenuEvent) {
    let id = event.id().as_ref().to_string();
    match id.as_str() {
        "open" => {
            if let Some(w) = app.get_webview_window("main") {
                let _ = w.show();
                let _ = w.set_focus();
            }
        },
        "quit" => app.exit(0),
        "check_updates" => {
            if let Some(w) = app.get_webview_window("main") {
                let _ = w.show();
                let _ = w.set_focus();
            }
            let _ = app.emit("tray:check-updates", ());
        },
        "toggle_watch" => {
            let state = app.state::<AppState>();
            let was_paused = state.paused.load(Ordering::Relaxed);
            let now_paused = !was_paused;
            state.paused.store(now_paused, Ordering::Relaxed);

            // Collect paths under db lock, then send commands without holding it
            let paths: Vec<String> = {
                let conn = state.db.lock().unwrap();
                let folders = db::list_folders(&conn).unwrap_or_default();
                if now_paused {
                    folders.into_iter().map(|f| f.path).collect()
                } else {
                    folders
                        .into_iter()
                        .filter(|f| f.enabled)
                        .map(|f| f.path)
                        .collect()
                }
            };

            {
                let watcher = state.watcher.lock().unwrap();
                if let Some(w) = watcher.as_ref() {
                    for path in paths {
                        let cmd = if now_paused {
                            WatcherCmd::Remove(path.into())
                        } else {
                            WatcherCmd::Add(path.into())
                        };
                        let _ = w.tx.send(cmd);
                    }
                }
            }

            rebuild(app);
        },
        _ => {},
    }
}

fn build_menu(app: &AppHandle) -> tauri::Result<Menu<tauri::Wry>> {
    let state = app.state::<AppState>();
    let paused = state.paused.load(Ordering::Relaxed);

    let mut items: Vec<TrayItem> = Vec::new();

    // Primary action at top (mirrors Postgres.app pattern)
    items.push(TrayItem::Plain(MenuItem::with_id(
        app,
        "open",
        "Open Forel",
        true,
        None::<&str>,
    )?));
    items.push(TrayItem::Sep(PredefinedMenuItem::separator(app)?));

    // Status row + toggle — descriptive text forces a decent menu width
    let (status_label, action_label) = if paused {
        ("File watching is paused", "Start Watching")
    } else {
        ("File watching is active", "Stop Watching")
    };

    items.push(TrayItem::Icon(
        IconMenuItemBuilder::with_id("status", status_label)
            .enabled(false)
            .icon(status_icon(paused))
            .build(app)?,
    ));
    items.push(TrayItem::Plain(MenuItem::with_id(
        app,
        "toggle_watch",
        action_label,
        true,
        None::<&str>,
    )?));
    items.push(TrayItem::Sep(PredefinedMenuItem::separator(app)?));
    items.push(TrayItem::Plain(MenuItem::with_id(
        app,
        "check_updates",
        "Check for Updates...",
        true,
        None::<&str>,
    )?));
    items.push(TrayItem::Plain(MenuItem::with_id(
        app,
        "quit",
        "Quit Forel",
        true,
        None::<&str>,
    )?));

    let refs: Vec<&dyn tauri::menu::IsMenuItem<tauri::Wry>> =
        items.iter().map(TrayItem::as_menu_item).collect();
    Menu::with_items(app, &refs)
}
