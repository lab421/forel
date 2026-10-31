// Forel - A native macOS file-automation app
// Copyright (C) 2026 Lab421

import Foundation
import Testing
@testable import ForelCore

@Suite struct HazelDuplicateTests {
    private struct Platform: ActionPlatform {
        let trashDirectory: String
        func open(path: String, application: String?, passFile: Bool, bringToFront: Bool) throws {}
        func showInFinder(path: String, bringToFront: Bool) throws {}
        func notify(text: String, sound: Bool) throws {}
        func pause(seconds: TimeInterval) throws {}
        func trash(path: String) throws -> String {
            let target = (trashDirectory as NSString).appendingPathComponent((path as NSString).lastPathComponent)
            try FileManager.default.moveItem(atPath: path, toPath: target)
            return target
        }
    }
    @Test func realHazelDuplicateOptionDistinguishesContentsAndStopsAfterTrash() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["FOREL_HAZEL_CORPUS"], testTrashDirectory() != nil else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("Downloads.hazelrules"))
        let source = TempDir()
        let destination = TempDir()
        let trash = TempDir()
        let platform = Platform(trashDirectory: trash.path)
        let folder = WatchedFolder(path: source.path)
        let db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        let imported = try RuleTransfer.importRules(from: data, folderId: folder.id)
        var rule = try #require(imported.rules.first { $0.name == "Downloaded Documents to Dropbox" })
        #expect(rule.importError == nil)
        #expect(rule.actions.first?.params[ActionParam.discardDuplicates]?.boolValue == true)
        rule.enabled = true
        rule.actions[0].params = .object([ActionParam.destination: .string(destination.path), ActionParam.discardDuplicates: .bool(true)])
        rule.actions.append(makeAction(.addTag, .object([ActionParam.tags: .stringArray(["must-not-run"])]), position: 1, ruleId: rule.id))
        let prefix = UUID().uuidString
        let preview = source.file("\(prefix)-preview.pdf", contents: "identical")
        let manual = source.file("\(prefix)-manual.pdf", contents: "identical")
        let watched = source.file("\(prefix)-watcher.pdf", contents: "identical")
        for path in [preview, manual, watched] { _ = destination.file((path as NSString).lastPathComponent, contents: "identical") }
        let previewResult = try #require(RuleEngine.previewFile(path: preview, depth: 0, rules: [rule]))
        #expect(previewResult.rules.first?.actions.count == 1)
        #expect(previewResult.rules.first?.actions.first?.description.contains("identical file to Trash") == true)
        #expect(FileManager.default.fileExists(atPath: preview))
        let run = RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "duplicate", platform: platform)
        let entry = try #require(run.history.first)
        #expect(run.history.count == 1)
        #expect(entry.status == .applied)
        #expect(!FileManager.default.fileExists(atPath: manual))
        #expect(FileManager.default.fileExists(atPath: entry.resultPath))
        #expect(FinderTags.read(entry.resultPath).isEmpty)
        #expect(try String(contentsOfFile: (destination.path as NSString).appendingPathComponent((manual as NSString).lastPathComponent), encoding: .utf8) == "identical")
        try ActionExecutor.revert(Undo.fromJSON(entry.undo))
        #expect(FileManager.default.fileExists(atPath: manual))
        try db.insertRule(rule)
        WatcherCoordinator(db: db, actionPlatform: platform).handle(path: watched)
        #expect(try db.listHistory().map(\.status) == [.applied])
        #expect(!FileManager.default.fileExists(atPath: watched))

        let different = source.file("different.pdf", contents: "new")
        _ = destination.file("different.pdf", contents: "old")
        let differentRun = RuleEngine.run(path: different, depth: 0, rules: [rule], batchId: "different")
        #expect(differentRun.history.first?.status == .applied)
        #expect(try String(contentsOfFile: (destination.path as NSString).appendingPathComponent("different.pdf"), encoding: .utf8) == "old")
        #expect(try String(contentsOfFile: (destination.path as NSString).appendingPathComponent("different (1).pdf"), encoding: .utf8) == "new")
        let otherName = source.file("other.pdf", contents: "same")
        _ = destination.file("unrelated.pdf", contents: "same")
        #expect(RuleEngine.run(path: otherName, depth: 0, rules: [rule], batchId: "other-name").history.first?.status == .applied)
        #expect(FileManager.default.fileExists(atPath: (destination.path as NSString).appendingPathComponent("other.pdf")))
    }

    @Test func duplicateComparisonBlocksUnsafeOrOversizedCases() throws {
        let source = TempDir()
        let destination = TempDir()
        let action = makeAction(.moveToFolder, .object([ActionParam.destination: .string(destination.path), ActionParam.discardDuplicates: .bool(true)]))
        let folder = source.dir("archive.pdf")
        _ = destination.dir("archive.pdf")
        #expect(try ActionExecutor.plan(action, path: folder).status == .blocked)
        #expect(throws: ActionError.self) { try ActionExecutor.execute(action, path: folder) }
        let large = source.file("large.pdf")
        let largeTarget = destination.file("large.pdf")
        for path in [large, largeTarget] {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            try handle.truncate(atOffset: 100 * 1024 * 1024 + 1)
            try handle.close()
        }
        #expect(try ActionExecutor.plan(action, path: large).status == .blocked)
        #expect(throws: ActionError.self) { try ActionExecutor.execute(action, path: large) }
        #expect(FileManager.default.fileExists(atPath: large))
        let linkSource = source.file("link.pdf", contents: "source")
        let linkTarget = destination.file("target.pdf", contents: "source")
        try FileManager.default.createSymbolicLink(atPath: (destination.path as NSString).appendingPathComponent("link.pdf"), withDestinationPath: linkTarget)
        #expect(try ActionExecutor.plan(action, path: linkSource).status == .blocked)
        #expect(throws: ActionError.self) { try ActionExecutor.execute(action, path: linkSource) }
        #expect(FileManager.default.fileExists(atPath: linkSource))
        #expect(try String(contentsOfFile: linkTarget, encoding: .utf8) == "source")
        let same = makeAction(.moveToFolder, .object([ActionParam.destination: .string(source.path), ActionParam.discardDuplicates: .bool(true)]))
        #expect(throws: ActionError.self) { try ActionExecutor.execute(same, path: large) }
    }
}
