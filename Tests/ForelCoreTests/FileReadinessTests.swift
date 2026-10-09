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

import Foundation
import Testing
@testable import ForelCore

@Suite struct FileReadinessTests {
    @Test func detectsFinderBusyCreationDate() throws {
        let dir = TempDir()
        let file = dir.file("incoming.pdf")

        #expect(!FileReadiness.isMarkedBusy(file))

        try FileManager.default.setAttributes([.creationDate: FileReadiness.busyCreationDate], ofItemAtPath: file)
        #expect(FileReadiness.isMarkedBusy(file))

        // Written as a local time on some volumes: any time zone offset
        // around the marker still counts.
        try FileManager.default.setAttributes([.creationDate: FileReadiness.busyCreationDate.addingTimeInterval(-9 * 3600)], ofItemAtPath: file)
        #expect(FileReadiness.isMarkedBusy(file))

        try FileManager.default.setAttributes([.creationDate: Date()], ofItemAtPath: file)
        #expect(!FileReadiness.isMarkedBusy(file))
    }

    @Test func missingFileIsNotBusy() {
        #expect(!FileReadiness.isMarkedBusy("/nonexistent/forel/incoming.pdf"))
    }

    @Test(arguments: [ActionKind.moveToFolder, .copyToFolder])
    func folderWithBusyDescendantIsIgnoredByRunAndPreview(action: ActionKind) throws {
        let dir = TempDir()
        let incoming = dir.dir("Export")
        let nested = dir.dir("Export/Nested")
        let child = (nested as NSString).appendingPathComponent("data.bin")
        try "partial".write(toFile: child, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.creationDate: FileReadiness.busyCreationDate], ofItemAtPath: child)
        let destination = dir.dir("Archive")
        let resultPath = (destination as NSString).appendingPathComponent("Export")
        let rule = makeRule(
            name: "archive exports",
            conditions: [makeCondition(.name, .is, "Export")],
            actions: [makeAction(action, .object(["destination": .string(destination)]))]
        )

        #expect(!FileReadiness.isMarkedBusy(incoming))
        #expect(FileReadiness.snapshot(incoming)?.isMarkedBusy == true)
        #expect(RuleEngine.previewFile(path: incoming, depth: 0, rules: [rule]) == nil)
        let (matched, history) = RuleEngine.run(path: incoming, depth: 0, rules: [rule], batchId: "batch")
        #expect(matched.isEmpty)
        #expect(history.isEmpty)
        #expect(FileManager.default.fileExists(atPath: child))
        #expect(!FileManager.default.fileExists(atPath: resultPath))

        try "complete".write(toFile: child, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.creationDate: Date()], ofItemAtPath: child)
        #expect(RuleEngine.previewFile(path: incoming, depth: 0, rules: [rule]) != nil)
        #expect(RuleEngine.run(path: incoming, depth: 0, rules: [rule], batchId: "batch").matched == ["archive exports"])
        let resultChild = (resultPath as NSString).appendingPathComponent("Nested/data.bin")
        #expect(try String(contentsOfFile: resultChild, encoding: .utf8) == "complete")
    }

    @Test func watcherWaitsForBusyDescendantOfArrivingFolder() throws {
        let dir = TempDir()
        let incoming = dir.dir("Export")
        let nested = dir.dir("Export/Nested")
        let child = (nested as NSString).appendingPathComponent("data.bin")
        try "partial".write(toFile: child, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.creationDate: FileReadiness.busyCreationDate], ofItemAtPath: child)
        let destination = dir.dir("Archive")
        let resultPath = (destination as NSString).appendingPathComponent("Export")
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "archive exports")
        rule.conditions = [makeCondition(.name, .is, "Export", ruleId: rule.id)]
        rule.actions = [makeAction(.moveToFolder, .object(["destination": .string(destination)]), position: 0, ruleId: rule.id)]
        try db.insertRule(rule)
        let coordinator = WatcherCoordinator(db: db, settleInterval: 0.05)
        coordinator.enqueue(event: .pathArrived(incoming))
        Thread.sleep(forTimeInterval: 0.3)
        #expect(FileManager.default.fileExists(atPath: child))
        #expect(!FileManager.default.fileExists(atPath: resultPath))
        #expect(try db.listHistory().isEmpty)

        try "complete".write(toFile: child, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.creationDate: Date()], ofItemAtPath: child)
        coordinator.waitForPendingEvents()
        #expect(!FileManager.default.fileExists(atPath: incoming))
        let resultChild = (resultPath as NSString).appendingPathComponent("Nested/data.bin")
        #expect(try String(contentsOfFile: resultChild, encoding: .utf8) == "complete")
        #expect(try db.listHistory().count == 1)
    }

    @Test func busyFileIsIgnoredByRunPreviewAndStaysInPlace() throws {
        let dir = TempDir()
        let file = dir.file("incoming.pdf")
        let destination = dir.dir("Documents")
        let rule = makeRule(
            name: "pdfs",
            conditions: [makeCondition(.extension_, .is, "pdf")],
            actions: [makeAction(.moveToFolder, .object(["destination": .string(destination)]))]
        )
        try FileManager.default.setAttributes([.creationDate: FileReadiness.busyCreationDate], ofItemAtPath: file)

        #expect(RuleEngine.previewFile(path: file, depth: 0, rules: [rule]) == nil)
        let (matched, history) = RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "batch")
        #expect(matched.isEmpty)
        #expect(history.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file))

        // Once the transfer completes and the marker is cleared, the same
        // file is previewed and moved as usual.
        try FileManager.default.setAttributes([.creationDate: Date()], ofItemAtPath: file)
        #expect(RuleEngine.previewFile(path: file, depth: 0, rules: [rule]) != nil)
        #expect(RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "batch").matched == ["pdfs"])
        #expect(!FileManager.default.fileExists(atPath: file))
    }
}
