extension Database {
    func migrateV10AddHazelMode() throws {
        if try !tableHasColumn("rules", "is_hazel_imported") {
            try exec("ALTER TABLE rules ADD COLUMN is_hazel_imported INTEGER NOT NULL DEFAULT 0")
        }
    }
}
