// Forel - A native macOS file-automation app
// Copyright (C) 2026 Lab421

import Foundation
import Testing
@testable import ForelCore

@Suite struct HazelDepthConditionTests {
    @Test func unzipExportImportsDepthEquality() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_UNZIP"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("download.hazelrules"))
        let result = try RuleTransfer.importRules(from: data, folderId: "f")
        let mount = try #require(result.rules.first { $0.name == "Mount" })
        let depth = try #require(mount.conditions.first { $0.kind == .subfolderDepth })
        #expect(depth.operator == .is && depth.value == "0")
        #expect(mount.importError == nil, "\(mount.importError ?? "")")
        let dir = TempDir()
        let file = dir.file("archive.dmg")
        #expect(ConditionEvaluator.evaluate(depth, path: file, depth: 0))
        #expect(!ConditionEvaluator.evaluate(depth, path: file, depth: 1))
        let archiveRule = try #require(result.rules.first { $0.name == "unZip(7z)" })
        #expect(archiveRule.conditions.contains { $0.kind == .contentType && $0.value == "hazelkind:7-Zip Archive" })
        #expect(archiveRule.conditions.contains { $0.kind == .contentType && $0.value == "hazelkind:RAR Archive" })
    }
    @Test func depthOperatorsAndValidation() {
        let dir = TempDir()
        let path = dir.file("item.txt")
        for (op, value, expected) in [(Operator.is, "1", true), (.isNot, "2", true), (.greaterThan, "0", true), (.lessThan, "2", true), (.lessThan, "1", false)] {
            #expect(ConditionEvaluator.evaluate(makeCondition(.subfolderDepth, op, value), path: path, depth: 1) == expected)
        }
        let condition = makeCondition(.subfolderDepth, .lessThan, "2")
        #expect(!ConditionEvaluator.evaluate(condition, path: path))
        #expect(!ConditionEvaluator.evaluate(condition, path: path, depth: -1))
        #expect(!RuleValidator.validate([makeCondition(.subfolderDepth, .is, "-1")]).isEmpty)
        #expect(!RuleValidator.validate([makeCondition(.subfolderDepth, .is, "2.5")]).isEmpty)
        #expect(RuleValidator.validate([condition]).isEmpty)
    }

    @Test func realTicklerDepthConditionRunsAcrossPaths() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_TICKLER"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("tickler.hazelrules"))
        let imported = try RuleTransfer.importRules(from: data, folderId: "folder")
        let original = try #require(imported.rules.first { $0.name == "Scan folders for files to bring forward" })
        let condition = try #require(original.conditions.first { $0.kind == .subfolderDepth })
        #expect(condition.operator == .lessThan)
        #expect(condition.value == "2")

        let dir = TempDir()
        _ = dir.dir("first/second")
        let folder = WatchedFolder(path: dir.path)
        let db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "depth", recursionDepth: nil)
        rule.conditions = [makeCondition(.subfolderDepth, condition.operator, condition.value, ruleId: rule.id)]
        rule.actions = [makeAction(.addTag, .object([ActionParam.tags: .stringArray(["depth-test"])]), ruleId: rule.id)]
        let preview = dir.file("first/preview.txt")
        let manual = dir.file("first/manual.txt")
        let watched = dir.file("first/watcher.txt")
        let tooDeep = dir.file("first/second/deep.txt")
        #expect(RuleEngine.previewFile(path: preview, depth: 1, rules: [rule])?.rules.first?.actions.first?.status == .wouldRun)
        #expect(RuleEngine.previewFile(path: tooDeep, depth: 2, rules: [rule]) == nil)
        #expect(RuleEngine.run(path: manual, depth: 1, rules: [rule], batchId: "depth").history.first?.status == .applied)
        #expect(FinderTags.read(manual).contains("depth-test"))
        #expect(RuleEngine.run(path: tooDeep, depth: 2, rules: [rule], batchId: "deep").history.isEmpty)
        try db.insertRule(rule)
        let watcher = WatcherCoordinator(db: db)
        watcher.handle(path: watched)
        watcher.handle(path: tooDeep)
        #expect(FinderTags.read(watched).contains("depth-test"))
        #expect(FinderTags.read(tooDeep).isEmpty)
        #expect(try db.listHistory().count == 1)
    }
}
