import Foundation
import Darwin
import Testing
@testable import ForelCore

@Suite struct HazelConditionGroupTests {
    private func leaf(_ kind: ConditionKind, _ op: Operator, _ value: String) -> Condition {
        Condition(ruleId: "r", kind: kind, operator: op, value: value)
    }
    private func group(_ mode: ConditionGroup.Match, _ target: ConditionGroup.Target = .current, _ children: [Condition]) -> Condition {
        leaf(.conditionGroup, .is, ConditionGroup(match: mode, target: target, conditions: children).encoded)
    }

    @Test func nestedGroupsRoundTripAndRunAcrossPaths() throws {
        let source = TempDir(), destination = TempDir()
        let folder = WatchedFolder(path: source.path)
        let db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        let nested = group(.all, .current, [
            group(.any, .current, [leaf(.fullNameInsensitive, .contains, "CAFÉ"), leaf(.fullName, .contains, "invoice")]),
            group(.none, .current, [leaf(.fullNameInsensitive, .contains, "draft")])
        ])
        var rule = makeRule(folderId: folder.id, name: "nested")
        var linked = nested; linked.ruleId = rule.id
        rule.conditions = [linked]
        var move = makeAction(.moveToFolder, .object([ActionParam.destination: .string(destination.path)])); move.ruleId = rule.id
        rule.actions = [move]
        try db.insertRule(rule)
        let persisted = try #require(db.listRules(folderId: folder.id).first)
        #expect(persisted.conditions.first?.value == nested.value)
        let exported = try RuleTransfer.exportForel([persisted])
        let restored = try #require(RuleTransfer.importRules(from: exported, folderId: folder.id).rules.first)
        let again = try #require(RuleTransfer.importRules(from: exported, folderId: folder.id).rules.first)
        let originalGroup = try #require(ConditionGroup.decode(nested.value))
        let restoredCondition = try #require(restored.conditions.first)
        let againCondition = try #require(again.conditions.first)
        let restoredGroup = try #require(ConditionGroup.decode(restoredCondition.value))
        let againGroup = try #require(ConditionGroup.decode(againCondition.value))
        #expect(restoredGroup.match == originalGroup.match && restoredGroup.target == originalGroup.target)
        #expect(restoredGroup.conditions.map(\.kind) == originalGroup.conditions.map(\.kind))
        #expect(restoredGroup.conditions.map(\.id) != originalGroup.conditions.map(\.id))
        #expect(restoredGroup.conditions.map(\.id) != againGroup.conditions.map(\.id))
        #expect(restoredGroup.conditions.allSatisfy { $0.ruleId == restored.id })
        let originalNested = try #require(ConditionGroup.decode(originalGroup.conditions[0].value))
        let restoredNested = try #require(ConditionGroup.decode(restoredGroup.conditions[0].value))
        #expect(restoredNested.conditions.map(\.value) == originalNested.conditions.map(\.value))
        #expect(restoredNested.conditions.map(\.id) != originalNested.conditions.map(\.id))
        #expect(restoredNested.conditions.allSatisfy { $0.ruleId == restored.id })
        let preview = source.file("cafe\u{301}-preview.pdf")
        let manual = source.file("cafe\u{301}-manual.pdf")
        let watched = source.file("cafe\u{301}-watcher.pdf")
        let excluded = source.file("cafe\u{301}-draft.pdf")
        #expect(RuleEngine.previewFile(path: preview, depth: 0, rules: [persisted]) != nil)
        #expect(RuleEngine.previewFile(path: excluded, depth: 0, rules: [persisted]) == nil)
        #expect(RuleEngine.run(path: manual, depth: 0, rules: [persisted], batchId: "groups").history.first?.status == .applied)
        WatcherCoordinator(db: db).handle(path: watched)
        #expect(FileManager.default.fileExists(atPath: "\(destination.path)/cafe\u{301}-manual.pdf"))
        #expect(FileManager.default.fileExists(atPath: "\(destination.path)/cafe\u{301}-watcher.pdf"))
        #expect(FileManager.default.fileExists(atPath: excluded))
    }

    @Test func relatedTargetsAndHiddenChildCount() throws {
        let parent = TempDir()
        let subfolder = "\(parent.path)/Photos"
        try FileManager.default.createDirectory(atPath: subfolder, withIntermediateDirectories: true)
        let child = "\(subfolder)/picture.jpg"
        try Data().write(to: URL(fileURLWithPath: child))
        try Data().write(to: URL(fileURLWithPath: "\(subfolder)/.DS_Store"))
        #expect(ConditionEvaluator.evaluate(leaf(.subfileCount, .is, "1"), path: subfolder))
        #expect(ConditionEvaluator.evaluate(leaf(.subfileCount, .is, "0"), path: child))
        #expect(ConditionEvaluator.evaluate(group(.all, .parent, [leaf(.fullName, .is, "Photos")]), path: child))
        #expect(ConditionEvaluator.evaluate(group(.all, .anyChild, [leaf(.extension_, .is, "jpg")]), path: subfolder))
        #expect(!ConditionEvaluator.evaluate(group(.all, .anyChild, [leaf(.extension_, .is, "jpg")]), path: child))
        let empty = "\(parent.path)/empty"
        try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: false)
        #expect(!ConditionEvaluator.evaluate(group(.all, .allChildren, [leaf(.extension_, .is, "jpg")]), path: empty))
    }

    @Test func finderLockAndBlankCommentConditions() throws {
        let dir = TempDir()
        let path = dir.file("sample.txt")
        #expect(ConditionEvaluator.evaluate(leaf(.locked, .is, "false"), path: path))
        #expect(chflags(path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(path, 0) }
        #expect(ConditionEvaluator.evaluate(leaf(.locked, .is, "true"), path: path))
        #expect(ConditionEvaluator.evaluate(leaf(.finderComment, .isBlank, ""), path: path))
    }

    @Test func anyFileRequiresAnExistingItem() {
        let dir = TempDir()
        let file = dir.file("item.txt")
        let condition = leaf(.anyFile, .is, "")
        #expect(ConditionEvaluator.evaluate(condition, path: file))
        #expect(ConditionEvaluator.evaluate(condition, path: dir.path))
        #expect(!ConditionEvaluator.evaluate(condition, path: "\(dir.path)/missing"))
        #expect(RuleValidator.validate([condition]).isEmpty)
    }

    @Test func customHazelKindsUseExactLocalizedDescription() {
        #expect(ConditionEvaluator.matchHazelKind("7-Zip Archive", actual: "7-Zip Archive", operator: .is) == true)
        #expect(ConditionEvaluator.matchHazelKind("7-zip archive", actual: "7-Zip Archive", operator: .is) == false)
        #expect(ConditionEvaluator.matchHazelKind("RAR Archive", actual: "Document", operator: .is) == false)
        #expect(ConditionEvaluator.matchHazelKind("RAR Archive", actual: nil, operator: .isNot) == nil)
    }

    @Test func contentBlankAndRecognitionOptionsFailClosed() throws {
        let dir = TempDir()
        let blank = dir.file("blank.txt"), text = dir.file("text.txt", contents: "hello")
        let unknown = "\(dir.path)/opaque.bin"
        try Data([0, 0xff]).write(to: URL(fileURLWithPath: unknown))
        #expect(ConditionEvaluator.evaluate(leaf(.contents, .isBlank, ""), path: blank))
        #expect(ConditionEvaluator.evaluate(leaf(.contentsWithoutOCR, .isNotBlank, ""), path: text))
        #expect(!ConditionEvaluator.evaluate(leaf(.contents, .isBlank, ""), path: unknown))
        #expect(!ConditionEvaluator.evaluate(leaf(.contents, .isNotBlank, ""), path: unknown))
        let png = "\(dir.path)/one.png"
        let image = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/qGkAAAAASUVORK5CYII="))
        try image.write(to: URL(fileURLWithPath: png))
        let extraction = ContentExtractor.extract(path: png, useOCR: false)
        #expect(extraction.text == "" && extraction.strategy == .imageWithoutOCR)
        #expect(ConditionEvaluator.evaluate(leaf(.contentsWithoutOCR, .isBlank, ""), path: png))
    }

    @Test func currentTimeUsesLocalCalendarMinute() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 5 * 3600 + 30 * 60))
        let date = try #require(calendar.date(from: DateComponents(year: 2025, month: 6, day: 1, hour: 9, minute: 5, second: 59)))
        #expect(CurrentTimeCondition.matches("09:05", now: date, calendar: calendar))
        #expect(!CurrentTimeCondition.matches("09:06", now: date, calendar: calendar))
        #expect(CurrentTimeCondition.components("24:00") == nil)
        #expect(CurrentTimeCondition.components("9:05") == nil)
        #expect(CurrentTimeCondition.components("０９:05") == nil)
        var schedule = CurrentTimeCondition.Schedule(time: "09:05", weekdays: "1, 3", monthdays: "1,15", months: "6")
        #expect(CurrentTimeCondition.isValid(schedule.encoded))
        #expect(CurrentTimeCondition.matches(schedule.encoded, now: date, calendar: calendar))
        schedule.weekdays = "2"
        #expect(!CurrentTimeCondition.matches(schedule.encoded, now: date, calendar: calendar))
        schedule.weekdays = "8"
        #expect(!CurrentTimeCondition.isValid(schedule.encoded))
    }

    @Test func ticklerDailyTimesImportAsScheduledConditions() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_TICKLER"] else { return }
        let url = URL(fileURLWithPath: root).appendingPathComponent("tickler.hazelrules")
        let imported = try RuleTransfer.importRules(from: Data(contentsOf: url), folderId: "f")
        let group = try #require(imported.rules.flatMap(\.conditions).compactMap { condition in
            condition.kind == .conditionGroup ? ConditionGroup.decode(condition.value) : nil
        }.first { $0.conditions.contains { $0.kind == .currentTime } })
        #expect(group.match == .any && group.target == .current)
        #expect(group.conditions.map(\.value) == (0..<24).map { String(format: "%02d:00", $0) })
        #expect(imported.rules.first { $0.name == "Move files" }?.importError == nil)
    }

    @Test func unreadableContentUnderNotCannotRunDestructiveAction() throws {
        let source = TempDir()
        let file = "\(source.path)/opaque.bin"
        try Data([0, 0xff, 0, 0xfe]).write(to: URL(fileURLWithPath: file))
        var rule = makeRule(folderId: "f", name: "must not delete")
        rule.conditions = [group(.none, .current, [leaf(.contents, .contains, "confidential")])]
        rule.actions = [makeAction(.delete, .object([:]))]
        #expect(RuleEngine.previewFile(path: file, depth: 0, rules: [rule]) == nil)
        #expect(RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "not").history.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file))
    }

    @Test func topLevelNoneRoundTripsAndFailsClosedOnUnknown() throws {
        let dir = TempDir()
        let folder = WatchedFolder(path: dir.path)
        let db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "none", conditionMatch: .none)
        rule.conditions = [Condition(ruleId: rule.id, kind: .contents, operator: .contains, value: "secret")]
        rule.actions = [Action(ruleId: rule.id, kind: .delete, params: .object([:]), position: 0)]
        try db.insertRule(rule)
        let saved = try #require(db.listRules(folderId: folder.id).first)
        #expect(saved.conditionMatch == .none)
        let restored = try #require(RuleTransfer.importRules(from: RuleTransfer.exportForel([saved]), folderId: folder.id).rules.first)
        #expect(restored.conditionMatch == .none)
        let unreadable = "\(dir.path)/binary.bin"
        try Data([0, 0xff]).write(to: URL(fileURLWithPath: unreadable))
        #expect(RuleEngine.previewFile(path: unreadable, depth: 0, rules: [saved]) == nil)
        #expect(RuleEngine.run(path: unreadable, depth: 0, rules: [saved], batchId: "none").history.isEmpty)
        #expect(FileManager.default.fileExists(atPath: unreadable))
        let readable = dir.file("readable.txt", contents: "ordinary")
        #expect(RuleEngine.previewFile(path: readable, depth: 0, rules: [saved])?.rules.first?.actions.first?.status == .wouldRun)
    }

    @Test func unknownValuesUseThreeValuedLogicAndRelatedDepths() throws {
        let dir = TempDir()
        let folder = dir.dir("folder")
        let file = "\(folder)/opaque.bin"
        try Data([0, 0xff]).write(to: URL(fileURLWithPath: file))
        let unknown = leaf(.contents, .contains, "text")
        let yes = leaf(.fullName, .is, "opaque.bin")
        let no = leaf(.fullName, .is, "other.bin")
        #expect(ConditionEvaluator.evaluate(group(.any, .current, [unknown, yes]), path: file, depth: 1))
        #expect(!ConditionEvaluator.evaluate(group(.none, .current, [unknown, yes]), path: file, depth: 1))
        let notAll = group(.none, .current, [group(.all, .current, [unknown, no])])
        #expect(ConditionEvaluator.evaluate(notAll, path: file, depth: 1))
        #expect(!ConditionEvaluator.evaluate(group(.none, .current, [unknown]), path: file, depth: 1))
        #expect(ConditionEvaluator.evaluate(group(.all, .parent, [leaf(.subfolderDepth, .is, "0")]), path: file, depth: 1))
        #expect(ConditionEvaluator.evaluate(group(.all, .anyChild, [leaf(.subfolderDepth, .is, "1")]), path: folder, depth: 0))
        #expect(!ConditionEvaluator.evaluate(group(.none, .parent, [leaf(.subfolderDepth, .is, "0")]), path: file, depth: 0))
    }

    @Test func installerExportPreservesNegatedNestedCondition() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_INSTALLER"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("Applications.hazelrules"))
        let imported = try RuleTransfer.importRules(from: data, folderId: "f")
        let sourceRule = try #require(imported.rules.first)
        let nested = try #require(sourceRule.conditions.first { $0.kind == .conditionGroup })
        let parsed = try #require(ConditionGroup.decode(nested.value))
        #expect(parsed.match == .none && parsed.target == .current && parsed.conditions.count == 1)
        #expect(parsed.conditions[0].kind == .dateModified && parsed.conditions[0].operator == .hazelWithinLast && parsed.conditions[0].value == "5 minute")
        #expect(sourceRule.importError == nil, "\(sourceRule.importError ?? "")")
        let lastMatchedGroup = try #require(sourceRule.conditions.compactMap { condition in
            condition.kind == .conditionGroup ? ConditionGroup.decode(condition.value) : nil
        }.first { $0.conditions.contains { $0.kind == .dateLastMatched } })
        #expect(lastMatchedGroup.match == .any)
        #expect(lastMatchedGroup.conditions.map(\.operator) == [.isBlank, .beforeLastModified])
        // Exercise this predicate independently; the public external script is
        // retained but is not executed by the test.
        let dir = TempDir(), destination = TempDir()
        let folder = WatchedFolder(path: dir.path)
        let db = try Database(path: ":memory:"); try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "not recent")
        var linked = nested; linked.ruleId = rule.id; rule.conditions = [linked]
        var move = makeAction(.moveToFolder, .object([ActionParam.destination: .string(destination.path)])); move.ruleId = rule.id
        rule.actions = [move]
        try db.insertRule(rule)
        let old = Date().addingTimeInterval(-600)
        func fixture(_ name: String) throws -> String {
            let path = dir.file(name)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path)
            return path
        }
        let preview = try fixture("preview.txt"), manual = try fixture("manual.txt"), watched = try fixture("watched.txt")
        #expect(RuleEngine.previewFile(path: preview, depth: 0, rules: [rule]) != nil)
        #expect(RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "nested").history.first?.status == .applied)
        WatcherCoordinator(db: db).handle(path: watched)
        #expect(FileManager.default.fileExists(atPath: "\(destination.path)/manual.txt"))
        #expect(FileManager.default.fileExists(atPath: "\(destination.path)/watched.txt"))
    }
}
