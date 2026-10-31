// Forel - A native macOS file-automation app
// Copyright (C) 2026 Lab421

import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ForelCore

@Suite struct HazelShellScriptTests {
    @Test func publicExportsPreserveInertScripts() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_SHELL_CORPUS"],
              let extras = ProcessInfo.processInfo.environment["FOREL_HAZEL_SHELL_EXTRAS"] else { return }
        let samples: [(String, String, String)] = [
            ("\(root)/hazel-open-url/to-open-url.hazelrules", "/bin/bash", "open `cat \"$1\"`"),
            ("\(root)/hazel-unzip/download.hazelrules", "/bin/zsh", "7z x \"$FILE\""),
            ("\(extras)/forel-hazel-heic2jpg/Downloads-HEIC2jpg.hazelrules", "/bin/zsh", "heic2jpg.sh \"$1\""),
            ("\(extras)/forel-hazel-jaxfry/modules/home/programs/hazel-backup/16777230-36143.hazelrules", "/bin/zsh", "xattr -dr com.apple.quarantine \"$1\"")
        ]
        for (file, interpreter, snippet) in samples {
            let result = try RuleTransfer.importRules(from: Data(contentsOf: URL(fileURLWithPath: file)), folderId: "folder")
            let rule = try #require(result.rules.first { $0.actions.contains { $0.kind == .runHazelShellScript } }, "\(file)")
            let script = try #require(rule.actions.first { $0.kind == .runHazelShellScript })
            #expect(!rule.enabled)
            #expect(rule.isHazelImported)
            #expect(script.params[ActionParam.shell]?.stringValue == interpreter)
            #expect(script.params[ActionParam.script]?.stringValue?.contains(snippet) == true)
            #expect(result.issues.contains { $0.ruleName == rule.name && $0.message.contains("Review the imported shell script") })
        }
    }

    @Test func reviewedQuarantineScriptRunsOnIsolatedFixtures() throws {
        guard let extras = ProcessInfo.processInfo.environment["FOREL_HAZEL_SHELL_EXTRAS"] else { return }
        let url = URL(fileURLWithPath: extras).appendingPathComponent("forel-hazel-jaxfry/modules/home/programs/hazel-backup/16777230-36143.hazelrules")
        let result = try RuleTransfer.importRules(from: Data(contentsOf: url), folderId: "folder")
        var rule = try #require(result.rules.first { $0.name == "FLAC dequarentine" })
        // Do not run a changed or unreviewed downloaded script.
        #expect(rule.actions.first?.params[ActionParam.script]?.stringValue == "xattr -dr com.apple.quarantine \"$1\"")
        guard rule.actions.first?.params[ActionParam.script]?.stringValue == "xattr -dr com.apple.quarantine \"$1\"" else { return }
        let directory = TempDir()
        let folder = WatchedFolder(path: directory.path)
        let db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        rule.folderId = folder.id
        rule.enabled = true
        func xattr(_ arguments: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        let preview = directory.file("preview.flac")
        let manual = directory.file("manual.flac")
        let watched = directory.file("watcher.flac")
        for file in [preview, manual, watched] {
            #expect(try xattr(["-w", "com.apple.quarantine", "0081;00000000;Forel;", file]) == 0)
        }
        // Some macOS installations have no FLAC type declaration. Preserve
        // both imported predicates and exercise only the action in that case.
        if UTType(filenameExtension: "flac")?.conforms(to: .audio) != true {
            #expect(RuleEngine.previewFile(path: preview, depth: 0, rules: [rule]) == nil)
            #expect(try xattr(["-p", "com.apple.quarantine", preview]) == 0)
            _ = try ActionExecutor.execute(try #require(rule.actions.first), path: manual)
            #expect(try xattr(["-p", "com.apple.quarantine", manual]) != 0)
            return
        }
        #expect(RuleEngine.previewFile(path: preview, depth: 0, rules: [rule])?.rules.first?.actions.first?.status == .wouldRun)
        #expect(try xattr(["-p", "com.apple.quarantine", preview]) == 0)
        let run = RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "flac-script")
        #expect(run.history.first?.status == .applied, "\(run.history.first?.message ?? "")")
        #expect(try xattr(["-p", "com.apple.quarantine", manual]) != 0)
        try db.insertRule(rule)
        WatcherCoordinator(db: db).handle(path: watched)
        #expect(try db.listHistory().first?.status == .applied)
        #expect(try xattr(["-p", "com.apple.quarantine", watched]) != 0)
    }

    private func action(_ source: String, shell: String = "/bin/zsh", position: Int64 = 0) -> Action {
        makeAction(.runHazelShellScript, .object([
            ActionParam.script: .string(source), ActionParam.shell: .string(shell)
        ]), position: position)
    }

    private func linkedRule(folderId: String, actions: [Action]) -> Rule {
        var rule = makeRule(folderId: folderId, name: "shell script")
        rule.actions = actions.map { action in
            var copy = action
            copy.ruleId = rule.id
            return copy
        }
        return rule
    }

    @Test func positionalPathAndInterpreterWorkAcrossExecutionPaths() throws {
        let directory = TempDir()
        let folder = WatchedFolder(path: directory.path)
        let db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        // The zsh-only syntax verifies the selected interpreter is used.
        let script = action("[[ -n $ZSH_VERSION ]] || exit 11\nprintf '%s' \"$1\" > \"$1\"")
        let rule = linkedRule(folderId: folder.id, actions: [script])
        let preview = directory.file("preview ' $ file.txt", contents: "before")
        let manual = directory.file("manual ' $ file.txt", contents: "before")
        let watched = directory.file("watcher ' $ file.txt", contents: "before")
        #expect(RuleEngine.previewFile(path: preview, depth: 0, rules: [rule])?.rules.first?.actions.first?.status == .wouldRun)
        #expect(try String(contentsOfFile: preview, encoding: .utf8) == "before")
        let run = RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "shell")
        #expect(run.history.first?.status == .applied, "\(run.history.first?.message ?? "")")
        #expect(try String(contentsOfFile: manual, encoding: .utf8) == manual)
        try db.insertRule(rule)
        WatcherCoordinator(db: db).handle(path: watched)
        #expect(try db.listHistory().first?.status == .applied)
        #expect(try String(contentsOfFile: watched, encoding: .utf8) == watched)
    }

    @Test func nonShellInterpreterReceivesOneArgument() throws {
        let directory = TempDir()
        let file = directory.file("one argument.txt", contents: "before")
        let script = action("die unless @ARGV == 1; open my $f, '>', $ARGV[0] or die $!; print $f $ARGV[0]; close $f;", shell: "/usr/bin/perl")
        _ = try ActionExecutor.execute(script, path: file)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == file)
    }

    @Test func externalExecutableReceivesMatchedPathAndPreviewIsInert() throws {
        let directory = TempDir()
        let matched = directory.file("matched ' file.txt", contents: "before")
        let script = directory.file("safe executable.sh", contents: "#!/bin/sh\nprintf '%s' \"$1\" > \"$1\"\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script)
        let action = makeAction(.runHazelShellScript, .object([
            ActionParam.shellMode: .string("external"), ActionParam.shellPath: .string(script)
        ]))
        #expect(try ActionExecutor.plan(action, path: matched).status == .wouldRun)
        #expect(try String(contentsOfFile: matched, encoding: .utf8) == "before")
        _ = try ActionExecutor.execute(action, path: matched)
        #expect(try String(contentsOfFile: matched, encoding: .utf8) == matched)
    }

    @Test func publicExternalAliasIsPreservedWithoutExecution() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_SHELL_CORPUS"] else { return }
        let url = URL(fileURLWithPath: root).appendingPathComponent("hazel-installer/Applications.hazelrules")
        let imported = try RuleTransfer.importRules(from: Data(contentsOf: url), folderId: "folder")
        let rule = try #require(imported.rules.first { $0.actions.contains { $0.kind == .runHazelShellScript } })
        let action = try #require(rule.actions.first { $0.kind == .runHazelShellScript })
        #expect(!rule.enabled)
        #expect(action.params[ActionParam.shellMode]?.stringValue == "external")
        #expect(action.params[ActionParam.shellPath]?.stringValue == "/usr/local/bin/archive_osx_installer_app")
        let encoded = try #require(action.params[ActionParam.shellBookmark]?.stringValue)
        #expect(Data(base64Encoded: encoded)?.count == 426_068)
        let directory = TempDir()
        let matched = directory.file("fixture.txt", contents: "unchanged")
        #expect(try ActionExecutor.plan(action, path: matched).status == .wouldRun)
        #expect(try String(contentsOfFile: matched, encoding: .utf8) == "unchanged")
        let missing = makeAction(.runHazelShellScript, .object([ActionParam.shellMode: .string("external"), ActionParam.shellPath: .string("/nonexistent-forel-test-script")]))
        #expect(throws: ActionError.self) { try ActionExecutor.execute(missing, path: matched) }
        #expect(try String(contentsOfFile: matched, encoding: .utf8) == "unchanged")
    }

    @Test func failureStopsLaterActionsOnManualAndWatcherRuns() throws {
        let directory = TempDir()
        let folder = WatchedFolder(path: directory.path)
        let db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        let rule = linkedRule(folderId: folder.id, actions: [action("echo deliberate-failure >&2; exit 42"), makeAction(.delete, .object([:]), position: 1)])
        let preview = directory.file("preview.txt")
        let manual = directory.file("manual.txt")
        let watched = directory.file("watcher.txt")
        #expect(RuleEngine.previewFile(path: preview, depth: 0, rules: [rule])?.rules.first?.actions.count == 2)
        let run = RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "failed-shell")
        #expect(run.history.map(\.status) == [.failed])
        #expect(run.history.first?.message?.contains("deliberate-failure") == true)
        try db.insertRule(rule)
        WatcherCoordinator(db: db).handle(path: watched)
        #expect(try db.listHistory().map(\.status) == [.failed])
        for path in [preview, manual, watched] { #expect(FileManager.default.fileExists(atPath: path)) }
    }

    @Test func invalidInterpreterIsNotExecutedInPreviewAndFailsAtRunTime() throws {
        let file = TempDir().file("file.txt")
        let script = action("exit 0", shell: "/does/not/exist")
        #expect(try ActionExecutor.plan(script, path: file).status == .wouldRun)
        #expect(throws: ActionError.self) { try ActionExecutor.execute(script, path: file) }
    }
}
