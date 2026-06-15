use std::sync::atomic::Ordering;

use tauri::{
    menu::{Menu, MenuItem, PredefinedMenuItem},
    tray::TrayIconBuilder,
    AppHandle, Manager,
};

use crate::{db, state::AppState, watcher::WatcherCmd};

const TRAY_ID: &str = "forel_tray";

enum TrayItem {
    Plain(MenuItem<tauri::Wry>),
    Sep(PredefinedMenuItem<tauri::Wry>),
}

impl TrayItem {
    fn as_menu_item(&self) -> &dyn tauri::menu::IsMenuItem<tauri::Wry> {
        match self {
            TrayItem::Plain(i) => i,
            TrayItem::Sep(i) => i,
        }
    }
}

/// Breathing room around the content, as a fraction of its longest side.
const TRAY_MARGIN_RATIO: u32 = 10; // 1/10 = 10% on each side

/// Builds the tray icon from the high-res source. The generated app icon has
/// asymmetric transparent padding (the artwork sits in the upper portion of
/// the canvas), which makes the menu-bar icon look off-center. This trims that
/// padding and re-centers the artwork in a square canvas at full resolution —
/// macOS then scales the large image down to the menu-bar height, so it lines
/// up with the native icons next to it.
fn tray_icon() -> tauri::image::Image<'static> {
    let src = tauri::include_image!("icons/icon.png");
    let sw = src.width();
    let sh = src.height();
    let rgba = src.rgba();

    // Bounding box of non-transparent content.
    let (mut x0, mut y0, mut x1, mut y1) = (sw, sh, 0u32, 0u32);
    for y in 0..sh {
        for x in 0..sw {
            if rgba[((y * sw + x) * 4 + 3) as usize] > 16 {
                x0 = x0.min(x);
                y0 = y0.min(y);
                x1 = x1.max(x);
                y1 = y1.max(y);
            }
        }
    }
    if x1 < x0 || y1 < y0 {
        return src; // fully transparent — nothing to trim
    }

    let content_w = x1 - x0 + 1;
    let content_h = y1 - y0 + 1;

    // Square canvas = longest content side + symmetric margin.
    let side = content_w.max(content_h) + 2 * (content_w.max(content_h) / TRAY_MARGIN_RATIO);
    let off_x = (side - content_w) / 2;
    let off_y = (side - content_h) / 2;

    // Copy the trimmed content into the center of a transparent square.
    let mut dst = vec![0u8; (side * side * 4) as usize];
    for cy in 0..content_h {
        for cx in 0..content_w {
            let si = (((y0 + cy) * sw + (x0 + cx)) * 4) as usize;
            let di = (((off_y + cy) * side + (off_x + cx)) * 4) as usize;
            dst[di..di + 4].copy_from_slice(&rgba[si..si + 4]);
        }
    }

    tauri::image::Image::new_owned(dst, side, side)
}

pub fn setup(app: &AppHandle) -> tauri::Result<()> {
    let menu = build_menu(app)?;
    let icon = tray_icon();

    TrayIconBuilder::with_id(TRAY_ID)
        .icon(icon)
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
            let _ = tray.set_icon(Some(tray_icon()));
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
        }
        "quit" => app.exit(0),
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
                    folders.into_iter().filter(|f| f.enabled).map(|f| f.path).collect()
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
        }
        _ => {}
    }
}

fn build_menu(app: &AppHandle) -> tauri::Result<Menu<tauri::Wry>> {
    let state = app.state::<AppState>();
    let paused = state.paused.load(Ordering::Relaxed);

    let mut items: Vec<TrayItem> = Vec::new();

    // Primary action at top (mirrors Postgres.app pattern)
    items.push(TrayItem::Plain(MenuItem::with_id(
        app, "open", "Open Forel", true, None::<&str>,
    )?));
    items.push(TrayItem::Sep(PredefinedMenuItem::separator(app)?));

    // Status row + toggle — descriptive text forces a decent menu width
    let (status_label, action_label) = if paused {
        ("🔴  File watching is paused", "Start Watching")
    } else {
        ("🟢  File watching is active", "Stop Watching")
    };

    items.push(TrayItem::Plain(MenuItem::with_id(
        app, "status", status_label, false, None::<&str>,
    )?));
    items.push(TrayItem::Plain(MenuItem::with_id(
        app, "toggle_watch", action_label, true, None::<&str>,
    )?));
    items.push(TrayItem::Sep(PredefinedMenuItem::separator(app)?));
    items.push(TrayItem::Plain(MenuItem::with_id(
        app, "quit", "Quit Forel", true, None::<&str>,
    )?));

    let refs: Vec<&dyn tauri::menu::IsMenuItem<tauri::Wry>> =
        items.iter().map(TrayItem::as_menu_item).collect();
    Menu::with_items(app, &refs)
}
