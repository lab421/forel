import Foundation
import Testing
@testable import ForelCore

@Suite struct NativeHazelModeValidationTests {
    @Test(arguments: [ActionKind.hazelContinue, .hazelRecurse])
    func selectableFlowActionsRequireHazelOrdering(kind: ActionKind) {
        #expect(RuleSchema.actionKinds.contains(kind))
        var rule = makeRule(name: "flow", actions: [makeAction(kind, .object([:]))])
        #expect(!rule.isHazelImported)
        #expect(!RuleValidator.validateExecutionMode(rule).isEmpty)
        rule.isHazelImported = true
        #expect(RuleValidator.validateExecutionMode(rule).isEmpty)
    }

    @Test func nativeRecurseWithoutHazelOrderingIsExplicitlyBlocked() throws {
        let root = TempDir()
        let folderPath = root.dir("folder")
        let child = (folderPath as NSString).appendingPathComponent("child.txt")
        try "keep".write(toFile: child, atomically: true, encoding: .utf8)
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: root.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "recurse", actions: [makeAction(.hazelRecurse, .object([:]))])
        rule.actions[0].ruleId = rule.id
        #expect(!rule.isHazelImported)
        #expect(!RuleValidator.validateExecutionMode(rule).isEmpty)
        let preview = try #require(RuleEngine.previewFile(path: folderPath, depth: 0, rules: [rule]))
        #expect(preview.rules.first?.actions.first?.status == .blocked)
        let run = RuleEngine.run(path: folderPath, depth: 0, rules: [rule], batchId: "native")
        #expect(run.history.first?.status == .failed)
        try db.insertRule(rule)
        WatcherCoordinator(db: db).handle(path: folderPath)
        #expect(try db.listHistory().first?.status == .failed)
        #expect(FileManager.default.fileExists(atPath: child))
        rule.isHazelImported = true
        #expect(RuleValidator.validateExecutionMode(rule).isEmpty)
    }
}
