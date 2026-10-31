// Forel - A native macOS file-automation app
// Copyright (C) 2026 Lab421

import Foundation
import Testing
import Darwin
@testable import ForelCore

@Suite struct HazelAdditionalPublicRulesTests {
    @Test func publicGermanScreenshotRuleRunsAcrossExecutionPaths() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_TUXPEOPLE"] else { return }
        let file = URL(fileURLWithPath: root).appendingPathComponent("files/Hazel/hazelrules/Desktop.hazelrules")
        let source = TempDir()
        let destination = TempDir()
        let folder = WatchedFolder(path: source.path)
        let db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        let imported = try RuleTransfer.importRules(from: Data(contentsOf: file), folderId: folder.id)
        var rule = try #require(imported.rules.first { $0.name == "Screenshots aufräumen" })
        #expect(rule.importError == nil)
        #expect(rule.actions.map(\.kind) == [.moveToFolder])
        rule.enabled = true
        rule.actions[0].params = .object([ActionParam.destination: .string(destination.path)])
        let preview = source.file("bildschirmfoto-preview.PNG")
        let manual = source.file("BILDSCHIRMFOTO-manual.png")
        let watched = source.file("Bildschirmfoto-watched.png")
        let nonmatch = source.file("other.png")
        for path in [preview, manual, watched, nonmatch] {
            var attributes = attrlist()
            attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
            attributes.commonattr = UInt32(ATTR_CMN_ADDEDTIME)
            var added = timespec(tv_sec: Int(Date().addingTimeInterval(-7 * 86400).timeIntervalSince1970), tv_nsec: 0)
            #expect(withUnsafeMutablePointer(to: &added) { setattrlist(path, &attributes, $0, MemoryLayout<timespec>.size, 0) } == 0)
        }
        #expect(RuleEngine.previewFile(path: preview, depth: 0, rules: [rule])?.rules.first?.actions.first?.status == .wouldRun)
        #expect(RuleEngine.previewFile(path: nonmatch, depth: 0, rules: [rule]) == nil)
        #expect(RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "public-screenshot").history.first?.status == .applied)
        try db.insertRule(rule)
        WatcherCoordinator(db: db).handle(path: watched)
        #expect(try db.listHistory().first?.status == .applied)
        #expect(FileManager.default.fileExists(atPath: (destination.path as NSString).appendingPathComponent("BILDSCHIRMFOTO-manual.png")))
        #expect(FileManager.default.fileExists(atPath: (destination.path as NSString).appendingPathComponent("Bildschirmfoto-watched.png")))
    }

    @Test func otherSupportedPublicRulesRunAcrossExecutionPaths() throws {
        let env = ProcessInfo.processInfo.environment
        guard let root = env["FOREL_HAZEL_TUXPEOPLE"], testTrashDirectory() != nil else { return }
        let directory = URL(fileURLWithPath: root).appendingPathComponent("files/Hazel/hazelrules")
        var tested = 0
        for export in ["Desktop.hazelrules", "Downloads-old.hazelrules", "Downloads.hazelrules"] {
            let source = TempDir()
            let destination = TempDir()
            let folder = WatchedFolder(path: source.path)
            let db = try Database(path: ":memory:")
            try db.insertFolder(folder)
            let imported = try RuleTransfer.importRules(from: Data(contentsOf: directory.appendingPathComponent(export)), folderId: folder.id)
            for original in imported.rules where original.name != "Screenshots aufräumen" && original.importError == nil {
                var rule = original
                rule.enabled = true
                if rule.actions.first?.kind == .moveToFolder {
                    rule.actions[0].params = .object([ActionParam.destination: .string(destination.path)])
                }
                let id = UUID().uuidString
                let preview = source.file("\(id)-preview.txt")
                let manual = source.file("\(id)-manual.txt")
                let watched = source.file("\(id)-watched.txt")
                for path in [preview, manual, watched] {
                    var attributes = attrlist()
                    attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
                    attributes.commonattr = UInt32(ATTR_CMN_ADDEDTIME)
                    var added = timespec(tv_sec: Int(Date().addingTimeInterval(-500 * 86400).timeIntervalSince1970), tv_nsec: 0)
                    #expect(withUnsafeMutablePointer(to: &added) { setattrlist(path, &attributes, $0, MemoryLayout<timespec>.size, 0) } == 0)
                }
                #expect(RuleEngine.previewFile(path: preview, depth: 0, rules: [rule])?.rules.first?.actions.first?.status == .wouldRun, "\(export): \(rule.name)")
                #expect(RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "public-old-files").history.first?.status == .applied, "\(export): \(rule.name)")
                try db.insertRule(rule)
                WatcherCoordinator(db: db).handle(path: watched)
                #expect(try db.listHistory().first?.status == .applied, "\(export): \(rule.name)")
                #expect(!FileManager.default.fileExists(atPath: manual))
                #expect(!FileManager.default.fileExists(atPath: watched))
                tested += 1
            }
        }
        #expect(tested == 3)
    }

    @Test func publiclySharedStartsWithConditionsMatchCaseAndAccents() throws {
        let env = ProcessInfo.processInfo.environment
        guard let root = env["FOREL_HAZEL_TUXPEOPLE"], let heic = env["FOREL_HAZEL_HEIC"] else { return }
        let files = [URL(fileURLWithPath: root).appendingPathComponent("files/Hazel/hazelrules/Desktop.hazelrules"),
                     URL(fileURLWithPath: heic).appendingPathComponent("Downloads-HEIC2jpg.hazelrules")]
        for file in files {
            let imported = try RuleTransfer.importRules(from: Data(contentsOf: file), folderId: "folder")
            let condition = try #require(imported.rules.flatMap(\.conditions).first { $0.kind == .nameInsensitive && $0.operator == .startsWith })
            let dir = TempDir()
            let positive = dir.file(condition.value.lowercased().replacingOccurrences(of: "i", with: "í") + "-test.txt")
            let negative = dir.file("other-" + condition.value + ".txt")
            #expect(ConditionEvaluator.evaluate(condition, path: positive))
            #expect(!ConditionEvaluator.evaluate(condition, path: negative))
        }
    }
    @Test func publiclySharedExportsImportDisabledAndIncompleteRulesAreBlocked() throws {
        let env = ProcessInfo.processInfo.environment
        guard let root = env["FOREL_HAZEL_TUXPEOPLE"], let heic = env["FOREL_HAZEL_HEIC"] else { return }
        let directory = URL(fileURLWithPath: root).appendingPathComponent("files/Hazel/hazelrules")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "hazelrules" } + [URL(fileURLWithPath: heic).appendingPathComponent("Downloads-HEIC2jpg.hazelrules")]
        #expect(files.count == 6)
        let temporary = TempDir()
        let path = temporary.file("sample.txt", contents: "sample")
        var total = 0
        for file in files {
            let result = try RuleTransfer.importRules(from: Data(contentsOf: file), folderId: "folder")
            for original in result.rules {
                total += 1
                #expect(!original.enabled)
                if original.importError != nil {
                    var rule = original
                    rule.enabled = true
                    let plan = try #require(RuleEngine.previewFile(path: path, depth: 0, rules: [rule]))
                    #expect(plan.rules.first?.actions.first?.status == .blocked)
                    let run = RuleEngine.run(path: path, depth: 0, rules: [rule], batchId: "public-import")
                    #expect(run.history.map(\.status) == [.failed])
                    #expect(FileManager.default.fileExists(atPath: path))
                }
            }
        }
        #expect(total == 7)
    }
}
