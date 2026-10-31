extension Database {
    func migrateV12AddFolderCounters() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS folder_counters (
            folder_id TEXT PRIMARY KEY REFERENCES watched_folders(id) ON DELETE CASCADE,
            value INTEGER NOT NULL DEFAULT 0,
            generation INTEGER NOT NULL DEFAULT 0
        )
        """)
    }
}
