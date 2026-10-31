extension Database {
    func migrateV14AddChangeBaselines() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS hazel_change_baseline (
            rule_id TEXT NOT NULL REFERENCES rules(id) ON DELETE CASCADE,
            item_key TEXT NOT NULL,
            condition_key TEXT NOT NULL,
            value TEXT NOT NULL,
            PRIMARY KEY (rule_id, item_key, condition_key)
        )
        """)
    }
}
