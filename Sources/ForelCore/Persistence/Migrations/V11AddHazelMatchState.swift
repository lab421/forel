extension Database {
    func migrateV11AddHazelMatchState() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS hazel_match_state (
            rule_id TEXT NOT NULL REFERENCES rules(id) ON DELETE CASCADE,
            item_key TEXT NOT NULL,
            condition_signature TEXT NOT NULL,
            matched INTEGER NOT NULL,
            recurses INTEGER NOT NULL DEFAULT 0,
            fingerprint TEXT,
            last_matched TEXT,
            PRIMARY KEY (rule_id, item_key)
        )
        """)
    }
}
