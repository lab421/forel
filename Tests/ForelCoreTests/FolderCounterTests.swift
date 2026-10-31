import Foundation
import Darwin
import Testing
@testable import ForelCore

@Suite struct FolderCounterTests {
    private final class Values: @unchecked Sendable {
        let lock = NSLock()
        var values: [Int64] = []
        var failures: [String] = []
        func append(_ value: Int64) { lock.lock(); defer { lock.unlock() }; values.append(value) }
        func fail(_ error: Error) { lock.lock(); defer { lock.unlock() }; failures.append(String(describing: error)) }
    }

    @Test func lowestReservationsAreAtomicAcrossConnections() throws {
        let dir = TempDir()
        let file = (dir.path as NSString).appendingPathComponent("state.sqlite")
        let first = DatabaseFolderCounterStore(db: try Database(path: file))
        let second = DatabaseFolderCounterStore(db: try Database(path: file))
        let values = Values()
        let targetDirectory = dir.path
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            do {
                let store = index.isMultiple(of: 2) ? first : second
                let reservation = try store.reserveLowest(folderId: "folder") { value in
                    (targetDirectory as NSString).appendingPathComponent("number-\(value)")
                }
                let target = try #require(reservation.destination)
                let fd = open(target, O_WRONLY | O_CREAT | O_EXCL, 0o600)
                guard fd >= 0 else { throw ActionError("Counter destination collision") }
                close(fd)
                try store.commit(reservation)
                values.append(reservation.value)
            } catch { values.fail(error) }
        }
        #expect(values.failures.isEmpty)
        #expect(values.values.sorted() == Array(1...20).map(Int64.init))
    }

    @Test func lowestFillsGapsInPreviewManualAndWatcherWithoutConsumingSequence() throws {
        let dir = TempDir()
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        let store = DatabaseFolderCounterStore(db: db)
        let previewStore = PreviewFolderCounterStore(underlying: store)
        var rule = makeRule(folderId: folder.id, name: "lowest")
        rule.isHazelImported = true
        rule.actions = [makeAction(.rename, .object([ActionParam.pattern: .string("counter"), HazelPattern.tokensKey: .array([
            .object(["type": .string("counter"), "digits": .string("4"), "allocation": .string("lowest")]),
            .object(["type": .string("extension")])
        ])]), ruleId: rule.id)]
        try db.insertRule(rule)
        _ = dir.file("0001.txt")
        _ = dir.file("0003.txt")
        let one = dir.file("one.txt")
        let two = dir.file("two.txt")
        let first = try #require(RuleEngine.previewFile(path: one, depth: 0, rules: [rule], counterStore: previewStore))
        let second = try #require(RuleEngine.previewFile(path: two, depth: 0, rules: [rule], counterStore: previewStore))
        #expect(first.rules.first?.actions.first?.targetPath == (dir.path as NSString).appendingPathComponent("0002.txt"))
        #expect(second.rules.first?.actions.first?.targetPath == (dir.path as NSString).appendingPathComponent("0004.txt"))
        #expect(try store.nextValue(folderId: folder.id) == 1)
        #expect(RuleEngine.run(path: one, depth: 0, rules: [rule], batchId: "one", counterStore: store).history.first?.status == .applied)
        WatcherCoordinator(db: db).handle(path: two)
        let secondResult = (dir.path as NSString).appendingPathComponent("0002.txt")
        #expect(FileManager.default.fileExists(atPath: secondResult))
        #expect(FileManager.default.fileExists(atPath: (dir.path as NSString).appendingPathComponent("0004.txt")))
        try FileManager.default.removeItem(atPath: secondResult)
        let three = dir.file("three.txt")
        #expect(RuleEngine.run(path: three, depth: 0, rules: [rule], batchId: "three", counterStore: store).history.first?.status == .applied)
        #expect(FileManager.default.fileExists(atPath: secondResult))
        #expect(try store.nextValue(folderId: folder.id) == 1)
    }

    @Test func lowestRollbackMakesUnpublishedNameAvailableAgain() throws {
        let dir = TempDir()
        let databasePath = (dir.path as NSString).appendingPathComponent("counter.sqlite")
        let first = DatabaseFolderCounterStore(db: try Database(path: databasePath))
        let second = DatabaseFolderCounterStore(db: try Database(path: databasePath))
        let candidate: (Int64) -> String = { (dir.path as NSString).appendingPathComponent("item-\($0)") }
        let reserved = try first.reserveLowest(folderId: "folder", candidate: candidate)
        let other = try second.reserveLowest(folderId: "folder", candidate: candidate)
        #expect(reserved.value == 1)
        #expect(other.value == 2)
        try first.rollback(reserved)
        let retry = try second.reserveLowest(folderId: "folder", candidate: candidate)
        #expect(retry.value == 1)
        try second.rollback(retry)
        try second.rollback(other)
    }

    @Test func lowestReclaimsReusedPIDButKeepsLiveReservations() throws {
        let dir = TempDir()
        let db = try Database(path: ":memory:")
        let store = DatabaseFolderCounterStore(db: db)
        let candidate: (Int64) -> String = { (dir.path as NSString).appendingPathComponent("item-\($0)") }
        try db.withLock { db in
            let stmt = try db.statement("INSERT INTO folder_counter_reservations(folder_id,destination,token,owner_pid,owner_start) VALUES (?1,?2,?3,?4,?5)")
            stmt.bind(1, "folder"); stmt.bind(2, candidate(1)); stmt.bind(3, "old")
            stmt.bind(4, Int64(getpid())); stmt.bind(5, Int64(1)); try stmt.runToCompletion()
        }
        let first = try store.reserveLowest(folderId: "folder", candidate: candidate)
        #expect(first.value == 1)
        let second = try store.reserveLowest(folderId: "folder", candidate: candidate)
        #expect(second.value == 2)
        try store.rollback(first)
        try store.rollback(second)
    }

    @Test func lowestRejectsRepeatedGeneratedNames() throws {
        let dir = TempDir()
        let occupied = dir.file("same")
        let store = DatabaseFolderCounterStore(db: try Database(path: ":memory:"))
        #expect(throws: ActionError.self) { try store.reserveLowest(folderId: "folder") { _ in occupied } }
        let preview = PreviewFolderCounterStore(underlying: store)
        #expect(throws: ActionError.self) { try preview.reserveLowest(folderId: "folder") { _ in occupied } }
    }

    @Test func reservationsAreAtomicAndSurviveDatabaseReopen() throws {
        let dir = TempDir()
        let file = (dir.path as NSString).appendingPathComponent("state.sqlite")
        let db = try Database(path: file)
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        let store = DatabaseFolderCounterStore(db: db)
        let secondConnection = try Database(path: file)
        let otherStore = DatabaseFolderCounterStore(db: secondConnection)
        let results = Values()
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            do {
                let selected = index.isMultiple(of: 2) ? store : otherStore
                let reserved = try selected.reserve(folderId: folder.id)
                try selected.commit(reserved)
                results.append(reserved.value)
            } catch { results.fail(error) }
        }
        #expect(results.failures.isEmpty)
        #expect(results.values.sorted() == Array(1...40).map(Int64.init))
        let reopened = try Database(path: file)
        let reopenedStore = DatabaseFolderCounterStore(db: reopened)
        #expect(try reopenedStore.nextValue(folderId: folder.id) == 41)
    }

    @Test func rollbackIsConditionalAndResetInvalidatesOldReservation() throws {
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: TempDir().path)
        try db.insertFolder(folder)
        let store = DatabaseFolderCounterStore(db: db)
        let first = try store.reserve(folderId: folder.id)
        try store.rollback(first)
        #expect(try store.nextValue(folderId: folder.id) == 1)
        let old = try store.reserve(folderId: folder.id)
        let later = try store.reserve(folderId: folder.id)
        try store.rollback(old)
        #expect(try store.nextValue(folderId: folder.id) == 3)
        try store.commit(later)
        try store.reset(folderId: folder.id)
        let afterReset = try store.reserve(folderId: folder.id)
        #expect(afterReset.value == 1)
        try store.rollback(old)
        #expect(try store.nextValue(folderId: folder.id) == 2)
    }

    @Test func previewDoesNotConsumeCounterAndFailedRenameRollsBack() throws {
        let dir = TempDir()
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        let store = DatabaseFolderCounterStore(db: db)
        let previewStore = PreviewFolderCounterStore(underlying: store)
        var rule = makeRule(folderId: folder.id, name: "number")
        rule.isHazelImported = true
        rule.actions = [makeAction(.rename, .object([ActionParam.pattern: .string("counter"), HazelPattern.tokensKey: .array([
            .object(["type": .string("counter"), "digits": .string("4")]),
            .object(["type": .string("extension")])
        ])]), ruleId: rule.id)]
        try db.insertRule(rule)
        let one = dir.file("one.txt")
        let two = dir.file("two.txt")
        let firstPreview = try #require(RuleEngine.previewFile(path: one, depth: 0, rules: [rule], counterStore: previewStore))
        let secondPreview = try #require(RuleEngine.previewFile(path: two, depth: 0, rules: [rule], counterStore: previewStore))
        #expect(firstPreview.rules.first?.actions.first?.targetPath == (dir.path as NSString).appendingPathComponent("0001.txt"))
        #expect(secondPreview.rules.first?.actions.first?.targetPath == (dir.path as NSString).appendingPathComponent("0002.txt"))
        #expect(try store.nextValue(folderId: folder.id) == 1)
        #expect(RuleEngine.run(path: one, depth: 0, rules: [rule], batchId: "one", counterStore: store).history.first?.status == .applied)
        WatcherCoordinator(db: db).handle(path: two)
        #expect(FileManager.default.fileExists(atPath: (dir.path as NSString).appendingPathComponent("0002.txt")))
        #expect(try store.nextValue(folderId: folder.id) == 3)
        _ = dir.file("0003.txt")
        let blocked = dir.file("blocked.txt")
        #expect(RuleEngine.run(path: blocked, depth: 0, rules: [rule], batchId: "blocked", counterStore: store).history.first?.status == .failed)
        #expect(try store.nextValue(folderId: folder.id) == 3)
    }
}
