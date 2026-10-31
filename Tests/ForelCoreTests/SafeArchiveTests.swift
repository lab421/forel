import Foundation
import Darwin
import ZIPFoundation
import Testing
@testable import ForelCore

@Suite struct SafeArchiveTests {
    private struct Platform: ActionPlatform {
        var failTrash = false
        func open(path: String, application: String?, passFile: Bool, bringToFront: Bool) throws {}
        func showInFinder(path: String, bringToFront: Bool) throws {}
        func notify(text: String, sound: Bool) throws {}
        func pause(seconds: TimeInterval) throws {}
        func trash(path: String) throws -> String {
            if failTrash { throw ActionError("Injected Trash failure") }
            let target = path + ".trashed"
            try FileManager.default.moveItem(atPath: path, toPath: target)
            return target
        }
    }

    private func archive(in dir: TempDir, link: Bool = false, multiple: Bool = false) throws -> String {
        let source = dir.dir("source")
        let item = (source as NSString).appendingPathComponent("report.txt")
        if link { try FileManager.default.createSymbolicLink(atPath: item, withDestinationPath: "../outside") }
        else { try "content".write(toFile: item, atomically: true, encoding: .utf8) }
        if multiple { try "second".write(toFile: (source as NSString).appendingPathComponent("second.txt"), atomically: true, encoding: .utf8) }
        let result = (dir.path as NSString).appendingPathComponent("sample.tar.gz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-czf", result, "-C", source, "report.txt"] + (multiple ? ["second.txt"] : [])
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        try FileManager.default.removeItem(atPath: source)
        return result
    }

    @Test func compressedTarWorksInPreviewManualAndWatcher() throws {
        let action = makeAction(.uncompress, .object([:]))
        let previewDir = TempDir()
        let previewPath = try archive(in: previewDir)
        let rule = makeRule(name: "unarchive", actions: [action])
        let preview = try #require(RuleEngine.previewFile(path: previewPath, depth: 0, rules: [rule]))
        #expect(preview.rules.first?.actions.first?.status == .wouldRun)
        #expect(FileManager.default.fileExists(atPath: previewPath))

        let manualDir = TempDir()
        let manualPath = try archive(in: manualDir)
        let run = RuleEngine.run(path: manualPath, depth: 0, rules: [rule], batchId: "manual", platform: Platform())
        #expect(run.history.first?.status == .applied)
        #expect(try String(contentsOfFile: (manualDir.path as NSString).appendingPathComponent("report.txt"), encoding: .utf8) == "content")
        #expect(FileManager.default.fileExists(atPath: manualPath + ".trashed"))

        let watchedDir = TempDir()
        let watchedPath = try archive(in: watchedDir)
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: watchedDir.path)
        try db.insertFolder(folder)
        var watchedRule = makeRule(folderId: folder.id, name: "unarchive", actions: [action])
        watchedRule.actions[0].ruleId = watchedRule.id
        try db.insertRule(watchedRule)
        WatcherCoordinator(db: db, actionPlatform: Platform()).handle(path: watchedPath)
        #expect(try db.listHistory().first?.status == .applied)
        #expect(try String(contentsOfFile: (watchedDir.path as NSString).appendingPathComponent("report.txt"), encoding: .utf8) == "content")
    }

    @Test func multiRootCompoundArchiveUsesBaseFolderAcrossPaths() throws {
        let action = makeAction(.uncompress, .object([:]))
        let previewDir = TempDir()
        let previewPath = try archive(in: previewDir, multiple: true)
        let rule = makeRule(name: "unarchive", actions: [action])
        let preview = try #require(RuleEngine.previewFile(path: previewPath, depth: 0, rules: [rule]))
        #expect(preview.rules.first?.actions.first?.targetPath == (previewDir.path as NSString).appendingPathComponent("sample"))
        let manualDir = TempDir()
        let manualPath = try archive(in: manualDir, multiple: true)
        #expect(RuleEngine.run(path: manualPath, depth: 0, rules: [rule], batchId: "manual", platform: Platform()).history.first?.status == .applied)
        #expect(FileManager.default.fileExists(atPath: (manualDir.path as NSString).appendingPathComponent("sample/second.txt")))
        let watchedDir = TempDir()
        let watchedPath = try archive(in: watchedDir, multiple: true)
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: watchedDir.path)
        try db.insertFolder(folder)
        var watchedRule = makeRule(folderId: folder.id, name: "unarchive", actions: [action])
        watchedRule.actions[0].ruleId = watchedRule.id
        try db.insertRule(watchedRule)
        WatcherCoordinator(db: db, actionPlatform: Platform()).handle(path: watchedPath)
        #expect(try db.listHistory().first?.status == .applied)
        #expect(FileManager.default.fileExists(atPath: (watchedDir.path as NSString).appendingPathComponent("sample/report.txt")))
    }

    @Test func tarSymbolicLinksAreRejectedBeforeExtraction() throws {
        let dir = TempDir()
        let path = try archive(in: dir, link: true)
        let action = makeAction(.uncompress, .object([:]))
        #expect(throws: ActionError.self) { try ActionExecutor.plan(action, path: path) }
        #expect(throws: ActionError.self) { try ActionExecutor.execute(action, path: path, platform: Platform()) }
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func trashFailureRollsBackNewExtraction() throws {
        let dir = TempDir()
        let path = try archive(in: dir)
        #expect(throws: ActionError.self) {
            try ActionExecutor.execute(makeAction(.uncompress, .object([:])), path: path, platform: Platform(failTrash: true))
        }
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(!FileManager.default.fileExists(atPath: (dir.path as NSString).appendingPathComponent("report.txt")))
    }

    @Test func gzipStreamsWithActualOutputLimit() throws {
        let dir = TempDir()
        let source = dir.file("message", contents: "hello world")
        let archive = (dir.path as NSString).appendingPathComponent("message.gz")
        #expect(FileManager.default.createFile(atPath: archive, contents: nil))
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: archive))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", source]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        try output.close()
        #expect(process.terminationStatus == 0)
        let extraction = dir.dir("extract")
        #expect(throws: ActionError.self) { try SafeArchive.extract(path: archive, destination: extraction, maxOutputBytes: 4) }
        let successful = dir.dir("success")
        try SafeArchive.extract(path: archive, destination: successful, maxOutputBytes: 100)
        #expect(try String(contentsOfFile: (successful as NSString).appendingPathComponent("message"), encoding: .utf8) == "hello world")
    }

    @Test func sevenZipExtractsUsingSystemReader() throws {
        let dir = TempDir()
        let source = dir.dir("input")
        try "seven".write(toFile: (source as NSString).appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        let path = (dir.path as NSString).appendingPathComponent("sample.7z")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["--format", "7zip", "-cf", path, "-C", source, "report.txt"]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        try FileManager.default.removeItem(atPath: source)
        let applied = try ActionExecutor.execute(makeAction(.uncompress, .object([:])), path: path, platform: Platform())
        #expect(try String(contentsOfFile: applied.newPath, encoding: .utf8) == "seven")
    }

    @Test func unsupportedFilterCannotLaunchPathHelper() throws {
        let dir = TempDir()
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let main = (dir.path as NSString).appendingPathComponent("main.swift")
        let program = (dir.path as NSString).appendingPathComponent("probe")
        let source = """
            import Foundation
            struct ActionError: Error { init(_ message: String) {} }
            do { _ = try SafeArchive.topLevelItems(path: CommandLine.arguments[1]) } catch {}
            """
        try source.write(toFile: main, atomically: true, encoding: .utf8)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["swiftc", "-module-cache-path", (dir.path as NSString).appendingPathComponent("module-cache"), "-I", repository.appendingPathComponent("Sources/CArchive").path,
                              repository.appendingPathComponent("Sources/ForelCore/Engine/SafeArchive.swift").path,
                              main, "-o", program]
        compiler.standardOutput = FileHandle.nullDevice
        compiler.standardError = FileHandle.nullDevice
        try compiler.run()
        compiler.waitUntilExit()
        try #require(compiler.terminationStatus == 0)
        let helper = (dir.path as NSString).appendingPathComponent("lzop")
        try "#!/bin/sh\n/usr/bin/touch \"$FOREL_TEST_CANARY\"\nexit 1\n".write(toFile: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper)
        let input = (dir.path as NSString).appendingPathComponent("unsafe.lzo")
        try Data([0x89, 0x4c, 0x5a, 0x4f, 0x00, 0x0d, 0x0a, 0x1a, 0x0a] + Array(repeating: 0, count: 64)).write(to: URL(fileURLWithPath: input))
        let canary = (dir.path as NSString).appendingPathComponent("canary")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = [input]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = dir.path
        environment["FOREL_TEST_CANARY"] = canary
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(!FileManager.default.fileExists(atPath: canary))
    }

    @Test func archivePreservesExecutablePermission() throws {
        let dir = TempDir()
        let source = dir.dir("input")
        let executable = (source as NSString).appendingPathComponent("script.sh")
        try "#!/bin/sh\n".write(toFile: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable)
        let path = (dir.path as NSString).appendingPathComponent("sample.tar")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-cf", path, "-C", source, "script.sh"]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        try FileManager.default.removeItem(atPath: source)
        let applied = try ActionExecutor.execute(makeAction(.uncompress, .object([:])), path: path, platform: Platform())
        let attributes = try FileManager.default.attributesOfItem(atPath: applied.newPath)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
    }

    @Test func zipExtractionPreservesEntryModificationDate() throws {
        let dir = TempDir()
        let path = (dir.path as NSString).appendingPathComponent("dated.zip")
        let expected = Date(timeIntervalSince1970: 1_600_000_000)
        let zip = try Archive(url: URL(fileURLWithPath: path), accessMode: .create)
        try zip.addEntry(with: "report.txt", type: .file, uncompressedSize: Int64(1), modificationDate: expected, provider: { _, _ in Data([65]) })
        let applied = try ActionExecutor.execute(makeAction(.uncompress, .object([:])), path: path, platform: Platform())
        let actual = try #require(FileManager.default.attributesOfItem(atPath: applied.newPath)[.modificationDate] as? Date)
        #expect(abs(actual.timeIntervalSince(expected)) < 2)
    }

    @Test func tarExtractionPreservesFileAndDirectoryModificationDates() throws {
        let dir = TempDir()
        let input = dir.dir("input")
        let nested = (input as NSString).appendingPathComponent("nested")
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: false)
        let file = (nested as NSString).appendingPathComponent("item.txt")
        try "content".write(toFile: file, atomically: true, encoding: .utf8)
        let fileDate = Date(timeIntervalSince1970: 1_600_000_100)
        let directoryDate = Date(timeIntervalSince1970: 1_500_000_000)
        try FileManager.default.setAttributes([.modificationDate: fileDate], ofItemAtPath: file)
        try FileManager.default.setAttributes([.modificationDate: directoryDate], ofItemAtPath: nested)
        let archive = (dir.path as NSString).appendingPathComponent("dated.tar")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-cf", archive, "-C", input, "nested"]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        try FileManager.default.removeItem(atPath: input)
        let applied = try ActionExecutor.execute(makeAction(.uncompress, .object([:])), path: archive, platform: Platform())
        let extractedFile = (applied.newPath as NSString).appendingPathComponent("item.txt")
        let actualFileDate = try #require(FileManager.default.attributesOfItem(atPath: extractedFile)[.modificationDate] as? Date)
        let actualDirectoryDate = try #require(FileManager.default.attributesOfItem(atPath: applied.newPath)[.modificationDate] as? Date)
        #expect(abs(actualFileDate.timeIntervalSince(fileDate)) < 1)
        #expect(abs(actualDirectoryDate.timeIntervalSince(directoryDate)) < 1)
    }

    @Test func archiveAndUnarchivePreserveQuarantine() throws {
        let dir = TempDir()
        let source = dir.file("script.sh", contents: "#!/bin/sh\n")
        let marker = Data("0081;65000000;ForelFixture;".utf8)
        let set = marker.withUnsafeBytes { setxattr(source, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) }
        #expect(set == 0)
        let archived = try ActionExecutor.execute(makeAction(.archive, .object([:])), path: source, platform: Platform())
        #expect(try SafeArchive.readQuarantine(path: archived.newPath) == marker)
        let extracted = try ActionExecutor.execute(makeAction(.uncompress, .object([:])), path: archived.newPath, platform: Platform())
        #expect(try SafeArchive.readQuarantine(path: extracted.newPath) == marker)
    }

    @Test(arguments: ["validZip", "mislabeled", "officeZip"])
    func archiveSkipsOnlyRealZipWithZipExtensionAcrossPaths(kind: String) throws {
        let dir = TempDir()
        func file(_ name: String) throws -> String {
            let ext = kind == "officeZip" ? "docx" : "zip"
            let path = (dir.path as NSString).appendingPathComponent("\(name).\(ext)")
            if kind == "mislabeled" { try "plain".write(toFile: path, atomically: true, encoding: .utf8) }
            else {
                let zip = try Archive(url: URL(fileURLWithPath: path), accessMode: .create)
                try zip.addEntry(with: "item", type: .file, uncompressedSize: Int64(1), provider: { _, _ in Data([65]) })
            }
            return path
        }
        let manual = try file("manual"), watched = try file("watched")
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "archive")
        rule.isHazelImported = true
        rule.actions = [makeAction(.archive, .object([:]), position: 0, ruleId: rule.id), makeAction(.pause, .object([ActionParam.durationSeconds: .string("0")]), position: 1, ruleId: rule.id)]
        let preview = try #require(RuleEngine.previewFile(path: manual, depth: 0, rules: [rule]))
        #expect(preview.rules[0].actions.map(\.status) == [kind == "validZip" ? .wouldSkip : .wouldRun, .wouldRun])
        let result = RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "manual", platform: Platform())
        #expect(result.history.map(\.status) == [kind == "validZip" ? .skipped : .applied, .applied])
        try db.insertRule(rule)
        WatcherCoordinator(db: db, actionPlatform: Platform()).handle(path: watched)
        let history = try db.listHistory()
        #expect(history.count == 2)
        #expect(history.first(where: { $0.actionKind == .archive })?.status == (kind == "validZip" ? .skipped : .applied))
        #expect(history.first(where: { $0.actionKind == .pause })?.status == .applied)
        #expect(FileManager.default.fileExists(atPath: kind == "validZip" ? watched : watched + ".zip"))
    }
}
