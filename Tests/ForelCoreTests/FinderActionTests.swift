import Foundation
import Testing
@testable import ForelCore

@Suite struct FinderActionTests {
    private func key(_ kind: ActionKind) -> String {
        kind == .toggleLock ? ActionParam.locked : ActionParam.extensionHidden
    }

    private func state(_ kind: ActionKind, path: String) throws -> Bool {
        let values = try URL(fileURLWithPath: path).resourceValues(forKeys: [.isUserImmutableKey, .hasHiddenExtensionKey])
        return try #require(kind == .toggleLock ? values.isUserImmutable : values.hasHiddenExtension)
    }

    private func setState(_ kind: ActionKind, path: String, value: Bool) throws {
        var url = URL(fileURLWithPath: path)
        var values = URLResourceValues()
        if kind == .toggleLock { values.isUserImmutable = value }
        else { values.hasHiddenExtension = value }
        try url.setResourceValues(values)
    }

    @Test(arguments: [ActionKind.toggleLock, .toggleExtension], [false, true])
    func supportsBothDirectionsAndUndo(kind: ActionKind, isFolder: Bool) throws {
        let dir = TempDir()
        let path = isFolder ? dir.dir("Project.folder") : dir.file("report.txt", contents: "report")
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: path) }
        for target in [true, false] {
            try setState(kind, path: path, value: !target)
            let action = makeAction(kind, .object([key(kind): .bool(target)]))
            #expect(RuleSchema.actionKinds.contains(kind))
            #expect(RuleValidator.validate([action]).isEmpty)
            #expect(try ActionExecutor.plan(action, path: path).status == .wouldRun)
            #expect(try state(kind, path: path) == !target)
            let applied = try ActionExecutor.execute(action, path: path)
            #expect(applied.newPath == path)
            #expect(try state(kind, path: path) == target)
            #expect(try ActionExecutor.plan(action, path: path).status == .wouldSkip)
            #expect(!ActionExecutor.wouldChange(action, path: path))
            #expect(Undo.fromJSON(applied.undo.toJSON()) == applied.undo)
            try ActionExecutor.revert(Undo.fromJSON(applied.undo.toJSON()))
            #expect(try state(kind, path: path) == !target)
            #expect(FileManager.default.fileExists(atPath: path))
            if !isFolder { #expect(try String(contentsOfFile: path, encoding: .utf8) == "report") }
        }
    }

    @Test(arguments: ["preview", "manual", "watcher"], [ActionKind.toggleLock, .toggleExtension])
    func persistedRulesAndHistoryAcrossExecutionPaths(execution: String, kind: ActionKind) throws {
        for target in [true, false] {
            let dir = TempDir()
            let input = dir.dir("Input")
            let path = dir.file("Input/report.txt", contents: "report")
            defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: path) }
            try setState(kind, path: path, value: !target)
            let folder = WatchedFolder(path: input)
            var rule = makeRule(folderId: folder.id, name: kind.label)
            rule.conditions = [makeCondition(.extension_, .is, "txt", ruleId: rule.id)]
            rule.actions = [makeAction(kind, .object([key(kind): .bool(target)]), ruleId: rule.id)]
            let databasePath = dir.path + "/rules.db"
            do {
                let saved = try Database(path: databasePath)
                try saved.insertFolder(folder)
                try saved.insertRule(rule)
            }
            let db = try Database(path: databasePath)
            let rules = try db.executionRules(folderID: folder.id, isPro: false)
            #expect(rules.first?.actions == rule.actions)
            let entries = RuleEngine.walkEntries(root: input, maxDepth: RuleEngine.maxRuleDepth(rules))
            if execution == "preview" {
                let previews = entries.compactMap {
                    RuleEngine.previewFile(path: $0.path, depth: $0.depth, rules: rules, root: input, isPro: false)
                }
                let preview = try #require(previews.first)
                #expect(previews.count == 1)
                #expect(preview.rules[0].actions[0].kind == kind)
                #expect(preview.rules[0].actions[0].status == .wouldRun)
                #expect(try state(kind, path: path) == !target)
            } else {
                if execution == "manual" {
                    let history = entries.flatMap {
                        RuleEngine.run(path: $0.path, depth: $0.depth, rules: rules, batchId: "manual", root: input, isPro: false).history
                    }
                    try db.insertHistoryEntries(history)
                } else {
                    let coordinator = WatcherCoordinator(db: db, settleInterval: 0.01)
                    for entry in entries { coordinator.enqueue(event: .pathArrived(entry.path)) }
                    coordinator.waitForPendingEvents()
                }
                let reopened = try Database(path: databasePath)
                let history = try reopened.listHistory()
                #expect(history.map(\.status) == [.applied])
                let entry = try #require(history.first)
                #expect(entry.actionKind == kind)
                #expect(entry.reversible)
                #expect(try state(kind, path: path) == target)
                #expect(UndoChecker.evaluate(entry) == .safe)
                // A repeated run sets the requested state rather than flipping it.
                let repeated = RuleEngine.run(path: path, depth: 0, rules: rules, batchId: "repeat", root: input, isPro: false)
                #expect(repeated.history.map(\.status) == [.skipped])
                #expect(try state(kind, path: path) == target)
                try ActionExecutor.revert(Undo.fromJSON(entry.undo))
                #expect(try state(kind, path: path) == !target)
                var replaced = entry
                replaced.resultFileId = (entry.resultFileId ?? 0) + 1
                guard case .unsafe = UndoChecker.evaluate(replaced) else {
                    Issue.record("Undo must reject a replacement file")
                    return
                }
            }
        }
    }

    @Test(arguments: [ActionKind.toggleLock, .toggleExtension])
    func invalidParametersAndMissingFilesFailWithoutChanges(kind: ActionKind) throws {
        let dir = TempDir()
        let path = dir.file("report.txt")
        for params: JSONValue in [.object([:]), .object([key(kind): .string("false")])] {
            let action = makeAction(kind, params)
            #expect(!RuleValidator.validate([action]).isEmpty)
            #expect(throws: (any Error).self) { try ActionExecutor.execute(action, path: path) }
            #expect(throws: (any Error).self) { try ActionExecutor.plan(action, path: path) }
        }
        #expect(try !state(kind, path: path))
        let valid = makeAction(kind, .object([key(kind): .bool(true)]))
        #expect(throws: (any Error).self) { try ActionExecutor.execute(valid, path: dir.path + "/missing.txt") }
    }

    @Test func unlockAllowsLaterActionsInTheChain() throws {
        let dir = TempDir()
        let source = dir.file("report.txt", contents: "report")
        let renamed = dir.path + "/renamed.txt"
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: source)
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: renamed)
        }
        try setState(.toggleLock, path: source, value: true)
        let rule = makeRule(name: "Unlock and rename", conditions: [makeCondition(.locked, .isTrue, "")], actions: [
            makeAction(.toggleLock, .object([ActionParam.locked: .bool(false)])),
            makeAction(.rename, .object([ActionParam.pattern: .string("renamed")]), position: 1),
        ])
        let preview = try #require(RuleEngine.previewFile(path: source, depth: 0, rules: [rule]))
        #expect(preview.rules[0].actions.map(\.status) == [.wouldRun, .wouldRun])
        #expect(try state(.toggleLock, path: source))
        let result = RuleEngine.run(path: source, depth: 0, rules: [rule], batchId: "chain")
        #expect(result.history.map(\.status) == [.applied, .applied])
        #expect(FileManager.default.fileExists(atPath: renamed))
        #expect(try !state(.toggleLock, path: renamed))
        for entry in result.history.reversed() { try ActionExecutor.revert(Undo.fromJSON(entry.undo)) }
        #expect(try state(.toggleLock, path: source))
    }

    @Test(arguments: [ActionKind.toggleLock, .toggleExtension])
    func metadataActionFollowsRenameInPreviewAndExecution(kind: ActionKind) throws {
        let dir = TempDir()
        let source = dir.file("report.txt", contents: "report")
        let renamed = dir.path + "/renamed.txt"
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: source)
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: renamed)
        }
        let rule = makeRule(name: "Rename then update Finder", conditions: [makeCondition(.extension_, .is, "txt")], actions: [
            makeAction(.rename, .object([ActionParam.pattern: .string("renamed")])),
            makeAction(kind, .object([key(kind): .bool(true)]), position: 1),
        ])
        let preview = try #require(RuleEngine.previewFile(path: source, depth: 0, rules: [rule]))
        #expect(preview.rules[0].actions.map(\.status) == [.wouldRun, .wouldRun])
        #expect(FileManager.default.fileExists(atPath: source))
        #expect(!FileManager.default.fileExists(atPath: renamed))
        let result = RuleEngine.run(path: source, depth: 0, rules: [rule], batchId: "chain")
        #expect(result.history.map(\.status) == [.applied, .applied])
        #expect(try state(kind, path: renamed))
        for entry in result.history.reversed() { try ActionExecutor.revert(Undo.fromJSON(entry.undo)) }
        #expect(try !state(kind, path: source))
    }
}
