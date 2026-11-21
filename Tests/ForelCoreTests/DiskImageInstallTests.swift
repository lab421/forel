import Foundation
import Testing
@testable import ForelCore

@Suite struct DiskImageInstallTests {
    /// Whether `hdiutil` can build disk images on this host. Tests that need
    /// a real image are disabled (and reported as skipped) when it cannot,
    /// instead of passing without checking anything.
    static let canCreateDiskImages: Bool = {
        let dir = TempDir()
        return (try? buildDiskImage(in: dir, apps: [])) != nil
    }()

    private static let needsDiskImages = ConditionTrait.enabled(if: canCreateDiskImages, "hdiutil cannot create disk images on this host")

    /// Builds a real read-only disk image holding the given app bundles and a
    /// notes file.
    private static func buildDiskImage(in dir: TempDir, apps: [String]) throws -> String {
        let fm = FileManager.default
        let source = dir.path + "/source"
        try fm.createDirectory(atPath: source, withIntermediateDirectories: true)
        for app in apps {
            let contents = (source as NSString).appendingPathComponent("\(app)/Contents")
            try fm.createDirectory(atPath: contents, withIntermediateDirectories: true)
            fm.createFile(atPath: contents + "/Info.plist", contents: Data("<plist/>".utf8))
        }
        fm.createFile(atPath: source + "/notes.txt", contents: Data("readme".utf8))
        let image = dir.path + "/Fixture.dmg"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["create", "-quiet", "-fs", "HFS+", "-srcfolder", source, "-format", "UDRO", image]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, fm.fileExists(atPath: image) else {
            throw ActionError("hdiutil create failed with status \(process.terminationStatus)")
        }
        return image
    }

    private func makeDiskImage(in dir: TempDir, apps: [String]) throws -> String {
        try Self.buildDiskImage(in: dir, apps: apps)
    }

    private func installAction(into destination: String, deleteImage: Bool = false, ruleId: String = "rule") -> Action {
        makeAction(.installDiskImage, .object([
            ActionParam.destination: .string(destination),
            ActionParam.deleteDiskImageAfterInstall: .bool(deleteImage),
        ]), ruleId: ruleId)
    }

    private func installedApp(_ destination: String, _ name: String = "Fixture.app") -> String {
        destination + "/\(name)/Contents/Info.plist"
    }

    private func stagedLeftovers(in destination: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: destination)) ?? []
        return names.filter { $0.hasPrefix(DiskImageInstaller.stagingPrefix) }
    }

    /// Stands in for the Trash: moves the item into `trash` and says where.
    private func fakeTrash(_ trash: String, recording trashed: @escaping (String) -> Void = { _ in }) -> (String) throws -> String? {
        { path in
            trashed(path)
            try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
            let target = (trash as NSString).appendingPathComponent(UUID().uuidString + "-" + (path as NSString).lastPathComponent)
            try FileManager.default.moveItem(atPath: path, toPath: target)
            return target
        }
    }

    private func makeExistingApp(in destination: String, _ name: String = "Fixture.app", version: String = "old") throws -> String {
        let contents = destination + "/\(name)/Contents"
        try FileManager.default.createDirectory(atPath: contents, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: contents + "/Version.txt", contents: Data(version.utf8))
        return contents + "/Version.txt"
    }

    // MARK: - Install

    @Test(needsDiskImages) func installCopiesTheAppAndKeepsTheImageByDefault() throws {
        let dir = TempDir()
        let image = try makeDiskImage(in: dir, apps: ["Fixture.app"])
        let destination = dir.dir("Applications")

        let applied = try ActionExecutor.execute(installAction(into: destination), path: image)

        #expect(FileManager.default.fileExists(atPath: installedApp(destination)))
        #expect(!FileManager.default.fileExists(atPath: destination + "/notes.txt"))
        #expect(FileManager.default.fileExists(atPath: image))
        #expect(applied.newPath == image)
        #expect(!applied.undo.isReversible)
    }

    @Test(needsDiskImages) func movingTheImageToTheTrashIsRecordedAndUndoable() throws {
        let dir = TempDir()
        let image = try makeDiskImage(in: dir, apps: ["Fixture.app"])
        let destination = dir.dir("Applications")
        let trash = dir.dir("Trash")

        let applied = try ActionExecutor.installDiskImage(installAction(into: destination, deleteImage: true), path: image, trashDirectory: trash)

        #expect(FileManager.default.fileExists(atPath: installedApp(destination)))
        #expect(!FileManager.default.fileExists(atPath: image))
        #expect(applied.newPath == trash + "/Fixture.dmg")
        #expect(FileManager.default.fileExists(atPath: applied.newPath))
        #expect(applied.undo.isReversible)
        guard case .move(let from, let to) = applied.undo else {
            Issue.record("Expected a move undo, got \(applied.undo)")
            return
        }
        #expect(from == image)
        #expect(to == applied.newPath)
    }

    @Test(needsDiskImages) func installRefusesToReplaceAnAppAlreadyInstalled() throws {
        let dir = TempDir()
        let image = try makeDiskImage(in: dir, apps: ["Fixture.app"])
        let destination = dir.dir("Applications")
        let version = try makeExistingApp(in: destination, version: "installed")

        #expect(throws: ActionError.self) {
            try ActionExecutor.execute(installAction(into: destination), path: image)
        }
        #expect(FileManager.default.fileExists(atPath: version))
        #expect(!FileManager.default.fileExists(atPath: installedApp(destination)))
        #expect(FileManager.default.fileExists(atPath: image))
    }

    @Test(needsDiskImages) func installFailsWhenTheImageHasNoApplication() throws {
        let dir = TempDir()
        let image = try makeDiskImage(in: dir, apps: [])
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

    @Test(needsDiskImages) func aCopyThatFailsHalfwayLeavesNothingBehind() throws {
        let dir = TempDir()
        let image = try makeDiskImage(in: dir, apps: ["Fixture.app"])
        let destination = dir.dir("Applications")

        #expect(throws: ActionError.self) {
            try DiskImageInstaller.install(imagePath: image, into: destination, copyApp: { _, copy in
                try FileManager.default.createDirectory(atPath: copy + "/Contents", withIntermediateDirectories: true)
                throw ActionError("No space left on device")
            })
        }
        #expect(stagedLeftovers(in: destination).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: destination + "/Fixture.app"))
    }

    // MARK: - Replace existing

    @Test(needsDiskImages) func replaceExistingSwapsInTheNewAppAndTrashesTheOldOne() throws {
        let dir = TempDir()
        let image = try makeDiskImage(in: dir, apps: ["Fixture.app"])
        let destination = dir.path + "/Applications"
        let version = try makeExistingApp(in: destination)
        var trashed: [String] = []

        _ = try DiskImageInstaller.install(
            imagePath: image, into: destination, replaceExisting: true,
            moveToTrash: fakeTrash(dir.path + "/Trash") { trashed.append($0) }
        )

        #expect(trashed == [destination + "/Fixture.app"])
        #expect(!FileManager.default.fileExists(atPath: version))
        #expect(FileManager.default.fileExists(atPath: installedApp(destination)))
        #expect(stagedLeftovers(in: destination).isEmpty)
    }

    @Test(needsDiskImages) func replaceExistingOffStillStopsWithoutTouchingTheOldApp() throws {
        let dir = TempDir()
        let image = try makeDiskImage(in: dir, apps: ["Fixture.app"])
        let destination = dir.path + "/Applications"
        let version = try makeExistingApp(in: destination)
        var trashed: [String] = []

        #expect(throws: ActionError.self) {
            try DiskImageInstaller.install(
                imagePath: image, into: destination, replaceExisting: false,
                moveToTrash: fakeTrash(dir.path + "/Trash") { trashed.append($0) }
            )
        }
        #expect(trashed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: version))
    }

    @Test(needsDiskImages) func aFailedReplacementPutsEveryOldAppBack() throws {
        let dir = TempDir()
        let image = try makeDiskImage(in: dir, apps: ["Alpha.app", "Beta.app"])
        let destination = dir.path + "/Applications"
        let alphaVersion = try makeExistingApp(in: destination, "Alpha.app", version: "old alpha")
        let betaVersion = try makeExistingApp(in: destination, "Beta.app", version: "old beta")
        let trash = fakeTrash(dir.path + "/Trash")

        #expect(throws: ActionError.self) {
            try DiskImageInstaller.install(imagePath: image, into: destination, replaceExisting: true, moveToTrash: { path in
                // Alpha is replaced first; Beta then cannot be moved away.
                if path.hasSuffix("Beta.app") { throw ActionError("Beta.app is in use") }
                return try trash(path)
            })
        }
        #expect(try String(contentsOfFile: alphaVersion, encoding: .utf8) == "old alpha")
        #expect(try String(contentsOfFile: betaVersion, encoding: .utf8) == "old beta")
        #expect(!FileManager.default.fileExists(atPath: installedApp(destination, "Alpha.app")))
        #expect(stagedLeftovers(in: destination).isEmpty)
    }

    // MARK: - Dry Run

    @Test func dryRunDescribesTheInstallWithoutMountingTheImage() throws {
        let plan = try ActionExecutor.plan(installAction(into: "/Users/example/Apps"), path: "/Users/example/Fixture.dmg")

        #expect(plan.status == .wouldRun)
        #expect(plan.isTerminal)
        #expect(plan.targetPath == "/Users/example/Apps")
        #expect(plan.finalPath == "/Users/example/Fixture.dmg")
        #expect(plan.description == "Install apps from disk image to /Users/example/Apps")
        #expect(plan.warning != nil)
    }

    @Test func dryRunMentionsTheTrashWhenTheImageWillBeRemoved() throws {
        let plan = try ActionExecutor.plan(installAction(into: "/Applications", deleteImage: true), path: "/Users/example/Fixture.dmg")

        #expect(plan.description.hasSuffix("; move disk image to Trash"))
        #expect(plan.finalPath == (try ActionExecutor.trashDir() as NSString).appendingPathComponent("Fixture.dmg"))
    }

    @Test func dryRunSkipsFilesThatAreNotDiskImages() throws {
        let plan = try ActionExecutor.plan(installAction(into: "/Applications"), path: "/Users/example/bundle.zip")

        #expect(plan.status == .wouldSkip)
        #expect(plan.description.hasPrefix("Skip —"))
        #expect(plan.description.contains("disk images"))
    }

    @Test func dryRunMentionsReplacementWhenEnabled() throws {
        let params: JSONValue = .object([
            ActionParam.destination: .string("/Applications"),
            ActionParam.replaceExistingApp: .bool(true),
        ])
        let plan = try ActionExecutor.plan(makeAction(.installDiskImage, params), path: "/Users/example/Fixture.dmg")

        #expect(plan.description.contains("replace existing apps"))
    }

    // MARK: - Execution paths

    @Test(needsDiskImages) func ruleRunAndDryRunAgreeOnTheDiskImage() throws {
        let dir = TempDir()
        let image = try makeDiskImage(in: dir, apps: ["Fixture.app"])
        let destination = dir.path + "/Applications"
        var rule = makeRule(name: "Install images")
        rule.conditions = [makeCondition(.extension_, .is, "dmg", ruleId: rule.id)]
        rule.actions = [installAction(into: destination, ruleId: rule.id)]

        let preview = RuleEngine.previewFile(path: image, depth: 0, rules: [rule])
        #expect(preview?.rules.first?.actions.first?.status == .wouldRun)
        #expect(!FileManager.default.fileExists(atPath: destination))

        let result = RuleEngine.run(path: image, depth: 0, rules: [rule], batchId: "manual")
        #expect(result.history.first?.status == .applied)
        #expect(FileManager.default.fileExists(atPath: installedApp(destination)))
    }

    @Test func runRecordsWhyAFileThatIsNotADiskImageIsSkipped() throws {
        let dir = TempDir()
        let archive = dir.file("bundle.zip", contents: "not an image")
        var rule = makeRule(name: "Install images")
        rule.conditions = [makeCondition(.extension_, .is, "zip", ruleId: rule.id)]
        rule.actions = [installAction(into: dir.path + "/Applications", ruleId: rule.id)]

        let preview = RuleEngine.previewFile(path: archive, depth: 0, rules: [rule])
        #expect(preview?.rules.first?.actions.first?.status == .wouldSkip)

        let result = RuleEngine.run(path: archive, depth: 0, rules: [rule], batchId: "manual")
        #expect(result.history.first?.status == .skipped)
        #expect(result.history.first?.message?.contains("disk images") == true)
    }

    @Test(needsDiskImages) func watcherInstallsDiskImagesThatArriveInAWatchedFolder() throws {
        let dir = TempDir()
        let image = try makeDiskImage(in: dir, apps: ["Fixture.app"])
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
        #expect(FileManager.default.fileExists(atPath: installedApp(destination)))
    }

    /// A watched install folder must never act on the hidden copy that is
    /// still being written: not in Dry Run, Run Now, the folder scan, or the
    /// watcher.
    @Test func stagedCopiesAreIgnoredOnEveryExecutionPath() throws {
        let dir = TempDir()
        let staged = dir.file("\(DiskImageInstaller.stagingPrefix)1A2B3C-Notes.txt", contents: "half written")
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "Tag text")
        rule.conditions = [makeCondition(.extension_, .is, "txt", ruleId: rule.id)]
        rule.actions = [makeAction(.addTag, .object([ActionParam.tags: .stringArray(["Seen"])]), ruleId: rule.id)]
        try db.insertRule(rule)

        #expect(RuleEngine.previewFile(path: staged, depth: 0, rules: [rule]) == nil)
        #expect(RuleEngine.run(path: staged, depth: 0, rules: [rule], batchId: "manual").history.isEmpty)
        #expect(!RuleEngine.walkEntries(root: dir.path, maxDepth: nil).contains { $0.path == staged })

        WatcherCoordinator(db: db).handle(path: staged)
        #expect(try db.listHistory().isEmpty)
    }
}
