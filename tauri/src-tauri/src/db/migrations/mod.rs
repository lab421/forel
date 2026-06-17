use anyhow::{bail, Context, Result};
use rusqlite::Connection;

mod v1_add_recursion_depth;
mod v2_add_action_history;
mod v3_add_app_settings;

const CURRENT_SCHEMA_VERSION: i64 = 3;

struct Migration {
    version: i64,
    name: &'static str,
    apply: fn(&Connection) -> Result<()>,
}

const MIGRATIONS: &[Migration] = &[
    Migration {
        version: 1,
        name: "add recursion depth to rules",
        apply: v1_add_recursion_depth::apply,
    },
    Migration {
        version: 2,
        name: "add action history table",
        apply: v2_add_action_history::apply,
    },
    Migration {
        version: 3,
        name: "add app settings table",
        apply: v3_add_app_settings::apply,
    },
];

pub fn run(conn: &Connection) -> Result<()> {
    let version: i64 = conn.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if version > CURRENT_SCHEMA_VERSION {
        bail!("database schema version {version} is newer than supported {CURRENT_SCHEMA_VERSION}");
    }

    for migration in MIGRATIONS
        .iter()
        .filter(|migration| migration.version > version)
    {
        run_migration(conn, migration)?;
    }

    Ok(())
}

fn run_migration(conn: &Connection, migration: &Migration) -> Result<()> {
    conn.execute_batch("BEGIN IMMEDIATE")?;

    let result = (|| -> Result<()> {
        (migration.apply)(conn).with_context(|| format!("migration {}", migration.name))?;
        conn.execute_batch(&format!("PRAGMA user_version = {};", migration.version))?;
        Ok(())
    })();

    if let Err(err) = result {
        let _ = conn.execute_batch("ROLLBACK");
        return Err(err);
    }

    conn.execute_batch("COMMIT")?;
    Ok(())
}
