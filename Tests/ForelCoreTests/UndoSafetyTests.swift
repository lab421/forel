import Testing
import Foundation
@testable import ForelCore

@Suite struct UndoSafetyTests {
    private func moveHistoryEntry(from: String, to: String, createdAt: String = ISO8601DateFormatter().string(from: Date())) -> HistoryEntry {
        let identity = FileFingerprint.identity(to)
        return HistoryEntry(
            batchId: "batch-1",
            ruleId: "rule-1",
            ruleName: "archive",
            actionKind: .moveToFolder,
            originalPath: from,
            resultPath: to,
            undo: Undo.move(from: from, to: to).toJSON(),
            reversible: true,
            status: .applied,
            createdAt: createdAt,
            resultVolumeId: identity?.volumeId,
            resultFileId: identity?.fileId
        )
    }

    @Test func safeMoveUndoIsAllowed() throws {
        let dir = TempDir()
        let original = (dir.path as NSString).appendingPathComponent("a.txt")
        let destination = dir.dir("Archive")
        let moved = (destination as NSString).appendingPathComponent("a.txt")
        try "hi".write(toFile: moved, atomically: true, encoding: .utf8)

        let entry = moveHistoryEntry(from: original, to: moved)

        #expect(UndoChecker.evaluate(entry) == .safe)
    }

    @Test func moveUndoBlockedWhenOriginalPathIsOccupied() throws {
        let dir = TempDir()
        let original = dir.file("a.txt", contents: "someone else's file")
        let destination = dir.dir("Archive")
        let moved = (destination as NSString).appendingPathComponent("a.txt")
        try "hi".write(toFile: moved, atomically: true, encoding: .utf8)

        let entry = moveHistoryEntry(from: original, to: moved)

        guard case .unsafe = UndoChecker.evaluate(entry) else {
            Issue.record("expected unsafe")
            return
        }
    }

    @Test func moveUndoBlockedWhenResultFileIdentityChanged() throws {
        let dir = TempDir()
        let original = (dir.path as NSString).appendingPathComponent("a.txt")
        let destination = dir.dir("Archive")
        let moved = (destination as NSString).appendingPathComponent("a.txt")
        try "hi".write(toFile: moved, atomically: true, encoding: .utf8)

        var entry = moveHistoryEntry(from: original, to: moved)
        entry.resultFileId = (entry.resultFileId ?? 0) + 999_999

        guard case .unsafe = UndoChecker.evaluate(entry) else {
            Issue.record("expected unsafe")
            return
        }
    }

    @Test func tagUndoSafeWhenFileStillExists() throws {
        let dir = TempDir()
        let file = dir.file("a.txt")
        let entry = HistoryEntry(
            batchId: "batch-1",
            ruleId: "rule-1",
            ruleName: "tag",
            actionKind: .addTag,
            originalPath: file,
            resultPath: file,
            undo: Undo.addTags(path: file, tags: ["Reviewed"]).toJSON(),
            reversible: true,
            status: .applied
        )

        #expect(UndoChecker.evaluate(entry) == .safe)
    }

    @Test func copyUndoIgnoresActiveRulesSinceNothingIsRestored() throws {
        let dir = TempDir()
        let original = dir.file("a.txt", contents: "hi")
        let destination = dir.dir("Backup")
        let copy = (destination as NSString).appendingPathComponent("a.txt")
        try FileManager.default.copyItem(atPath: original, toPath: copy)

        // A rule that would obviously match the (untouched) original file —
        // must not block the copy-undo, since copy-undo only deletes the
        // copy and never restores anything to `originalPath`.
        var rule = makeRule(name: "archive txt", conditions: [makeCondition(.extension_, .is, "txt")])
        rule.actions = [makeAction(.moveToFolder, .object(["destination": .string(destination)]), position: 0)]

        let entry = HistoryEntry(
            batchId: "batch-1",
            ruleId: "rule-1",
            ruleName: "backup",
            actionKind: .copyToFolder,
            originalPath: original,
            resultPath: original,
            undo: Undo.copy(copy: copy).toJSON(),
            reversible: true,
            status: .applied
        )

        #expect(UndoChecker.evaluate(entry, activeRules: [rule], watchedRoot: dir.path) == .safe)
    }

    @Test func undoBlockedWhenAnActiveRuleWouldImmediatelyReprocessTheRestoredFile() throws {
        let dir = TempDir()
        let original = (dir.path as NSString).appendingPathComponent("a.txt")
        let destination = dir.dir("Archive")
        let moved = (destination as NSString).appendingPathComponent("a.txt")
        try "hi".write(toFile: moved, atomically: true, encoding: .utf8)

        var archiveRule = makeRule(name: "archive txt", conditions: [makeCondition(.extension_, .is, "txt")])
        archiveRule.actions = [makeAction(.moveToFolder, .object(["destination": .string(destination)]), position: 0, ruleId: archiveRule.id)]

        let entry = moveHistoryEntry(from: original, to: moved)

        guard case .unsafe(let reason) = UndoChecker.evaluate(entry, activeRules: [archiveRule], watchedRoot: dir.path) else {
            Issue.record("expected unsafe")
            return
        }
        #expect(reason.contains("archive txt"))
    }

    @Test func undoSafeWhenNoActiveRuleMatchesTheRestoredPath() throws {
        let dir = TempDir()
        let original = (dir.path as NSString).appendingPathComponent("a.txt")
        let destination = dir.dir("Archive")
        let moved = (destination as NSString).appendingPathComponent("a.txt")
        try "hi".write(toFile: moved, atomically: true, encoding: .utf8)

        var pngRule = makeRule(name: "archive png", conditions: [makeCondition(.extension_, .is, "png")])
        pngRule.actions = [makeAction(.moveToFolder, .object(["destination": .string(destination)]), position: 0, ruleId: pngRule.id)]

        let entry = moveHistoryEntry(from: original, to: moved)

        #expect(UndoChecker.evaluate(entry, activeRules: [pngRule], watchedRoot: dir.path) == .safe)
    }

    @Test func collidingRestoreTargetsDetectsTwoEntriesRestoringToTheSamePath() throws {
        let dir = TempDir()
        let shared = (dir.path as NSString).appendingPathComponent("a.txt")
        let destination = dir.dir("Archive")
        let movedA = (destination as NSString).appendingPathComponent("a.txt")
        let movedB = (destination as NSString).appendingPathComponent("b.txt")

        let entryA = moveHistoryEntry(from: shared, to: movedA)
        var entryB = moveHistoryEntry(from: shared, to: movedB)
        entryB.id = UUID().uuidString

        let colliding = UndoChecker.collidingRestoreTargets([entryA, entryB])

        #expect(colliding == Set([entryA.id, entryB.id]))
    }

    @Test func collidingRestoreTargetsIsEmptyForDistinctRestorePaths() throws {
        let dir = TempDir()
        let destination = dir.dir("Archive")
        let entryA = moveHistoryEntry(from: (dir.path as NSString).appendingPathComponent("a.txt"), to: (destination as NSString).appendingPathComponent("a.txt"))
        let entryB = moveHistoryEntry(from: (dir.path as NSString).appendingPathComponent("b.txt"), to: (destination as NSString).appendingPathComponent("b.txt"))

        #expect(UndoChecker.collidingRestoreTargets([entryA, entryB]).isEmpty)
    }
}
