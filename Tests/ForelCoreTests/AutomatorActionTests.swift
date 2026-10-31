import Foundation
import Testing
@testable import ForelCore

@Suite struct AutomatorActionTests {
    private final class Platform: ActionPlatform, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [(String, String)] = []
        func runWorkflow(workflowPath: String, inputPath: String) throws {
            lock.lock(); defer { lock.unlock() }; values.append((workflowPath, inputPath))
        }
        func results() -> [(String, String)] { lock.lock(); defer { lock.unlock() }; return values }
        func open(path: String, application: String?, passFile: Bool, bringToFront: Bool) throws {}
        func showInFinder(path: String, bringToFront: Bool) throws {}
        func notify(text: String, sound: Bool) throws {}
        func pause(seconds: TimeInterval) throws {}
        func trash(path: String) throws -> String { path }
    }

    @Test func workflowReceivesMatchedPathInManualAndWatcherButNotPreview() throws {
        let dir = TempDir()
        let folder = WatchedFolder(path: dir.path)
        let db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        let platform = Platform()
        let action = makeAction(.runWorkflow, .object([ActionParam.workflowPath: .string("/tmp/example workflow.workflow")]))
        var rule = makeRule(folderId: folder.id, name: "workflow", actions: [action])
        rule.actions[0].ruleId = rule.id
        let preview = dir.file("preview.txt")
        let manual = dir.file("manual file.txt")
        let watched = dir.file("watched file.txt")
        #expect(RuleEngine.previewFile(path: preview, depth: 0, rules: [rule])?.rules.first?.actions.first?.status == .wouldRun)
        #expect(platform.results().isEmpty)
        #expect(RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "workflow", platform: platform).history.first?.status == .applied)
        try db.insertRule(rule)
        WatcherCoordinator(db: db, actionPlatform: platform).handle(path: watched)
        let calls = platform.results()
        #expect(calls.count == 2)
        #expect(calls.map(\.0) == ["/tmp/example workflow.workflow", "/tmp/example workflow.workflow"])
        #expect(calls.map(\.1) == [manual, watched])
    }

    @Test func realTemporaryWorkflowReceivesFileURLWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["FOREL_AUTOMATOR_INTEGRATION"] == "1" else { return }
        let dir = TempDir()
        let input = dir.file("input ' file.txt")
        let workflow = (dir.path as NSString).appendingPathComponent("fixture.workflow")
        let output = (dir.path as NSString).appendingPathComponent("observed.txt")
        let quoted = "'" + output.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = "printf '%s' \"$1\" > \(quoted)"
        let creator = #"""
        ObjC.import('Automator'); ObjC.import('Foundation');
        function run(a) {
          const action=$.AMAction.alloc.initWithContentsOfURLError($.NSURL.fileURLWithPath('/System/Library/Automator/Run Shell Script.action'),Ref());
          if (action.isNil()) throw Error('Cannot create test action');
          action.parameters.setObjectForKey($.NSString.stringWithString(a[1]),'source');
          action.parameters.setObjectForKey($.NSString.stringWithString(a[1]),'COMMAND_STRING');
          action.parameters.setObjectForKey($.NSNumber.numberWithInt(1),'inputMethod');
          const workflow=$.AMWorkflow.alloc.init; workflow.addAction(action);
          if (!workflow.writeToURLError($.NSURL.fileURLWithPath(a[0]),Ref())) throw Error('Cannot save test workflow');
        }
        """#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", creator, "--", workflow, command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        try AutomatorRunner.run(workflowPath: workflow, inputPath: input)
        let received = try String(contentsOfFile: output, encoding: .utf8)
        let url = try #require(URL(string: received))
        #expect(url.isFileURL)
        #expect(url.resolvingSymlinksInPath() == URL(fileURLWithPath: input).resolvingSymlinksInPath())
    }
}
