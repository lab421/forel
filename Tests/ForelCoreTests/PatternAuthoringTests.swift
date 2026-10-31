import Foundation
import Testing
@testable import ForelCore

@Suite struct PatternAuthoringTests {
    @Test func convertingBasicRenamePreservesOutputAndBothDrafts() throws {
        let dir = TempDir(); let path = dir.file("report.txt", contents: "hello")
        var blank = makeAction(.rename, .object([ActionParam.pattern: .string("")]))
        PatternAuthoring.setStructured(true, on: &blank)
        #expect(RuleValidator.validate([blank]).isEmpty)
        PatternAuthoring.setStructured(false, on: &blank)
        #expect(blank.params[ActionParam.pattern]?.stringValue == "")
        for basic in ["{name}.{extension}", "{name}-copy", "{size}-{date_modified}-{current_date}", "{name}--{extension}"] {
            var action = makeAction(.rename, .object([ActionParam.pattern: .string(basic)]))
            let basicTarget = try ActionExecutor.plan(action, path: path).targetPath
            PatternAuthoring.setStructured(true, on: &action)
            #expect(RuleValidator.validate([action]).isEmpty)
            #expect(try ActionExecutor.plan(action, path: path).targetPath == basicTarget)
            guard case .object(var params) = action.params else { Issue.record("Expected action parameters"); return }
            params["hazel_pattern_tokens"] = .array([.object(["type": .string("literal"), "value": .string("draft.txt")])]); action.params = .object(params)
            PatternAuthoring.setStructured(false, on: &action)
            #expect(action.params[ActionParam.pattern]?.stringValue == basic)
            #expect(action.params["hazel_pattern_tokens"] == nil)
            PatternAuthoring.setStructured(true, on: &action)
            #expect(action.params["hazel_pattern_tokens"]?.arrayValue?.first?["value"]?.stringValue == "draft.txt")
        }
    }

    @Test func sortModeKeepsFolderDraftAndRoundTrips() throws {
        let dir = TempDir(); let folder = WatchedFolder(path: dir.path); let db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        var action = makeAction(.moveToFolder, .object([ActionParam.destination: .string("/tmp/example")]))
        var blank = makeAction(.moveToFolder, .object([:]))
        PatternAuthoring.setStructured(true, on: &blank)
        #expect(RuleValidator.validate([blank]).isEmpty)
        let source = dir.file("report.txt")
        #expect(try ActionExecutor.plan(blank, path: source).targetPath == "\(dir.path)/report/report.txt")
        PatternAuthoring.setStructured(true, on: &action)
        #expect(RuleValidator.validate([action]).isEmpty)
        #expect(action.params["hazel_sort_subfolder"]?.boolValue == true)
        PatternAuthoring.setStructured(false, on: &action)
        #expect(action.params[ActionParam.destination]?.stringValue == "/tmp/example")
        var rule = makeRule(folderId: folder.id, name: "sort", actions: [action]); rule.actions[0].ruleId = rule.id
        try db.insertRule(rule)
        var saved = try #require(db.listRules(folderId: folder.id).first?.actions.first)
        PatternAuthoring.setStructured(true, on: &saved)
        #expect(saved.params["hazel_pattern_tokens"]?.arrayValue?.first?["type"]?.stringValue == "name")
        PatternAuthoring.setStructured(false, on: &saved)
        #expect(saved.params[ActionParam.destination]?.stringValue == "/tmp/example")
    }

    @Test func importedPeerFiltersGetFreshNestedIdentities() throws {
        let child = makeCondition(.name, .is, "report")
        let group = makeCondition(.conditionGroup, .is, ConditionGroup(conditions: [child]).encoded)
        var ranking = PeerRankingCondition(); ranking.filters = [group]
        let source = makeRule(name: "ranking", conditions: [makeCondition(.peerRanking, .is, ranking.encoded)])
        let data = try RuleTransfer.exportForel([source])
        let first = try #require(RuleTransfer.importRules(from: data, folderId: "f").rules.first)
        let second = try #require(RuleTransfer.importRules(from: data, folderId: "f").rules.first)
        let firstCondition = try #require(first.conditions.first); let secondCondition = try #require(second.conditions.first)
        let firstRank = try #require(PeerRankingCondition.decode(firstCondition.value))
        let secondRank = try #require(PeerRankingCondition.decode(secondCondition.value))
        let firstFilter = try #require(firstRank.filters.first); let secondFilter = try #require(secondRank.filters.first)
        #expect(firstFilter.ruleId == first.id && secondFilter.ruleId == second.id)
        #expect(firstFilter.id != secondFilter.id && firstFilter.id != group.id)
        let firstGroup = try #require(ConditionGroup.decode(firstFilter.value)); let secondGroup = try #require(ConditionGroup.decode(secondFilter.value))
        #expect(firstGroup.conditions.first?.ruleId == first.id && secondGroup.conditions.first?.ruleId == second.id)
        #expect(firstGroup.conditions.first?.id != secondGroup.conditions.first?.id)
    }

    @Test func convertedSizeWorksAfterVirtualMoveAndCopyAcrossExecutionPaths() throws {
        for kind: ActionKind in [.moveToFolder, .copyToFolder] {
            for mode in ["preview", "manual", "watcher"] {
                let source = TempDir(); let destination = TempDir(); let path = source.file("original.txt", contents: "hello")
                let folder = WatchedFolder(path: source.path)
                var rename = makeAction(.rename, .object([ActionParam.pattern: .string("{size}")]), position: 1)
                PatternAuthoring.setStructured(true, on: &rename)
                let transfer = makeAction(kind, .object([ActionParam.destination: .string(destination.path)]), position: 0)
                var rule = makeRule(folderId: folder.id, name: "size after transfer", conditions: [makeCondition(.anyFile, .is, "")], actions: [transfer, rename])
                rule.isHazelImported = true
                for index in rule.conditions.indices { rule.conditions[index].ruleId = rule.id }
                for index in rule.actions.indices { rule.actions[index].ruleId = rule.id }
                let target = "\(destination.path)/5B.txt"
                if mode == "preview" {
                    let preview = try #require(RuleEngine.previewFile(path: path, depth: 0, rules: [rule]))
                    #expect(preview.rules.first?.actions.count == 2)
                    #expect(preview.rules.first?.actions.last?.targetPath == target)
                    #expect(FileManager.default.fileExists(atPath: path))
                } else if mode == "manual" {
                    let result = RuleEngine.run(path: path, depth: 0, rules: [rule], batchId: "size")
                    #expect(result.history.map(\.status) == [.applied, .applied])
                    #expect(FileManager.default.fileExists(atPath: target))
                } else {
                    let db = try Database(path: ":memory:"); try db.insertFolder(folder); try db.insertRule(rule)
                    WatcherCoordinator(db: db).handle(path: path)
                    #expect(try db.listHistory().map(\.status) == [.applied, .applied])
                    #expect(FileManager.default.fileExists(atPath: target))
                }
            }
        }
        let dir = TempDir(); let path = dir.file("changing.txt", contents: "x")
        var rename = makeAction(.rename, .object([ActionParam.pattern: .string("{size}")]))
        PatternAuthoring.setStructured(true, on: &rename)
        let context = HazelPatternContext(path: path, actions: [rename])
        try "longer".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(try HazelPattern.render(rename, path: path, contextPath: path, context: context) == "6B.txt")
    }
}
