use anyhow::Result;
use rusqlite::Connection;

use super::super::table_has_column;

pub fn apply(conn: &Connection) -> Result<()> {
    if table_has_column(conn, "rules", "recursion_depth")? {
        return Ok(());
    }

    conn.execute_batch(
        "ALTER TABLE rules
         ADD COLUMN recursion_depth INTEGER NOT NULL DEFAULT 0;",
    )?;
    Ok(())
}
