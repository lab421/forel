import Foundation
import Testing
@testable import ForelCore

@Suite struct PeerRankingTests {
    @Test func rankingExposesBothPositiveAndNegativeOperators() {
        #expect(ConditionKind.peerRanking.validOperators == [.is, .isNot])
    }
    @Test func peerRecheckRespectsEarlierHazelGatesWithoutReplayingOtherRules() throws {
        let dir = TempDir(); let path = dir.file("item.txt")
        let spec = PeerRankingCondition()
        let ranked = makeRule(name: "ranked", conditions: [makeCondition(.peerRanking, .is, spec.encoded)], actions: [makeAction(.delete, .object([:]))])
        let unrelated = makeRule(name: "native", conditions: [makeCondition(.anyFile, .is, "")], actions: [makeAction(.delete, .object([:]))])
        for action in [makeAction(.ignore, .object([:])), makeAction(.moveToFolder, .object([ActionParam.destination: .string("\(dir.path)/other")]))] {
            var gate = makeRule(name: "Hazel gate", conditions: [makeCondition(.name, .is, "item")], actions: [action]); gate.isHazelImported = true
            let result = RuleEngine.runWithTraversal(path: path, depth: 0, rules: [unrelated, gate, ranked], batchId: "peer", root: dir.path, peerRecheckOnly: true)
            #expect(result.history.isEmpty)
            #expect(FileManager.default.fileExists(atPath: path))
        }
    }
    @Test func watcherPeerRecheckDoesNotBypassHazelIgnoreOrMove() throws {
        for gateKind: ActionKind in [.ignore, .moveToFolder] {
            let dir = TempDir(); let folder = WatchedFolder(path: dir.path); let db = try Database(path: ":memory:")
            try db.insertFolder(folder)
            let path = dir.file("item.txt")
            var native = makeRule(folderId: folder.id, name: "native", conditions: [makeCondition(.anyFile, .is, "")], actions: [makeAction(.delete, .object([:]))]); native.priority = 0
            let params: JSONValue = gateKind == .moveToFolder ? .object([ActionParam.destination: .string("\(dir.path)/outside")]) : .object([:])
            var gate = makeRule(folderId: folder.id, name: "gate", conditions: [makeCondition(.name, .is, "item")], actions: [makeAction(gateKind, params)])
            gate.isHazelImported = true; gate.priority = 1
            var ranked = makeRule(folderId: folder.id, name: "ranked", conditions: [makeCondition(.peerRanking, .is, PeerRankingCondition().encoded)], actions: [makeAction(.delete, .object([:]))]); ranked.priority = 2
            for var rule in [native, gate, ranked] {
                for index in rule.conditions.indices { rule.conditions[index].ruleId = rule.id }
                for index in rule.actions.indices { rule.actions[index].ruleId = rule.id }
                try db.insertRule(rule)
            }
            WatcherCoordinator(db: db, settleInterval: 0).handle(event: .peerChanged("\(dir.path)/removed.txt"))
            #expect(FileManager.default.fileExists(atPath: path))
            #expect(try db.listHistory().isEmpty)
        }
    }
    @Test func peerRecheckExplainsScriptGateWithoutRunningScript() throws {
        let dir = TempDir(); let path = dir.file("item.txt"); let marker = "\(dir.path)/marker"
        let script = HazelScriptCondition(source: "touch '\(marker)'\nexit 0")
        var gate = makeRule(name: "script gate", conditions: [makeCondition(.hazelScriptCondition, .is, script.encoded)], actions: [makeAction(.ignore, .object([:]))]); gate.isHazelImported = true
        let ranked = makeRule(name: "ranked", conditions: [makeCondition(.peerRanking, .is, PeerRankingCondition().encoded)], actions: [makeAction(.delete, .object([:]))])
        let result = RuleEngine.runWithTraversal(path: path, depth: 0, rules: [gate, ranked], batchId: "peer", root: dir.path, peerRecheckOnly: true)
        #expect(result.history.first?.status == .skipped)
        #expect(result.history.first?.message?.contains("script condition") == true)
        #expect(!FileManager.default.fileExists(atPath: marker))
        #expect(FileManager.default.fileExists(atPath: path))
    }
    @Test func peerRecheckDoesNotApplyParentRulesToNestedWatchedFolder() throws {
        let dir = TempDir(); let parent = WatchedFolder(path: dir.path); let nestedPath = dir.dir("nested")
        let nested = WatchedFolder(path: nestedPath); let db = try Database(path: ":memory:")
        try db.insertFolder(parent); try db.insertFolder(nested)
        let conditions = [makeCondition(.name, .is, "nested"), makeCondition(.peerRanking, .is, PeerRankingCondition().encoded)]
        var rule = makeRule(folderId: parent.id, name: "parent", conditions: conditions, actions: [makeAction(.delete, .object([:]))])
        for index in rule.conditions.indices { rule.conditions[index].ruleId = rule.id }; rule.actions[0].ruleId = rule.id
        try db.insertRule(rule)
        WatcherCoordinator(db: db, settleInterval: 0).handle(event: .peerChanged("\(dir.path)/removed.txt"))
        #expect(FileManager.default.fileExists(atPath: nestedPath))
        #expect(try db.listHistory().isEmpty)
    }
    @Test func normalPreviewAndManualRunRespectEarlierHazelGate() throws {
        for kind: ActionKind in [.ignore, .moveToFolder] {
            let dir = TempDir(); let path = dir.file("item.txt")
            let destination = dir.dir("destination")
            let params: JSONValue = kind == .moveToFolder ? .object([ActionParam.destination: .string(destination)]) : .object([:])
            var gate = makeRule(name: "gate", conditions: [makeCondition(.name, .is, "item")], actions: [makeAction(kind, params)]); gate.isHazelImported = true
            let ranked = makeRule(name: "ranked", conditions: [makeCondition(.peerRanking, .is, PeerRankingCondition().encoded)], actions: [makeAction(.delete, .object([:]))])
            let preview = try #require(RuleEngine.previewFile(path: path, depth: 0, rules: [gate, ranked], root: dir.path))
            #expect(!preview.rules.contains { $0.ruleName == "ranked" && $0.actions.contains { $0.status == .wouldRun } })
            _ = RuleEngine.run(path: path, depth: 0, rules: [gate, ranked], batchId: "gate", root: dir.path)
            #expect(FileManager.default.fileExists(atPath: kind == .ignore ? path : "\(destination)/item.txt"))
        }
    }
    @Test func ruleAllFiltersRankingAndWatcherRechecksOnSiblingChanges() throws {
        let dir = TempDir(); let folder = WatchedFolder(path: dir.path); let db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        let older = dir.file("old.pdf"), newer = dir.file("new.pdf"), other = dir.file("later.txt")
        for (path, seconds) in [(older, 1000.0), (newer, 2000.0), (other, 3000.0)] {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: path)
        }
        let spec = PeerRankingCondition()
        let rank = makeCondition(.peerRanking, .is, spec.encoded)
        let ext = makeCondition(.extension_, .is, "pdf")
        let action = makeAction(.addTag, .object([ActionParam.tags: .stringArray(["Ranked"])]))
        var rule = makeRule(folderId: folder.id, name: "newest PDF", conditions: [ext, rank], actions: [action])
        for index in rule.conditions.indices { rule.conditions[index].ruleId = rule.id }
        rule.actions[0].ruleId = rule.id
        try db.insertRule(rule)
        let preview = try #require(RuleEngine.previewFile(path: newer, depth: 0, rules: [rule]))
        #expect(preview.rules.first?.conditions.allSatisfy(\.matched) == true)
        let watcher = WatcherCoordinator(db: db, settleInterval: 0)
        watcher.handle(event: .pathArrived(newer))
        #expect(FinderTags.read(newer).contains("Ranked"))
        #expect(!FinderTags.read(older).contains("Ranked"))
        try FileManager.default.removeItem(atPath: newer)
        watcher.handle(event: .peerChanged(newer))
        #expect(FinderTags.read(older).contains("Ranked"))
    }
    @Test func nestedHazelPeerRecheckRecoversTraversalAfterRestartWithoutReplayingFileActions() throws {
        let dir = TempDir(); let outside = TempDir()
        let folder = WatchedFolder(path: dir.path); let db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        _ = dir.dir("nested")
        let older = dir.file("nested/old.pdf"), newer = dir.file("nested/new.pdf")
        for (path, seconds) in [(older, 1000.0), (newer, 2000.0)] {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: path)
        }
        let marker = "\(outside.path)/runs"
        var native = makeRule(folderId: folder.id, name: "ordinary action", conditions: [makeCondition(.name, .is, "old")], actions: [makeAction(.runHazelShellScript, .object([ActionParam.script: .string("printf x >> '\(marker)'"), ActionParam.shell: .string("/bin/sh")]))], recursionDepth: 1)
        native.priority = 0
        var recurse = makeRule(folderId: folder.id, name: "recurse", conditions: [makeCondition(.name, .is, "nested")], actions: [makeAction(.hazelRecurse, .object([:]))])
        recurse.isHazelImported = true; recurse.priority = 1
        var ranked = makeRule(folderId: folder.id, name: "newest", conditions: [makeCondition(.extension_, .is, "pdf"), makeCondition(.peerRanking, .is, PeerRankingCondition().encoded)], actions: [makeAction(.addTag, .object([ActionParam.tags: .stringArray(["Ranked"])]))])
        ranked.isHazelImported = true; ranked.priority = 2
        for var rule in [native, recurse, ranked] {
            for index in rule.conditions.indices { rule.conditions[index].ruleId = rule.id }
            for index in rule.actions.indices { rule.actions[index].ruleId = rule.id }
            try db.insertRule(rule)
        }
        WatcherCoordinator(db: db, settleInterval: 0).handle(path: older)
        #expect(try String(contentsOfFile: marker, encoding: .utf8) == "x")
        #expect(!FinderTags.read(older).contains("Ranked"))
        try FileManager.default.removeItem(atPath: newer)
        WatcherCoordinator(db: db, settleInterval: 0).handle(event: .peerChanged(newer))
        #expect(FinderTags.read(older).contains("Ranked"))
        #expect(try String(contentsOfFile: marker, encoding: .utf8) == "x")
    }
    @Test func ranksOnlyFilteredVisiblePeersAndHandlesNegation() throws {
        let dir = TempDir()
        let older = dir.file("old.pdf"), newer = dir.file("new.pdf"), other = dir.file("latest.txt")
        for (path, seconds) in [(older, 1000.0), (newer, 2000.0), (other, 3000.0)] {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: path)
        }
        var spec = PeerRankingCondition(); spec.attribute = .modified
        spec.filters = [makeCondition(.extension_, .is, "pdf")]
        let condition = makeCondition(.peerRanking, .is, spec.encoded)
        #expect(ConditionEvaluator.evaluate(condition, path: newer))
        #expect(!ConditionEvaluator.evaluate(condition, path: older))
        let inverse = makeCondition(.peerRanking, .isNot, spec.encoded)
        #expect(ConditionEvaluator.evaluate(inverse, path: older))
        #expect(!ConditionEvaluator.evaluate(inverse, path: other))
        try FileManager.default.removeItem(atPath: newer)
        #expect(ConditionEvaluator.evaluate(condition, path: older))
        let hidden = dir.file(".hidden.pdf")
        #expect(!ConditionEvaluator.evaluate(inverse, path: hidden))
    }
    @Test func tiesUseStablePathOrderAndPeerFilterIsBounded() throws {
        let dir = TempDir(); let a = dir.file("a.txt", contents: "12"); let b = dir.file("b.txt", contents: "34")
        var spec = PeerRankingCondition(); spec.attribute = .size
        #expect(ConditionEvaluator.evaluate(makeCondition(.peerRanking, .is, spec.encoded), path: a))
        #expect(!ConditionEvaluator.evaluate(makeCondition(.peerRanking, .is, spec.encoded), path: b))
        spec.filters = [makeCondition(.peerRanking, .is, spec.encoded)]
        #expect(spec.validationError != nil)
    }
}
