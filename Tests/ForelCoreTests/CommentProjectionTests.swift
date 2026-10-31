import Foundation
import Testing
@testable import ForelCore

@Suite struct CommentProjectionTests {
    private func setupRule(folder: WatchedFolder, actions: [Action]) -> Rule {
        var rule = makeRule(folderId: folder.id, name: "comment projection", conditions: [makeCondition(.anyFile, .is, "")], actions: actions)
        rule.isHazelImported = true
        for index in rule.conditions.indices { rule.conditions[index].ruleId = rule.id }
        for index in rule.actions.indices { rule.actions[index].ruleId = rule.id }
        return rule
    }

    @Test func renamedNameAndCommentAgreeAcrossPreviewManualAndWatcher() throws {
        for mode in ["preview", "manual", "watcher"] {
            let dir = TempDir(); let path = dir.file("old.txt", contents: "x"); try FinderComment.write(path, value: "new|seed")
            let folder = WatchedFolder(path: dir.path)
            let rename = makeAction(.rename, .object([ActionParam.pattern: .string("new")]), position: 0)
            let comment: JSONValue = .object(["type": .string("comment"), "replacements": .array([
                .object(["find": .string("^new\\|"), "replace": .string(""), "regex": .bool(true)])
            ])])
            let set = makeAction(.setFinderComment, .object([HazelPattern.tokensKey: .array([
                .object(["type": .string("name")]), .object(["type": .string("literal"), "value": .string("|")]), comment
            ])]), position: 1)
            let rule = setupRule(folder: folder, actions: [rename, set]); let target = "\(dir.path)/new.txt"
            if mode == "preview" {
                let preview = try #require(RuleEngine.previewFile(path: path, depth: 0, rules: [rule]))
                #expect(preview.rules.first?.actions.map(\.status) == [.wouldRun, .wouldSkip])
                #expect(FileManager.default.fileExists(atPath: path))
            } else if mode == "manual" {
                let result = RuleEngine.run(path: path, depth: 0, rules: [rule], batchId: "comment")
                #expect(result.history.map(\.status) == [.applied, .skipped])
                #expect(try FinderComment.read(target) == "new|seed")
            } else {
                let db = try Database(path: ":memory:"); try db.insertFolder(folder); try db.insertRule(rule)
                WatcherCoordinator(db: db).handle(path: path)
                let history = try db.listHistory()
                #expect(history.count == 2 && history.filter { $0.status == .applied }.count == 1 && history.filter { $0.status == .skipped }.count == 1)
                #expect(try FinderComment.read(target) == "new|seed")
            }
        }
    }

    @Test func commentTokensAfterMoveOrCopyAgreeAcrossExecutionPaths() throws {
        for kind: ActionKind in [.moveToFolder, .copyToFolder] {
            for mode in ["preview", "manual", "watcher"] {
                let source = TempDir(); let destination = TempDir(); let path = source.file("old.txt", contents: "x")
                try FinderComment.write(path, value: "seed")
                let folder = WatchedFolder(path: source.path)
                let transfer = makeAction(kind, .object([ActionParam.destination: .string(destination.path)]), position: 0)
                let rename = makeAction(.rename, .object([ActionParam.pattern: .string("dynamic"), HazelPattern.tokensKey: .array([
                    .object(["type": .string("comment")]), .object(["type": .string("extension")])
                ])]), position: 1)
                let tag = makeAction(.addTag, .object([HazelPattern.tokensKey: .array([.object(["type": .string("comment")])])]), position: 2)
                let rule = setupRule(folder: folder, actions: [transfer, rename, tag]); let target = "\(destination.path)/seed.txt"
                if mode == "preview" {
                    let preview = try #require(RuleEngine.previewFile(path: path, depth: 0, rules: [rule]))
                    let actions = try #require(preview.rules.first?.actions)
                    try #require(actions.count == 3)
                    #expect(actions.map(\.status) == [.wouldRun, .wouldRun, .wouldRun])
                    #expect(actions[1].targetPath == target)
                    #expect(actions[2].description.contains("seed"))
                } else if mode == "manual" {
                    let result = RuleEngine.run(path: path, depth: 0, rules: [rule], batchId: "comment")
                    #expect(result.history.map(\.status) == [.applied, .applied, .applied])
                    #expect(FinderTags.read(target).contains("seed"))
                } else {
                    let db = try Database(path: ":memory:"); try db.insertFolder(folder); try db.insertRule(rule)
                    WatcherCoordinator(db: db).handle(path: path)
                    #expect(try db.listHistory().allSatisfy { $0.status == .applied })
                    #expect(try db.listHistory().count == 3)
                    #expect(FinderTags.read(target).contains("seed"))
                }
            }
        }
    }
}
