extension Database {
    func migrateV15AddConditionOrder() throws {
        if try !tableHasColumn("conditions", "position") {
            try exec("ALTER TABLE conditions ADD COLUMN position INTEGER NOT NULL DEFAULT 0")
            // Existing rules were inserted in evaluation order. Preserve that
            // historical row order independently for each rule.
            try exec("""
                WITH ranked AS (
                    SELECT rowid AS original_rowid,
                           ROW_NUMBER() OVER (PARTITION BY rule_id ORDER BY rowid) - 1 AS ordered_position
                    FROM conditions
                )
                UPDATE conditions SET position = (
                    SELECT ordered_position FROM ranked WHERE original_rowid = conditions.rowid
                )
                """)
        }
        try exec("CREATE INDEX IF NOT EXISTS idx_conditions_rule_position ON conditions(rule_id, position)")
    }
}
