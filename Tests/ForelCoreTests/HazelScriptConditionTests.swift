import Foundation
import Testing
@testable import ForelCore

@Suite struct HazelScriptConditionTests {
    @Test func compiledConditionInspectionAndExplicitSourceConversion() throws {
        let dir = TempDir(), file = dir.file("fixture.txt")
        let output = URL(fileURLWithPath: dir.path).appendingPathComponent("condition.scpt")
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        compiler.arguments = ["-l", "JavaScript", "-o", output.path, "-e", "function hazelMatchFile(theFile, inputAttributes) { return true; }"]
        compiler.standardOutput = FileHandle.nullDevice; compiler.standardError = FileHandle.nullDevice
        try compiler.run(); compiler.waitUntilExit()
        #expect(compiler.terminationStatus == 0)
        let original = try Data(contentsOf: output)
        var spec = HazelScriptCondition(language: .javaScript, compiledData: original.base64EncodedString())
        let source = try CompiledScriptInspection.source(from: original)
        #expect(spec.compiledData == original.base64EncodedString())
        spec.compiledData = nil; spec.source = source; spec.sourceIsHandler = true
        #expect(spec.validationError == nil)
        #expect(try HazelScriptConditionRunner.run(spec: spec, path: file, attributes: [:]).matched)
        let decoded = try #require(HazelScriptCondition.decode(spec.encoded))
        #expect(decoded.sourceIsHandler == true && decoded.source == source)
    }
    @Test func shellConditionsPassTheMatchedPathAndHonorExitStatus() throws {
        let directory = TempDir()
        let path = directory.file("a file.txt")
        let yes = HazelScriptCondition(source: "test -f \"$1\"", interpreter: "/bin/bash")
        #expect(try HazelScriptConditionRunner.run(spec: yes, path: path, attributes: [:]).matched)
        let no = HazelScriptCondition(source: "exit 7", interpreter: "/bin/bash")
        #expect(try !HazelScriptConditionRunner.run(spec: no, path: path, attributes: [:]).matched)
        let signaled = HazelScriptCondition(source: "kill -TERM $$", interpreter: "/bin/bash")
        #expect(throws: ActionError.self) { try HazelScriptConditionRunner.run(spec: signaled, path: path, attributes: [:]) }
        let missing = HazelScriptCondition(source: "true", interpreter: "/no/such/interpreter")
        #expect(throws: ActionError.self) { try HazelScriptConditionRunner.run(spec: missing, path: path, attributes: [:]) }
        let external = directory.file("external.sh", contents: "#!/bin/bash\ntest -f \"$1\"\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: external)
        let externalSpec = HazelScriptCondition(externalPath: external)
        #expect(try HazelScriptConditionRunner.run(spec: externalSpec, path: path, attributes: [:]).matched)
    }

    @Test func validatesSourceAndAttributeConfiguration() {
        #expect(HazelScriptCondition().validationError != nil)
        #expect(HazelScriptCondition(source: "true", interpreter: "relative").validationError != nil)
        #expect(HazelScriptCondition(language: .shell, source: "true", inputNames: ["name"]).validationError != nil)
        #expect(HazelScriptCondition(language: .javaScript, source: "return true", outputNames: ["a", "a"]).validationError != nil)
    }

    @Test func ticklerShellPredicateIsImportedInertly() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_TICKLER"] else { return }
        let url = URL(fileURLWithPath: root).appendingPathComponent("tickler.hazelrules")
        let imported = try RuleTransfer.importRules(from: Data(contentsOf: url), folderId: "f")
        let condition = try #require(imported.rules.flatMap(\.conditions).first { $0.kind == .hazelScriptCondition })
        let spec = try #require(HazelScriptCondition.decode(condition.value))
        #expect(spec.language == .shell && spec.interpreter == "/bin/bash")
        #expect(spec.source.contains("FILEDAY=") && spec.source.contains("exit 1"))
        #expect(imported.rules.allSatisfy { !$0.enabled })
    }

    @Test func scriptConditionRunsOnceDuringPreviewManualAndWatcher() throws {
        let directory = TempDir()
        let folder = WatchedFolder(path: directory.path)
        let db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "script condition")
        rule.isHazelImported = true
        let script = HazelScriptCondition(source: "printf x >> \"$1.marker\"", interpreter: "/bin/bash")
        rule.conditions = [Condition(ruleId: rule.id, kind: .hazelScriptCondition, operator: .is, value: script.encoded)]
        rule.actions = [Action(ruleId: rule.id, kind: .rename, params: .object([ActionParam.pattern: .string("done-{name}")]), position: 0)]
        let preview = directory.file("preview.txt"), manual = directory.file("manual.txt"), watched = directory.file("watched.txt")
        let plan = try #require(RuleEngine.previewFile(path: preview, depth: 0, rules: [rule]))
        #expect(plan.rules.first?.actions.first?.status == .wouldRun)
        #expect(FileManager.default.fileExists(atPath: preview))
        #expect(try String(contentsOfFile: preview + ".marker", encoding: .utf8) == "x")
        #expect(RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "shell-condition").history.first?.status == .applied)
        #expect(try String(contentsOfFile: manual + ".marker", encoding: .utf8) == "x")
        try db.insertRule(rule)
        WatcherCoordinator(db: db).handle(path: watched)
        #expect(try String(contentsOfFile: watched + ".marker", encoding: .utf8) == "x")
        #expect(FileManager.default.fileExists(atPath: "\(directory.path)/done-watched.txt"))
    }

    @Test func conditionScriptLaunchFailurePreventsDestructiveAction() throws {
        let directory = TempDir()
        let file = directory.file("file.txt")
        var rule = makeRule(folderId: "f", name: "failed condition")
        rule.isHazelImported = true
        let script = HazelScriptCondition(source: "true", interpreter: "/no/such/interpreter")
        rule.conditions = [Condition(ruleId: rule.id, kind: .hazelScriptCondition, operator: .is, value: script.encoded)]
        rule.actions = [Action(ruleId: rule.id, kind: .delete, params: .object([:]), position: 0)]
        let preview = try #require(RuleEngine.previewFile(path: file, depth: 0, rules: [rule]))
        #expect(preview.rules.first?.actions.first?.status == .blocked)
        let run = RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "failed-condition")
        #expect(run.history.first?.status == .failed)
        #expect(FileManager.default.fileExists(atPath: file))
    }
}
