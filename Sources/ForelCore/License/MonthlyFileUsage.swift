import Foundation

public struct MonthlyFileUsage: Equatable, Sendable {
    let month: String
    public let processed: Int
    public let resetsAt: Date
    public var isExhausted: Bool { processed >= FreePlan.monthlyFileLimit }

    init(processed: Int = 0, at date: Date, calendar: Calendar = .current) {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let components = gregorian.dateComponents([.year, .month], from: date)
        month = String(format: "%04d-%02d", components.year!, components.month!)
        self.processed = processed
        resetsAt = gregorian.dateInterval(of: .month, for: date)!.end
    }
}

extension Database {
    /// Independent of history retention and Undo; only Free processing uses it.
    /// Call while holding the database lock, as for other persistence methods.
    public func monthlyFileUsage(at date: Date = Date(), calendar: Calendar = .current) throws -> MonthlyFileUsage {
        let period = MonthlyFileUsage(at: date, calendar: calendar)
        let stmt = try statement("SELECT processed FROM monthly_file_usage WHERE month = ?1")
        stmt.bind(1, period.month)
        let stored = try stmt.step() ? Int(stmt.columnInt64(0)) : 0
        let key = "free.monthlyFileUsage.\(period.month)"
        let backup = monthlyUsagePreferences?.integer(forKey: key) ?? 0
        let processed = max(stored, backup)
        if processed > stored {
            let restore = try statement("""
                INSERT INTO monthly_file_usage (month, processed) VALUES (?1, ?2)
                ON CONFLICT(month) DO UPDATE SET processed = MAX(processed, excluded.processed)
                """)
            restore.bind(1, period.month)
            restore.bind(2, Int64(processed))
            try restore.runToCompletion()
        }
        if processed > backup {
            monthlyUsagePreferences?.set(processed, forKey: key)
        }
        return MonthlyFileUsage(processed: processed, at: date, calendar: calendar)
    }

    /// Shared by Run Now and both watcher paths. A file's complete action chain
    /// occupies one slot, released when no action was actually applied.
    public func runWithFreePlan(path: String, depth: Int, rules: [Rule], batchId: String,
                                root: String? = nil, isPro: Bool, at date: Date = Date(),
                                calendar: Calendar = .current) throws -> (matched: [String], history: [HistoryEntry]) {
        if isPro {
            return RuleEngine.run(path: path, depth: depth, rules: rules, batchId: batchId, root: root, isPro: true)
        }
        let period = MonthlyFileUsage(at: date, calendar: calendar)
        try withLock { db in
            let usage = try db.monthlyFileUsage(at: date, calendar: calendar)
            let pending = db.monthlyUsageReservations[period.month, default: 0]
            guard usage.processed + pending < FreePlan.monthlyFileLimit else {
                throw FreePlanError.monthlyFileLimit
            }
            db.monthlyUsageReservations[period.month] = pending + 1
        }
        let result = RuleEngine.run(path: path, depth: depth, rules: rules, batchId: batchId, root: root, isPro: false)
        try withLock { db in
            defer { db.monthlyUsageReservations[period.month, default: 0] -= 1 }
            if result.history.contains(where: { $0.status == .applied }) {
                let stmt = try db.statement("""
                    INSERT INTO monthly_file_usage (month, processed) VALUES (?1, 1)
                    ON CONFLICT(month) DO UPDATE SET processed = processed + 1
                    """)
                stmt.bind(1, period.month)
                try stmt.runToCompletion()
                _ = try db.monthlyFileUsage(at: date, calendar: calendar)
            }
        }
        return result
    }

    func queueQuotaPendingFile(_ path: String) throws {
        let stmt = try statement("INSERT OR IGNORE INTO quota_pending_files (path) VALUES (?1)")
        stmt.bind(1, path)
        try stmt.runToCompletion()
    }

    func removeQuotaPendingFile(_ path: String) throws {
        let stmt = try statement("DELETE FROM quota_pending_files WHERE path = ?1")
        stmt.bind(1, path)
        try stmt.runToCompletion()
    }

    func quotaPendingFiles() throws -> [String] {
        let stmt = try statement("SELECT path FROM quota_pending_files ORDER BY path")
        var paths: [String] = []
        while try stmt.step() { paths.append(stmt.columnText(0)) }
        return paths
    }
}
