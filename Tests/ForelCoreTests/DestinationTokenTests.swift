import Foundation
import Testing
@testable import ForelCore

@Suite struct DestinationTokenTests {
    private func setCreationDate(_ path: String, hour: Int, minute: Int) throws {
        let date = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: hour, minute: minute)))
        try FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: path)
    }

    private func plannedTarget(_ kind: ActionKind, _ destination: String, path: String) throws -> String? {
        let action = makeAction(kind, .object([ActionParam.destination: .string(destination)]))
        return try ActionExecutor.plan(action, path: path).targetPath
    }

    @Test(arguments: [
        ("report.pdf", "pdf", "PDF"),
        ("Photo.JPG", "jpg", "Image"),
        ("clip.mov", "mov", "Movie"),
        ("backup.tar.gz", "gz", "Archive"),
        ("notes.pages", "pages", "Document"),
        ("README", "No Extension", "Document"),
    ], [ActionKind.moveToFolder, .copyToFolder])
    func extensionAndKindNameTheFolder(file: (name: String, ext: String, kind: String), action: ActionKind) throws {
        let dir = TempDir()
        let path = dir.file(file.name, contents: "x")
        let target = try plannedTarget(action, dir.path + "/Sorted/{kind}/{extension}", path: path)
        #expect(target == dir.path + "/Sorted/\(file.kind)/\(file.ext)/\(file.name)")
        #expect(!FileManager.default.fileExists(atPath: dir.path + "/Sorted"))
    }

    /// `{kind}` and `{extension}` name folders on disk: they stay in English
    /// whatever the app's language, or a rule would start filing into new
    /// folders after a language change.
    @Test func folderNamesNeverFollowTheAppLanguage() {
        #expect(FileKindCatalog.all.map(\.folderName) == [
            "Image", "Movie", "Music", "PDF", "Text", "Document", "Presentation",
            "Archive", "Disk Image", "Folder", "Application",
        ])
        #expect(ActionExecutor.noExtensionFolderName == "No Extension")
    }

    @Test func folderUsesTheFolderKind() throws {
        let dir = TempDir()
        let folder = dir.dir("Project")
        let target = try plannedTarget(.moveToFolder, dir.path + "/Sorted/{kind}/{extension}", path: folder)
        #expect(target == dir.path + "/Sorted/Folder/No Extension/Project")
    }

    @Test(arguments: [(9, 5, "09h05"), (0, 0, "00h00"), (23, 59, "23h59")])
    func hourAndMinuteAreZeroPaddedOn24Hours(time: (hour: Int, minute: Int, expected: String)) throws {
        let dir = TempDir()
        let path = dir.file("scan.pdf", contents: "x")
        try setCreationDate(path, hour: time.hour, minute: time.minute)
        let target = try plannedTarget(.moveToFolder, dir.path + "/{year}-{month}-{day} {hour}h{minute}", path: path)
        #expect(target == dir.path + "/2026-03-07 \(time.expected)/scan.pdf")
    }

    @Test(arguments: ["preview", "manual", "watcher"], [ActionKind.moveToFolder, .copyToFolder])
    func persistedTokensResolveTheSameOnEveryExecutionPath(execution: String, kind: ActionKind) throws {
        let dir = TempDir()
        let input = dir.dir("Input")
        let output = dir.dir("Sorted")
        let path = dir.file("Input/Invoice.PDF", contents: "invoice")
        try setCreationDate(path, hour: 8, minute: 30)
        let destination = output + "/{kind}/{extension}/{hour}h{minute}"
        let expected = output + "/PDF/pdf/08h30/Invoice.PDF"
        let folder = WatchedFolder(path: input)
        var rule = makeRule(folderId: folder.id, name: "Sort by type")
        rule.conditions = [makeCondition(.kind, .is, "pdf", ruleId: rule.id)]
        rule.actions = [makeAction(kind, .object([ActionParam.destination: .string(destination)]), ruleId: rule.id)]
        let databasePath = dir.path + "/rules.db"
        do {
            let saved = try Database(path: databasePath)
            try saved.insertFolder(folder)
            try saved.insertRule(rule)
        }
        let db = try Database(path: databasePath)
        let rules = try db.executionRules(folderID: folder.id, isPro: false)
        #expect(rules.first?.actions == rule.actions)
        if execution == "preview" {
            let entries = RuleEngine.walkEntries(root: input, maxDepth: RuleEngine.maxRuleDepth(rules))
            let previews = entries.compactMap {
                RuleEngine.previewFile(path: $0.path, depth: $0.depth, rules: rules, root: input, isPro: false)
            }
            let preview = try #require(previews.first)
            #expect(previews.count == 1)
            #expect(preview.rules[0].actions[0].targetPath == expected)
            #expect(preview.rules[0].actions[0].status == .wouldRun)
            #expect(FileManager.default.fileExists(atPath: path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: output).isEmpty)
        } else {
            let history: [HistoryEntry]
            if execution == "manual" {
                history = RuleEngine.walkEntries(root: input, maxDepth: RuleEngine.maxRuleDepth(rules)).flatMap {
                    RuleEngine.run(path: $0.path, depth: $0.depth, rules: rules, batchId: "tokens", root: input, isPro: false).history
                }
            } else {
                let coordinator = WatcherCoordinator(db: db, settleInterval: 0.01)
                coordinator.enqueue(event: .pathArrived(path))
                coordinator.waitForPendingEvents()
                history = try db.listHistory()
            }
            #expect(history.map(\.status) == [.applied])
            #expect(history.first?.resultPath == expected)
            #expect(try String(contentsOfFile: expected, encoding: .utf8) == "invoice")
            #expect(FileManager.default.fileExists(atPath: path) == (kind == .copyToFolder))
        }
    }
}
