import Testing
import Foundation
@testable import ForelCore

@Suite struct ActionExecutorTests {
    @Test func addAndRemoveTagUpdatesFinderTagXattrWithoutDuplicates() throws {
        let dir = TempDir()
        let file = dir.file("document.txt", contents: "hello")
        let add = makeAction(.addTag, .object(["tags": .stringArray(["Project"])]))
        let remove = makeAction(.removeTag, .object(["tags": .stringArray(["Project"])]))

        _ = try ActionExecutor.execute(add, path: file)
        _ = try ActionExecutor.execute(add, path: file)
        #expect(FinderTags.read(file) == ["Project"])

        _ = try ActionExecutor.execute(remove, path: file)
        #expect(FinderTags.read(file).isEmpty)
    }

    @Test func setColorLabelReplacesExistingColorAndPreservesTextTags() throws {
        let dir = TempDir()
        let file = dir.file("image.png", contents: "png")
        _ = try ActionExecutor.execute(makeAction(.addTag, .object(["tags": .stringArray(["Project"])])), path: file)
        _ = try ActionExecutor.execute(makeAction(.setColorLabel, .object(["color": .string("Red")])), path: file)
        _ = try ActionExecutor.execute(makeAction(.setColorLabel, .object(["color": .string("Blue")])), path: file)

        #expect(FinderTags.read(file) == ["Project", "Blue\n4"])
    }

    @Test func setColorLabelWithMissingColorClearsExistingLabel() throws {
        let dir = TempDir()
        let file = dir.file("image.png", contents: "png")
        _ = try ActionExecutor.execute(makeAction(.addTag, .object(["tags": .stringArray(["Project"])])), path: file)
        _ = try ActionExecutor.execute(makeAction(.setColorLabel, .object(["color": .string("Red")])), path: file)
        _ = try ActionExecutor.execute(makeAction(.setColorLabel, .object([:])), path: file)

        #expect(FinderTags.read(file) == ["Project"])
    }

    @Test func renamePatternDoesNotAppendExtensionTwiceWhenExtensionTokenIsUsed() throws {
        let dir = TempDir()
        let file = dir.file("report.txt", contents: "hello")
        let rename = makeAction(.rename, .object(["pattern": .string("{name}-archived.{extension}")]))

        _ = try ActionExecutor.execute(rename, path: file)

        #expect(!FileManager.default.fileExists(atPath: file))
        #expect(FileManager.default.fileExists(atPath: (dir.path as NSString).appendingPathComponent("report-archived.txt")))
        #expect(!FileManager.default.fileExists(atPath: (dir.path as NSString).appendingPathComponent("report-archived.txt.txt")))
    }

    @Test func moveToFolderRenamesOnConflictByDefault() throws {
        let dir = TempDir()
        let destination = dir.dir("Archive")
        let existing = (destination as NSString).appendingPathComponent("note.txt")
        try "old".write(toFile: existing, atomically: true, encoding: .utf8)
        let file = dir.file("note.txt", contents: "new")
        let moveAction = makeAction(.moveToFolder, .object(["destination": .string(destination)]))

        let applied = try ActionExecutor.execute(moveAction, path: file)

        let numbered = (destination as NSString).appendingPathComponent("note (1).txt")
        #expect(applied.newPath == numbered)
        #expect(try String(contentsOfFile: existing, encoding: .utf8) == "old")
        #expect(try String(contentsOfFile: numbered, encoding: .utf8) == "new")
    }

    @Test func moveToFolderReplacesExistingFileWhenConfigured() throws {
        let dir = TempDir()
        let destination = dir.dir("Archive")
        let existing = (destination as NSString).appendingPathComponent("note.txt")
        try "old".write(toFile: existing, atomically: true, encoding: .utf8)
        let file = dir.file("note.txt", contents: "new")
        let moveAction = makeAction(.moveToFolder, .object([
            "destination": .string(destination),
            "on_conflict": .string("replace"),
        ]))

        let applied = try ActionExecutor.execute(moveAction, path: file)

        #expect(applied.newPath == existing)
        #expect(try String(contentsOfFile: existing, encoding: .utf8) == "new")
        // The implementation sends the displaced file to `trashDir()` rather
        // than deleting it, but asserting against the real `~/.Trash`
        // listing here would be fragile (TCC/sandboxing, shared global
        // state across test runs) — covered at the `moveIntoDir` level by
        // code review instead of a filesystem assertion.
    }

    @Test func moveToFolderPlanPreviewMatchesWhatExecutionActuallyDoes() throws {
        let dir = TempDir()
        let destination = dir.dir("Archive")
        let existing = (destination as NSString).appendingPathComponent("note.txt")
        try "old".write(toFile: existing, atomically: true, encoding: .utf8)
        let file = dir.file("note.txt", contents: "new")
        let renameAction = makeAction(.moveToFolder, .object(["destination": .string(destination)]))

        let planned = try ActionExecutor.plan(renameAction, path: file)
        #expect(planned.status == .wouldRun)
        #expect(planned.description.contains("renamed to avoid"))

        let applied = try ActionExecutor.execute(renameAction, path: file)
        #expect(planned.targetPath == applied.newPath)
    }

    @Test func moveToFolderPlanDescribesReplaceConflict() throws {
        let dir = TempDir()
        let destination = dir.dir("Archive")
        try "old".write(toFile: (destination as NSString).appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let file = dir.file("note.txt", contents: "new")
        let replaceAction = makeAction(.moveToFolder, .object([
            "destination": .string(destination),
            "on_conflict": .string("replace"),
        ]))

        let planned = try ActionExecutor.plan(replaceAction, path: file)

        #expect(planned.status == .wouldRun)
        #expect(planned.description.contains("replacing"))
        #expect(planned.targetPath == (destination as NSString).appendingPathComponent("note.txt"))
    }

    @Test func moveToFolderSkipsOnConflictWhenConfigured() throws {
        let dir = TempDir()
        let destination = dir.dir("Archive")
        let existing = (destination as NSString).appendingPathComponent("note.txt")
        try "old".write(toFile: existing, atomically: true, encoding: .utf8)
        let file = dir.file("note.txt", contents: "new")
        let skipAction = makeAction(.moveToFolder, .object([
            "destination": .string(destination),
            "on_conflict": .string("skip"),
        ]))

        let planned = try ActionExecutor.plan(skipAction, path: file)

        #expect(planned.status == .wouldSkip)
        #expect(FileManager.default.fileExists(atPath: file))
        #expect(try String(contentsOfFile: existing, encoding: .utf8) == "old")
    }

    @Test func moveToFolderSkipDoesNotAffectAPlainMoveWithoutConflict() throws {
        let dir = TempDir()
        let destination = dir.dir("Archive")
        let file = dir.file("note.txt", contents: "new")
        let skipAction = makeAction(.moveToFolder, .object([
            "destination": .string(destination),
            "on_conflict": .string("skip"),
        ]))

        let planned = try ActionExecutor.plan(skipAction, path: file)
        #expect(planned.status == .wouldRun)

        let applied = try ActionExecutor.execute(skipAction, path: file)
        #expect(applied.newPath == (destination as NSString).appendingPathComponent("note.txt"))
    }

    @Test func revertMoveRestoresFileToOriginalLocation() throws {
        let dir = TempDir()
        let file = dir.file("note.txt", contents: "hello")
        let dest = (dir.path as NSString).appendingPathComponent("Archive")
        let moveAction = makeAction(.moveToFolder, .object(["destination": .string(dest)]))

        let applied = try ActionExecutor.execute(moveAction, path: file)
        #expect(!FileManager.default.fileExists(atPath: file))
        #expect(FileManager.default.fileExists(atPath: applied.newPath))

        try ActionExecutor.revert(applied.undo)
        #expect(FileManager.default.fileExists(atPath: file))
        #expect(!FileManager.default.fileExists(atPath: applied.newPath))
    }

    @Test func revertRenameRestoresOriginalName() throws {
        let dir = TempDir()
        let file = dir.file("report.txt", contents: "hi")
        let rename = makeAction(.rename, .object(["pattern": .string("renamed")]))

        let applied = try ActionExecutor.execute(rename, path: file)
        #expect(!FileManager.default.fileExists(atPath: file))

        try ActionExecutor.revert(applied.undo)
        #expect(FileManager.default.fileExists(atPath: file))
    }

    @Test func revertCopyDeletesTheCreatedCopy() throws {
        let dir = TempDir()
        let file = dir.file("data.bin", contents: "x")
        let dest = (dir.path as NSString).appendingPathComponent("Backup")
        let copyAction = makeAction(.copyToFolder, .object(["destination": .string(dest)]))

        let applied = try ActionExecutor.execute(copyAction, path: file)
        #expect(FileManager.default.fileExists(atPath: file))
        let copiedPath = (dest as NSString).appendingPathComponent("data.bin")
        #expect(FileManager.default.fileExists(atPath: copiedPath))

        try ActionExecutor.revert(applied.undo)
        #expect(FileManager.default.fileExists(atPath: file))
        #expect(!FileManager.default.fileExists(atPath: copiedPath))
    }

    @Test func revertAddTagOnlyRemovesNewlyAddedTags() throws {
        let dir = TempDir()
        let file = dir.file("doc.txt", contents: "x")
        _ = try ActionExecutor.execute(makeAction(.addTag, .object(["tags": .stringArray(["Existing"])])), path: file)

        let add = makeAction(.addTag, .object(["tags": .stringArray(["Existing", "Fresh"])]))
        let applied = try ActionExecutor.execute(add, path: file)
        #expect(FinderTags.read(file) == ["Existing", "Fresh"])

        try ActionExecutor.revert(applied.undo)
        #expect(FinderTags.read(file) == ["Existing"])
    }

    @Test func revertRemoveTagRestoresRemovedTags() throws {
        let dir = TempDir()
        let file = dir.file("doc.txt", contents: "x")
        _ = try ActionExecutor.execute(makeAction(.addTag, .object(["tags": .stringArray(["Keep"])])), path: file)

        let remove = makeAction(.removeTag, .object(["tags": .stringArray(["Keep"])]))
        let applied = try ActionExecutor.execute(remove, path: file)
        #expect(FinderTags.read(file).isEmpty)

        try ActionExecutor.revert(applied.undo)
        #expect(FinderTags.read(file) == ["Keep"])
    }

    @Test func revertColorLabelRestoresPreviousColor() throws {
        let dir = TempDir()
        let file = dir.file("image.png", contents: "png")
        _ = try ActionExecutor.execute(makeAction(.setColorLabel, .object(["color": .string("Red")])), path: file)

        let setBlue = makeAction(.setColorLabel, .object(["color": .string("Blue")]))
        let applied = try ActionExecutor.execute(setBlue, path: file)
        #expect(FinderTags.read(file) == ["Blue\n4"])

        try ActionExecutor.revert(applied.undo)
        #expect(FinderTags.read(file) == ["Red\n6"])
    }

    @Test func revertRunScriptIsRejectedAsIrreversible() throws {
        let dir = TempDir()
        let file = dir.file("x.txt", contents: "x")
        let script = makeAction(.runScript, .object(["script": .string("true")]))
        let applied = try ActionExecutor.execute(script, path: file)
        #expect(!applied.undo.isReversible)
        #expect(throws: (any Error).self) {
            try ActionExecutor.revert(applied.undo)
        }
    }

    @Test func runShortcutPreviewUsesShortcutNameAndSkipsWhenMissing() throws {
        let dir = TempDir()
        let file = dir.file("shortcut-input.txt", contents: "x")

        let named = makeAction(.runShortcut, .object(["shortcut_name": .string("Archive Invoice")]))
        let namedPlan = try ActionExecutor.plan(named, path: file)
        #expect(namedPlan.description == "Run shortcut: Archive Invoice")
        #expect(namedPlan.status == .wouldRun)
        #expect(namedPlan.finalPath == file)
        #expect(!namedPlan.isTerminal)

        let missing = makeAction(.runShortcut, .object([:]))
        let missingPlan = try ActionExecutor.plan(missing, path: file)
        #expect(missingPlan.description == "Run shortcut")
        #expect(missingPlan.status == .wouldSkip)
    }

    @Test func runShortcutInputModeDefaultsFallsBackAndAffectsPreview() throws {
        let dir = TempDir()
        let file = dir.file("shortcut-input.txt", contents: "x")

        let defaultAction = makeAction(.runShortcut, .object(["shortcut_name": .string("Archive Invoice")]))
        #expect(ActionExecutor.shortcutInputMode(defaultAction) == .matchedFile)

        let oldJsonAction = makeAction(.runShortcut, .object([
            "shortcut_name": .string("Archive Invoice"),
            "shortcut_input_mode": .string("json_context"),
        ]))
        #expect(ActionExecutor.shortcutInputMode(oldJsonAction) == .matchedFile)
        #expect(try ActionExecutor.plan(oldJsonAction, path: file).description == "Run shortcut: Archive Invoice")

        let noneAction = makeAction(.runShortcut, .object([
            "shortcut_name": .string("Archive Invoice"),
            "shortcut_input_mode": .string("none"),
        ]))
        #expect(try ActionExecutor.plan(noneAction, path: file).description == "Run shortcut: Archive Invoice with no input")
    }

    @Test func shortcutListParsingTrimsEmptyAndDuplicateNames() {
        let output = "\nArchive Invoice\n  Resize Images  \nArchive Invoice\n\n"
        #expect(ShortcutCatalog.parseShortcutList(output) == ["Archive Invoice", "Resize Images"])
    }

    @Test func shortcutRunnerBuildsArgumentsForInputModes() {
        #expect(ShortcutRunner.arguments(name: "Archive", input: .file("/tmp/a.txt")) == [
            "run", "Archive", "--input-path", "/tmp/a.txt",
        ])
        #expect(ShortcutRunner.arguments(name: "Archive", input: .none) == ["run", "Archive"])
    }
}
