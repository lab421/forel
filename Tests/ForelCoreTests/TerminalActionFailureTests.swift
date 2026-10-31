import Foundation
import Testing
@testable import ForelCore

@Suite struct TerminalActionFailureTests {
    private struct Platform: ActionPlatform {
        func open(path: String, application: String?, passFile: Bool, bringToFront: Bool) throws {}
        func showInFinder(path: String, bringToFront: Bool) throws {}
        func notify(text: String, sound: Bool) throws {}
        func pause(seconds: TimeInterval) throws {}
        func trash(path: String) throws -> String { throw ActionError("Injected Trash failure") }
    }

    @Test func failedTrashNeverFallsThroughToDelete() throws {
        let dir = TempDir()
        let manual = dir.file("manual.txt"), watched = dir.file("watched.txt")
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "fail trash")
        rule.actions = [makeAction(.moveToTrash, .object([:]), position: 0, ruleId: rule.id), makeAction(.delete, .object([:]), position: 1, ruleId: rule.id)]
        let preview = try #require(RuleEngine.previewFile(path: manual, depth: 0, rules: [rule]))
        #expect(preview.rules[0].actions.map(\.kind) == [.moveToTrash])
        let run = RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "manual", platform: Platform())
        #expect(run.history.map(\.status) == [.failed])
        #expect(FileManager.default.fileExists(atPath: manual))
        try db.insertRule(rule)
        WatcherCoordinator(db: db, actionPlatform: Platform()).handle(path: watched)
        #expect(try db.listHistory().map(\.status) == [.failed])
        #expect(FileManager.default.fileExists(atPath: watched))
    }

    @Test func failedMoveNeverRunsLaterScript() throws {
        let dir = TempDir()
        let manual = dir.dir("manual"), watched = dir.dir("watched")
        let marker = (dir.path as NSString).appendingPathComponent("script-ran")
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        func rule(for source: String) -> Rule {
            var rule = makeRule(folderId: folder.id, name: "fail move")
            rule.actions = [makeAction(.moveToFolder, .object([ActionParam.destination: .string((source as NSString).appendingPathComponent("inside"))]), position: 0, ruleId: rule.id), makeAction(.runScript, .object([ActionParam.script: .string("touch '\(marker)'")]), position: 1, ruleId: rule.id)]
            return rule
        }
        let manualRule = rule(for: manual)
        let preview = try #require(RuleEngine.previewFile(path: manual, depth: 0, rules: [manualRule]))
        #expect(preview.rules[0].actions.count == 1)
        #expect(preview.rules[0].actions[0].status == .blocked)
        #expect(RuleEngine.run(path: manual, depth: 0, rules: [manualRule], batchId: "manual").history.first?.status == .failed)
        let watchedRule = rule(for: watched)
        try db.insertRule(watchedRule)
        WatcherCoordinator(db: db).handle(path: watched)
        #expect(try db.listHistory().map(\.status) == [.failed])
        #expect(!FileManager.default.fileExists(atPath: marker))
        #expect(FileManager.default.fileExists(atPath: manual) && FileManager.default.fileExists(atPath: watched))
    }
}
