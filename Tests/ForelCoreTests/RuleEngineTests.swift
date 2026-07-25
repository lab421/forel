// Forel - A native macOS file-automation app
// Copyright (C) 2026  Lab421
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import Testing
import Foundation
@testable import ForelCore

@Suite struct RuleEngineTests {
    @Test func evaluateFileMatchesEnabledRulesWithAllOrAnyConditions() throws {
        let dir = TempDir()
        let file = dir.file("invoice.txt", contents: "paid")
        let rules = [
            makeRule(name: "all matched", conditionMatch: .all, conditions: [
                makeCondition(.name, .contains, "invoice"),
                makeCondition(.extension_, .is, "txt"),
            ]),
            makeRule(name: "any matched", conditionMatch: .any, conditions: [
                makeCondition(.name, .contains, "receipt"),
                makeCondition(.contents, .contains, "paid"),
            ]),
            makeRule(name: "disabled", enabled: false, conditions: [makeCondition(.extension_, .is, "pdf")]),
            makeRule(name: "empty"),
        ]

        let (matched, history) = RuleEngine.run(path: file, depth: 0, rules: rules, batchId: "batch")
        #expect(matched == ["all matched", "any matched", "empty"])
        #expect(history.isEmpty)
    }

    @Test func runIgnoresIncompleteBrowserDownloadsEvenWhenRuleWouldMatch() throws {
        let dir = TempDir()
        let file = dir.file("report.pdf.crdownload", contents: "")
        try setQuarantineAgent(file, agent: "Google Chrome")
        let destination = dir.dir("Documents")
        let rule = makeRule(
            name: "chrome downloads",
            conditions: [makeCondition(.downloadedWithApp, .is, "Google Chrome")],
            actions: [makeAction(.moveToFolder, .object(["destination": .string(destination)]))]
        )

        let (matched, history) = RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "batch")

        #expect(matched.isEmpty)
        #expect(history.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file))
        #expect(!FileManager.default.fileExists(atPath: (destination as NSString).appendingPathComponent("report.pdf.crdownload")))
    }

    @Test func previewFileIgnoresIncompleteBrowserDownloadsEvenWhenRuleWouldMatch() throws {
        let dir = TempDir()
        let file = dir.file("report.pdf.crdownload", contents: "")
        try setQuarantineAgent(file, agent: "Google Chrome")
        let rule = makeRule(
            name: "chrome downloads",
            conditions: [makeCondition(.downloadedWithApp, .is, "Google Chrome")]
        )

        #expect(RuleEngine.previewFile(path: file, depth: 0, rules: [rule]) == nil)
    }

    @Test func walkEntriesSkipsIncompleteBrowserDownloadsForFolderRuns() throws {
        let dir = TempDir()
        _ = dir.file("report.pdf.crdownload", contents: "")
        let finished = dir.file("report.pdf", contents: "done")

        #expect(RuleEngine.walkEntries(root: dir.path, maxDepth: 0).map(\.path) == [finished])
    }

    @Test func conditionOrderDoesNotChangeAllOrAnyMatching() throws {
        // `ruleMatches` evaluates cheap conditions before `contents` and
        // short-circuits. Reordering must not change the boolean outcome, so a
        // `contents` condition that disagrees with a cheap one decides `.all`
        // and `.any` exactly as if it were evaluated in declaration order.
        let dir = TempDir()
        let file = dir.file("invoice.txt", contents: "paid")
        let rules = [
            // `.all`: cheap name passes but contents disagrees -> no match,
            // regardless of which condition is listed first.
            makeRule(name: "all contents-gated", conditionMatch: .all, conditions: [
                makeCondition(.contents, .contains, "refunded"),
                makeCondition(.name, .contains, "invoice"),
            ]),
            // `.any`: cheap name fails but contents matches -> match.
            makeRule(name: "any contents-gated", conditionMatch: .any, conditions: [
                makeCondition(.name, .contains, "receipt"),
                makeCondition(.contents, .contains, "paid"),
            ]),
        ]

        let (matched, _) = RuleEngine.run(path: file, depth: 0, rules: rules, batchId: "batch")
        #expect(matched == ["any contents-gated"])
    }

    @Test func noneConditionMatchRequiresEveryConditionToFailInPreviewAndRun() throws {
        let dir = TempDir()
        let file = dir.file("invoice.txt", contents: "paid")
        let matchesNone = makeRule(
            name: "matches none",
            conditionMatch: .none,
            conditions: [
                makeCondition(.name, .contains, "receipt"),
                makeCondition(.contents, .contains, "refunded"),
            ]
        )
        let matchesOne = makeRule(
            name: "matches one",
            conditionMatch: .none,
            conditions: [
                makeCondition(.name, .contains, "invoice"),
                makeCondition(.contents, .contains, "refunded"),
            ]
        )

        let preview = RuleEngine.previewFile(path: file, depth: 0, rules: [matchesNone, matchesOne])
        let run = RuleEngine.run(path: file, depth: 0, rules: [matchesNone, matchesOne], batchId: "batch")

        #expect(preview?.rules.map(\.ruleName) == ["matches none"])
        #expect(run.matched == ["matches none"])
    }

    @Test func finderCommentConditionMatchesInPreviewAndManualRun() throws {
        let dir = TempDir()
        let file = dir.file("invoice.txt")
        try FinderTags.writeComment(file, "Ready to file")
        let rule = makeRule(
            name: "file ready invoices",
            conditions: [makeCondition(.finderComment, .contains, "Ready")]
        )

        let preview = RuleEngine.previewFile(path: file, depth: 0, rules: [rule])
        let run = RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "batch")

        #expect(preview?.rules.map(\.ruleName) == ["file ready invoices"])
        #expect(run.matched == ["file ready invoices"])
    }

    @Test func pauseIsShownInPreviewAndDelaysManualExecution() throws {
        let dir = TempDir()
        let file = dir.file("invoice.txt")
        let pause = makeAction(.pause, .object([ActionParam.pauseSeconds: .number(0.02)]))
        let rule = makeRule(name: "pause", actions: [pause])

        let previewStarted = Date()
        let preview = RuleEngine.previewFile(path: file, depth: 0, rules: [rule])
        let previewElapsed = Date().timeIntervalSince(previewStarted)

        let runStarted = Date()
        let run = RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "batch")
        let runElapsed = Date().timeIntervalSince(runStarted)

        #expect(preview?.rules[0].actions.map(\.description) == ["Pause for 0.02 seconds"])
        #expect(previewElapsed < 0.01)
        #expect(run.matched == ["pause"])
        #expect(run.history.map(\.actionKind) == [.pause])
        #expect(runElapsed >= 0.015)
    }

    @Test func runRulesOnFolderContentsAppliesTheFullRuleListToChildren() throws {
        let dir = TempDir()
        let folder = dir.dir("Incoming")
        let child = (folder as NSString).appendingPathComponent("document.txt")
        FileManager.default.createFile(atPath: child, contents: Data())
        let descend = makeRule(
            name: "descend",
            conditions: [makeCondition(.kind, .is, "folder")],
            actions: [makeAction(.runRulesOnFolderContents, .object([:]))]
        )
        let tag = makeRule(
            name: "tag text",
            conditions: [makeCondition(.extension_, .is, "txt")],
            actions: [makeAction(.addTag, .object([ActionParam.tags: .stringArray(["Processed"])]))]
        )

        let result = RuleEngine.run(path: folder, depth: 0, rules: [descend, tag], batchId: "batch", root: dir.path)

        #expect(result.matched == ["descend", "tag text"])
        #expect(result.history.map(\.actionKind) == [.runRulesOnFolderContents, .addTag])
        #expect(FinderTags.read(child).contains("Processed"))
    }

    @Test func ignoreStopsThisItemFromReachingLaterRules() throws {
        let dir = TempDir()
        let file = dir.file("document.txt")
        let ignore = makeRule(name: "ignore", actions: [makeAction(.ignore, .object([:]))])
        let tag = makeRule(name: "tag", actions: [makeAction(.addTag, .object([ActionParam.tags: .stringArray(["Wrong"])]))])

        let result = RuleEngine.run(path: file, depth: 0, rules: [ignore, tag], batchId: "batch")

        #expect(result.matched == ["ignore"])
        #expect(result.history.map(\.actionKind) == [.ignore])
        #expect(!FinderTags.read(file).contains("Wrong"))
    }

    @Test func allConditionsCombineRegexWithCompleteFilenameExclusionsInPreviewAndRun() throws {
        let dir = TempDir()
        let destination = dir.dir("Processed")
        let excluded = ["Desktop.ini", "Thumbs.db", "$RECYCLE.BIN"]
        let included = dir.file("report.pdf")
        let excludedPaths = excluded.map { dir.file($0) }
        let rule = makeRule(
            name: "move non-system files",
            conditionMatch: .all,
            conditions: [
                makeCondition(.name, .matchesRegex, #"^[^.]"#),
                makeCondition(.name, .isNot, "Desktop.ini"),
                makeCondition(.name, .isNot, "Thumbs.db"),
                makeCondition(.name, .isNot, "$RECYCLE.BIN"),
            ],
            actions: [makeAction(.moveToFolder, .object(["destination": .string(destination)]))]
        )

        #expect(RuleEngine.previewFile(path: included, depth: 0, rules: [rule]) != nil)
        for path in excludedPaths {
            #expect(RuleEngine.previewFile(path: path, depth: 0, rules: [rule]) == nil)
        }

        for path in excludedPaths {
            let result = RuleEngine.run(path: path, depth: 0, rules: [rule], batchId: "excluded")
            #expect(result.matched.isEmpty)
            #expect(result.history.isEmpty)
            #expect(FileManager.default.fileExists(atPath: path))
        }

        let includedResult = RuleEngine.run(path: included, depth: 0, rules: [rule], batchId: "included")
        #expect(includedResult.matched == ["move non-system files"])
        #expect(includedResult.history.count == 1)
        #expect(FileManager.default.fileExists(
            atPath: (destination as NSString).appendingPathComponent("report.pdf")
        ))
    }

    @Test func previewFileHidesAlreadyAppliedActions() throws {
        let dir = TempDir()
        let file = dir.file("photo.jpg", contents: "img")
        var rule = makeRule(name: "label jpgs", conditions: [makeCondition(.extension_, .is, "jpg")])
        rule.actions = [
            makeAction(.setColorLabel, .object(["color": .string("Yellow")]), position: 1),
            makeAction(.addTag, .object(["tags": .stringArray(["Sorted"])]), position: 2),
        ]

        let before = RuleEngine.previewFile(path: file, depth: 0, rules: [rule])
        #expect(before?.rules[0].actions.count == 2)
        #expect(before?.rules[0].actions.map(\.status) == [.wouldRun, .wouldRun])

        let (_, history) = RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "batch")
        #expect(history.count == 2)
        #expect(history.allSatisfy { $0.reversible })
        let after = RuleEngine.previewFile(path: file, depth: 0, rules: [rule])
        #expect(after?.rules[0].actions.map(\.status) == [.wouldSkip, .wouldSkip])
    }

    @Test func previewFileReturnsOrderedActionsWithoutExecutingThem() throws {
        let dir = TempDir()
        let file = dir.file("invoice.pdf", contents: "paid")
        let destination = dir.dir("Processed")
        var rule = makeRule(name: "archive invoice", conditions: [makeCondition(.extension_, .is, "pdf")])
        rule.actions = [
            makeAction(.addTag, .object(["tag": .string("Reviewed")]), position: 1),
            makeAction(.moveToFolder, .object(["destination": .string(destination)]), position: 2),
        ]

        let preview = RuleEngine.previewFile(path: file, depth: 0, rules: [rule])
        #expect(preview != nil)
        #expect(FileManager.default.fileExists(atPath: file))
        #expect(!FileManager.default.fileExists(atPath: (destination as NSString).appendingPathComponent("invoice.pdf")))
        #expect(preview?.name == "invoice.pdf")
        #expect(preview?.rules[0].ruleName == "archive invoice")
        #expect(preview?.rules[0].actions.map(\.description) == [
            "Add tag 'Reviewed'",
            "Move to \((destination as NSString).appendingPathComponent("invoice.pdf"))",
        ])
        #expect(preview?.rules[0].actions.map(\.sourcePath) == [file, file])
        #expect(preview?.rules[0].actions[1].targetPath == (destination as NSString).appendingPathComponent("invoice.pdf"))
        #expect(preview?.rules[0].actions.map(\.status) == [.wouldRun, .wouldRun])
    }

    @Test func previewFileShowsConditionResults() throws {
        let dir = TempDir()
        let file = dir.file("invoice.pdf", contents: "paid")
        let rule = makeRule(
            name: "maybe invoice",
            conditionMatch: .any,
            conditions: [
                makeCondition(.name, .contains, "receipt"),
                makeCondition(.extension_, .is, "pdf"),
            ],
            actions: [makeAction(.addTag, .object(["tag": .string("Reviewed")]))]
        )

        let preview = RuleEngine.previewFile(path: file, depth: 0, rules: [rule])

        #expect(preview?.rules[0].conditions.map(\.matched) == [false, true])
        #expect(preview?.rules[0].conditions.map(\.kind) == [.name, .extension_])
    }

    @Test func previewFileShowsMatchedRulesWithoutActions() throws {
        let dir = TempDir()
        let file = dir.file("invoice.pdf", contents: "paid")
        let rule = makeRule(
            name: "review invoices",
            conditions: [makeCondition(.extension_, .is, "pdf")]
        )

        let preview = RuleEngine.previewFile(path: file, depth: 0, rules: [rule])

        #expect(preview?.name == "invoice.pdf")
        #expect(preview?.rules.map(\.ruleName) == ["review invoices"])
        #expect(preview?.rules[0].conditions.map(\.matched) == [true])
        #expect(preview?.rules[0].actions.isEmpty == true)
    }

    /// `moveToFolder` resolves a same-name conflict itself (default: rename
    /// the incoming file) rather than blocking, so Dry Run shows the actual
    /// destination Run Now/the watcher will use — no `(1)`-suffixed surprise
    /// at execution time that didn't appear in the preview.
    @Test func previewFileResolvesDestinationConflictByRenamingWithoutMutatingFiles() throws {
        let dir = TempDir()
        let file = dir.file("invoice.pdf", contents: "paid")
        let destination = dir.dir("Processed")
        let conflict = (destination as NSString).appendingPathComponent("invoice.pdf")
        try "existing".write(toFile: conflict, atomically: true, encoding: .utf8)
        let rule = makeRule(
            name: "archive invoice",
            actions: [makeAction(.moveToFolder, .object(["destination": .string(destination)]))]
        )

        let preview = RuleEngine.previewFile(path: file, depth: 0, rules: [rule])

        let renamed = (destination as NSString).appendingPathComponent("invoice (1).pdf")
        #expect(preview?.rules[0].actions[0].status == .wouldRun)
        #expect(preview?.rules[0].actions[0].targetPath == renamed)
        #expect(FileManager.default.fileExists(atPath: file))
        #expect(!FileManager.default.fileExists(atPath: renamed))
        #expect((try String(contentsOfFile: conflict, encoding: .utf8)) == "existing")
    }

    @Test func previewFileSkipsAMoveToFolderThatWouldLandInTheSameFolderItsAlreadyIn() throws {
        let dir = TempDir()
        let pdfDir = dir.dir("PDF")
        let existing = (pdfDir as NSString).appendingPathComponent("existing.pdf")
        try "x".write(toFile: existing, atomically: true, encoding: .utf8)
        let rule = makeRule(
            name: "sort pdf",
            actions: [makeAction(.moveToFolder, .object(["destination": .string(pdfDir)]))]
        )

        let preview = RuleEngine.previewFile(path: existing, depth: 0, rules: [rule])

        #expect(preview?.rules[0].actions[0].status == .wouldSkip)
        let numberedDuplicate = (pdfDir as NSString).appendingPathComponent("existing (1).pdf")
        #expect(!FileManager.default.fileExists(atPath: numberedDuplicate))
    }

    @Test func previewFileFollowsSimulatedRenameThroughFollowingRules() throws {
        let dir = TempDir()
        let file = dir.file("draft.pdf", contents: "content")
        let archivedDir = dir.dir("Archived")
        let renameRule = makeRule(
            name: "Rename to final",
            actions: [makeAction(.rename, .object(["pattern": .string("final.pdf")]))]
        )
        let archiveRenamedRule = makeRule(
            name: "Archive final",
            conditions: [makeCondition(.name, .contains, "final")],
            actions: [makeAction(.moveToFolder, .object(["destination": .string(archivedDir)]))]
        )

        let preview = RuleEngine.previewFile(path: file, depth: 0, rules: [renameRule, archiveRenamedRule])
        let renamed = (dir.path as NSString).appendingPathComponent("final.pdf")

        #expect(preview?.rules.map(\.ruleName) == ["Rename to final", "Archive final"])
        #expect(preview?.rules[1].conditions.map(\.matched) == [true])
        #expect(preview?.rules[1].actions[0].sourcePath == renamed)
        #expect(FileManager.default.fileExists(atPath: file))
        #expect(!FileManager.default.fileExists(atPath: renamed))

        let result = RuleEngine.run(
            path: file,
            depth: 0,
            rules: [renameRule, archiveRenamedRule],
            batchId: "batch",
            root: dir.path
        )
        #expect(preview?.rules.map(\.ruleName) == result.matched)
        #expect(preview?.rules.flatMap { $0.actions.map(\.kind) } == result.history.map(\.actionKind))
    }

    @Test func recursionDepthBlocksNestedMatchesButAllowsDirectChildren() throws {
        let dir = TempDir()
        let direct = dir.file("direct.txt", contents: "direct")
        let nestedDir = dir.dir("Nested")
        let nested = (nestedDir as NSString).appendingPathComponent("inside.txt")
        try "nested".write(toFile: nested, atomically: true, encoding: .utf8)

        let shallowRule = makeRule(name: "shallow", conditions: [makeCondition(.name, .contains, "direct")], recursionDepth: 0)

        #expect(RuleEngine.run(path: direct, depth: 0, rules: [shallowRule], batchId: "batch").matched == ["shallow"])
        #expect(RuleEngine.run(path: nested, depth: 1, rules: [shallowRule], batchId: "batch").matched == [])
    }

    @Test func recursionDepthSupportsCurrentFolderLimitedDepthAndAllLevels() throws {
        let ruleCurrent = makeRule(name: "current", recursionDepth: 0)
        let ruleOneLevel = makeRule(name: "one level", recursionDepth: 1)
        let ruleAllLevels = makeRule(name: "all levels", recursionDepth: nil)

        #expect(RuleEngine.run(path: "/tmp/file.txt", depth: 0, rules: [ruleCurrent, ruleOneLevel, ruleAllLevels], batchId: "batch").matched == [
            "current",
            "one level",
            "all levels",
        ])
        #expect(RuleEngine.run(path: "/tmp/Sub/file.txt", depth: 1, rules: [ruleCurrent, ruleOneLevel, ruleAllLevels], batchId: "batch").matched == [
            "one level",
            "all levels",
        ])
        #expect(RuleEngine.run(path: "/tmp/Sub/Deep/file.txt", depth: 2, rules: [ruleCurrent, ruleOneLevel, ruleAllLevels], batchId: "batch").matched == [
            "all levels",
        ])
    }

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

    @Test func walkEntriesSkipsMacOSAndOfficeSystemFiles() throws {
        let dir = TempDir()
        let real = dir.file("report.pdf")
        _ = dir.file(".DS_Store")
        _ = dir.file("._report.pdf") // AppleDouble resource fork
        _ = dir.file("~$budget.docx") // Office lock file for an open document

        let entries = RuleEngine.walkEntries(root: dir.path, maxDepth: 0)

        #expect(entries.map(\.path) == [real])
    }

    @Test func evaluateFileExecutesMatchingRulesAndSkipsNonMatchingRules() throws {
        let dir = TempDir()
        let file = dir.file("photo.jpg", contents: "image")
        let matching = makeRule(
            name: "matching image",
            conditions: [
                makeCondition(.extension_, .is, "jpg"),
                makeCondition(.kind, .is, "image"),
            ],
            actions: [makeAction(.addTag, .object(["tags": .stringArray(["Matched"])]))]
        )
        let nonMatching = makeRule(
            name: "non matching pdf",
            conditions: [makeCondition(.kind, .is, "pdf")],
            actions: [makeAction(.addTag, .object(["tags": .stringArray(["Wrong"])]))]
        )

        let result = RuleEngine.run(path: file, depth: 0, rules: [matching, nonMatching], batchId: "batch")

        #expect(result.matched == ["matching image"])
        #expect(result.history.count == 1)
        #expect(FinderTags.read(file) == ["Matched"])
    }

    @Test func evaluateFileRecordsSkippedActions() throws {
        let dir = TempDir()
        let file = dir.file("same.txt", contents: "content")
        let rule = makeRule(
            name: "No-op rename",
            actions: [makeAction(.rename, .object(["pattern": .string("same.txt")]))]
        )

        let result = RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "batch")

        #expect(result.history.count == 1)
        #expect(result.history[0].status == .skipped)
        #expect(result.history[0].originalPath == file)
        #expect(result.history[0].resultPath == file)
        #expect(result.history[0].reversible == false)
        #expect(result.history[0].message == "Skipped because the action would not change this file.")
        #expect(FileManager.default.fileExists(atPath: file))
    }

    @Test func evaluateFileRecordsFailedActions() throws {
        let dir = TempDir()
        let file = dir.file("script.txt", contents: "content")
        let rule = makeRule(
            name: "Failing script",
            actions: [makeAction(.runScript, .object(["script": .string("exit 7")]))]
        )

        let result = RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "batch")

        #expect(result.history.count == 1)
        #expect(result.history[0].status == .failed)
        #expect(result.history[0].originalPath == file)
        #expect(result.history[0].resultPath == file)
        #expect(result.history[0].reversible == false)
        #expect(result.history[0].message?.contains("script exited with status 7") == true)
        #expect(FileManager.default.fileExists(atPath: file))
    }

    @Test func runSkipsAMoveToFolderThatWouldLandInTheSameFolderItsAlreadyIn() throws {
        let dir = TempDir()
        let pdfDir = dir.dir("PDF")
        let existing = (pdfDir as NSString).appendingPathComponent("existing.pdf")
        try "x".write(toFile: existing, atomically: true, encoding: .utf8)
        let rule = makeRule(
            name: "sort pdf",
            actions: [makeAction(.moveToFolder, .object(["destination": .string(pdfDir)]))]
        )

        let result = RuleEngine.run(path: existing, depth: 0, rules: [rule], batchId: "batch")

        let numberedDuplicate = (pdfDir as NSString).appendingPathComponent("existing (1).pdf")
        #expect(!FileManager.default.fileExists(atPath: numberedDuplicate))
        #expect(FileManager.default.fileExists(atPath: existing))
        #expect(result.history.count == 1)
        #expect(result.history[0].status == .skipped)
    }

    @Test func runResolvesDestinationConflictByRenamingByDefault() throws {
        let dir = TempDir()
        let destination = dir.dir("Archive")
        let existing = (destination as NSString).appendingPathComponent("note.txt")
        try "old".write(toFile: existing, atomically: true, encoding: .utf8)
        let file = dir.file("note.txt", contents: "new")
        let rule = makeRule(
            name: "archive",
            actions: [makeAction(.moveToFolder, .object(["destination": .string(destination)]))]
        )

        let result = RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "batch")

        let numbered = (destination as NSString).appendingPathComponent("note (1).txt")
        #expect(result.history.count == 1)
        #expect(result.history[0].status == .applied)
        #expect(result.history[0].resultPath == numbered)
        #expect(try String(contentsOfFile: existing, encoding: .utf8) == "old")
        #expect(try String(contentsOfFile: numbered, encoding: .utf8) == "new")
    }

    @Test func runReplacesExistingFileWhenConfigured() throws {
        let dir = TempDir()
        let destination = dir.dir("Archive")
        let existing = (destination as NSString).appendingPathComponent("note.txt")
        try "old".write(toFile: existing, atomically: true, encoding: .utf8)
        let file = dir.file("note.txt", contents: "new")
        let rule = makeRule(
            name: "archive",
            actions: [makeAction(.moveToFolder, .object([
                "destination": .string(destination),
                "on_conflict": .string("replace"),
            ]))]
        )

        let result = RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "batch")

        #expect(result.history.count == 1)
        #expect(result.history[0].status == .applied)
        #expect(result.history[0].resultPath == existing)
        #expect(try String(contentsOfFile: existing, encoding: .utf8) == "new")
    }

    @Test func runSkipOnConflictStopsLaterActionsInTheSameRule() throws {
        let dir = TempDir()
        let destination = dir.dir("Archive")
        let existing = (destination as NSString).appendingPathComponent("note.txt")
        try "old".write(toFile: existing, atomically: true, encoding: .utf8)
        let file = dir.file("note.txt", contents: "new")
        var rule = makeRule(name: "archive then tag")
        rule.actions = [
            makeAction(.moveToFolder, .object([
                "destination": .string(destination),
                "on_conflict": .string("skip"),
            ]), position: 0),
            makeAction(.addTag, .object(["tag": .string("Archived")]), position: 1),
        ]

        let result = RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "batch")

        #expect(FileManager.default.fileExists(atPath: file))
        #expect(FinderTags.read(file).isEmpty)
        #expect(result.history.count == 1)
        #expect(result.history[0].status == .skipped)
    }

    @Test func runSkippedCopyDoesNotStopLaterActionsInTheSameRule() throws {
        let dir = TempDir()
        let destination = dir.dir("Backup")
        let existing = (destination as NSString).appendingPathComponent("note.txt")
        try "old".write(toFile: existing, atomically: true, encoding: .utf8)
        let file = dir.file("note.txt", contents: "new")
        var rule = makeRule(name: "backup then tag")
        rule.actions = [
            makeAction(.copyToFolder, .object([
                "destination": .string(destination),
                "on_conflict": .string("skip"),
            ]), position: 0),
            makeAction(.addTag, .object(["tag": .string("Reviewed")]), position: 1),
        ]

        let result = RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "batch")

        #expect(result.history.count == 2)
        #expect(result.history[0].status == .skipped)
        #expect(result.history[1].status == .applied)
        #expect(FinderTags.read(file) == ["Reviewed"])
    }

    @Test func previewMoveToFolderContinuesLaterActionsOnMovedPath() throws {
        let dir = TempDir()
        let destination = dir.dir("PDF")
        let file = dir.file("image.png", contents: "image")
        let moved = (destination as NSString).appendingPathComponent("image.png")
        var rule = makeRule(
            name: "move then color",
            conditions: [makeCondition(.extension_, .is, "png")]
        )
        rule.actions = [
            makeAction(.moveToFolder, .object(["destination": .string(destination)]), position: 0),
            makeAction(.setColorLabel, .object(["color": .string("Red")]), position: 1),
        ]

        let preview = RuleEngine.previewFile(path: file, depth: 0, rules: [rule])

        #expect(preview?.rules[0].actions.map(\.kind) == [.moveToFolder, .setColorLabel])
        #expect(preview?.rules[0].actions.map(\.status) == [.wouldRun, .wouldRun])
        #expect(preview?.rules[0].actions[1].sourcePath == moved)
    }

    @Test func runMoveToFolderContinuesLaterActionsOnMovedPath() throws {
        let dir = TempDir()
        let destination = dir.dir("PDF")
        let file = dir.file("image.png", contents: "image")
        let moved = (destination as NSString).appendingPathComponent("image.png")
        var rule = makeRule(
            name: "move then color",
            conditions: [makeCondition(.extension_, .is, "png")]
        )
        rule.actions = [
            makeAction(.moveToFolder, .object(["destination": .string(destination)]), position: 0),
            makeAction(.setColorLabel, .object(["color": .string("Red")]), position: 1),
        ]

        let result = RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "batch")

        #expect(result.history.map(\.actionKind) == [.moveToFolder, .setColorLabel])
        #expect(result.history.allSatisfy { $0.status == .applied })
        #expect(!FileManager.default.fileExists(atPath: file))
        #expect(FileManager.default.fileExists(atPath: moved))
        #expect(FinderTags.currentColorName(moved) == "red")
    }

    @Test func previewUncompressContinuesLaterActionsOnExtractedPath() throws {
        let dir = TempDir()
        let staging = dir.dir("staging")
        try "hello".write(toFile: (staging as NSString).appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        let zip = (dir.path as NSString).appendingPathComponent("download.zip")
        try makeZip(in: staging, items: ["report.txt"], destination: zip)
        try FileManager.default.removeItem(atPath: staging)

        let extracted = (dir.path as NSString).appendingPathComponent("report.txt")
        let renamed = (dir.path as NSString).appendingPathComponent("final.txt")
        var rule = makeRule(name: "unzip then rename", conditions: [makeCondition(.kind, .is, "archive")])
        rule.actions = [
            makeAction(.uncompress, .object([:]), position: 0),
            makeAction(.rename, .object(["pattern": .string("final.txt")]), position: 1),
        ]

        let preview = RuleEngine.previewFile(path: zip, depth: 0, rules: [rule])

        #expect(preview?.rules[0].actions.map(\.kind) == [.uncompress, .rename])
        #expect(preview?.rules[0].actions.map(\.status) == [.wouldRun, .wouldRun])
        #expect(preview?.rules[0].actions[1].sourcePath == extracted)
        #expect(preview?.rules[0].actions[1].targetPath == renamed)
        #expect(!FileManager.default.fileExists(atPath: extracted))
    }

    @Test func runUncompressContinuesLaterActionsOnExtractedPath() throws {
        let dir = TempDir()
        let staging = dir.dir("staging")
        try "hello".write(toFile: (staging as NSString).appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        let zip = (dir.path as NSString).appendingPathComponent("download.zip")
        try makeZip(in: staging, items: ["report.txt"], destination: zip)
        try FileManager.default.removeItem(atPath: staging)

        let final = (dir.path as NSString).appendingPathComponent("final.txt")
        var rule = makeRule(name: "unzip then rename", conditions: [makeCondition(.kind, .is, "archive")])
        rule.actions = [
            makeAction(.uncompress, .object([:]), position: 0),
            makeAction(.rename, .object(["pattern": .string("final.txt")]), position: 1),
        ]

        let result = RuleEngine.run(path: zip, depth: 0, rules: [rule], batchId: "batch")

        #expect(result.history.map(\.actionKind) == [.uncompress, .rename])
        #expect(result.history.allSatisfy { $0.status == .applied })
        #expect(!FileManager.default.fileExists(atPath: zip))
        #expect(FileManager.default.fileExists(atPath: final))
        #expect(try String(contentsOfFile: final, encoding: .utf8) == "hello")
    }

    @Test func previewUncompressSkipConflictStopsLaterActions() throws {
        let dir = TempDir()
        let existing = dir.file("report.txt", contents: "existing")
        let staging = dir.dir("staging")
        try "new".write(toFile: (staging as NSString).appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        let zip = (dir.path as NSString).appendingPathComponent("download.zip")
        try makeZip(in: staging, items: ["report.txt"], destination: zip)
        try FileManager.default.removeItem(atPath: staging)

        var rule = makeRule(name: "skip unzip then rename", conditions: [makeCondition(.kind, .is, "archive")])
        rule.actions = [
            makeAction(.uncompress, .object([ActionParam.onConflict: .string(MoveConflictResolution.skip.rawValue)]), position: 0),
            makeAction(.rename, .object(["pattern": .string("final.txt")]), position: 1),
        ]

        let preview = RuleEngine.previewFile(path: zip, depth: 0, rules: [rule])

        #expect(preview?.rules[0].actions.map(\.kind) == [.uncompress])
        #expect(preview?.rules[0].actions[0].status == .wouldSkip)
        #expect(try String(contentsOfFile: existing, encoding: .utf8) == "existing")
    }

    @Test func runUncompressSkipConflictStopsLaterActions() throws {
        let dir = TempDir()
        let existing = dir.file("report.txt", contents: "existing")
        let staging = dir.dir("staging")
        try "new".write(toFile: (staging as NSString).appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        let zip = (dir.path as NSString).appendingPathComponent("download.zip")
        try makeZip(in: staging, items: ["report.txt"], destination: zip)
        try FileManager.default.removeItem(atPath: staging)
        let wronglyRenamedArchive = (dir.path as NSString).appendingPathComponent("final.txt")

        var rule = makeRule(name: "skip unzip then rename", conditions: [makeCondition(.kind, .is, "archive")])
        rule.actions = [
            makeAction(.uncompress, .object([ActionParam.onConflict: .string(MoveConflictResolution.skip.rawValue)]), position: 0),
            makeAction(.rename, .object(["pattern": .string("final.txt")]), position: 1),
        ]

        let result = RuleEngine.run(path: zip, depth: 0, rules: [rule], batchId: "batch")

        #expect(result.history.map(\.actionKind) == [.uncompress])
        #expect(result.history[0].status == .skipped)
        #expect(FileManager.default.fileExists(atPath: zip))
        #expect(!FileManager.default.fileExists(atPath: wronglyRenamedArchive))
        #expect(try String(contentsOfFile: existing, encoding: .utf8) == "existing")
    }

    @Test func previewRenameAfterSimulatedMoveDoesNotNeedMovedFileToExistYet() throws {
        let dir = TempDir()
        let firstDestination = dir.dir("PDF")
        let secondDestination = dir.dir("DMG")
        let file = dir.file("image.png", contents: "image")
        let secondMoved = (secondDestination as NSString).appendingPathComponent("image.png")
        let renamed = (secondDestination as NSString).appendingPathComponent("image-moved.png")
        var rule = makeRule(
            name: "move twice then rename",
            conditions: [makeCondition(.extension_, .is, "png")]
        )
        rule.actions = [
            makeAction(.moveToFolder, .object(["destination": .string(firstDestination)]), position: 0),
            makeAction(.moveToFolder, .object(["destination": .string(secondDestination)]), position: 1),
            makeAction(.rename, .object(["pattern": .string("{name}-moved")]), position: 2),
        ]

        let preview = RuleEngine.previewFile(path: file, depth: 0, rules: [rule])

        #expect(preview?.rules[0].actions.map(\.kind) == [.moveToFolder, .moveToFolder, .rename])
        #expect(preview?.rules[0].actions.map(\.status) == [.wouldRun, .wouldRun, .wouldRun])
        #expect(preview?.rules[0].actions[2].sourcePath == secondMoved)
        #expect(preview?.rules[0].actions[2].targetPath == renamed)
        #expect(!FileManager.default.fileExists(atPath: secondMoved))
        #expect(!FileManager.default.fileExists(atPath: renamed))
    }

    @Test func copiedFilesContinueThroughFollowingRulesWithoutRepeatingCopyRule() throws {
        let dir = TempDir()
        let file = dir.file("document.pdf", contents: "content")
        let archivedDir = dir.dir("Archived")

        let labelRule = makeRule(
            name: "Change color label",
            actions: [makeAction(.setColorLabel, .object(["color": .string("Blue")]))]
        )
        let copyRule = makeRule(
            name: "Copy",
            actions: [makeAction(.copyToFolder, .object(["destination": .string(dir.path)]))]
        )
        let deleteDuplicateRule = makeRule(
            name: "Delete duplicates",
            conditionMatch: .any,
            conditions: [
                makeCondition(.name, .contains, "(1)"),
                makeCondition(.name, .contains, "(2)"),
            ],
            actions: [makeAction(.moveToFolder, .object(["destination": .string(archivedDir)]))]
        )

        let result = RuleEngine.run(
            path: file,
            depth: 0,
            rules: [labelRule, copyRule, deleteDuplicateRule],
            batchId: "batch",
            root: dir.path
        )

        let duplicate = (dir.path as NSString).appendingPathComponent("document (1).pdf")
        let archivedDuplicate = (archivedDir as NSString).appendingPathComponent("document (1).pdf")

        #expect(result.matched == ["Change color label", "Copy", "Delete duplicates"])
        #expect(result.history.map(\.actionKind) == [.setColorLabel, .copyToFolder, .moveToFolder])
        #expect(result.history[1].resultPath == duplicate)
        #expect(result.history[2].originalPath == duplicate)
        #expect(FileManager.default.fileExists(atPath: file))
        #expect(!FileManager.default.fileExists(atPath: duplicate))
        #expect(FileManager.default.fileExists(atPath: archivedDuplicate))
        #expect(!FileManager.default.fileExists(atPath: (dir.path as NSString).appendingPathComponent("document (2).pdf")))
    }

    @Test func renamedFilesContinueThroughFollowingRulesAtTheirNewName() throws {
        let dir = TempDir()
        let file = dir.file("draft.pdf", contents: "content")
        let archivedDir = dir.dir("Archived")

        let renameRule = makeRule(
            name: "Rename to final",
            actions: [makeAction(.rename, .object(["pattern": .string("final.pdf")]))]
        )
        let archiveRenamedRule = makeRule(
            name: "Archive final",
            conditions: [makeCondition(.name, .contains, "final")],
            actions: [makeAction(.moveToFolder, .object(["destination": .string(archivedDir)]))]
        )
        let shouldNeverMatchOldName = makeRule(
            name: "Would only match the old name",
            conditions: [makeCondition(.name, .contains, "draft")],
            actions: [makeAction(.addTag, .object(["tags": .stringArray(["Stale"])]))]
        )

        let result = RuleEngine.run(
            path: file,
            depth: 0,
            rules: [renameRule, archiveRenamedRule, shouldNeverMatchOldName],
            batchId: "batch",
            root: dir.path
        )

        let renamed = (dir.path as NSString).appendingPathComponent("final.pdf")
        let archived = (archivedDir as NSString).appendingPathComponent("final.pdf")

        #expect(result.matched == ["Rename to final", "Archive final"])
        #expect(result.history.map(\.actionKind) == [.rename, .moveToFolder])
        #expect(result.history[1].originalPath == renamed)
        #expect(!FileManager.default.fileExists(atPath: file))
        #expect(!FileManager.default.fileExists(atPath: renamed))
        #expect(FileManager.default.fileExists(atPath: archived))
    }

    @Test func pathDepthComputesRelativeDepthFromRoot() throws {
        #expect(RuleEngine.pathDepth(root: "/Users/x/Inbox", path: "/Users/x/Inbox/file.txt") == 0)
        #expect(RuleEngine.pathDepth(root: "/Users/x/Inbox", path: "/Users/x/Inbox/Sub/file.txt") == 1)
        #expect(RuleEngine.pathDepth(root: "/Users/x/Inbox", path: "/Users/x/Other/file.txt") == nil)
    }
}
