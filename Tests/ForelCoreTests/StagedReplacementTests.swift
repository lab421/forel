import Foundation
import Testing
@testable import ForelCore

@Suite struct StagedReplacementTests {
    @Test func syncTimeoutTerminatesBlockedProcess() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let started = Date()
        #expect(throws: ActionError.self) { try ActionExecutor.runSyncProcess(process, timeout: 0.05) }
        #expect(!process.isRunning)
        #expect(Date().timeIntervalSince(started) < 4)
    }

    @Test func collisionDuringStagingDoesNotReplaceNewDestination() throws {
        let source = TempDir()
        let destination = TempDir()
        let incoming = source.file("item.txt", contents: "new")
        let target = destination.file("item.txt", contents: "old")
        #expect(throws: ActionError.self) {
            try ActionExecutor.stagedReplace(path: incoming, target: target, moving: true, beforePublish: {
                try "concurrent".write(toFile: target, atomically: true, encoding: .utf8)
            })
        }
        #expect(try String(contentsOfFile: incoming, encoding: .utf8) == "new")
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "concurrent")
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["item.txt"])
    }

    @Test func replacementPublishesThenMovesSourceAndPreservesOldTarget() throws {
        let source = TempDir()
        let destination = TempDir()
        let incoming = source.file("item.txt", contents: "new")
        let target = destination.file("item.txt", contents: "old")
        let backup = (destination.path as NSString).appendingPathComponent("backup")
        let applied = try ActionExecutor.stagedReplace(path: incoming, target: target, moving: true, trash: { displaced in
            #expect(try String(contentsOfFile: target, encoding: .utf8) == "new")
            #expect(FileManager.default.fileExists(atPath: incoming))
            try FileManager.default.moveItem(atPath: displaced, toPath: backup)
        })
        #expect(applied.newPath == target)
        #expect(applied.undo == .none)
        #expect(!FileManager.default.fileExists(atPath: incoming))
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "new")
        #expect(try String(contentsOfFile: backup, encoding: .utf8) == "old")
    }

    @Test func replacementWithoutConflictRetainsMoveUndo() throws {
        let source = TempDir()
        let destination = TempDir()
        let incoming = source.file("item.txt", contents: "new")
        let target = (destination.path as NSString).appendingPathComponent("item.txt")
        let applied = try ActionExecutor.stagedReplace(path: incoming, target: target, moving: true)
        #expect(applied.undo == .move(from: incoming, to: target))
        #expect(!FileManager.default.fileExists(atPath: incoming))
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "new")
    }

    @Test func failedTrashRestoresOldTargetAndKeepsSource() throws {
        let source = TempDir()
        let destination = TempDir()
        let incoming = source.file("item.txt", contents: "new")
        let target = destination.file("item.txt", contents: "old")
        #expect(throws: ActionError.self) {
            try ActionExecutor.stagedReplace(path: incoming, target: target, moving: true, trash: { _ in
                throw ActionError("injected Trash failure")
            })
        }
        #expect(try String(contentsOfFile: incoming, encoding: .utf8) == "new")
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "old")
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["item.txt"])
    }

    @Test func concurrentReplacementKeepsSourceAndDisplacedItem() throws {
        let source = TempDir()
        let destination = TempDir()
        let incoming = source.file("item.txt", contents: "new")
        let target = destination.file("item.txt", contents: "old")
        #expect(throws: ActionError.self) {
            try ActionExecutor.stagedReplace(path: incoming, target: target, moving: true, trash: { _ in
                try FileManager.default.removeItem(atPath: target)
                try "concurrent".write(toFile: target, atomically: true, encoding: .utf8)
                throw ActionError("injected Trash failure")
            })
        }
        #expect(try String(contentsOfFile: incoming, encoding: .utf8) == "new")
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "concurrent")
        let recovery = try #require(FileManager.default.contentsOfDirectory(atPath: destination.path).first { $0.hasPrefix(".forel-replace-") })
        #expect(try String(contentsOfFile: (destination.path as NSString).appendingPathComponent(recovery), encoding: .utf8) == "old")
    }

    @Test func changedSourceAfterPublicationIsNotRemoved() throws {
        let source = TempDir()
        let destination = TempDir()
        let incoming = source.file("item.txt", contents: "new")
        let target = destination.file("item.txt", contents: "old")
        let backup = (destination.path as NSString).appendingPathComponent("backup")
        #expect(throws: ActionError.self) {
            try ActionExecutor.stagedReplace(path: incoming, target: target, moving: true, trash: { displaced in
                try FileManager.default.moveItem(atPath: displaced, toPath: backup)
                try "changed".write(toFile: incoming, atomically: true, encoding: .utf8)
            })
        }
        #expect(try String(contentsOfFile: incoming, encoding: .utf8) == "changed")
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "new")
        #expect(try String(contentsOfFile: backup, encoding: .utf8) == "old")
    }
}
