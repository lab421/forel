import Foundation
import Testing
@testable import ForelCore

@Suite struct RuleMatchPreviewTests {
    private func pdfRule(folderId: String, destination: String) -> Rule {
        var rule = makeRule(folderId: folderId, name: "PDFs")
        rule.enabled = false
        rule.conditions = [makeCondition(.extension_, .is, "pdf", ruleId: rule.id)]
        rule.actions = [makeAction(.moveToFolder, .object([ActionParam.destination: .string(destination)]), ruleId: rule.id)]
        return rule
    }

    @Test func countsMatchesOfAnUnsavedDisabledRuleWithoutTouchingFiles() throws {
        let dir = TempDir()
        let input = dir.dir("Input")
        let archive = dir.path + "/Archive"
        _ = dir.file("Input/a.pdf", contents: "a")
        _ = dir.file("Input/b.txt", contents: "b")
        _ = dir.file("Input/c.PDF", contents: "c")
        let rule = pdfRule(folderId: "folder", destination: archive)

        let summary = RuleEngine.previewMatches(of: rule, root: input, isPro: true)

        #expect(summary.isComplete)
        #expect(summary.checked == 3)
        #expect(summary.total == 2)
        #expect(summary.matches.map(\.name) == ["a.pdf", "c.PDF"])
        #expect(summary.matches.allSatisfy { $0.wouldRun && $0.warning == nil })
        #expect(summary.matches.first?.action?.contains("Archive") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: input).sorted() == ["a.pdf", "b.txt", "c.PDF"])
        #expect(!FileManager.default.fileExists(atPath: archive))
    }

    @Test func plansTheSameTargetAsDryRun() throws {
        let dir = TempDir()
        let input = dir.dir("Input")
        let path = dir.file("Input/a.pdf", contents: "a")
        var rule = pdfRule(folderId: "folder", destination: dir.path + "/Archive")
        let summary = RuleEngine.previewMatches(of: rule, root: input, isPro: true)
        rule.enabled = true
        let dryRun = try #require(RuleEngine.previewFile(path: path, depth: 0, rules: [rule], root: input, isPro: true))
        #expect(summary.matches.first?.action == dryRun.rules.first?.actions.first?.description)
    }

    @Test func stopsAtTheScanLimitAndKeepsOnlyTheFirstMatches() {
        let dir = TempDir()
        let input = dir.dir("Input")
        for index in 0..<30 { _ = dir.file("Input/\(String(format: "%02d", index)).pdf", contents: "x") }
        let rule = pdfRule(folderId: "folder", destination: dir.path + "/Archive")

        let summary = RuleEngine.previewMatches(of: rule, root: input, isPro: true, scanLimit: 10, keep: 4)

        #expect(!summary.isComplete)
        #expect(summary.checked == 10)
        #expect(summary.total == 10)
        #expect(summary.matches.map(\.name) == ["00.pdf", "01.pdf", "02.pdf", "03.pdf"])
    }

    @Test func stopsWhenCancelled() {
        let dir = TempDir()
        let input = dir.dir("Input")
        for index in 0..<5 { _ = dir.file("Input/\(index).pdf", contents: "x") }
        let rule = pdfRule(folderId: "folder", destination: dir.path + "/Archive")
        var calls = 0

        let summary = RuleEngine.previewMatches(of: rule, root: input, isPro: true) {
            calls += 1
            return calls > 2
        }

        #expect(!summary.isComplete)
        #expect(summary.checked == 2)
    }

    @Test func earlyStopUnwindsNestedFolders() {
        let dir = TempDir()
        let root = dir.dir("Root")
        _ = dir.dir("Root/A")
        _ = dir.file("Root/A/1.txt", contents: "x")
        _ = dir.file("Root/A/2.txt", contents: "x")
        _ = dir.file("Root/B.txt", contents: "x")
        var visited: [String] = []

        RuleEngine.forEachEntry(root: root, maxDepth: nil, while: { entry in
            visited.append((entry.path as NSString).lastPathComponent)
            return visited.count < 2
        })

        #expect(visited == ["A", "1.txt"])
        #expect(RuleEngine.walkEntries(root: root, maxDepth: nil).count == 4)
    }
}
