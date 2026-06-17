use std::sync::{atomic::AtomicBool, Arc, Mutex};

use rusqlite::Connection;

use crate::watcher::WatcherHandle;

pub struct AppState {
    pub db: Arc<Mutex<Connection>>,
    pub watcher: Mutex<Option<WatcherHandle>>,
    /// When true, file watching is paused globally (no fs events processed).
    pub paused: Arc<AtomicBool>,
}
