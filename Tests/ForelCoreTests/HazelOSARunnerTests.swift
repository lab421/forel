import Foundation
import Testing
@testable import ForelCore

@Suite struct HazelOSARunnerTests {
    @Test func resultPreflightRejectsDeepAndWideJSONBeforeDecoding() {
        #expect(HazelOSARunner.resultWithinLimits(Data(#"{"text":"[escaped \\\" ]","nested":[1,2]}"#.utf8)))
        #expect(!HazelOSARunner.resultWithinLimits(Data((String(repeating: "[", count: 33) + "0" + String(repeating: "]", count: 33)).utf8)))
        #expect(!HazelOSARunner.resultWithinLimits(Data(("[" + Array(repeating: "0", count: 30_002).joined(separator: ",") + "]").utf8)))
    }
    @Test func embeddedHandlersReceiveAliasAttributesAndReturnControl() throws {
        let dir = TempDir()
        let file = dir.file("matched ' file.txt")
        let samples: [(HazelOSARunner.Language, String)] = [
            (.appleScript, "return {hazelStop:true, hazelSwitchFile:theFile, hazelOutputAttributes:{value:item 1 of inputAttributes}}"),
            (.javaScript, "return {hazelStop:true, hazelSwitchFile:theFile, hazelOutputAttributes:{value:inputAttributes[0]}};")
        ]
        for (language, source) in samples {
            let result = try HazelOSARunner.run(language: language, source: .embedded(source), path: file, inputs: [.string("value ' test")])
            #expect(result.stop)
            #expect(URL(fileURLWithPath: try #require(result.switchPath)).resolvingSymlinksInPath() == URL(fileURLWithPath: file).resolvingSymlinksInPath())
            #expect(result.attributes["value"] == .string("value ' test"))
        }
    }

    @Test func compiledExternalHandlerReceivesBothArguments() throws {
        let dir = TempDir()
        let file = dir.file("matched.txt")
        let scripts: [(String, String, HazelOSARunner.Language)] = [
            ("AppleScript", "on hazelProcessFile(theFile, inputAttributes)\nreturn {hazelStop:(item 1 of inputAttributes is \"ok\")}\nend hazelProcessFile", .appleScript),
            ("JavaScript", "function hazelProcessFile(theFile, inputAttributes) { return {hazelStop: inputAttributes[0] === 'ok'}; }", .javaScript)
        ]
        for (language, source, expected) in scripts {
            let output = URL(fileURLWithPath: dir.path).appendingPathComponent("\(language).scpt")
            let compiler = Process()
            compiler.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
            compiler.arguments = ["-l", language, "-o", output.path, "-e", source]
            compiler.standardOutput = FileHandle.nullDevice
            compiler.standardError = FileHandle.nullDevice
            try compiler.run()
            compiler.waitUntilExit()
            #expect(compiler.terminationStatus == 0)
            let result = try HazelOSARunner.run(language: expected, source: .external(output.path), path: file, inputs: [.string("ok")])
            #expect(result.stop)
            let decompiled = try CompiledScriptInspection.source(from: Data(contentsOf: output))
            let converted = try HazelOSARunner.run(language: expected, source: .sourceHandler(decompiled), path: file, inputs: [.string("ok")])
            #expect(converted.stop)
        }
    }

    @Test func scriptOutputFeedsLaterScriptAndStopStopsChain() throws {
        let dir = TempDir()
        let folder = WatchedFolder(path: dir.path)
        let db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        let producer = makeAction(.runHazelOSA, .object([
            ActionParam.osaLanguage: .string("JavaScript"), ActionParam.script: .string("return {hazelOutputAttributes:{value:'expected'}};"),
            ActionParam.osaOutputs: .stringArray(["answer"])
        ]), position: 0)
        let consumer = makeAction(.runHazelOSA, .object([
            ActionParam.osaLanguage: .string("JavaScript"), ActionParam.script: .string("if (inputAttributes[0] !== 'expected') throw Error('missing input'); return {hazelStop:true};"),
            ActionParam.osaInputs: .stringArray(["answer"])
        ]), position: 1)
        var rule = makeRule(folderId: folder.id, name: "scripts", actions: [producer, consumer, makeAction(.delete, .object([:]), position: 2)])
        for index in rule.actions.indices { rule.actions[index].ruleId = rule.id }
        rule.isHazelImported = true
        let preview = dir.file("preview.txt")
        let manual = dir.file("manual.txt")
        let watched = dir.file("watched.txt")
        #expect(RuleEngine.previewFile(path: preview, depth: 0, rules: [rule])?.rules.first?.actions.count == 3)
        let run = RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "osa-output")
        #expect(run.history.map(\.status) == [.applied, .applied], "\(run.history.map(\.message))")
        #expect(FileManager.default.fileExists(atPath: manual))
        try db.insertRule(rule)
        WatcherCoordinator(db: db).handle(path: watched)
        #expect(try db.listHistory().map(\.status) == [.applied, .applied])
        #expect(FileManager.default.fileExists(atPath: watched))
    }

    @Test func scriptSwitchesSubsequentActionTarget() throws {
        let dir = TempDir()
        let original = dir.file("original.txt")
        let next = dir.file("original.txt.next")
        let script = makeAction(.runHazelOSA, .object([
            ActionParam.osaLanguage: .string("JavaScript"),
            ActionParam.script: .string("return {hazelSwitchFile:Path(theFile.toString()+'.next')};")
        ]))
        let applied = try ActionExecutor.execute(script, path: original)
        #expect(URL(fileURLWithPath: applied.newPath).resolvingSymlinksInPath() == URL(fileURLWithPath: next).resolvingSymlinksInPath())
        #expect(FileManager.default.fileExists(atPath: original))
    }

    @Test func switchingOutsideWatchedRootStopsLaterRulesButContinuesCurrentActions() throws {
        let root = TempDir()
        let outside = TempDir()
        let original = root.file("original.txt")
        let target = outside.file("target.txt")
        let script = makeAction(.runHazelOSA, .object([
            ActionParam.osaLanguage: .string("JavaScript"),
            ActionParam.script: .string("return {hazelSwitchFile:Path('\(target)')};")
        ]), position: 0)
        var first = makeRule(name: "first", actions: [script, makeAction(.rename, .object([ActionParam.pattern: .string("renamed.txt")]), position: 1), makeAction(.hazelContinue, .object([:]), position: 2)])
        first.isHazelImported = true
        var second = makeRule(name: "later")
        second.isHazelImported = true
        let result = RuleEngine.run(path: original, depth: 0, rules: [first, second], batchId: "switch", root: root.path)
        #expect(result.matched == ["first"])
        #expect(result.history.map(\.status) == [.applied, .applied])
        #expect(FileManager.default.fileExists(atPath: (outside.path as NSString).appendingPathComponent("renamed.txt")))
        #expect(FileManager.default.fileExists(atPath: original))
    }

    @Test func dateAttributesRoundTripThroughBothLanguages() throws {
        let dir = TempDir()
        let file = dir.file("date.txt")
        let inputs: [JSONValue] = [.object(["__forelDate": .number(1_700_000_000)])]
        let samples: [(HazelOSARunner.Language, String)] = [
            (.appleScript, "return {hazelOutputAttributes:{value:item 1 of inputAttributes}}"),
            (.javaScript, "return {hazelOutputAttributes:{value:inputAttributes[0]}};")
        ]
        for (language, source) in samples {
            let result = try HazelOSARunner.run(language: language, source: .embedded(source), path: file, inputs: inputs)
            guard case .number(let seconds) = result.attributes["value"]?["__forelDate"] else {
                Issue.record("Script did not return a typed date")
                continue
            }
            #expect(abs(seconds - 1_700_000_000) < 1)
        }
    }

    @Test func conditionScriptsReturnBooleanOrRecordAndErrorsRemainErrors() throws {
        let dir = TempDir()
        let file = dir.file("condition.txt")
        for (language, source) in [(HazelOSARunner.Language.appleScript, "return {hazelPassesScript:true, hazelOutputAttributes:{value:item 1 of inputAttributes}}"),
                                   (.javaScript, "return {hazelPassesScript:true, hazelOutputAttributes:{value:inputAttributes[0]}};")] {
            let result = try HazelOSARunner.run(language: language, source: .embedded(source), path: file, inputs: [.string("match")], purpose: .condition)
            #expect(result.passes == true)
            #expect(result.orderedAttributes == [.string("match")])
        }
        let noMatch = try HazelOSARunner.run(language: .javaScript, source: .embedded("return false;"), path: file, inputs: [], purpose: .condition)
        #expect(noMatch.passes == false)
        #expect(throws: (any Error).self) {
            try HazelOSARunner.run(language: .javaScript, source: .embedded("throw Error('intentional');"), path: file, inputs: [], purpose: .condition)
        }
    }

    @Test func modernPublicExportsRemainDisabledAndInert() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_SHELL_CORPUS"] else { return }
        for (file, language) in [("hazel-samples-3/Screen Shots.hazelrules", "AppleScript"), ("hazel-photos/google_photos.hazelrules", "JavaScript")] {
            let result = try RuleTransfer.importRules(from: Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(file)), folderId: "folder")
            let rule = try #require(result.rules.first { $0.actions.contains { $0.kind == .runHazelOSA } }, "\(file)")
            #expect(!rule.enabled)
            let action = try #require(rule.actions.first { $0.kind == .runHazelOSA })
            #expect(action.params[ActionParam.osaLanguage]?.stringValue == language)
            #expect(action.params[ActionParam.osaMode]?.stringValue == "compiled")
        }
    }
}
