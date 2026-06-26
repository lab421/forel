// Forel - A native macOS file-automation app
// Copyright (C) 2026  Lab421
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

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

    @Test func uncompressZipExtractsSingleRootItemAndMovesArchiveAway() throws {
        let dir = TempDir()
        let staging = dir.dir("staging")
        try "hello".write(toFile: (staging as NSString).appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        let zip = (dir.path as NSString).appendingPathComponent("download.zip")
        try makeZip(in: staging, items: ["report.txt"], destination: zip)
        try FileManager.default.removeItem(atPath: staging)

        let action = makeAction(.uncompress, .object([:]))
        let plan = try ActionExecutor.plan(action, path: zip)
        #expect(plan.targetPath == (dir.path as NSString).appendingPathComponent("report.txt"))
        #expect(plan.finalPath == plan.targetPath)

        let applied = try ActionExecutor.execute(action, path: zip)

        #expect(applied.newPath == (dir.path as NSString).appendingPathComponent("report.txt"))
        #expect(try String(contentsOfFile: applied.newPath, encoding: .utf8) == "hello")
        #expect(!FileManager.default.fileExists(atPath: zip))
        #expect(applied.undo == .none)
    }

    @Test func uncompressZipWithMultipleRootItemsExtractsIntoWrapperFolder() throws {
        let dir = TempDir()
        let staging = dir.dir("staging")
        try "a".write(toFile: (staging as NSString).appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "b".write(toFile: (staging as NSString).appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let zip = (dir.path as NSString).appendingPathComponent("bundle.zip")
        try makeZip(in: staging, items: ["a.txt", "b.txt"], destination: zip)
        try FileManager.default.removeItem(atPath: staging)

        let applied = try ActionExecutor.execute(makeAction(.uncompress, .object([:])), path: zip)

        #expect(applied.newPath == (dir.path as NSString).appendingPathComponent("bundle"))
        #expect(FileManager.default.fileExists(atPath: (applied.newPath as NSString).appendingPathComponent("a.txt")))
        #expect(FileManager.default.fileExists(atPath: (applied.newPath as NSString).appendingPathComponent("b.txt")))
        #expect(!FileManager.default.fileExists(atPath: zip))
    }

    @Test func uncompressSkipConflictPlansAndDoesNotExtract() throws {
        let dir = TempDir()
        _ = dir.file("report.txt", contents: "existing")
        let staging = dir.dir("staging")
        try "new".write(toFile: (staging as NSString).appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        let zip = (dir.path as NSString).appendingPathComponent("download.zip")
        try makeZip(in: staging, items: ["report.txt"], destination: zip)
        try FileManager.default.removeItem(atPath: staging)

        let action = makeAction(.uncompress, .object([ActionParam.onConflict: .string(MoveConflictResolution.skip.rawValue)]))
        let plan = try ActionExecutor.plan(action, path: zip)

        #expect(plan.status == .wouldSkip)
        #expect(plan.isTerminal)
        #expect(plan.finalPath == zip)
        #expect(try String(contentsOfFile: (dir.path as NSString).appendingPathComponent("report.txt"), encoding: .utf8) == "existing")
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

    // MARK: - Clean file name

    @Test func cleanFileNameStripsDiacriticsAndSpecialChars() {
        #expect(ActionExecutor.cleanFileName("café") == "cafe")
        #expect(ActionExecutor.cleanFileName("français") == "francais")
        #expect(ActionExecutor.cleanFileName("über cool") == "uber-cool")
        #expect(ActionExecutor.cleanFileName("naïve_file") == "naive-file")
        #expect(ActionExecutor.cleanFileName("München.txt") == "munchen.txt")
    }

    @Test func cleanFileNameConvertsSpacesAndUnderscoresToHyphens() {
        #expect(ActionExecutor.cleanFileName("hello world") == "hello-world")
        #expect(ActionExecutor.cleanFileName("hello_world") == "hello-world")
        #expect(ActionExecutor.cleanFileName("a b_c d") == "a-b-c-d")
    }

    @Test func cleanFileNameSplitsCamelCase() {
        #expect(ActionExecutor.cleanFileName("myFile") == "my-file")
        #expect(ActionExecutor.cleanFileName("PDFReport") == "pdfreport")
        #expect(ActionExecutor.cleanFileName("helloWorldAgain") == "hello-world-again")
        #expect(ActionExecutor.cleanFileName("my2Files") == "my2-files")
    }

    @Test func cleanFileNameRemovesSpecialCharacters() {
        #expect(ActionExecutor.cleanFileName("hello's world") == "hellos-world")
        #expect(ActionExecutor.cleanFileName("price (2024).txt") == "price-2024.txt")
        #expect(ActionExecutor.cleanFileName("file@name!") == "filename")
        #expect(ActionExecutor.cleanFileName("100% done") == "100-done")
    }

    @Test func cleanFileNameCollapsesMultipleHyphens() {
        #expect(ActionExecutor.cleanFileName("hello   world") == "hello-world")
        #expect(ActionExecutor.cleanFileName("hello___world") == "hello-world")
        #expect(ActionExecutor.cleanFileName("hello - world") == "hello-world")
    }

    @Test func cleanFileNameStripsLeadingAndTrailingHyphens() {
        #expect(ActionExecutor.cleanFileName(" hello ") == "hello")
        #expect(ActionExecutor.cleanFileName("_hello_") == "hello")
        #expect(ActionExecutor.cleanFileName("-hello-") == "hello")
    }

    @Test func cleanFileNamePreservesExtension() {
        #expect(ActionExecutor.cleanFileName("Hello World.txt") == "hello-world.txt")
        #expect(ActionExecutor.cleanFileName("Café Report.PDF") == "cafe-report.PDF")
        #expect(ActionExecutor.cleanFileName("myFile.txt") == "my-file.txt")
    }

    @Test func cleanFileNameFallsBackToOriginalWhenResultIsEmpty() {
        #expect(ActionExecutor.cleanFileName("___") == "___")
        #expect(ActionExecutor.cleanFileName("!@#") == "!@#")
    }

    @Test func cleanFileNameHandlesComplexMixedInput() {
        #expect(ActionExecutor.cleanFileName("L'Été 2024 (Report).txt") == "lete-2024-report.txt")
        #expect(ActionExecutor.cleanFileName("Déjà_Vu - Copy (2).txt") == "deja-vu-copy-2.txt")
        #expect(ActionExecutor.cleanFileName("MyCafé_Report (final)") == "my-cafe-report-final")
    }

    @Test func cleanFileNameWithOptionRenamesFileCorrectly() throws {
        let dir = TempDir()
        let file = dir.file("Café Report.txt", contents: "hello")
        let rename = makeAction(.rename, .object([
            "pattern": .string("{name}"),
            "clean_file_name": .bool(true),
        ]))

        _ = try ActionExecutor.execute(rename, path: file)

        #expect(!FileManager.default.fileExists(atPath: file))
        #expect(FileManager.default.fileExists(atPath: (dir.path as NSString).appendingPathComponent("cafe-report.txt")))
    }

    // MARK: - Rename

    @Test func revertRenameRestoresOriginalName() throws {
        let dir = TempDir()
        let file = dir.file("report.txt", contents: "hi")
        let rename = makeAction(.rename, .object(["pattern": .string("renamed")]))

        let applied = try ActionExecutor.execute(rename, path: file)
        #expect(!FileManager.default.fileExists(atPath: file))

        try ActionExecutor.revert(applied.undo)
        #expect(FileManager.default.fileExists(atPath: file))
    }

    /// Copy is intentionally not reversible (matches Revert, which
    /// doesn't cover Copy either): a copy is an independent file once
    /// created, not something to roll back.
    @Test func copyIsNotReversibleButStillTracksWhereItLanded() throws {
        let dir = TempDir()
        let file = dir.file("data.bin", contents: "x")
        let dest = (dir.path as NSString).appendingPathComponent("Backup")
        let copyAction = makeAction(.copyToFolder, .object(["destination": .string(dest)]))

        let applied = try ActionExecutor.execute(copyAction, path: file)
        #expect(FileManager.default.fileExists(atPath: file))
        let copiedPath = (dest as NSString).appendingPathComponent("data.bin")
        #expect(FileManager.default.fileExists(atPath: copiedPath))

        #expect(applied.undo.isReversible == false)
        #expect(applied.copiedPath == copiedPath)
    }

    /// Copies recorded before this behavior changed are still revertible —
    /// existing history entries keep working exactly as they did when saved.
    @Test func revertStillSupportsCopyEntriesSavedBeforeCopyBecameIrreversible() throws {
        let dir = TempDir()
        let file = dir.file("data.bin", contents: "x")
        let copiedPath = (dir.path as NSString).appendingPathComponent("data (copy).bin")
        try FileManager.default.copyItem(atPath: file, toPath: copiedPath)

        try ActionExecutor.revert(.copy(copy: copiedPath))

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
        #expect(try ActionExecutor.preview(oldJsonAction, path: file) == "Run shortcut: Archive Invoice")

        let noneAction = makeAction(.runShortcut, .object([
            "shortcut_name": .string("Archive Invoice"),
            "shortcut_input_mode": .string("none"),
        ]))
        #expect(try ActionExecutor.preview(noneAction, path: file) == "Run shortcut: Archive Invoice with no input")
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

func makeZip(in directory: String, items: [String], destination: String) throws {
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zip.currentDirectoryURL = URL(fileURLWithPath: directory)
    zip.arguments = ["-r", "-q", destination] + items
    zip.standardError = FileHandle.nullDevice
    try zip.run()
    zip.waitUntilExit()
    if zip.terminationStatus != 0 {
        throw ActionError("zip exited with status \(zip.terminationStatus)")
    }
}
