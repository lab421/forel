// Forel - A native macOS file-automation app
// Copyright (C) 2026 Lab421

import Foundation
import Testing
@testable import ForelCore

@Suite struct HazelAppleScriptTests {
    private func linkedRule(folderId: String, name: String, actions: [Action]) -> Rule {
        var rule = makeRule(folderId: folderId, name: name)
        rule.actions = actions.map { action in
            var copy = action
            copy.ruleId = rule.id
            return copy
        }
        return rule
    }

    private func compiledAction(_ source: String, directory: TempDir) throws -> Action {
        let output = URL(fileURLWithPath: directory.path).appendingPathComponent("fixture.scpt")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        process.arguments = ["-o", output.path, "-e", source]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let data = try Data(contentsOf: output)
        return makeAction(.runHazelAppleScript, .object([ActionParam.compiledAppleScript: .string(data.base64EncodedString())]))
    }

    @Test func inspectedLegacyScriptCanBeConvertedWithoutRunningDuringInspection() throws {
        let dir = TempDir()
        let target = dir.file("fixture.txt", contents: "before")
        let compiled = try compiledAction("""
        on hazelProcessFile(theFile)
            set f to open for access theFile with write permission
            set eof f to 0
            write "after" to f
            close access f
            return {hazelStop:true}
        end hazelProcessFile
        """, directory: dir)
        let encoded = try #require(compiled.params[ActionParam.compiledAppleScript]?.stringValue)
        let data = try #require(Data(base64Encoded: encoded))
        let source = try CompiledScriptInspection.source(from: data)
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "before")
        let converted = makeAction(.runHazelOSA, .object([
            ActionParam.osaLanguage: .string("AppleScript"), ActionParam.osaMode: .string("legacySource"),
            ActionParam.script: .string(source), ActionParam.compiledAppleScript: .string(encoded)
        ]))
        let result = try ActionExecutor.execute(converted, path: target)
        #expect(result.stopsActionChain)
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "after")
        #expect(converted.params[ActionParam.compiledAppleScript]?.stringValue == encoded)
    }

    @Test func publicCompiledScriptsArePreservedWithoutExecution() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_CORPUS"] else { return }
        var count = 0
        for name in ["Statements.hazelrules", "Incoming Documents.hazelrules", "To Evernote.hazelrules"] {
            let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(name))
            let result = try RuleTransfer.importRules(from: data, folderId: "folder")
            for rule in result.rules {
                for action in rule.actions where action.kind == .runHazelAppleScript {
                    count += 1
                    let encoded = try #require(action.params[ActionParam.compiledAppleScript]?.stringValue)
                    let compiled = try #require(Data(base64Encoded: encoded))
                    #expect(compiled.starts(with: Data("Fasd".utf8)))
                    #expect(!rule.enabled)
                    #expect(result.issues.contains { $0.ruleName == rule.name && $0.message.contains("Review the imported AppleScript") })
                }
            }
        }
        #expect(count == 9)
    }

    @Test func publicRulesRunWithHarmlessScriptSubstituted() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["FOREL_HAZEL_CORPUS"], testTrashDirectory() != nil else { return }
        let compiler = TempDir()
        let harmless = try compiledAction("""
        on hazelProcessFile(theFile)
            set fileHandle to open for access theFile with write permission
            set eof fileHandle to 0
            write "processed" to fileHandle
            close access fileHandle
        end hazelProcessFile
        """, directory: compiler)
        var tested = 0
        for export in ["Statements.hazelrules", "Incoming Documents.hazelrules", "To Evernote.hazelrules"] {
            let imported = try RuleTransfer.importRules(from: Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(export)), folderId: "folder")
            for original in imported.rules where original.importError == nil && original.actions.contains(where: { $0.kind == .runHazelAppleScript }) {
                let source = TempDir()
                let destination = TempDir()
                let folder = WatchedFolder(path: source.path)
                let db = try Database(path: ":memory:")
                try db.insertFolder(folder)
                var rule = original
                rule.folderId = folder.id
                rule.enabled = true
                for index in rule.actions.indices {
                    if rule.actions[index].kind == .moveToFolder {
                        rule.actions[index].params = .object([ActionParam.destination: .string(destination.path)])
                    } else if rule.actions[index].kind == .runHazelAppleScript {
                        rule.actions[index].params = harmless.params
                    }
                }
                let condition = rule.conditions.first
                let prefix = condition?.kind == .nameInsensitive ? (condition?.value ?? "sample") : "sample"
                let text = condition?.kind == .contents ? "Account: \(condition?.value ?? "")" : "original"
                func fixture(_ suffix: String) throws -> String {
                    let file = source.file("\(prefix)-\(suffix).txt", contents: text)
                    if condition?.kind == .createdAt {
                        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-90 * 86400)], ofItemAtPath: file)
                    }
                    return file
                }
                let preview = try fixture("preview")
                let manual = try fixture("manual")
                let watched = try fixture("watcher")
                if condition?.kind == .anyFile {
                    let match = source.file("unrelated.txt", contents: "unrelated")
                    #expect(RuleEngine.previewFile(path: match, depth: 0, rules: [rule]) != nil, "\(rule.name)")
                } else if condition != nil {
                    let nonmatch = source.file("unrelated.txt", contents: "unrelated")
                    #expect(RuleEngine.previewFile(path: nonmatch, depth: 0, rules: [rule]) == nil, "\(rule.name)")
                }
                let plan = try #require(RuleEngine.previewFile(path: preview, depth: 0, rules: [rule]), "\(rule.name)")
                #expect(plan.rules.first?.actions.count == rule.actions.count, "\(rule.name)")
                #expect(plan.rules.first?.actions.allSatisfy { $0.status == .wouldRun } == true, "\(rule.name)")
                #expect(try String(contentsOfFile: preview, encoding: .utf8) == text)
                let run = RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "substituted-script")
                #expect(run.history.count == rule.actions.count, "\(rule.name)")
                #expect(run.history.allSatisfy { $0.status == .applied }, "\(rule.name): \(run.history.map(\.message))")
                let result = try #require(run.history.last?.resultPath)
                #expect(try String(contentsOfFile: result, encoding: .utf8) == "processed")
                try db.insertRule(rule)
                WatcherCoordinator(db: db).handle(path: watched)
                let history = try db.listHistory()
                #expect(history.count == rule.actions.count, "\(rule.name)")
                #expect(history.allSatisfy { $0.status == .applied }, "\(rule.name): \(history.map(\.message))")
                let final = try #require(history.first { $0.actionKind == rule.actions.last?.kind }?.resultPath)
                #expect(try String(contentsOfFile: final, encoding: .utf8) == "processed")
                tested += 1
            }
        }
        #expect(tested == 9)
    }

    @Test func harmlessCompiledHandlerRunsAcrossExecutionPaths() throws {
        let source = """
        on hazelProcessFile(theFile)
            set fileHandle to open for access theFile with write permission
            set eof fileHandle to 0
            write "processed" to fileHandle
            close access fileHandle
        end hazelProcessFile
        """
        let compiler = TempDir()
        let action = try compiledAction(source, directory: compiler)
        let directory = TempDir()
        let folder = WatchedFolder(path: directory.path)
        let db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        let rule = linkedRule(folderId: folder.id, name: "script", actions: [action])
        let preview = directory.file("preview's file.txt", contents: "before")
        let manual = directory.file("manual's file.txt", contents: "before")
        let watched = directory.file("watcher's file.txt", contents: "before")
        #expect(RuleEngine.previewFile(path: preview, depth: 0, rules: [rule])?.rules.first?.actions.first?.status == .wouldRun)
        #expect(try String(contentsOfFile: preview, encoding: .utf8) == "before")
        let run = RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "script")
        #expect(run.history.first?.status == .applied, "\(run.history.first?.message ?? "")")
        #expect(try String(contentsOfFile: manual, encoding: .utf8) == "processed")
        try db.insertRule(rule)
        WatcherCoordinator(db: db).handle(path: watched)
        #expect(try db.listHistory().first?.status == .applied)
        #expect(try String(contentsOfFile: watched, encoding: .utf8) == "processed")
    }

    @Test func failedHandlerStopsLaterActions() throws {
        let compiler = TempDir()
        let action = try compiledAction("on hazelProcessFile(theFile)\nerror \"deliberate test failure\"\nend hazelProcessFile", directory: compiler)
        let directory = TempDir()
        let folder = WatchedFolder(path: directory.path)
        let db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        let rule = linkedRule(folderId: folder.id, name: "failure", actions: [action, makeAction(.moveToTrash, .object([:]), position: 1)])
        let preview = directory.file("preview.txt")
        let manual = directory.file("manual.txt")
        let watched = directory.file("watcher.txt")
        #expect(RuleEngine.previewFile(path: preview, depth: 0, rules: [rule])?.rules.first?.actions.count == 2)
        let run = RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "failed-script")
        #expect(run.history.map(\.status) == [.failed])
        #expect(run.history.first?.message?.contains("deliberate test failure") == true)
        try db.insertRule(rule)
        WatcherCoordinator(db: db).handle(path: watched)
        #expect(try db.listHistory().map(\.status) == [.failed])
        for path in [preview, manual, watched] { #expect(FileManager.default.fileExists(atPath: path)) }
    }

    @Test func returnedControlRecordStopsLaterActions() throws {
        let compiler = TempDir()
        let action = try compiledAction("on hazelProcessFile(theFile)\nreturn {hazelStop:true}\nend hazelProcessFile", directory: compiler)
        let directory = TempDir()
        let folder = WatchedFolder(path: directory.path)
        let db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        let rule = linkedRule(folderId: folder.id, name: "returned record", actions: [action, makeAction(.moveToTrash, .object([:]), position: 1)])
        let manual = directory.file("manual.txt")
        let watched = directory.file("watcher.txt")
        let run = RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "script-record")
        #expect(run.history.map(\.status) == [.applied])
        try db.insertRule(rule)
        WatcherCoordinator(db: db).handle(path: watched)
        #expect(try db.listHistory().map(\.status) == [.applied])
        #expect(FileManager.default.fileExists(atPath: manual))
        #expect(FileManager.default.fileExists(atPath: watched))
    }

    @Test func earlierConflictStopsScriptInPreviewAndExecution() throws {
        let compiler = TempDir()
        var action = try compiledAction("on hazelProcessFile(theFile)\nerror \"must not run\"\nend hazelProcessFile", directory: compiler)
        action.position = 1
        let directory = TempDir()
        _ = directory.file("occupied.txt")
        let folder = WatchedFolder(path: directory.path)
        let db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        let rule = linkedRule(folderId: folder.id, name: "conflict", actions: [
            makeAction(.rename, .object([ActionParam.pattern: .string("occupied")]), position: 0),
            action,
            makeAction(.moveToTrash, .object([:]), position: 2),
        ])
        let preview = directory.file("preview.txt")
        let manual = directory.file("manual.txt")
        let watched = directory.file("watcher.txt")
        #expect(RuleEngine.previewFile(path: preview, depth: 0, rules: [rule])?.rules.first?.actions.map(\.status) == [.blockedByConflict])
        let run = RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "conflict")
        #expect(run.history.map(\.status) == [.failed])
        try db.insertRule(rule)
        WatcherCoordinator(db: db).handle(path: watched)
        #expect(try db.listHistory().map(\.status) == [.failed])
        for path in [preview, manual, watched] { #expect(FileManager.default.fileExists(atPath: path)) }
    }
}
