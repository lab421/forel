import Foundation
import Testing
@testable import ForelCore

@Suite struct FolderStructureTests {
    @Test func monitoredStructureMatchesPreviewManualAndWatcher() throws {
        let source = TempDir()
        let destination = TempDir()
        _ = source.dir("a/b")
        let preview = source.file("a/b/preview.txt", contents: "a")
        let manual = source.file("a/b/manual.txt", contents: "b")
        let watched = source.file("a/b/watched.txt", contents: "c")
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: source.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "copy", recursionDepth: nil)
        rule.actions = [makeAction(.copyToFolder, .object([ActionParam.destination: .string(destination.path), ActionParam.folderStructure: .string("monitored")]), ruleId: rule.id)]
        let result = try #require(RuleEngine.previewFile(path: preview, depth: 2, rules: [rule], root: source.path))
        #expect(result.rules.first?.actions.first?.targetPath == (destination.path as NSString).appendingPathComponent("a/b/preview.txt"))
        #expect(RuleEngine.run(path: manual, depth: 2, rules: [rule], batchId: "manual", root: source.path).history.first?.status == .applied)
        try db.insertRule(rule)
        WatcherCoordinator(db: db).handle(path: watched)
        #expect(try db.listHistory().first?.status == .applied)
        #expect(FileManager.default.fileExists(atPath: (destination.path as NSString).appendingPathComponent("a/b/manual.txt")))
        #expect(FileManager.default.fileExists(atPath: (destination.path as NSString).appendingPathComponent("a/b/watched.txt")))
    }

    @Test func structureOptionsAndEscapingSymlinkAreChecked() throws {
        let source = TempDir()
        let destination = TempDir()
        let outside = TempDir()
        _ = source.dir("a/b")
        let file = source.file("a/b/file.txt")
        let parent = makeAction(.moveToFolder, .object([ActionParam.destination: .string(destination.path), ActionParam.folderStructure: .string("parent")]))
        #expect(try ActionExecutor.plan(parent, path: file, watchedRoot: source.path).targetPath == (destination.path as NSString).appendingPathComponent("b/file.txt"))
        let monitored = makeAction(.copyToFolder, .object([ActionParam.destination: .string(destination.path), ActionParam.folderStructure: .string("monitored")]))
        #expect(throws: (any Error).self) { try ActionExecutor.plan(monitored, path: file) }
        let rootAction = makeAction(.copyToFolder, .object([ActionParam.destination: .string(destination.path), ActionParam.folderStructure: .string("root")]))
        let parentURL = URL(fileURLWithPath: file).standardizedFileURL.deletingLastPathComponent()
        let resourceValues = try parentURL.resourceValues(forKeys: [.volumeURLKey])
        let volume = try #require(resourceValues.volume)
        let relative = parentURL.resolvingSymlinksInPath().pathComponents.dropFirst(volume.standardizedFileURL.resolvingSymlinksInPath().pathComponents.count)
        let expected = relative.reduce(destination.path) { ($0 as NSString).appendingPathComponent($1) }
        #expect(try ActionExecutor.plan(rootAction, path: file).targetPath == (expected as NSString).appendingPathComponent("file.txt"))
        try FileManager.default.createSymbolicLink(atPath: (destination.path as NSString).appendingPathComponent("a"), withDestinationPath: outside.path)
        #expect(throws: (any Error).self) { try ActionExecutor.plan(monitored, path: file, watchedRoot: source.path) }
        #expect(throws: (any Error).self) { try ActionExecutor.execute(monitored, path: file, watchedRoot: source.path) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func duplicateCopySkipsWithoutRunningSubsequentHazelActions() throws {
        let source = TempDir()
        let destination = TempDir()
        let file = source.file("same.txt", contents: "identical")
        _ = destination.file("same.txt", contents: "identical")
        let copy = makeAction(.copyToFolder, .object([ActionParam.destination: .string(destination.path), ActionParam.skipDuplicates: .bool(true)]))
        var rule = makeRule(name: "copy", actions: [copy, makeAction(.delete, .object([:]), position: 1)])
        rule.isHazelImported = true
        let preview = try #require(RuleEngine.previewFile(path: file, depth: 0, rules: [rule]))
        #expect(preview.rules.first?.actions.count == 1)
        #expect(preview.rules.first?.actions.first?.status == .wouldSkip)
        let result = RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "copy")
        #expect(result.history.map(\.status) == [.skipped])
        #expect(FileManager.default.fileExists(atPath: file))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["same.txt"])
    }
}
