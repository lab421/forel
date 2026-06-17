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
}
