// Forel - A native macOS file-automation app
// Copyright (C) 2026  Lab421
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

extension Database {
    typealias Migration = (version: Int64, apply: @Sendable (Database) throws -> Void)

    static let migrations: [Migration] = [
        (1, { try $0.migrateV1AddRecursionDepth() }),
        (2, { try $0.migrateV2AddActionHistory() }),
        (3, { try $0.migrateV3AddAppSettings() }),
        (4, { try $0.migrateV4AddHistoryMessage() }),
        (5, { try $0.migrateV5AddFolderPriority() }),
        (6, { try $0.migrateV6AddWatchedPathState() }),
        (7, { try $0.migrateV7AddHistoryResultIdentity() }),
        (8, { try $0.migrateV8AddHistoryPathIndexes() }),
    ]

    func runMigrations() throws {
        let version = try userVersion()
        if version > Self.currentSchemaVersion {
            throw SQLiteError("database schema version \(version) is newer than supported \(Self.currentSchemaVersion)")
        }

        let migrations = try Self.validatedMigrations()
        for migration in migrations where version < migration.version {
            try runMigration(migration.version) {
                try migration.apply(self)
            }
        }
    }

    private func runMigration(_ version: Int64, _ apply: () throws -> Void) throws {
        try transaction {
            try apply()
            try setUserVersion(version)
        }
    }

    private static func validatedMigrations() throws -> [Migration] {
        let sorted = migrations.sorted { $0.version < $1.version }
        let versions = sorted.map(\.version)
        let expected = Array(Int64(1)...currentSchemaVersion)
        guard versions == expected else {
            throw SQLiteError("database migrations must cover versions 1...\(currentSchemaVersion) exactly")
        }
        return sorted
    }
}
