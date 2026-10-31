import Foundation
import Testing
@testable import ForelCore

@Suite struct HazelRuleCopyTests {
    @Test func copiesPreserveHazelStateAndRemapNestedConditions() throws {
        let dir = TempDir(); let db = try Database(path: ":memory:")
        let source = WatchedFolder(path: dir.dir("source")), destination = WatchedFolder(path: dir.dir("destination"))
        try db.insertFolder(source); try db.insertFolder(destination)
        let nested = makeCondition(.name, .is, "report")
        let group = makeCondition(.conditionGroup, .is, ConditionGroup(conditions: [nested]).encoded)
        var peer = PeerRankingCondition(); peer.filters = [group]
        var rule = makeRule(folderId: source.id, name: "Hazel", enabled: false, conditionMatch: .none,
                            conditions: [makeCondition(.peerRanking, .is, peer.encoded)], actions: [makeAction(.ignore, .object([:]))])
        rule.isHazelImported = true; rule.importError = "Unsupported original feature"
        rule.conditions[0].ruleId = rule.id; rule.actions[0].ruleId = rule.id
        try db.insertRule(rule)
        let copy = try #require(db.copyRules([rule.id], fromFolderID: source.id, toFolderID: destination.id, isPro: true).first)
        #expect(copy.isHazelImported && copy.importError == rule.importError && !copy.enabled && copy.conditionMatch == .none)
        let copiedCondition = try #require(copy.conditions.first)
        let copiedPeer = try #require(PeerRankingCondition.decode(copiedCondition.value))
        let copiedGroup = try #require(copiedPeer.filters.first)
        #expect(copiedGroup.id != group.id && copiedGroup.ruleId == copy.id)
        let children = try #require(ConditionGroup.decode(copiedGroup.value)).conditions
        #expect(children.first?.id != nested.id && children.first?.ruleId == copy.id)
        #expect(try db.listRules(folderId: destination.id).first == copy)
    }
}
