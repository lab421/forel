// Forel - A native macOS file-automation app
// Copyright (C) 2026 Lab421

import Foundation
import Darwin
import Testing
@testable import ForelCore

@Suite struct HazelCalendarMonthTests {
    @Test func hazelWeeksUseFixedSecondsAcrossDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 12, minute: 0)))
        let fixed = try #require(ConditionEvaluator.hazelCutoffDate("35 week", now: now, calendar: calendar))
        let calendarCutoff = try #require(calendar.date(byAdding: .weekOfYear, value: -35, to: now))
        #expect(calendarCutoff.timeIntervalSince(fixed) == 3600)
        let directory = TempDir()
        let file = directory.file("date.txt")
        let condition = makeCondition(.dateModified, .hazelWithinLast, "35 week")
        for (offset, expected) in [(-60.0, false), (60.0, true)] {
            try FileManager.default.setAttributes([.modificationDate: fixed.addingTimeInterval(offset)], ofItemAtPath: file)
            #expect(ConditionEvaluator.evaluate(condition, path: file, now: now) == expected)
        }
        let month = try #require(ConditionEvaluator.hazelCutoffDate("2 month", now: now, calendar: calendar))
        #expect(month == calendar.date(byAdding: .month, value: -2, to: now))
    }
    @Test func relativeDatesDistinguishFutureAndInvalidValues() throws {
        let directory = TempDir()
        let file = directory.file("item.txt")
        let within = makeCondition(.dateModified, .hazelWithinLast, "2 months")
        let outside = makeCondition(.dateModified, .hazelNotWithinLast, "2 months")
        let cutoff = try #require(Calendar.current.date(byAdding: .month, value: -2, to: Date()))
        for (date, matches) in [(cutoff.addingTimeInterval(-300), false), (cutoff.addingTimeInterval(300), true), (Date().addingTimeInterval(600), false)] {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file)
            #expect(ConditionEvaluator.evaluate(within, path: file) == matches)
            #expect(ConditionEvaluator.evaluate(outside, path: file) != matches)
        }
        #expect(!ConditionEvaluator.evaluate(makeCondition(.dateModified, .hazelNotWithinLast, "bad"), path: file))
    }

    @Test func publicMonthRulesRunAcrossExecutionPaths() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["FOREL_HAZEL_TUX"], testTrashDirectory() != nil else { return }
        for export in ["iCloudDownloads-old.hazelrules", "iCloudDownloads.hazelrules"] {
            let dir = TempDir()
            let destination = TempDir()
            let folder = WatchedFolder(path: dir.path)
            let db = try Database(path: ":memory:")
            try db.insertFolder(folder)
            let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(export))
            let imported = try RuleTransfer.importRules(from: data, folderId: folder.id)
            var rule = try #require(imported.rules.first)
            #expect(rule.importError == nil, "\(export): \(rule.importError ?? "")")
            #expect(rule.conditions.contains {
                guard $0.kind == .conditionGroup, let group = ConditionGroup.decode($0.value) else { return false }
                return group.match == .none && group.target == .current && group.conditions.count == 1 &&
                    group.conditions[0].kind == .dateAdded && group.conditions[0].operator == .hazelWithinLast && group.conditions[0].value == "2 month"
            })
            rule.enabled = true
            if rule.actions.first?.kind == .moveToFolder {
                rule.actions[0].params = .object([ActionParam.destination: .string(destination.path)])
            }
            func fixture(_ name: String, date: Date) -> String {
                let file = dir.file("\(UUID().uuidString)-\(name).txt")
                var attrs = attrlist()
                attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
                attrs.commonattr = UInt32(ATTR_CMN_ADDEDTIME)
                var timestamp = timespec(tv_sec: Int(date.timeIntervalSince1970), tv_nsec: 0)
                #expect(withUnsafeMutablePointer(to: &timestamp) { setattrlist(file, &attrs, $0, MemoryLayout<timespec>.size, 0) } == 0)
                return file
            }
            let old = Date().addingTimeInterval(-100 * 86400)
            let preview = fixture("preview", date: old)
            let manual = fixture("manual", date: old)
            let watched = fixture("watcher", date: old)
            let recent = fixture("recent", date: Date().addingTimeInterval(-86400))
            let future = fixture("future", date: Date().addingTimeInterval(3600))
            #expect(RuleEngine.previewFile(path: preview, depth: 0, rules: [rule])?.rules.first?.actions.first?.status == .wouldRun, "\(export)")
            #expect(RuleEngine.previewFile(path: recent, depth: 0, rules: [rule]) == nil, "\(export)")
            #expect(RuleEngine.previewFile(path: future, depth: 0, rules: [rule])?.rules.first?.actions.first?.status == .wouldRun, "\(export)")
            #expect(RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "calendar").history.first?.status == .applied, "\(export)")
            try db.insertRule(rule)
            let watcher = WatcherCoordinator(db: db)
            watcher.handle(path: watched)
            watcher.handle(path: recent)
            #expect(try db.listHistory().map(\.status) == [.applied], "\(export)")
            #expect(!FileManager.default.fileExists(atPath: manual))
            #expect(!FileManager.default.fileExists(atPath: watched))
            #expect(FileManager.default.fileExists(atPath: recent))
        }
    }
}
