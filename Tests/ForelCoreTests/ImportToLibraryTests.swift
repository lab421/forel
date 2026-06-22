import Testing
import Foundation
#if canImport(Photos)
import Photos
#endif
@testable import ForelCore

/// Covers the format/parameter logic of the Import to Library action that can be
/// exercised without a real Music/Photos/TV library. The actual import paths
/// drive system apps over AppleScript/PhotoKit and aren't unit-testable here;
/// these tests pin down the parts that gate them — format compatibility,
/// conflict-resolution defaults, and parameter validation — so the three
/// execution paths (Dry Run, Run Now, watcher) stay consistent.
@Suite struct ImportToLibraryTests {
    // MARK: - Format compatibility

    @Test func canImportToLibraryAcceptsOnlyCompatibleFormats() {
        let dir = TempDir()
        let audio = dir.file("song.mp3", contents: "x")
        let image = dir.file("photo.png", contents: "x")
        let movie = dir.file("clip.mov", contents: "x")
        let text = dir.file("notes.txt", contents: "x")

        // Music accepts audio only.
        #expect(ActionExecutor.canImportToLibrary(audio, libraryType: .music))
        #expect(!ActionExecutor.canImportToLibrary(image, libraryType: .music))
        #expect(!ActionExecutor.canImportToLibrary(text, libraryType: .music))

        // Photos accepts images and movies.
        #expect(ActionExecutor.canImportToLibrary(image, libraryType: .photos))
        #expect(ActionExecutor.canImportToLibrary(movie, libraryType: .photos))
        #expect(!ActionExecutor.canImportToLibrary(audio, libraryType: .photos))
        #expect(!ActionExecutor.canImportToLibrary(text, libraryType: .photos))

        // TV accepts movies only.
        #expect(ActionExecutor.canImportToLibrary(movie, libraryType: .tv))
        #expect(!ActionExecutor.canImportToLibrary(audio, libraryType: .tv))
        #expect(!ActionExecutor.canImportToLibrary(image, libraryType: .tv))
    }

    @Test func formatDescriptionIsNonEmptyForEveryLibrary() {
        for type in LibraryType.allCases {
            #expect(!ActionExecutor.formatDescription(for: type).isEmpty)
        }
    }

    // MARK: - Conflict resolution defaults

    @Test func conflictResolutionUsesProvidedDefaultWhenParamMissing() {
        let noParam = makeAction(.importToLibrary, .object(["library_type": .string("music")]))
        #expect(ActionExecutor.conflictResolution(noParam, default: .skip) == .skip)

        let explicit = makeAction(.importToLibrary, .object([ActionParam.onConflict: .string("replace")]))
        #expect(ActionExecutor.conflictResolution(explicit, default: .skip) == .replace)

        // An unrecognized value falls back to the supplied default rather than .rename.
        let garbage = makeAction(.importToLibrary, .object([ActionParam.onConflict: .string("nonsense")]))
        #expect(ActionExecutor.conflictResolution(garbage, default: .skip) == .skip)
    }

    // MARK: - Parameter validation (safe paths that never touch a real library)

    @Test func executeRejectsIncompatibleFormatBeforeTouchingLibrary() {
        let dir = TempDir()
        let text = dir.file("notes.txt", contents: "x")
        let action = makeAction(.importToLibrary, .object(["library_type": .string("music")]))
        #expect(throws: (any Error).self) {
            try ActionExecutor.execute(action, path: text)
        }
    }

    @Test func planRejectsIncompatibleFormat() {
        let dir = TempDir()
        let text = dir.file("notes.txt", contents: "x")
        let action = makeAction(.importToLibrary, .object(["library_type": .string("tv")]))
        #expect(throws: (any Error).self) {
            try ActionExecutor.plan(action, path: text)
        }
    }

    @Test func invalidLibraryTypeThrows() {
        let dir = TempDir()
        let audio = dir.file("song.mp3", contents: "x")
        let action = makeAction(.importToLibrary, .object(["library_type": .string("nonsense")]))
        #expect(throws: (any Error).self) {
            try ActionExecutor.plan(action, path: audio)
        }
        #expect(throws: (any Error).self) {
            try ActionExecutor.execute(action, path: audio)
        }
    }

    // MARK: - Duplicate-detection predicates (regression guards)
    //
    // These pin down three crashes/bugs found in manual testing:
    // - AppleScript rejects a compound `whose (a) or (b)` clause with a syntax
    //   error (-10003); the fix is to issue each predicate as a separate
    //   `whose` check rather than combining them with `or`.
    // - Matching copied imports by byte size alone caused false positives: any
    //   unrelated track sharing that exact size made "already imported"
    //   detection stick forever, even after the real match was deleted from
    //   the library. The fix also compares the destination filename.
    // - PHFetchOptions only allows a small set of predicate keys; using
    //   `originalFilename` throws NSInvalidArgumentException at fetch time.
    //   The fix narrows by `mediaType` (an allowed key) and matches filename
    //   in code afterwards.

    @Test func musicTVSizeAndNameCheckNeverUsesACompoundWhoseClause() throws {
        let dir = TempDir()
        let file = dir.file("song.mp3", contents: "audio-bytes")
        let fragment = try #require(ActionExecutor.musicTVSizeAndNameCheck(path: file, onMatch: "return true"))

        // AppleScript rejects "whose (a) or (b)" combined in a single clause;
        // this fragment must filter by size only, then confirm in a loop.
        #expect(!fragment.contains(" or "))
        #expect(fragment.contains("whose size is"))
    }

    @Test func musicTVSizeAndNameCheckMatchesByFilenameNotJustSize() throws {
        let dir = TempDir()
        let file = dir.file("song.mp3", contents: "audio-bytes")
        let fragment = try #require(ActionExecutor.musicTVSizeAndNameCheck(path: file, onMatch: "return true"))

        // Matching on size alone caused false positives against unrelated
        // tracks of the same byte size; the destination filename must also be
        // checked via a path suffix (Music relocates the file, so it's not an
        // exact path match), with a leading separator so "song.mp3" can't
        // match a track actually named "mysong.mp3".
        #expect(fragment.contains("ends with \"/song.mp3\""))
        #expect(fragment.contains(#"if (POSIX path of (location of t)) ends with "/song.mp3" then return true"#))
    }

    @Test func musicTVSizeAndNameCheckUsesTheGivenOnMatchStatement() throws {
        let dir = TempDir()
        let file = dir.file("song.mp3", contents: "audio-bytes")
        let fragment = try #require(ActionExecutor.musicTVSizeAndNameCheck(path: file, onMatch: "delete t"))
        #expect(fragment.contains("then delete t"))
    }

    @Test func musicTVSizeAndNameCheckReturnsNilWhenSourceFileIsMissing() {
        #expect(ActionExecutor.musicTVSizeAndNameCheck(path: "/nonexistent/path/song.mp3", onMatch: "return true") == nil)
    }

    // Pins down a fourth bug found in manual testing: the Automation
    // permission probe used `tell application "X" to get name`, but
    // `name`/`version` are part of every scriptable app's Required Suite,
    // which macOS answers without enforcing Automation consent at all — so
    // the check always reported "granted" regardless of the real grant,
    // confirmed by it showing granted right after resetting permissions.
    // `count of tracks` reads real library data, the same class of event the
    // actual import sends, so it's gated identically.
    @Test func automationProbeScriptReadsRealDataNotJustRequiredSuiteMetadata() {
        let script = ActionExecutor.automationProbeScript(app: "Music")
        #expect(!script.contains("get name"))
        #expect(script.contains("count of tracks"))
        #expect(script.contains("\"Music\""))
    }

    #if canImport(Photos)
    @Test func photoFetchPredicateFiltersByMediaTypeNeverByFilename() {
        for isVideo in [true, false] {
            let predicate = ActionExecutor.photoFetchPredicate(isVideo: isVideo)
            // originalFilename is not a supported PHFetchOptions predicate key —
            // using it crashes PHAsset.fetchAssets(with:) outright.
            #expect(!predicate.predicateFormat.contains("originalFilename"))
            #expect(predicate.predicateFormat.contains("mediaType"))
        }
        let imageFormat = ActionExecutor.photoFetchPredicate(isVideo: false).predicateFormat
        let videoFormat = ActionExecutor.photoFetchPredicate(isVideo: true).predicateFormat
        #expect(imageFormat != videoFormat)
    }
    #endif

    @Test func fileByteSizeReturnsSizeForExistingFileAndNilForMissingFile() {
        let dir = TempDir()
        let file = dir.file("data.bin", contents: String(repeating: "x", count: 42))
        #expect(ActionExecutor.fileByteSize(file) == 42)
        #expect(ActionExecutor.fileByteSize("/nonexistent/path/missing.bin") == nil)
    }

    // MARK: - Persistence round-trip

    @Test func importToLibraryActionSurvivesDatabaseRoundTrip() throws {
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: "/tmp/forel-test-\(UUID().uuidString)")
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "import audio")
        try db.insertRule(rule)

        let params: JSONValue = .object([
            ActionParam.libraryType: .string(LibraryType.music.rawValue),
            ActionParam.targetPlaylist: .string("Favorites"),
            ActionParam.onConflict: .string(MoveConflictResolution.replace.rawValue),
        ])
        rule.actions = [makeAction(.importToLibrary, params, position: 0, ruleId: rule.id)]
        try db.updateRule(rule)

        let loaded = try db.listRules(folderId: folder.id)[0]
        #expect(loaded.actions.count == 1)
        #expect(loaded.actions[0].kind == .importToLibrary)
        #expect(loaded.actions[0].params == params)
    }
}
