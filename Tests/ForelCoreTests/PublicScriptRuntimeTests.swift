import Foundation
import CryptoKit
import ImageIO
import Darwin
import Testing
@testable import ForelCore

@Suite struct PublicScriptRuntimeTests {
    @Test func ticklerMoveRuleRunsReviewedConditionAcrossPaths() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_TICKLER"] else { return }
        let source = TempDir(), destination = TempDir(), folder = WatchedFolder(path: source.path), db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("tickler.hazelrules"))
        let imported = try RuleTransfer.importRules(from: data, folderId: folder.id)
        var rule = try #require(imported.rules.first { $0.name == "Move files" })
        let condition = try #require(rule.conditions.first { $0.kind == .hazelScriptCondition })
        let script = try #require(HazelScriptCondition.decode(condition.value))
        let hash = SHA256.hash(data: Data(script.source.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(hash == "0b3f724bf663f9f6d7495a27c204f38d0695de684694af828ab9396963ca0ed3")
        guard hash == "0b3f724bf663f9f6d7495a27c204f38d0695de684694af828ab9396963ca0ed3" else { return }
        #expect(rule.actions.map(\.kind) == [.moveToFolder, .setFinderLabel, .setFinderComment])
        rule.enabled = true
        var params: [String: JSONValue] = [:]
        if case .object(let old) = rule.actions[0].params { params = old }
        params[ActionParam.destination] = .string(destination.path)
        rule.actions[0].params = .object(params)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "MMM"
        let dayFormatter = DateFormatter(); dayFormatter.locale = Locale(identifier: "en_US_POSIX"); dayFormatter.dateFormat = "dd"
        let now = Date(), month = formatter.string(from: now), day = dayFormatter.string(from: now)
        let injected = try #require(Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: now))
        let folderPath = source.dir("\(month)/\(day)")
        let preview = source.file("\(month)/\(day)/preview.txt"), manual = source.file("\(month)/\(day)/manual.txt"), watched = source.file("\(month)/\(day)/watched.txt")
        #expect(RuleEngine.previewFile(path: preview, depth: 2, rules: [rule], root: source.path, now: injected) != nil)
        let result = RuleEngine.run(path: manual, depth: 2, rules: [rule], batchId: "tickler-reviewed", root: source.path, now: injected)
        #expect(result.history.map(\.status) == [.applied, .applied, .applied], "\(result.history.map(\.message))")
        var recurse = try #require(imported.rules.first { $0.name == "Scan folders for files to bring forward" })
        recurse.enabled = true; recurse.priority = 0; rule.priority = 1
        try db.insertRule(recurse); try db.insertRule(rule)
        WatcherCoordinator(db: db).recheckTimeSensitiveRules(root: source.path, now: injected)
        #expect(FileManager.default.fileExists(atPath: (destination.path as NSString).appendingPathComponent("watched.txt")))
        #expect(!FileManager.default.fileExists(atPath: watched))
        #expect(FileManager.default.fileExists(atPath: folderPath))
    }

    private final class Platform: ActionPlatform, @unchecked Sendable {
        var opened: [String] = []
        var notifications: [String] = []
        var failTrash = false
        func open(path: String, application: String?, passFile: Bool, bringToFront: Bool) throws { opened.append(path) }
        func showInFinder(path: String, bringToFront: Bool) throws {}
        func notify(text: String, sound: Bool) throws { notifications.append(text) }
        func pause(seconds: TimeInterval) throws {}
        func trash(path: String) throws -> String {
            if failTrash { throw ActionError("fixture Trash failure") }
            let result = path + ".fixture-trash"
            try FileManager.default.moveItem(atPath: path, toPath: result)
            return result
        }
    }

    @Test func unzipRuleUsesHarmlessScriptAcrossPaths() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_UNZIP"] else { return }
        let source = TempDir(), folder = WatchedFolder(path: source.path), db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("download.hazelrules"))
        var rule = try #require(RuleTransfer.importRules(from: data, folderId: folder.id).rules.first { $0.name == "unZip(7z)" })
        #expect(rule.importError == nil)
        #expect(rule.actions.map(\.kind) == [.runHazelShellScript])
        #expect(rule.actions[0].params[ActionParam.script]?.stringValue?.contains("7z x \"$FILE\"") == true)
        var params: [String: JSONValue] = [:]
        if case .object(let old) = rule.actions[0].params { params = old }
        params[ActionParam.script] = .string("test -f \"$1\"")
        rule.actions[0].params = .object(params)
        rule.enabled = true
        let preview = source.file("preview.zip"), manual = source.file("manual.zip"), watched = source.file("watched.zip")
        #expect(RuleEngine.previewFile(path: preview, depth: 0, rules: [rule]) != nil)
        #expect(RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "unzip-substitute").history.first?.status == .applied)
        try db.insertRule(rule)
        WatcherCoordinator(db: db).handle(path: watched)
        #expect(try db.listHistory().first?.status == .applied)
        #expect([preview, manual, watched].allSatisfy { FileManager.default.fileExists(atPath: $0) })
    }

    @Test func mountAndOpenURLRulesUseInjectedSafeEffectsAcrossPaths() throws {
        let env = ProcessInfo.processInfo.environment
        guard testTrashDirectory() != nil else {
            if env["FOREL_TEST_TRASH_DIRECTORY"] != nil { Issue.record("Dedicated debug test Trash is unavailable") }
            return
        }
        var tested = 0
        for (variable, archive, name) in [("FOREL_HAZEL_UNZIP", "download.hazelrules", "Mount"), ("FOREL_HAZEL_OPEN_URL", "to-open-url.hazelrules", "Open URL")] {
            guard let root = env[variable] else { continue }
            let source = TempDir(), folder = WatchedFolder(path: source.path), db = try Database(path: ":memory:")
            try db.insertFolder(folder)
            let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(archive))
            var rule = try #require(RuleTransfer.importRules(from: data, folderId: folder.id).rules.first { $0.name == name })
            #expect(rule.importError == nil)
            rule.enabled = true
            let platform = Platform()
            if name == "Open URL" {
                #expect(rule.actions.map(\.kind) == [.runHazelShellScript, .moveToTrash, .displayNotification])
                var params: [String: JSONValue] = [:]
                if case .object(let old) = rule.actions[0].params { params = old }
                params[ActionParam.script] = .string("test -f \"$1\"")
                rule.actions[0].params = .object(params)
            } else { #expect(rule.actions.map(\.kind) == [.openDefault, .moveToTrash]) }
            let ext = name == "Mount" ? "dmg" : "txt"
            let prefix = UUID().uuidString
            let preview = source.file("\(prefix)-preview.\(ext)"), manual = source.file("\(prefix)-manual.\(ext)"), watched = source.file("\(prefix)-watched.\(ext)")
            let expectedCount = name == "Open URL" ? 3 : 2
            #expect(RuleEngine.previewFile(path: preview, depth: 0, rules: [rule])?.rules.first?.actions.count == expectedCount, "\(name)")
            #expect(platform.opened.isEmpty)
            let result = RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "safe-effects", platform: platform)
            #expect(result.history.map(\.status) == Array(repeating: .applied, count: expectedCount), "\(name): \(result.history.map(\.message))")
            try db.insertRule(rule)
            WatcherCoordinator(db: db, actionPlatform: platform).handle(path: watched)
            #expect(try db.listHistory().map(\.status) == Array(repeating: .applied, count: expectedCount), "\(name)")
            #expect(FileManager.default.fileExists(atPath: manual + ".fixture-trash"))
            #expect(FileManager.default.fileExists(atPath: watched + ".fixture-trash"))
            if name == "Mount" { #expect(platform.opened == [manual, watched]) }
            if name == "Open URL" {
                #expect(platform.notifications.count == 2)
                #expect(platform.notifications.allSatisfy { $0.contains("Open URL") })
                let failed = source.file("\(prefix)-fail.txt")
                platform.failTrash = true
                let failure = RuleEngine.run(path: failed, depth: 0, rules: [rule], batchId: "failure", platform: platform)
                #expect(failure.history.map(\.status) == [.applied, .failed])
                #expect(platform.notifications.count == 2)
            }
            tested += 1
        }
        if env["FOREL_HAZEL_UNZIP"] != nil && env["FOREL_HAZEL_OPEN_URL"] != nil { #expect(tested == 2) }
    }

    @Test func originalRecursiveRulesGatePreviewManualAndWatcher() throws {
        let environment = ProcessInfo.processInfo.environment
        let cases = [
            ("FOREL_HAZEL_CORPUS", "2012_IITSEC_Booth_1149.hazelrules", "Go into subfolders"),
            ("FOREL_HAZEL_CORPUS_2", "Movies.hazelrules", "Recursive rule"),
            ("FOREL_HAZEL_PHOTOS", "google_photos.hazelrules", "Recursive Search"),
            ("FOREL_HAZEL_TICKLER", "tickler.hazelrules", "Scan folders for files to bring forward"),
            ("FOREL_HAZEL_UNZIP", "download.hazelrules", "Monitoring SubFolders"),
            ("FOREL_HAZEL_WRAPPED", "modules/home/programs/hazel-backup/16777230-36143.hazelrules", "Subfolder Search")
        ]
        for (variable, file, name) in cases {
            guard let root = environment[variable] else { continue }
            let source = TempDir(), folder = WatchedFolder(path: source.path), db = try Database(path: ":memory:")
            try db.insertFolder(folder)
            let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(file))
            var rule = try #require(RuleTransfer.importRules(from: data, folderId: folder.id).rules.first { $0.name == name })
            #expect(rule.importError == nil, "\(name): \(rule.importError ?? "")")
            #expect(rule.actions.map(\.kind) == [.hazelRecurse], "\(name)")
            rule.enabled = true
            let preview = source.dir("preview"), manual = source.dir("manual"), automatic = source.dir("automatic")
            _ = source.file("automatic/child.txt")
            var previewCallbacks: [String] = []
            let plan = RuleEngine.previewFile(path: preview, depth: 0, rules: [rule], root: source.path, onRecurse: { previewCallbacks.append($0) })
            #expect(plan != nil, "\(name): imported predicates must match fixture")
            #expect(previewCallbacks == [preview], "\(name)")
            var actualCallbacks: [String] = []
            let result = RuleEngine.runWithTraversal(path: manual, depth: 0, rules: [rule], batchId: "recursive-public", root: source.path, onRecurse: { actualCallbacks.append($0) })
            #expect(result.recurses && actualCallbacks == [manual], "\(name)")
            var marker = makeRule(folderId: folder.id, name: "child marker", conditions: [makeCondition(.extensionInsensitive, .is, "txt")], actions: [])
            marker.recursionDepth = nil
            marker.conditions[0].ruleId = marker.id
            marker.actions = [makeAction(.addTag, .object([ActionParam.tags: .stringArray(["visited"])]), ruleId: marker.id)]
            rule.priority = 0; marker.priority = 1
            try db.insertRule(rule); try db.insertRule(marker)
            WatcherCoordinator(db: db).handle(path: automatic)
            #expect(FinderTags.read((automatic as NSString).appendingPathComponent("child.txt")).contains("visited"), "\(name)")
        }
    }

    @Test func installerRuleUsesHarmlessExternalExecutableSubstitute() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_INSTALLER"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("Applications.hazelrules"))
        let source = TempDir(), folder = WatchedFolder(path: source.path), db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        var rule = try #require(RuleTransfer.importRules(from: data, folderId: folder.id).rules.first)
        #expect(rule.importError == nil)
        let shell = try #require(rule.actions.firstIndex { $0.kind == .runHazelShellScript })
        #expect(rule.actions[shell].params[ActionParam.shellPath]?.stringValue == "/usr/local/bin/archive_osx_installer_app")
        let marker = (source.path as NSString).appendingPathComponent("called")
        let helper = source.file("fixture.sh", contents: "#!/bin/sh\nprintf '%s' \"$1\" > \"$(dirname \"$0\")/called\"\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper)
        var params: [String: JSONValue] = [:]
        if case .object(let original) = rule.actions[shell].params { params = original }
        params[ActionParam.shellPath] = .string(helper)
        params.removeValue(forKey: ActionParam.shellBookmark)
        rule.actions[shell].params = .object(params)
        rule.enabled = true
        let app = source.dir("Install OS X Fixture.app"), watched = source.dir("Install OS X Watcher.app")
        for path in [app, watched] { try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-86_400)], ofItemAtPath: path) }
        if RuleEngine.previewFile(path: app, depth: 0, rules: [rule]) != nil {
            let result = RuleEngine.run(path: app, depth: 0, rules: [rule], batchId: "installer-substitute")
            #expect(result.history.first?.status == .applied, "\(result.history.map(\.message))")
            try db.insertRule(rule)
            WatcherCoordinator(db: db).handle(path: watched)
            #expect(try db.listHistory().first?.status == .applied)
            #expect(try String(contentsOfFile: marker, encoding: .utf8) == watched)
            print("Installer runtime: original predicates matched")
        } else {
            #expect(rule.conditions.contains { !ConditionEvaluator.evaluate($0, path: app) })
            _ = try ActionExecutor.execute(rule.actions[shell], path: app)
            print("Installer runtime: host metadata prevented original rule match; tested imported action separately")
        }
        if !FileManager.default.fileExists(atPath: marker) { Issue.record("The substituted installer helper did not run") }
    }

    @Test func reviewedHEICConverterDependencyFailureStopsTrash() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_HEIC"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("Downloads-HEIC2jpg.hazelrules"))
        let source = TempDir(), folder = WatchedFolder(path: source.path)
        var rule = try #require(RuleTransfer.importRules(from: data, folderId: folder.id).rules.first)
        #expect(rule.actions.map(\.kind) == [.rename, .runHazelShellScript, .moveToTrash])
        let shell = try #require(rule.actions.first { $0.kind == .runHazelShellScript })
        let text = try #require(shell.params[ActionParam.script]?.stringValue)
        #expect(text == "/usr/local/scripts/heic2jpg.sh \"$1\"\n\n# EOF\n")
        guard text == "/usr/local/scripts/heic2jpg.sh \"$1\"\n\n# EOF\n" else { return }
        // Never run an installed third-party converter. This dependency test
        // runs only when the reviewed absolute executable is absent.
        guard !FileManager.default.fileExists(atPath: "/usr/local/scripts/heic2jpg.sh") else { return }
        rule.enabled = true
        // The photo's date-taken metadata is unavailable for this synthetic
        // fixture, so test the original script and Trash actions as a chain.
        rule.actions = Array(rule.actions.dropFirst())
        let file = source.file("IMG_1.heic", contents: "fixture")
        let result = RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "missing-heic-converter")
        #expect(result.history.count == 1, "\(result.history.map(\.message))")
        #expect(result.history.first?.status == .failed)
        #expect(FileManager.default.fileExists(atPath: file))
    }

    @Test func originalHEICRenameThenMissingConverterStopsTrashWhenEncoderAvailable() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_HEIC"], !FileManager.default.fileExists(atPath: "/usr/local/scripts/heic2jpg.sh") else { return }
        let source = TempDir(), folder = WatchedFolder(path: source.path)
        let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("Downloads-HEIC2jpg.hazelrules"))
        var rule = try #require(RuleTransfer.importRules(from: data, folderId: folder.id).rules.first)
        #expect(rule.actions.map(\.kind) == [.rename, .runHazelShellScript, .moveToTrash])
        let script = try #require(rule.actions[1].params[ActionParam.script]?.stringValue)
        guard script == "/usr/local/scripts/heic2jpg.sh \"$1\"\n\n# EOF\n" else { Issue.record("Unreviewed HEIC script"); return }
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/a2UAAAAASUVORK5CYII="))
        let imageSource = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        let file = (source.path as NSString).appendingPathComponent("IMG_1.heic")
        guard let writer = CGImageDestinationCreateWithURL(URL(fileURLWithPath: file) as CFURL, "public.heic" as CFString, 1, nil) else {
            print("HEIC runtime: encoder unavailable; dependency component test remains")
            return
        }
        CGImageDestinationAddImage(writer, image, [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:05:09 12:34:56"]] as CFDictionary)
        guard CGImageDestinationFinalize(writer), (try? HazelPattern.dateValue("hazelbuiltin:dateTaken", path: file)) != nil else {
            print("HEIC runtime: generated image does not expose EXIF date; dependency component test remains")
            return
        }
        rule.enabled = true
        let plan = try #require(RuleEngine.previewFile(path: file, depth: 0, rules: [rule]))
        #expect(plan.rules.first?.actions.count == 3)
        let result = RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "heic-original", platform: Platform())
        #expect(result.history.map(\.status) == [.applied, .failed], "\(result.history.map(\.message))")
        let renamed = try #require(result.history.first?.resultPath)
        #expect(FileManager.default.fileExists(atPath: renamed))
        #expect(!FileManager.default.fileExists(atPath: renamed + ".fixture-trash"))
    }

    @Test func photoRuleRunsChainWithHarmlessDateScript() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_PHOTOS"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("google_photos.hazelrules"))
        let source = TempDir(), destination = TempDir()
        let folder = WatchedFolder(path: source.path)
        let db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        let counter = DatabaseFolderCounterStore(db: db)
        var rule = try #require(RuleTransfer.importRules(from: data, folderId: folder.id).rules.first { $0.name == "Move images and videos to photos folder" })
        #expect(rule.importError == nil)
        #expect(rule.actions.map(\.kind) == [.runHazelOSA, .moveToFolder, .rename, .moveToFolder])
        rule.enabled = true
        var script: [String: JSONValue] = [:]
        if case .object(let original) = rule.actions[0].params { script = original }
        script[ActionParam.osaMode] = .string("embedded")
        script[ActionParam.script] = .string("return {hazelOutputAttributes:{value:new Date('2024-05-09T12:00:00')}};")
        rule.actions[0].params = .object(script)
        var move: [String: JSONValue] = [:]
        if case .object(let original) = rule.actions[1].params { move = original }
        move[ActionParam.destination] = .string(destination.path)
        rule.actions[1].params = .object(move)
        let file = source.file("image.JPG", contents: "photo fixture")
        let watched = source.file("watched.JPG", contents: "photo fixture")
        if RuleEngine.previewFile(path: file, depth: 0, rules: [rule]) == nil {
            #expect(rule.conditions.contains { !ConditionEvaluator.evaluate($0, path: file) })
            print("Photo runtime: host type metadata unavailable; substituted extension predicate")
            rule.conditions = [Condition(ruleId: rule.id, kind: .extensionInsensitive, operator: .is, value: "JPG")]
        }
        let result = RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "photo-date-substitute", counterStore: counter)
        #expect(result.history.count == 4, "\(result.history.map(\.message))")
        #expect(result.history.allSatisfy { $0.status == .applied }, "\(result.history.map(\.message))")
        let final = try #require(result.history.last?.resultPath)
        #expect(final.contains("/2024/05-May/May 9, 2024/"))
        #expect((final as NSString).lastPathComponent.hasPrefix("2024-05-09 "))
        #expect(try String(contentsOfFile: final, encoding: .utf8) == "photo fixture")
        try db.insertRule(rule)
        WatcherCoordinator(db: db).handle(path: watched)
        #expect(try db.listHistory().map(\.status) == [.applied, .applied, .applied, .applied])
        #expect(!FileManager.default.fileExists(atPath: watched))
    }

    @Test func screenshotRuleRunsFullChainWithHarmlessClipboardSubstitute() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_CORPUS_3"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("Screen Shots.hazelrules"))
        let source = TempDir()
        let folder = WatchedFolder(path: source.path)
        let db = try Database(path: ":memory:"); try db.insertFolder(folder)
        var rule = try #require(RuleTransfer.importRules(from: data, folderId: folder.id).rules.first)
        #expect(rule.importError == nil, "\(rule.importError ?? "")")
        #expect(rule.actions.map(\.kind) == [.moveToFolder, .rename, .runHazelOSA])
        rule.enabled = true
        let script = try #require(rule.actions.firstIndex { $0.kind == .runHazelOSA })
        var params: [String: JSONValue] = [:]
        if case .object(let original) = rule.actions[script].params { params = original }
        params[ActionParam.osaMode] = .string("embedded")
        params[ActionParam.script] = .string("return {hazelStop:false}")
        rule.actions[script].params = .object(params)
        let file = source.file("Screen Shot test.png"), watched = source.file("Screen Shot watched.png")
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/a2UAAAAASUVORK5CYII="))
        try png.write(to: URL(fileURLWithPath: file))
        try png.write(to: URL(fileURLWithPath: watched))
        var added = attrlist(); added.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT); added.commonattr = UInt32(ATTR_CMN_ADDEDTIME)
        var earlier = timespec(tv_sec: Int(Date().addingTimeInterval(-120).timeIntervalSince1970), tv_nsec: 0)
        #expect(withUnsafeMutablePointer(to: &earlier) { setattrlist(watched, &added, $0, MemoryLayout<timespec>.size, 0) } == 0)
        // Some hosts do not provide localized Finder kind descriptions. Keep
        // the original condition whenever available; otherwise explicitly
        // verify the host limitation and exercise the chain with an extension check.
        let kind = try #require(rule.conditions.firstIndex { $0.value == "hazelkind:Portable Network Graphics image" })
        if !ConditionEvaluator.evaluate(rule.conditions[kind], path: file) {
            let description = try? URL(fileURLWithPath: file).resourceValues(forKeys: [.localizedTypeDescriptionKey]).localizedTypeDescription
            #expect(description != "Portable Network Graphics image")
            #expect(!ConditionEvaluator.evaluate(rule.conditions[kind], path: file))
            rule.conditions[kind].kind = .extensionInsensitive
            rule.conditions[kind].value = "png"
            print("Screenshot runtime: host Finder kind unavailable; substituted PNG extension condition")
        } else {
            print("Screenshot runtime: original PNG Finder kind condition matched")
        }
        let preview = try #require(RuleEngine.previewFile(path: file, depth: 0, rules: [rule]))
        #expect(preview.rules.first?.actions.count == 3)
        let result = RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "screenshot-substitute")
        #expect(result.history.count == 3, "\(result.history.map(\.message))")
        #expect(result.history.allSatisfy { $0.status == .applied }, "\(result.history.map(\.message))")
        let final = try #require(result.history.last?.resultPath)
        #expect(try Data(contentsOf: URL(fileURLWithPath: final)) == png)
        #expect(final.contains("Screen Shots"))
        try db.insertRule(rule)
        WatcherCoordinator(db: db).handle(path: watched)
        let history = try db.listHistory()
        #expect(history.map(\.status) == [.applied, .applied, .applied], "\(history.map(\.message))")
        #expect(!FileManager.default.fileExists(atPath: watched))
    }
}
