import Testing
import Foundation
@testable import ForelCore

@Suite struct RuleEngineTests {
    @Test func maxRuleDepthIgnoresDisabledRules() throws {
        let currentFolderRule = makeRule(name: "current", enabled: true, recursionDepth: 0)
        let disabledAllLevelsRule = makeRule(name: "disabled all levels", enabled: false, recursionDepth: nil)

        #expect(RuleEngine.maxRuleDepth([currentFolderRule, disabledAllLevelsRule]) == 0)
    }

    @Test func maxRuleDepthFallsBackToCurrentFolderWhenNoRulesAreEnabled() throws {
        let disabledAllLevelsRule = makeRule(name: "disabled all levels", enabled: false, recursionDepth: nil)

        #expect(RuleEngine.maxRuleDepth([disabledAllLevelsRule]) == 0)
    }

    @Test func walkEntriesAtCurrentFolderDepthDoesNotDescendIntoSubfolders() throws {
        let dir = TempDir()
        let direct = dir.file("direct.txt")
        let nestedDir = dir.dir("Nested")
        let nested = (nestedDir as NSString).appendingPathComponent("inside.txt")
        try "nested".write(toFile: nested, atomically: true, encoding: .utf8)

        let entries = RuleEngine.walkEntries(root: dir.path, maxDepth: 0)

        #expect(entries.map(\.path) == [nestedDir, direct].sorted())
        #expect(!entries.contains { $0.path == nested })
        #expect(entries.allSatisfy { $0.depth == 0 })
    }

    @Test func pathDepthComputesRelativeDepthFromRoot() throws {
        #expect(RuleEngine.pathDepth(root: "/Users/x/Inbox", path: "/Users/x/Inbox/file.txt") == 0)
        #expect(RuleEngine.pathDepth(root: "/Users/x/Inbox", path: "/Users/x/Inbox/Sub/file.txt") == 1)
        #expect(RuleEngine.pathDepth(root: "/Users/x/Inbox", path: "/Users/x/Other/file.txt") == nil)
    }
}
