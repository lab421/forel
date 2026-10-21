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

/// Free usage and pending files live outside SQLite so the main database
/// stays compatible with earlier Forel versions. Share one store between
/// manual and automatic processing to reserve slots consistently.
public final class MonthlyFileUsageStore: @unchecked Sendable {
    private let preferences: UserDefaults?
    private let lock = NSLock()
    private var reservations: [String: Int] = [:]
    private var inMemoryCounts: [String: Int] = [:]
    private var inMemoryPendingFiles: Set<String> = []
    private let pendingFilesKey = "free.quotaPendingFiles"

    /// Pass the app's dedicated preferences for persistence. Omitting them
    /// keeps isolated core clients and tests in memory.
    public init(preferences: UserDefaults? = nil) {
        self.preferences = preferences
    }

    public func monthlyFileUsage(at date: Date = Date(), calendar: Calendar = .current) -> MonthlyFileUsage {
        let period = MonthlyFileUsage(at: date, calendar: calendar)
        return withLock {
            MonthlyFileUsage(processed: processed(in: period.month), at: date, calendar: calendar)
        }
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
        try withLock {
            let pending = reservations[period.month, default: 0]
            guard processed(in: period.month) + pending < FreePlan.monthlyFileLimit else {
                throw FreePlanError.monthlyFileLimit
            }
            reservations[period.month] = pending + 1
        }
        let result = RuleEngine.run(path: path, depth: depth, rules: rules, batchId: batchId, root: root, isPro: false)
        withLock {
            defer { reservations[period.month, default: 0] -= 1 }
            if result.history.contains(where: { $0.status == .applied }) {
                let count = processed(in: period.month) + 1
                if let preferences {
                    preferences.set(count, forKey: countKey(for: period.month))
                } else {
                    inMemoryCounts[period.month] = count
                }
            }
        }
        return result
    }

    func queueQuotaPendingFile(_ path: String) {
        withLock {
            var paths = pendingFiles()
            if paths.insert(path).inserted { savePendingFiles(paths) }
        }
    }

    func removeQuotaPendingFile(_ path: String) {
        withLock {
            var paths = pendingFiles()
            if paths.remove(path) != nil { savePendingFiles(paths) }
        }
    }

    func quotaPendingFiles() -> [String] {
        withLock { pendingFiles().sorted() }
    }

    private func countKey(for month: String) -> String { "free.monthlyFileUsage.\(month)" }

    private func processed(in month: String) -> Int {
        max(0, preferences?.integer(forKey: countKey(for: month)) ?? inMemoryCounts[month, default: 0])
    }

    private func pendingFiles() -> Set<String> {
        if let preferences { return Set(preferences.stringArray(forKey: pendingFilesKey) ?? []) }
        return inMemoryPendingFiles
    }

    private func savePendingFiles(_ paths: Set<String>) {
        if let preferences { preferences.set(paths.sorted(), forKey: pendingFilesKey) }
        else { inMemoryPendingFiles = paths }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
