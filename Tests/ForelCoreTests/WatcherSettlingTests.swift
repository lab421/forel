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

import Testing
import Foundation
@testable import ForelCore

/// The watcher waits for an arriving file or folder to finish being written
/// before running rules on it.
@Suite struct WatcherSettlingTests {
    private func makeDB() throws -> Database {
        try Database(path: ":memory:")
    }

    /// A watched folder with one rule moving PDFs into `Documents`.
    private func makePDFSortingFolder(db: Database, dir: TempDir) throws -> String {
        let destination = dir.dir("Documents")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "sort pdf")
        rule.conditions = [makeCondition(.extension_, .is, "pdf", ruleId: rule.id)]
        rule.actions = [makeAction(.moveToFolder, .object(["destination": .string(destination)]), position: 0, ruleId: rule.id)]
        try db.insertRule(rule)
        return destination
    }

    @Test func arrivingFileIsNotMovedWhileItIsStillBeingWritten() throws {
        let db = try makeDB()
        let dir = TempDir()
        let destination = try makePDFSortingFolder(db: db, dir: dir)
        // Like AirDrop: created empty under its final name, then filled in.
        let file = dir.file("incoming.pdf")
        let movedPath = (destination as NSString).appendingPathComponent("incoming.pdf")

        let coordinator = WatcherCoordinator(db: db, settleInterval: 0.3)
        coordinator.enqueue(event: .pathArrived(file))

        let handle = try #require(FileHandle(forWritingAtPath: file))
        for _ in 0..<12 {
            Thread.sleep(forTimeInterval: 0.08)
            handle.seekToEndOfFile()
            handle.write(Data("chunk".utf8))
            #expect(FileManager.default.fileExists(atPath: file))
            #expect(!FileManager.default.fileExists(atPath: movedPath))
        }
        try handle.close()

        coordinator.waitForPendingEvents()

        #expect(!FileManager.default.fileExists(atPath: file))
        #expect(try String(contentsOfFile: movedPath, encoding: .utf8) == String(repeating: "chunk", count: 12))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination) == ["incoming.pdf"])
        #expect(try db.listHistory().count == 1)
    }

    @Test func arrivingFileMarkedBusyWaitsUntilTheMarkerIsCleared() throws {
        let db = try makeDB()
        let dir = TempDir()
        let destination = try makePDFSortingFolder(db: db, dir: dir)
        let file = dir.file("incoming.pdf", contents: "complete")
        let movedPath = (destination as NSString).appendingPathComponent("incoming.pdf")
        try FileManager.default.setAttributes([.creationDate: FileReadiness.busyCreationDate], ofItemAtPath: file)

        let coordinator = WatcherCoordinator(db: db, settleInterval: 0.05)
        coordinator.enqueue(event: .pathArrived(file))

        // Size and modification time are stable, but the writer hasn't
        // released the file yet.
        Thread.sleep(forTimeInterval: 0.4)
        #expect(FileManager.default.fileExists(atPath: file))
        #expect(!FileManager.default.fileExists(atPath: movedPath))
        #expect(try db.listHistory().isEmpty)

        try FileManager.default.setAttributes([.creationDate: Date()], ofItemAtPath: file)
        coordinator.waitForPendingEvents()

        #expect(!FileManager.default.fileExists(atPath: file))
        #expect(FileManager.default.fileExists(atPath: movedPath))
    }

    @Test func rescanAlsoWaitsForFilesToSettle() throws {
        let db = try makeDB()
        let dir = TempDir()
        let destination = try makePDFSortingFolder(db: db, dir: dir)
        let busy = dir.file("busy.pdf", contents: "partial")
        let ready = dir.file("ready.pdf", contents: "complete")
        try FileManager.default.setAttributes([.creationDate: FileReadiness.busyCreationDate], ofItemAtPath: busy)

        let coordinator = WatcherCoordinator(db: db, settleInterval: 0.05)
        coordinator.enqueue(event: .rescanSubtree(dir.path))

        Thread.sleep(forTimeInterval: 0.4)
        #expect(FileManager.default.fileExists(atPath: busy))
        #expect(!FileManager.default.fileExists(atPath: ready))
        #expect(FileManager.default.fileExists(atPath: (destination as NSString).appendingPathComponent("ready.pdf")))

        try FileManager.default.setAttributes([.creationDate: Date()], ofItemAtPath: busy)
        coordinator.waitForPendingEvents()

        #expect(FileManager.default.fileExists(atPath: (destination as NSString).appendingPathComponent("busy.pdf")))
    }

    @Test func stoppingAFolderDropsItsFilesStillWaitingToSettle() throws {
        let db = try makeDB()
        let dir = TempDir()
        let destination = try makePDFSortingFolder(db: db, dir: dir)
        let file = dir.file("incoming.pdf", contents: "complete")
        try FileManager.default.setAttributes([.creationDate: FileReadiness.busyCreationDate], ofItemAtPath: file)

        let coordinator = WatcherCoordinator(db: db, settleInterval: 0.05)
        coordinator.enqueue(event: .pathArrived(file))
        Thread.sleep(forTimeInterval: 0.2)

        // Pausing (or disabling/removing the folder) while the transfer is
        // still in progress: the rule must not run once it completes.
        coordinator.remove(dir.path)
        try FileManager.default.setAttributes([.creationDate: Date()], ofItemAtPath: file)
        coordinator.waitForPendingEvents()
        Thread.sleep(forTimeInterval: 0.2)

        #expect(FileManager.default.fileExists(atPath: file))
        #expect(!FileManager.default.fileExists(atPath: (destination as NSString).appendingPathComponent("incoming.pdf")))
        #expect(try db.listHistory().isEmpty)
    }

    @Test func arrivingFolderIsNotMovedWhileAFileInsideIsStillBeingWritten() throws {
        let db = try makeDB()
        let dir = TempDir()
        let destination = dir.dir("Archive")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "archive exports")
        rule.conditions = [makeCondition(.name, .is, "Export", ruleId: rule.id)]
        rule.actions = [makeAction(.moveToFolder, .object(["destination": .string(destination)]), position: 0, ruleId: rule.id)]
        try db.insertRule(rule)

        let incoming = dir.dir("Export")
        let inner = (incoming as NSString).appendingPathComponent("data.bin")
        FileManager.default.createFile(atPath: inner, contents: nil)
        let movedPath = (destination as NSString).appendingPathComponent("Export")

        let coordinator = WatcherCoordinator(db: db, settleInterval: 0.3)
        coordinator.enqueue(event: .pathArrived(incoming))

        // The folder's own size and modification time don't change while a
        // file inside it grows.
        let handle = try #require(FileHandle(forWritingAtPath: inner))
        for _ in 0..<12 {
            Thread.sleep(forTimeInterval: 0.08)
            handle.seekToEndOfFile()
            handle.write(Data("chunk".utf8))
            #expect(FileManager.default.fileExists(atPath: incoming))
            #expect(!FileManager.default.fileExists(atPath: movedPath))
        }
        try handle.close()

        coordinator.waitForPendingEvents()

        #expect(!FileManager.default.fileExists(atPath: incoming))
        let movedInner = (movedPath as NSString).appendingPathComponent("data.bin")
        #expect(try String(contentsOfFile: movedInner, encoding: .utf8) == String(repeating: "chunk", count: 12))
    }

    @Test func itemsArrivingInsideAWaitingFolderAreEvaluatedWhenItSettles() throws {
        let db = try makeDB()
        let dir = TempDir()
        let destination = dir.dir("Documents")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "sort pdf", recursionDepth: nil)
        rule.conditions = [makeCondition(.extension_, .is, "pdf", ruleId: rule.id)]
        rule.actions = [makeAction(.moveToFolder, .object(["destination": .string(destination)]), position: 0, ruleId: rule.id)]
        try db.insertRule(rule)

        // Like an unzip or a clone: a folder arrives, then its contents.
        let incoming = dir.dir("Export")
        let first = (incoming as NSString).appendingPathComponent("a.pdf")
        let second = (incoming as NSString).appendingPathComponent("Nested/b.pdf")
        _ = dir.dir("Export/Nested")
        try "a".write(toFile: first, atomically: true, encoding: .utf8)
        try "b".write(toFile: second, atomically: true, encoding: .utf8)

        let coordinator = WatcherCoordinator(db: db, settleInterval: 0.1)
        coordinator.enqueue(event: .pathArrived(incoming))
        coordinator.enqueue(event: .pathArrived(first))
        coordinator.enqueue(event: .pathArrived((incoming as NSString).appendingPathComponent("Nested")))
        coordinator.enqueue(event: .pathArrived(second))
        coordinator.waitForPendingEvents()

        #expect(!FileManager.default.fileExists(atPath: first))
        #expect(!FileManager.default.fileExists(atPath: second))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: destination)) == ["a.pdf", "b.pdf"])
        #expect(try db.listHistory().count == 2)
    }

    @Test func folderArrivingWithContentsProcessesThemWithoutTheirOwnEvents() throws {
        let db = try makeDB()
        let dir = TempDir()
        let destination = dir.dir("Documents")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "sort pdf", recursionDepth: nil)
        rule.conditions = [makeCondition(.extension_, .is, "pdf", ruleId: rule.id)]
        rule.actions = [makeAction(.moveToFolder, .object(["destination": .string(destination)]), position: 0, ruleId: rule.id)]
        try db.insertRule(rule)

        // Like moving a folder in from elsewhere: FSEvents reports only the
        // folder — its existing contents were created outside the watched
        // tree and never get events of their own.
        let incoming = dir.dir("Export")
        _ = dir.dir("Export/Nested")
        let first = (incoming as NSString).appendingPathComponent("a.pdf")
        let second = (incoming as NSString).appendingPathComponent("Nested/b.pdf")
        try "a".write(toFile: first, atomically: true, encoding: .utf8)
        try "b".write(toFile: second, atomically: true, encoding: .utf8)

        let coordinator = WatcherCoordinator(db: db, settleInterval: 0.05)
        coordinator.enqueue(event: .pathArrived(incoming))
        coordinator.waitForPendingEvents()

        #expect(FileManager.default.fileExists(atPath: incoming))
        #expect(!FileManager.default.fileExists(atPath: first))
        #expect(!FileManager.default.fileExists(atPath: second))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: destination)) == ["a.pdf", "b.pdf"])
        #expect(try db.listHistory().count == 2)
    }

    @Test(arguments: ["preview", "manual", "watcher-arrival", "watcher-rescan"])
    func directorySymlinksDoNotProcessExternalContents(execution: String) throws {
        let db = try makeDB()
        let dir = TempDir()
        let watched = dir.dir("Watched")
        let outside = dir.dir("Outside")
        let destination = dir.dir("Archive")
        let original = dir.file("Outside/private.pdf", contents: "private")
        let link = watched + "/Link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside)
        let folder = WatchedFolder(path: watched)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "sort pdf", recursionDepth: nil)
        rule.conditions = [makeCondition(.extension_, .is, "pdf", ruleId: rule.id)]
        rule.actions = [makeAction(.moveToFolder, .object(["destination": .string(destination)]), ruleId: rule.id)]
        try db.insertRule(rule)
        let rules = try db.executionRules(folderID: folder.id, isPro: false)

        if execution == "preview" || execution == "manual" {
            let entries = RuleEngine.walkEntries(root: watched, maxDepth: RuleEngine.maxRuleDepth(rules))
            #expect(entries.map(\.path) == [link])
            for entry in entries {
                if execution == "preview" {
                    #expect(RuleEngine.previewFile(path: entry.path, depth: entry.depth, rules: rules, isPro: false) == nil)
                } else {
                    let result = RuleEngine.run(path: entry.path, depth: entry.depth, rules: rules, batchId: "manual", root: watched, isPro: false)
                    #expect(result.history.isEmpty)
                }
            }
        } else {
            let coordinator = WatcherCoordinator(db: db, settleInterval: 0.01)
            coordinator.enqueue(event: execution == "watcher-arrival" ? .pathArrived(link) : .rescanSubtree(link))
            coordinator.waitForPendingEvents()
        }

        #expect(try String(contentsOfFile: original, encoding: .utf8) == "private")
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination).isEmpty)
        #expect(try db.listHistory().isEmpty)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == outside)
    }

    @Test(.timeLimit(.minutes(1)))
    func rescanDoesNotReadSubfoldersBeyondWhatTheRulesNeed() throws {
        let db = try makeDB()
        let dir = TempDir()
        let destination = try makePDFSortingFolder(db: db, dir: dir)
        let ready = dir.file("ready.pdf", contents: "complete")
        // Deeper than the rule's depth: a rescan must not look in here, so
        // this leftover busy file must not keep the subfolder waiting.
        let deep = dir.dir("Projects/Client")
        let leftover = (deep as NSString).appendingPathComponent("leftover.bin")
        try "partial".write(toFile: leftover, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.creationDate: FileReadiness.busyCreationDate], ofItemAtPath: leftover)

        let coordinator = WatcherCoordinator(db: db, settleInterval: 0.05)
        coordinator.enqueue(event: .rescanSubtree(dir.path))
        coordinator.waitForPendingEvents()

        #expect(FileManager.default.fileExists(atPath: (destination as NSString).appendingPathComponent("ready.pdf")))
        #expect(!FileManager.default.fileExists(atPath: ready))
        #expect(FileManager.default.fileExists(atPath: leftover))
    }
}
