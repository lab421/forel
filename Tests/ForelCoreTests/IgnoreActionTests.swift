import Foundation
import Testing
@testable import ForelCore

@Suite struct IgnoreActionTests {
    @Test(arguments: [false, true])
    func ignoreStopsCurrentAndLaterRulesInAllExecutionPaths(midChain: Bool) throws {
        let dir = TempDir()
        let manual = dir.file("manual.txt")
        let watched = dir.file("watched.txt")
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var first = makeRule(folderId: folder.id, name: "ignore")
        var actions: [Action] = []
        if midChain { actions.append(makeAction(.pause, .object([ActionParam.durationSeconds: .string("0")]), position: 0, ruleId: first.id)) }
        actions.append(makeAction(.ignore, .object([:]), position: Int64(actions.count), ruleId: first.id))
        if midChain { actions.append(makeAction(.delete, .object([:]), position: Int64(actions.count), ruleId: first.id)) }
        first.actions = actions
        var later = makeRule(folderId: folder.id, name: "later", actions: [makeAction(.delete, .object([:]))])
        later.priority = 1
        later.actions[0].ruleId = later.id
        let rules = [first, later]
        let preview = try #require(RuleEngine.previewFile(path: manual, depth: 0, rules: rules))
        #expect(preview.rules.count == 1)
        #expect(preview.rules[0].actions.map(\.kind) == (midChain ? [.pause, .ignore] : [.ignore]))
        let result = RuleEngine.run(path: manual, depth: 0, rules: rules, batchId: "ignore", platform: TemporaryTrashPlatform())
        #expect(result.matched == ["ignore"])
        #expect(FileManager.default.fileExists(atPath: manual))
        try db.insertRule(first)
        try db.insertRule(later)
        WatcherCoordinator(db: db, actionPlatform: TemporaryTrashPlatform()).handle(path: watched)
        #expect(try db.listHistory().allSatisfy { $0.ruleName == "ignore" })
        #expect(FileManager.default.fileExists(atPath: watched))
    }
}
