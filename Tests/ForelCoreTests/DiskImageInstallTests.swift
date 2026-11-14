import Foundation
import Testing
@testable import ForelCore

@Suite struct DiskImageInstallTests {
    /// Builds a real read-only disk image holding the given app bundles and a
    /// notes file. Returns nil when hdiutil cannot create images on this host,
    /// so these tests skip instead of failing.
    private func makeDiskImage(in dir: TempDir, apps: [String]) -> String? {
        let source = dir.path + "/source"
        for app in apps {
            let contents = (source as NSString).appendingPathComponent("\(app)/Contents")
            try? FileManager.default.createDirectory(atPath: contents, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: contents + "/Info.plist", contents: Data("<plist/>".utf8))
        }
        try? FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: source + "/notes.txt", contents: Data("readme".utf8))
        let image = dir.path + "/Fixture.dmg"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["create", "-quiet", "-fs", "HFS+", "-srcfolder", source, "-format", "UDRO", image]
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: image) ? image : nil
    }

    private func installAction(into destination: String, deleteImage: Bool = false, ruleId: String = "rule") -> Action {
        makeAction(.installDiskImage, .object([
            ActionParam.destination: .string(destination),
            ActionParam.deleteDiskImageAfterInstall: .bool(deleteImage),
        ]), ruleId: ruleId)
    }

    @Test func installCopiesTheAppAndKeepsTheImageByDefault() throws {
        let dir = TempDir()
        guard let image = makeDiskImage(in: dir, apps: ["Fixture.app"]) else { return }
        let destination = dir.dir("Applications")

        let applied = try ActionExecutor.execute(installAction(into: destination), path: image)

        #expect(FileManager.default.fileExists(atPath: destination + "/Fixture.app/Contents/Info.plist"))
        #expect(!FileManager.default.fileExists(atPath: destination + "/notes.txt"))
        #expect(FileManager.default.fileExists(atPath: image))
        #expect(applied.newPath == image)
    }

    @Test func installRefusesToReplaceAnAppAlreadyInstalled() throws {
        let dir = TempDir()
        guard let image = makeDiskImage(in: dir, apps: ["Fixture.app"]) else { return }
        let destination = dir.dir("Applications")
        let existing = destination + "/Fixture.app/Contents"
        try FileManager.default.createDirectory(atPath: existing, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: existing + "/Version.txt", contents: Data("installed".utf8))

        #expect(throws: ActionError.self) {
            try ActionExecutor.execute(installAction(into: destination), path: image)
        }
        #expect(FileManager.default.fileExists(atPath: existing + "/Version.txt"))
        #expect(!FileManager.default.fileExists(atPath: destination + "/Fixture.app/Contents/Info.plist"))
        #expect(FileManager.default.fileExists(atPath: image))
    }

    @Test func installFailsWhenTheImageHasNoApplication() throws {
        let dir = TempDir()
        guard let image = makeDiskImage(in: dir, apps: []) else { return }
        let destination = dir.path + "/Applications"

        #expect(throws: ActionError.self) {
            try ActionExecutor.execute(installAction(into: destination), path: image)
        }
        #expect(!FileManager.default.fileExists(atPath: destination))
        #expect(FileManager.default.fileExists(atPath: image))
    }

    @Test func installRejectsFilesThatAreNotDiskImages() throws {
        let dir = TempDir()
        let archive = dir.file("bundle.zip", contents: "not an image")

        #expect(throws: ActionError.self) {
            try ActionExecutor.execute(installAction(into: dir.dir("Applications")), path: archive)
        }
        #expect(FileManager.default.fileExists(atPath: archive))
    }

    @Test func dryRunDescribesTheInstallWithoutMountingTheImage() throws {
        let plan = try ActionExecutor.plan(installAction(into: "/Users/example/Apps"), path: "/Users/example/Fixture.dmg")

        #expect(plan.status == .wouldRun)
        #expect(plan.isTerminal)
        #expect(plan.targetPath == "/Users/example/Apps")
        #expect(plan.description == "Install apps from disk image to /Users/example/Apps")
        #expect(plan.warning != nil)
    }

    @Test func dryRunMentionsTheTrashWhenTheImageWillBeRemoved() throws {
        let plan = try ActionExecutor.plan(installAction(into: "/Applications", deleteImage: true), path: "/Users/example/Fixture.dmg")

        #expect(plan.description.hasSuffix("; move disk image to Trash"))
    }

    @Test func dryRunSkipsFilesThatAreNotDiskImages() throws {
        let plan = try ActionExecutor.plan(installAction(into: "/Applications"), path: "/Users/example/bundle.zip")

        #expect(plan.status == .wouldSkip)
    }

    @Test func ruleRunAndDryRunAgreeOnTheDiskImage() throws {
        let dir = TempDir()
        guard let image = makeDiskImage(in: dir, apps: ["Fixture.app"]) else { return }
        let destination = dir.path + "/Applications"
        var rule = makeRule(name: "Install images")
        rule.conditions = [makeCondition(.extension_, .is, "dmg", ruleId: rule.id)]
        rule.actions = [installAction(into: destination, ruleId: rule.id)]

        let preview = RuleEngine.previewFile(path: image, depth: 0, rules: [rule])
        #expect(preview?.rules.first?.actions.first?.status == .wouldRun)
        #expect(!FileManager.default.fileExists(atPath: destination))

        let result = RuleEngine.run(path: image, depth: 0, rules: [rule], batchId: "manual")
        #expect(result.history.first?.status == .applied)
        #expect(FileManager.default.fileExists(atPath: destination + "/Fixture.app/Contents/Info.plist"))
    }

    @Test func watcherInstallsDiskImagesThatArriveInAWatchedFolder() throws {
        let dir = TempDir()
        guard let image = makeDiskImage(in: dir, apps: ["Fixture.app"]) else { return }
        let destination = dir.path + "/Applications"
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "Install images")
        rule.conditions = [makeCondition(.extension_, .is, "dmg", ruleId: rule.id)]
        rule.actions = [installAction(into: destination, ruleId: rule.id)]
        try db.insertRule(rule)

        let watcher = WatcherCoordinator(db: db)
        watcher.handle(path: image)

        #expect(try db.listHistory().first?.status == .applied)
        #expect(FileManager.default.fileExists(atPath: destination + "/Fixture.app/Contents/Info.plist"))
    }

    @Test func replaceExistingSwapsInTheNewAppAndTrashesTheOldOne() throws {
        let dir = TempDir()
        guard let image = makeDiskImage(in: dir, apps: ["Fixture.app"]) else { return }
        let destination = dir.path + "/Applications"
        let existing = destination + "/Fixture.app/Contents"
        try FileManager.default.createDirectory(atPath: existing, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: existing + "/Version.txt", contents: Data("old".utf8))
        var trashed: [String] = []

        _ = try DiskImageInstaller.install(imagePath: image, into: destination, replaceExisting: true) { path in
            trashed.append(path)
            try FileManager.default.removeItem(atPath: path)
        }

        #expect(trashed == [destination + "/Fixture.app"])
        #expect(!FileManager.default.fileExists(atPath: existing + "/Version.txt"))
        #expect(FileManager.default.fileExists(atPath: destination + "/Fixture.app/Contents/Info.plist"))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: destination).filter { $0.hasPrefix(".forel-install-") }
        #expect(leftovers.isEmpty)
    }

    @Test func replaceExistingOffStillStopsWithoutTouchingTheOldApp() throws {
        let dir = TempDir()
        guard let image = makeDiskImage(in: dir, apps: ["Fixture.app"]) else { return }
        let destination = dir.path + "/Applications"
        let existing = destination + "/Fixture.app/Contents"
        try FileManager.default.createDirectory(atPath: existing, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: existing + "/Version.txt", contents: Data("old".utf8))
        var trashed: [String] = []

        #expect(throws: ActionError.self) {
            try DiskImageInstaller.install(imagePath: image, into: destination, replaceExisting: false) { path in
                trashed.append(path)
            }
        }
        #expect(trashed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: existing + "/Version.txt"))
    }

    @Test func dryRunMentionsReplacementWhenEnabled() throws {
        let params: JSONValue = .object([
            ActionParam.destination: .string("/Applications"),
            ActionParam.replaceExistingApp: .bool(true),
        ])
        let plan = try ActionExecutor.plan(makeAction(.installDiskImage, params), path: "/Users/example/Fixture.dmg")

        #expect(plan.description.contains("replace existing apps"))
    }
}
