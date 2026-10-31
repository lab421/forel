extension Database {
    func migrateV13AddCounterReservations() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS folder_counter_reservations (
                folder_id TEXT NOT NULL,
                destination TEXT NOT NULL,
                token TEXT NOT NULL,
                owner_pid INTEGER NOT NULL,
                owner_start INTEGER NOT NULL,
                PRIMARY KEY (destination)
            )
            """)
    }
}
