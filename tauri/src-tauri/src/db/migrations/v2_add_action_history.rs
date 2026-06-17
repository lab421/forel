use anyhow::Result;
use rusqlite::Connection;

pub fn apply(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS action_history (
             id            TEXT PRIMARY KEY,
             batch_id      TEXT NOT NULL,
             rule_id       TEXT,
             rule_name     TEXT NOT NULL,
             action_kind   TEXT NOT NULL,
             original_path TEXT NOT NULL,
             result_path   TEXT NOT NULL,
             undo          TEXT NOT NULL,
             reversible    INTEGER NOT NULL DEFAULT 0,
             status        TEXT NOT NULL DEFAULT 'applied',
             created_at    TEXT NOT NULL
         );
         CREATE INDEX IF NOT EXISTS idx_action_history_batch ON action_history(batch_id);
         CREATE INDEX IF NOT EXISTS idx_action_history_created ON action_history(created_at);",
    )?;
    Ok(())
}
