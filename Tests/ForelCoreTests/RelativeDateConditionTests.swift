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

import Darwin
import Foundation
import Testing
@testable import ForelCore

@Suite struct RelativeDateConditionTests {
    @Test(arguments: [ConditionKind.dateAdded, .createdAt, .dateModified], [Operator.olderThan, .withinLast])
    func hourlyConditionsAgreeInPreviewManualRunAndWatcher(kind: ConditionKind, op: Operator) throws {
        // Both files are less than a day old, but only one is less than an
        // hour old. This also catches hours accidentally being treated as days.
        for execution in ["preview", "manual", "watcher"] {
            let dir = TempDir()
            let input = dir.dir("Input")
            let destination = dir.dir("Processed")
            let recent = dir.file("Input/recent.txt", contents: "recent")
            let old = dir.file("Input/old.txt", contents: "old")
            try setTimestamp(kind, path: recent, age: 30 * 60)
            try setTimestamp(kind, path: old, age: 90 * 60)
            let expected = op == .withinLast ? recent : old
            let untouched = op == .withinLast ? old : recent

            let db = try Database(path: ":memory:")
            let folder = WatchedFolder(path: input)
            try db.insertFolder(folder)
            var rule = makeRule(folderId: folder.id, name: "hourly condition")
            rule.conditions = [makeCondition(kind, op, "1 hours", ruleId: rule.id)]
            rule.actions = [makeAction(.moveToFolder, .object([ActionParam.destination: .string(destination)]), ruleId: rule.id)]
            try db.insertRule(rule)
            let rules = try db.listRules(folderId: folder.id)
            #expect(rules.first?.conditions.first?.operator == op)
            #expect(rules.first?.conditions.first?.value == "1 hours")

            if execution == "preview" {
                let preview = try #require(RuleEngine.previewFile(path: expected, depth: 0, rules: rules))
                #expect(preview.rules.first?.actions.first?.targetPath == destination + "/" + (expected as NSString).lastPathComponent)
                #expect(RuleEngine.previewFile(path: untouched, depth: 0, rules: rules) == nil)
                #expect(FileManager.default.fileExists(atPath: recent))
                #expect(FileManager.default.fileExists(atPath: old))
                #expect(try db.listHistory().isEmpty)
            } else {
                if execution == "manual" {
                    for entry in RuleEngine.walkEntries(root: input, maxDepth: 0) {
                        let result = RuleEngine.run(path: entry.path, depth: entry.depth, rules: rules, batchId: "hourly")
                        #expect(result.history.filter { $0.status == .applied }.count == (entry.path == expected ? 1 : 0))
                    }
                } else {
                    let coordinator = WatcherCoordinator(db: db, settleInterval: 0.01)
                    coordinator.enqueue(event: .pathArrived(recent))
                    coordinator.enqueue(event: .pathArrived(old))
                    coordinator.waitForPendingEvents()
                    #expect(try db.listHistory().filter { $0.status == .applied }.count == 1)
                }
                #expect(!FileManager.default.fileExists(atPath: expected))
                #expect(FileManager.default.fileExists(atPath: destination + "/" + (expected as NSString).lastPathComponent))
                #expect(FileManager.default.fileExists(atPath: untouched))
            }
        }
    }

    @Test func hourlyDurationsAcceptSingularAndPreserveDayBasedRules() throws {
        let dir = TempDir()
        let file = dir.file("old.txt")
        try setTimestamp(.dateAdded, path: file, age: 90 * 60)

        #expect(ConditionEvaluator.evaluate(makeCondition(.dateAdded, .olderThan, "1 hour"), path: file))
        #expect(ConditionEvaluator.evaluate(makeCondition(.dateAdded, .withinLast, "2 hours"), path: file))
        #expect(ConditionEvaluator.evaluate(makeCondition(.dateAdded, .withinLast, "1 day"), path: file))
        #expect(!ConditionEvaluator.evaluate(makeCondition(.dateAdded, .olderThan, "1 day"), path: file))
        #expect(!ConditionEvaluator.evaluate(makeCondition(.dateAdded, .olderThan, "hours"), path: file))
        #expect(!ConditionEvaluator.evaluate(makeCondition(.dateAdded, .olderThan, "1 invalid"), path: file))
        #expect(!ConditionEvaluator.evaluate(makeCondition(.dateAdded, .olderThan, "1 hours"), path: dir.path + "/missing.txt"))
    }

    private func setTimestamp(_ kind: ConditionKind, path: String, age: TimeInterval) throws {
        let date = Date().addingTimeInterval(-age)
        if kind == .dateAdded {
            var attributes = attrlist()
            attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
            attributes.commonattr = attrgroup_t(ATTR_CMN_ADDEDTIME)
            var timestamp = timespec(tv_sec: Int(date.timeIntervalSince1970), tv_nsec: 0)
            let result = setattrlist(path, &attributes, &timestamp, MemoryLayout<timespec>.size, 0)
            try #require(result == 0, "Could not set Date Added: errno \(errno)")
        } else {
            try FileManager.default.setAttributes(
                [kind == .createdAt ? .creationDate : .modificationDate: date], ofItemAtPath: path
            )
        }
    }
}
