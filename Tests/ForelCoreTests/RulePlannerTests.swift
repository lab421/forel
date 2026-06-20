import Testing
import Foundation
@testable import ForelCore

@Suite struct RulePlannerTests {
    @Test func planFileOrdersActionsAndComputesTargetPaths() throws {
        let dir = TempDir()
        let file = dir.file("invoice.pdf", contents: "paid")
        let destination = dir.dir("Processed")
        var rule = makeRule(name: "archive invoice", conditions: [makeCondition(.extension_, .is, "pdf")])
        rule.actions = [
            makeAction(.addTag, .object(["tag": .string("Reviewed")]), position: 1),
            makeAction(.moveToFolder, .object(["destination": .string(destination)]), position: 2),
        ]

        let planned = try #require(RulePlanner.planFile(path: file, depth: 0, rules: [rule], root: nil))

        #expect(planned.rules.count == 1)
        #expect(planned.rules[0].actions.map(\.actionKind) == [.addTag, .moveToFolder])
        #expect(planned.rules[0].actions.map(\.status) == [.wouldRun, .wouldRun])
        #expect(planned.rules[0].actions[1].targetPath == (destination as NSString).appendingPathComponent("invoice.pdf"))
    }

    @Test func renameThenNextRuleSeesNewPath() throws {
        let dir = TempDir()
        let file = dir.file("a.txt")
        var renameRule = makeRule(name: "rename", conditions: [makeCondition(.extension_, .is, "txt")])
        renameRule.actions = [makeAction(.rename, .object(["pattern": .string("renamed.txt")]), position: 0)]
        var tagRule = makeRule(name: "tag renamed", conditions: [makeCondition(.name, .contains, "renamed")])
        tagRule.actions = [makeAction(.addTag, .object(["tag": .string("Done")]), position: 0)]

        let planned = try #require(RulePlanner.planFile(path: file, depth: 0, rules: [renameRule, tagRule], root: nil))

        #expect(planned.rules.count == 2)
        #expect(planned.rules[1].ruleName == "tag renamed")
        #expect(planned.rules[1].actions[0].sourcePath.hasSuffix("renamed.txt"))
    }

    @Test func copyThenFollowingRuleEvaluatesCopyWithoutRepeatingCopyRule() throws {
        let dir = TempDir()
        let file = dir.file("a.txt")
        let destination = dir.dir("Backup")
        var copyRule = makeRule(name: "copy", conditions: [makeCondition(.extension_, .is, "txt")])
        copyRule.actions = [makeAction(.copyToFolder, .object(["destination": .string(destination)]), position: 0)]
        var tagRule = makeRule(name: "tag all txt", conditions: [makeCondition(.extension_, .is, "txt")])
        tagRule.actions = [makeAction(.addTag, .object(["tag": .string("Seen")]), position: 0)]

        let planned = try #require(RulePlanner.planFile(path: file, depth: 0, rules: [copyRule, tagRule], root: nil))

        // The original gets: copy rule (1 action) + tag rule (1 action).
        // The copy does NOT get re-evaluated against the copy rule itself,
        // only against rules after it.
        let originalRuleNames = planned.rules.map(\.ruleName)
        #expect(originalRuleNames.filter { $0 == "copy" }.count == 1)
    }

    @Test func terminalMoveStopsFollowingActionsAndRules() throws {
        let dir = TempDir()
        let file = dir.file("a.txt")
        let destination = dir.dir("Archive")
        var rule = makeRule(name: "archive", conditions: [makeCondition(.extension_, .is, "txt")])
        rule.actions = [
            makeAction(.moveToFolder, .object(["destination": .string(destination)]), position: 0),
            makeAction(.addTag, .object(["tag": .string("Unreachable")]), position: 1),
        ]
        var nextRule = makeRule(name: "next", conditions: [makeCondition(.extension_, .is, "txt")])
        nextRule.actions = [makeAction(.addTag, .object(["tag": .string("ShouldNotRun")]), position: 0)]

        let planned = try #require(RulePlanner.planFile(path: file, depth: 0, rules: [rule, nextRule], root: nil))

        #expect(planned.rules.count == 1)
        #expect(planned.rules[0].actions.count == 1)
        #expect(planned.rules[0].actions[0].isTerminal)
    }

    @Test func moveToFolderTowardCurrentParentIsAlreadyInDestinationSkip() throws {
        let dir = TempDir()
        let pdfDir = dir.dir("PDF")
        let existing = (pdfDir as NSString).appendingPathComponent("existing.pdf")
        try "x".write(toFile: existing, atomically: true, encoding: .utf8)

        var rule = makeRule(name: "sort pdf", conditions: [makeCondition(.extension_, .is, "pdf")], recursionDepth: nil)
        rule.actions = [makeAction(.moveToFolder, .object(["destination": .string(pdfDir)]), position: 0)]

        let planned = try #require(RulePlanner.planFile(path: existing, depth: 1, rules: [rule], root: dir.path))

        #expect(planned.rules[0].actions.count == 1)
        #expect(planned.rules[0].actions[0].status == .wouldSkip)
        #expect(planned.rules[0].actions[0].skipReason == "alreadyInDestination")
        #expect(planned.rules[0].actions[0].targetPath == existing)
    }

    @Test func moveToFolderTowardCurrentParentNeverProducesNumberedDuplicate() throws {
        let dir = TempDir()
        let pdfDir = dir.dir("PDF")
        let existing = (pdfDir as NSString).appendingPathComponent("existing.pdf")
        try "x".write(toFile: existing, atomically: true, encoding: .utf8)

        var rule = makeRule(name: "sort pdf", conditions: [makeCondition(.extension_, .is, "pdf")], recursionDepth: nil)
        rule.actions = [makeAction(.moveToFolder, .object(["destination": .string(pdfDir)]), position: 0)]

        let planned = try #require(RulePlanner.planFile(path: existing, depth: 1, rules: [rule], root: dir.path))
        let numberedDuplicate = (pdfDir as NSString).appendingPathComponent("existing (1).pdf")

        #expect(planned.rules[0].actions.allSatisfy { $0.targetPath != numberedDuplicate })
        #expect(!FileManager.default.fileExists(atPath: numberedDuplicate))
    }

    @Test func planFileReturnsNilWhenNoRuleMatches() throws {
        let dir = TempDir()
        let file = dir.file("a.txt")
        let rule = makeRule(name: "only pdf", conditions: [makeCondition(.extension_, .is, "pdf")])

        #expect(RulePlanner.planFile(path: file, depth: 0, rules: [rule], root: nil) == nil)
    }

    @Test func planComputesIdentityAndFingerprintSnapshot() throws {
        let dir = TempDir()
        let file = dir.file("a.txt", contents: "hello")
        var rule = makeRule(name: "tag", conditions: [makeCondition(.extension_, .is, "txt")])
        rule.actions = [makeAction(.addTag, .object(["tag": .string("Seen")]), position: 0)]

        let planned = try #require(RulePlanner.planFile(path: file, depth: 0, rules: [rule], root: nil))

        #expect(planned.fileId != nil)
        #expect(planned.volumeId != nil)
        #expect(planned.contentFingerprint != nil)
    }
}
