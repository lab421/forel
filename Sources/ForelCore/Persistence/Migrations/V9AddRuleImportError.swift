// Forel - A native macOS file-automation app
// Copyright (C) 2026 Lab421

extension Database {
    func migrateV9AddRuleImportError() throws {
        if try !tableHasColumn("rules", "import_error") {
            try exec("ALTER TABLE rules ADD COLUMN import_error TEXT")
        }
    }
}
