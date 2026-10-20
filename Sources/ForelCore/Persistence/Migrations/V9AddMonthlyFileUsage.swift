extension Database {
    func migrateV9AddMonthlyFileUsage() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS monthly_file_usage (
                month TEXT PRIMARY KEY,
                processed INTEGER NOT NULL DEFAULT 0 CHECK (processed >= 0)
            );
            CREATE TABLE IF NOT EXISTS quota_pending_files (
                path TEXT PRIMARY KEY
            );
            """)
    }
}
