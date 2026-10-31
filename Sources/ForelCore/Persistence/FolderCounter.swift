import Foundation
import Darwin
import CArchive

public struct FolderCounterReservation: Sendable {
    public let folderId: String
    public let value: Int64
    public let generation: Int64
    public let destination: String?
    public let token: String?
    public init(folderId: String, value: Int64, generation: Int64, destination: String? = nil, token: String? = nil) {
        self.folderId = folderId; self.value = value; self.generation = generation; self.destination = destination; self.token = token
    }
}

public protocol FolderCounterStore: Sendable {
    func nextValue(folderId: String) throws -> Int64
    func reserve(folderId: String) throws -> FolderCounterReservation
    func reserveLowest(folderId: String, candidate: (Int64) throws -> String) throws -> FolderCounterReservation
    func isReserved(folderId: String, destination: String) throws -> Bool
    func commit(_ reservation: FolderCounterReservation) throws
    func rollback(_ reservation: FolderCounterReservation) throws
    func reset(folderId: String) throws
}

/// Counters belong to monitored folders. Reserving and rolling back use
/// SQLite transactions, so independent watchers cannot issue the same value.
public struct DatabaseFolderCounterStore: FolderCounterStore {
    private let db: Database
    public init(db: Database) { self.db = db }

    public func nextValue(folderId: String) throws -> Int64 {
        try db.withLock { db in
            let stmt = try db.statement("SELECT value FROM folder_counters WHERE folder_id=?1")
            stmt.bind(1, folderId)
            let value = try stmt.step() ? stmt.columnInt64(0) : 0
            guard value < Int64.max else { throw ActionError("Folder counter has reached its maximum") }
            return value + 1
        }
    }

    public func reserve(folderId: String) throws -> FolderCounterReservation {
        try db.withLock { db in
            var reservation: FolderCounterReservation?
            try db.transaction {
                let insert = try db.statement("INSERT OR IGNORE INTO folder_counters(folder_id,value,generation) VALUES (?1,0,0)")
                insert.bind(1, folderId); try insert.runToCompletion()
                let read = try db.statement("SELECT value,generation FROM folder_counters WHERE folder_id=?1")
                read.bind(1, folderId)
                guard try read.step() else { throw ActionError("Could not read folder counter") }
                let value = read.columnInt64(0)
                guard value < Int64.max else { throw ActionError("Folder counter has reached its maximum") }
                let generation = read.columnInt64(1)
                let update = try db.statement("UPDATE folder_counters SET value=?1 WHERE folder_id=?2")
                update.bind(1, value + 1); update.bind(2, folderId); try update.runToCompletion()
                reservation = FolderCounterReservation(folderId: folderId, value: value + 1, generation: generation)
            }
            guard let reservation else { throw ActionError("Could not reserve folder counter") }
            return reservation
        }
    }

    public func commit(_ reservation: FolderCounterReservation) throws {
        if let token = reservation.token { try release(token: token) }
    }

    public func rollback(_ reservation: FolderCounterReservation) throws {
        if let token = reservation.token { try release(token: token); return }
        try db.withLock { db in
            let stmt = try db.statement("UPDATE folder_counters SET value=value-1 WHERE folder_id=?1 AND value=?2 AND generation=?3")
            stmt.bind(1, reservation.folderId); stmt.bind(2, reservation.value); stmt.bind(3, reservation.generation)
            try stmt.runToCompletion()
        }
    }

    private func release(token: String) throws {
        try db.withLock { db in
            let stmt = try db.statement("DELETE FROM folder_counter_reservations WHERE token=?1")
            stmt.bind(1, token); try stmt.runToCompletion()
        }
    }

    public func isReserved(folderId: String, destination: String) throws -> Bool {
        try db.withLock { db in
            let stmt = try db.statement("SELECT owner_pid,owner_start FROM folder_counter_reservations WHERE destination=?1")
            stmt.bind(1, destination)
            guard try stmt.step() else { return false }
            let owner = stmt.columnInt64(0)
            let recordedStart = stmt.columnInt64(1)
            if owner > 0, owner <= Int64(Int32.max) {
                let actualStart = forel_process_start_time(Int32(owner))
                if actualStart != 0 && Int64(actualStart) != recordedStart { return false }
            }
            if owner > 0, owner <= Int64(Int32.max), kill(pid_t(owner), 0) != 0, errno == ESRCH { return false }
            return true
        }
    }

    public func reserveLowest(folderId: String, candidate: (Int64) throws -> String) throws -> FolderCounterReservation {
        try db.withLock { db in
            var reserved: FolderCounterReservation?
            try db.transaction {
                let ownStart = forel_process_start_time(getpid())
                guard ownStart != 0 else { throw ActionError("Cannot establish counter reservation process identity") }
                let owners = try db.statement("SELECT DISTINCT owner_pid,owner_start FROM folder_counter_reservations")
                var dead: [(Int64, Int64)] = []
                while try owners.step() {
                    let owner = owners.columnInt64(0)
                    let start = owners.columnInt64(1)
                    if owner > 0, owner <= Int64(Int32.max) {
                        let actual = forel_process_start_time(Int32(owner))
                        if (actual != 0 && Int64(actual) != start) || (actual == 0 && kill(pid_t(owner), 0) != 0 && errno == ESRCH) { dead.append((owner, start)) }
                    }
                }
                for (owner, start) in dead {
                    let cleanup = try db.statement("DELETE FROM folder_counter_reservations WHERE owner_pid=?1 AND owner_start=?2")
                    cleanup.bind(1, owner); cleanup.bind(2, start); try cleanup.runToCompletion()
                }
                let deadline = Date().addingTimeInterval(2)
                var seen = Set<String>()
                for value in Int64(1)...Int64(4096) {
                    guard !Task.isCancelled, Date() < deadline else { throw ActionError("Counter search was cancelled or timed out") }
                    let target = try candidate(value)
                    guard seen.insert(target).inserted else { throw ActionError("Counter formatting produces repeated destination names") }
                    var info = stat()
                    if lstat(target, &info) == 0 { continue }
                    guard errno == ENOENT else { throw ActionError("Cannot inspect a counter destination") }
                    let check = try db.statement("SELECT 1 FROM folder_counter_reservations WHERE destination=?1")
                    check.bind(1, target)
                    if try check.step() { continue }
                    let token = UUID().uuidString
                    let insert = try db.statement("INSERT INTO folder_counter_reservations(folder_id,destination,token,owner_pid,owner_start) VALUES (?1,?2,?3,?4,?5)")
                    insert.bind(1, folderId); insert.bind(2, target); insert.bind(3, token); insert.bind(4, Int64(getpid()))
                    insert.bind(5, Int64(ownStart))
                    try insert.runToCompletion()
                    reserved = FolderCounterReservation(folderId: folderId, value: value, generation: 0, destination: target, token: token)
                    break
                }
            }
            guard let reserved else { throw ActionError("No available counter value was found") }
            return reserved
        }
    }

    public func reset(folderId: String) throws {
        try db.withLock { db in
            let stmt = try db.statement("""
                INSERT INTO folder_counters(folder_id,value,generation) VALUES (?1,0,1)
                ON CONFLICT(folder_id) DO UPDATE SET value=0,generation=generation+1
                """)
            stmt.bind(1, folderId); try stmt.runToCompletion()
        }
    }
}

/// A Dry Run owns one of these per scan. Values advance only in memory so
/// successive previews can show distinct names without consuming counters.
public final class PreviewFolderCounterStore: FolderCounterStore, @unchecked Sendable {
    private let underlying: any FolderCounterStore
    private let lock = NSLock()
    private var values: [String: Int64] = [:]
    private var lowestTargets: Set<String> = []
    public init(underlying: any FolderCounterStore) { self.underlying = underlying }
    public func nextValue(folderId: String) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        if let value = values[folderId] {
            guard value < Int64.max else { throw ActionError("Folder counter has reached its maximum") }
            return value + 1
        }
        return try underlying.nextValue(folderId: folderId)
    }
    public func reserve(folderId: String) throws -> FolderCounterReservation {
        lock.lock(); defer { lock.unlock() }
        let value: Int64
        if let current = values[folderId] {
            guard current < Int64.max else { throw ActionError("Folder counter has reached its maximum") }
            value = current + 1
        } else { value = try underlying.nextValue(folderId: folderId) }
        values[folderId] = value
        return FolderCounterReservation(folderId: folderId, value: value, generation: 0)
    }
    public func commit(_ reservation: FolderCounterReservation) throws {}
    public func rollback(_ reservation: FolderCounterReservation) throws {
        lock.lock(); defer { lock.unlock() }
        if let destination = reservation.destination { lowestTargets.remove(destination); return }
        if values[reservation.folderId] == reservation.value { values[reservation.folderId] = reservation.value - 1 }
    }
    public func isReserved(folderId: String, destination: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if lowestTargets.contains(destination) { return true }
        return try underlying.isReserved(folderId: folderId, destination: destination)
    }
    public func reserveLowest(folderId: String, candidate: (Int64) throws -> String) throws -> FolderCounterReservation {
        lock.lock(); defer { lock.unlock() }
        let deadline = Date().addingTimeInterval(2)
        var seen = Set<String>()
        for value in Int64(1)...Int64(4096) {
            guard !Task.isCancelled, Date() < deadline else { throw ActionError("Counter search was cancelled or timed out") }
            let destination = try candidate(value)
            guard seen.insert(destination).inserted else { throw ActionError("Counter formatting produces repeated destination names") }
            var info = stat()
            if lstat(destination, &info) == 0 { continue }
            guard errno == ENOENT else { throw ActionError("Cannot inspect a counter destination") }
            if lowestTargets.contains(destination) { continue }
            if try underlying.isReserved(folderId: folderId, destination: destination) { continue }
            lowestTargets.insert(destination)
            return FolderCounterReservation(folderId: folderId, value: value, generation: 0, destination: destination, token: UUID().uuidString)
        }
        throw ActionError("No available counter value was found")
    }
    public func reset(folderId: String) throws { throw ActionError("A Dry Run cannot reset the folder counter") }
}
