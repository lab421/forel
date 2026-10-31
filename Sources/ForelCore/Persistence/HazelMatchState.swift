import Foundation
import Darwin

public struct HazelMatchState: Sendable {
    public var conditionSignature: String
    public var matched: Bool
    public var recurses: Bool
    public var fingerprint: String?
    public var lastMatched: Date?
    public init(conditionSignature: String, matched: Bool, lastMatched: Date?, recurses: Bool = false, fingerprint: String? = nil) {
        self.conditionSignature = conditionSignature
        self.matched = matched
        self.lastMatched = lastMatched
        self.recurses = recurses
        self.fingerprint = fingerprint
    }
}

public protocol HazelMatchStateStore: Sendable {
    func itemKey(path: String) -> String
    func state(ruleId: String, itemKey: String) throws -> HazelMatchState?
    func setState(_ state: HazelMatchState, ruleId: String, itemKey: String) throws
}

public protocol HazelChangeBaselineStore: Sendable {
    func changeBaseline(ruleId: String, itemKey: String, conditionKey: String) throws -> String?
    func setChangeBaselines(_ values: [String: String], ruleId: String, itemKey: String) throws
    func setChangeBaselineBatch(_ values: [String: [String: String]], ruleId: String) throws
}

/// Records the last successful match by rule and file identity. Replacing a
/// file at the same path does not inherit the previous file's match state.
public struct DatabaseHazelMatchStateStore: HazelMatchStateStore, HazelChangeBaselineStore {
    private let db: Database
    public init(db: Database) { self.db = db }

    public func itemKey(path: String) -> String {
        var info = stat()
        guard lstat(path, &info) == 0 else { return "path:\(path)" }
        return "id:\(FileFingerprint.databaseInteger(info.st_dev)):\(FileFingerprint.databaseInteger(info.st_ino)):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
    }

    public func state(ruleId: String, itemKey: String) throws -> HazelMatchState? {
        return try db.withLock { db in
            let stmt = try db.statement("SELECT condition_signature, matched, last_matched, recurses, fingerprint FROM hazel_match_state WHERE rule_id=?1 AND item_key=?2")
            stmt.bind(1, ruleId); stmt.bind(2, itemKey)
            guard try stmt.step() else { return nil }
            return HazelMatchState(conditionSignature: stmt.columnText(0), matched: stmt.columnBool(1),
                                   lastMatched: stmt.columnTextOrNil(2).flatMap(Double.init).map(Date.init(timeIntervalSince1970:)), recurses: stmt.columnBool(3), fingerprint: stmt.columnTextOrNil(4))
        }
    }

    public func setState(_ state: HazelMatchState, ruleId: String, itemKey: String) throws {
        try db.withLock { db in
            let stmt = try db.statement("""
                INSERT INTO hazel_match_state(rule_id,item_key,condition_signature,matched,last_matched,recurses,fingerprint)
                VALUES (?1,?2,?3,?4,?5,?6,?7)
                ON CONFLICT(rule_id,item_key) DO UPDATE SET condition_signature=excluded.condition_signature,
                    matched=excluded.matched,last_matched=excluded.last_matched,recurses=excluded.recurses,fingerprint=excluded.fingerprint
                """)
            stmt.bind(1, ruleId); stmt.bind(2, itemKey); stmt.bind(3, state.conditionSignature)
            stmt.bind(4, bool: state.matched); stmt.bind(5, state.lastMatched.map { String($0.timeIntervalSince1970) })
            stmt.bind(6, bool: state.recurses)
            stmt.bind(7, state.fingerprint)
            try stmt.runToCompletion()
        }
    }

    public func changeBaseline(ruleId: String, itemKey: String, conditionKey: String) throws -> String? {
        try db.withLock { db in
            let stmt = try db.statement("SELECT value FROM hazel_change_baseline WHERE rule_id=?1 AND item_key=?2 AND condition_key=?3")
            stmt.bind(1, ruleId); stmt.bind(2, itemKey); stmt.bind(3, conditionKey)
            return try stmt.step() ? stmt.columnText(0) : nil
        }
    }

    public func setChangeBaselines(_ values: [String: String], ruleId: String, itemKey: String) throws {
        try setChangeBaselineBatch([itemKey: values], ruleId: ruleId)
    }
    public func setChangeBaselineBatch(_ values: [String: [String: String]], ruleId: String) throws {
        try db.withLock { db in
            try db.transaction {
                for (itemKey, entries) in values {
                    for (key, value) in entries {
                        let stmt = try db.statement("INSERT INTO hazel_change_baseline(rule_id,item_key,condition_key,value) VALUES (?1,?2,?3,?4) ON CONFLICT(rule_id,item_key,condition_key) DO UPDATE SET value=excluded.value")
                        stmt.bind(1, ruleId); stmt.bind(2, itemKey); stmt.bind(3, key); stmt.bind(4, value)
                        try stmt.runToCompletion()
                    }
                }
            }
        }
    }
}
