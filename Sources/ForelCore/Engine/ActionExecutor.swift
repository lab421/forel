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

import Foundation
import UniformTypeIdentifiers
import ZIPFoundation
#if canImport(Photos)
import Photos
#endif

public struct ActionError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Reversal recipe for an executed action. Serialised to JSON and stored in the
/// action history so the change can be undone after the fact. Matches the Rust
/// `Undo` enum's `{"kind": "...", ...}` tagged JSON shape exactly.
public enum Undo: Equatable, Sendable {
    /// File was relocated; undo by moving `to` back to `from`.
    case move(from: String, to: String)
    /// A copy was created; undo by deleting it.
    /// No longer produced by new `copyToFolder` runs (the copy is an
    /// independent file, not something to roll back
    /// Revert, which doesn't cover Copy either). Kept so history entries
    /// already saved with this payload can still be parsed and reverted.
    case copy(copy: String)
    /// Tags were added; undo by removing exactly these.
    case addTags(path: String, tags: [String])
    /// Tags were removed; undo by re-adding exactly these.
    case removeTags(path: String, tags: [String])
    /// Colour label changed; undo by restoring `previous` ("" = none).
    case color(path: String, previous: String)
    /// Not reversible (e.g. a script with arbitrary side effects).
    case none

    public var isReversible: Bool {
        if case .none = self { return false }
        return true
    }

    public func toJSON() -> JSONValue {
        switch self {
        case .move(let from, let to):
            return .object(["kind": .string("move"), "from": .string(from), "to": .string(to)])
        case .copy(let copy):
            return .object(["kind": .string("copy"), "copy": .string(copy)])
        case .addTags(let path, let tags):
            return .object(["kind": .string("add_tags"), "path": .string(path), "tags": .stringArray(tags)])
        case .removeTags(let path, let tags):
            return .object(["kind": .string("remove_tags"), "path": .string(path), "tags": .stringArray(tags)])
        case .color(let path, let previous):
            return .object(["kind": .string("color"), "path": .string(path), "previous": .string(previous)])
        case .none:
            return .object(["kind": .string("none")])
        }
    }

    public static func fromJSON(_ json: JSONValue) -> Undo {
        guard let kind = json["kind"]?.stringValue else { return .none }
        switch kind {
        case "move":
            return .move(from: json["from"]?.stringValue ?? "", to: json["to"]?.stringValue ?? "")
        case "copy":
            return .copy(copy: json["copy"]?.stringValue ?? "")
        case "add_tags":
            return .addTags(path: json["path"]?.stringValue ?? "", tags: (json["tags"]?.arrayValue ?? []).compactMap(\.stringValue))
        case "remove_tags":
            return .removeTags(path: json["path"]?.stringValue ?? "", tags: (json["tags"]?.arrayValue ?? []).compactMap(\.stringValue))
        case "color":
            return .color(path: json["path"]?.stringValue ?? "", previous: json["previous"]?.stringValue ?? "")
        default:
            return .none
        }
    }
}

/// Outcome of executing an action: where the file ended up, plus the
/// information needed to reverse the change later.
public struct Applied {
    public let newPath: String
    public let undo: Undo
    /// Where a copy landed, when this action created one — tracked
    /// separately from `undo` since `copyToFolder` isn't undoable (see
    /// `Undo`) but the rule engine still needs to know the copy exists, to
    /// evaluate it against the rules that follow.
    public let copiedPath: String?

    public init(newPath: String, undo: Undo, copiedPath: String? = nil) {
        self.newPath = newPath
        self.undo = undo
        self.copiedPath = copiedPath
    }
}

/// How `moveToFolder`/`copyToFolder` resolve a destination that already has
/// a file with the same name. `rename` (the default) keeps both files;
/// `replace` keeps only the new one, sending the file it displaces to the
/// Trash rather than deleting it outright; `skip` leaves the source
/// untouched so nothing is moved/copied and no duplicate is created.
public enum MoveConflictResolution: String, CaseIterable, Sendable {
    case rename
    case replace
    case skip

    public var label: String {
        switch self {
        case .rename: return "Rename the file"
        case .replace: return "Replace existing file"
        case .skip: return "Skip the file"
        }
    }
}

public enum ShortcutInputMode: String, CaseIterable, Sendable {
    case matchedFile = "matched_file"
    case none

    public var label: String {
        switch self {
        case .matchedFile: return "Matched file"
        case .none: return "No input"
        }
    }
}

public enum DryRunStatus: String, Codable, Equatable, Sendable {
    case wouldRun = "would_run"
    case wouldSkip = "would_skip"
    case blockedByConflict = "blocked_by_conflict"
    case needsConfirmation = "needs_confirmation"
}

public struct ActionPlan: Equatable, Sendable {
    public let kind: ActionKind
    public let description: String
    public let sourcePath: String
    public let targetPath: String?
    public let status: DryRunStatus
    public let finalPath: String
    public let copiedPath: String?
    public let isTerminal: Bool

    public init(
        kind: ActionKind,
        description: String,
        sourcePath: String,
        targetPath: String?,
        status: DryRunStatus,
        finalPath: String,
        copiedPath: String?,
        isTerminal: Bool
    ) {
        self.kind = kind
        self.description = description
        self.sourcePath = sourcePath
        self.targetPath = targetPath
        self.status = status
        self.finalPath = finalPath
        self.copiedPath = copiedPath
        self.isTerminal = isTerminal
    }
}

public enum ActionExecutor {
    /// Executes the action on the file at `path`, returning the new path and an
    /// `Undo` describing how to reverse it.
    public static func execute(_ action: Action, path: String) throws -> Applied {
        switch action.kind {
        case .moveToFolder:
            let destDir = try stringParam(action, ActionParam.destination, "MoveToFolder")
            return try moveIntoDir(path: path, destDir: destDir, resolution: conflictResolution(action))
        case .copyToFolder:
            return try copyToFolder(action, path: path)
        case .rename:
            return try renameFile(action, path: path)
        case .moveToTrash:
            return try moveIntoDir(path: path, destDir: try trashDir())
        case .delete:
            try FileManager.default.removeItem(atPath: path)
            return Applied(newPath: path, undo: .none)
        case .addTag:
            return try applyTags(action, path: path, add: true)
        case .removeTag:
            return try applyTags(action, path: path, add: false)
        case .setColorLabel:
            return try setColor(action, path: path)
        case .runScript:
            return try runScript(action, path: path)
        case .runShortcut:
            return try runShortcut(action, path: path)
        case .importToLibrary:
            return try importToLibrary(action, path: path)
        case .uncompress:
            return try uncompress(action, path: path)
        }
    }

    private static func stringParam(_ action: Action, _ key: String, _ kind: String) throws -> String {
        guard let value = action.params[key]?.stringValue else {
            throw ActionError("\(kind) requires '\(key)' param")
        }
        return value
    }

    /// Moves `path` into `destDir` (created if needed). `resolution` decides
    /// what happens if a file with the same name is already there (see
    /// `resolveDestination`). Trash/delete have no user-facing conflict
    /// choice and always use the `.rename` default.
    private static func moveIntoDir(path: String, destDir: String, resolution: MoveConflictResolution = .rename) throws -> Applied {
        try FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        let fileName = (path as NSString).lastPathComponent
        let naiveDest = (destDir as NSString).appendingPathComponent(fileName)
        let dest = try resolveDestination(naiveDest: naiveDest, dir: destDir, fileName: fileName, resolution: resolution)
        try FileManager.default.moveItem(atPath: path, toPath: dest)
        return Applied(newPath: dest, undo: .move(from: path, to: dest))
    }

    private static func copyToFolder(_ action: Action, path: String) throws -> Applied {
        let destDir = try stringParam(action, ActionParam.destination, "CopyToFolder")
        try FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        let fileName = (path as NSString).lastPathComponent
        let naiveDest = (destDir as NSString).appendingPathComponent(fileName)
        let dest = try resolveDestination(naiveDest: naiveDest, dir: destDir, fileName: fileName, resolution: conflictResolution(action))
        try FileManager.default.copyItem(atPath: path, toPath: dest)
        return Applied(newPath: path, undo: .none, copiedPath: dest)
    }

    private struct ZipExtractionPlan {
        let target: String
        let topLevelItems: [String]
        let usesWrapperFolder: Bool
        let conflicts: Bool
        let resolution: MoveConflictResolution
    }

    private static func uncompress(_ action: Action, path: String) throws -> Applied {
        let plan = try zipExtractionPlan(action, path: path)
        if plan.conflicts, plan.resolution == .skip {
            throw ActionError("Skip — a file already exists at \(plan.target)")
        }

        let fm = FileManager.default
        let archiveURL = URL(fileURLWithPath: path)
        let replacementDir = try fm.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: archiveURL,
            create: true
        ).path
        let tempDir = (replacementDir as NSString).appendingPathComponent(".forel-uncompress-\(UUID().uuidString)")
        try fm.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: replacementDir) }

        do {
            try fm.unzipItem(at: archiveURL, to: URL(fileURLWithPath: tempDir))
        } catch {
            throw ActionError("Could not uncompress ZIP archive: \(error)")
        }

        if plan.conflicts, plan.resolution == .replace {
            _ = try moveIntoDir(path: plan.target, destDir: try trashDir())
        }

        if plan.usesWrapperFolder {
            try fm.createDirectory(atPath: plan.target, withIntermediateDirectories: true)
            for item in plan.topLevelItems {
                let extracted = (tempDir as NSString).appendingPathComponent(item)
                let destination = (plan.target as NSString).appendingPathComponent(item)
                try fm.moveItem(atPath: extracted, toPath: destination)
            }
        } else if let item = plan.topLevelItems.first {
            let extracted = (tempDir as NSString).appendingPathComponent(item)
            try fm.moveItem(atPath: extracted, toPath: plan.target)
        }

        _ = try moveIntoDir(path: path, destDir: try trashDir())
        return Applied(newPath: plan.target, undo: .none)
    }

    /// Resolves the actual path a move/copy should write to, given the
    /// configured conflict resolution: `.rename` numbers the file instead;
    /// `.replace` sends whatever is already at `naiveDest` to the Trash
    /// first, then returns `naiveDest` itself; `.skip` also returns
    /// `naiveDest` — planning already turns a real conflict under `.skip`
    /// into `wouldSkip` so this is never reached with one in practice, and
    /// if it somehow is, the caller's move/copy call throws instead of
    /// silently overwriting.
    private static func resolveDestination(naiveDest: String, dir: String, fileName: String, resolution: MoveConflictResolution) throws -> String {
        switch resolution {
        case .rename:
            return uniqueDest(dir: dir, fileName: fileName)
        case .replace:
            if FileManager.default.fileExists(atPath: naiveDest) {
                let displaced = uniqueDest(dir: try trashDir(), fileName: fileName)
                try FileManager.default.moveItem(atPath: naiveDest, toPath: displaced)
            }
            return naiveDest
        case .skip:
            return naiveDest
        }
    }

    static func conflictResolution(_ action: Action, default defaultResolution: MoveConflictResolution = .rename) -> MoveConflictResolution {
        guard let raw = action.params[ActionParam.onConflict]?.stringValue else { return defaultResolution }
        return MoveConflictResolution(rawValue: raw) ?? defaultResolution
    }

    private static func renameFile(_ action: Action, path: String) throws -> Applied {
        let pattern = try stringParam(action, ActionParam.pattern, "Rename")
        var newName = try applyRenamePattern(pattern, path: path)
        if action.params[ActionParam.cleanFileName]?.boolValue == true {
            newName = cleanFileName(newName)
        }
        let dest = (path as NSString).deletingLastPathComponent + "/" + newName
        try FileManager.default.moveItem(atPath: path, toPath: dest)
        return Applied(newPath: dest, undo: .move(from: path, to: dest))
    }

    /// Adds (`add = true`) or removes Finder tags, capturing exactly the tags
    /// that actually changed so the undo only touches those.
    private static func applyTags(_ action: Action, path: String, add: Bool) throws -> Applied {
        let existing = FinderTags.read(path)
        var changed: [String] = []
        for tag in paramTags(action) {
            let present = existing.contains(tag)
            if present != add && !changed.contains(tag) { changed.append(tag) }
            try FinderTags.apply(path, tag: tag, add: add)
        }
        let undo: Undo = add ? .addTags(path: path, tags: changed) : .removeTags(path: path, tags: changed)
        return Applied(newPath: path, undo: undo)
    }

    private static func setColor(_ action: Action, path: String) throws -> Applied {
        let color = action.params[ActionParam.color]?.stringValue ?? ""
        let previous = FinderTags.currentColorName(path)
        try FinderTags.setColorLabel(path, color: color)
        return Applied(newPath: path, undo: .color(path: path, previous: previous))
    }

    private static let scriptDefaultTimeout: TimeInterval = 60

    private static func runScript(_ action: Action, path: String) throws -> Applied {
        let script = try stringParam(action, ActionParam.script, "RunScript")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        var env = ProcessInfo.processInfo.environment
        env["FOREL_FILE"] = path
        process.environment = env
        try process.run()

        let startTime = Date()
        while process.isRunning && Date().timeIntervalSince(startTime) < scriptDefaultTimeout {
            Thread.sleep(forTimeInterval: 0.01)
        }

        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning {
                process.interrupt()
            }
            throw ActionError("script timed out after \(Int(scriptDefaultTimeout))s")
        }

        guard process.terminationStatus == 0 else {
            throw ActionError("script exited with status \(process.terminationStatus)")
        }
        return Applied(newPath: path, undo: .none)
    }

    private static func runShortcut(_ action: Action, path: String) throws -> Applied {
        let name = try stringParam(action, ActionParam.shortcutName, "RunShortcut")
        let inputMode = shortcutInputMode(action)
        try ShortcutRunner.run(name: name, input: shortcutInput(mode: inputMode, path: path))
        return Applied(newPath: path, undo: .none)
    }

    // MARK: - Import to Library

    private static func importToLibrary(_ action: Action, path: String) throws -> Applied {
        let libraryTypeRaw = action.params[ActionParam.libraryType]?.stringValue ?? LibraryType.music.rawValue
        guard let libraryType = LibraryType(rawValue: libraryTypeRaw) else {
            throw ActionError("Import to Library requires a 'library_type' parameter")
        }

        guard canImportToLibrary(path, libraryType: libraryType) else {
            throw ActionError("File format not supported by \(libraryType.label) — requires \(formatDescription(for: libraryType))")
        }

        if let accessMessage = ensureLibraryAccess(libraryType: libraryType, launchIfNeeded: true) {
            throw ActionError("Import to \(libraryType.label) — \(accessMessage)")
        }

        let playlist = action.params[ActionParam.targetPlaylist]?.stringValue ?? ""

        let resolution = conflictResolution(action, default: .skip)
        if resolution == .skip {
            if try libraryContainsFile(path, libraryType: libraryType, launchIfNeeded: true) {
                throw ActionError("Skip — file already exists in \(libraryType.label)")
            }
        } else if resolution == .replace {
            if try libraryContainsFile(path, libraryType: libraryType, launchIfNeeded: true) {
                try removeFromLibrary(path, libraryType: libraryType)
            }
        }

        try performImport(path: path, libraryType: libraryType, playlist: playlist)
        return Applied(newPath: path, undo: .none)
    }

    static func canImportToLibrary(_ path: String, libraryType: LibraryType) -> Bool {
        guard let typeID = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier,
              let utType = UTType(typeID) else {
            return false
        }
        switch libraryType {
        case .music:
            return utType.conforms(to: .audio)
        case .photos:
            return utType.conforms(to: .image) || utType.conforms(to: .movie)
        case .tv:
            return utType.conforms(to: .movie)
        }
    }

    static func formatDescription(for libraryType: LibraryType) -> String {
        switch libraryType {
        case .music: return "an audio file (MP3, AAC, WAV, AIFF, ALAC, etc.)"
        case .photos: return "an image or video file (JPEG, PNG, TIFF, HEIC, RAW, MP4, MOV, etc.)"
        case .tv: return "a video file (MP4, MOV, M4V, etc.)"
        }
    }

    /// Checks whether the file already exists in the target library.
    ///
    /// For Music/TV this talks to the app over AppleScript. When `launchIfNeeded`
    /// is `false` (Dry Run) and the app isn't already running, it returns `false`
    /// rather than launching the app for a mere preview.
    private static func libraryContainsFile(_ path: String, libraryType: LibraryType, launchIfNeeded: Bool) throws -> Bool {
        switch libraryType {
        case .music:
            return try musicTVLibraryContainsFile(app: "Music", path: path, launchIfNeeded: launchIfNeeded)
        case .photos:
            return photosLibraryContainsFile(path)
        case .tv:
            return try musicTVLibraryContainsFile(app: "TV", path: path, launchIfNeeded: launchIfNeeded)
        }
    }

    /// Size of the file on disk in bytes, used to confirm a library match by
    /// content rather than only by path (Music/TV copy files into their media
    /// folder, so the original path no longer matches once imported).
    static func fileByteSize(_ path: String) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return (attrs[.size] as? NSNumber)?.int64Value
    }

    /// Whether the given app already has a running process, checked via System
    /// Events so we don't launch the app itself just to ask. Shared with
    /// `PermissionsChecker`, which surfaces the same check in Settings.
    static func isAppRunning(_ app: String) -> Bool {
        let script = "tell application \"System Events\" to (exists (process \"\(appleScriptEscapePath(app))\"))"
        return (try? runAppleScript(script)) == "true"
    }

    private static func removeFromLibrary(_ path: String, libraryType: LibraryType) throws {
        switch libraryType {
        case .music:
            try removeFromMusicTVLibrary(app: "Music", path: path)
        case .photos:
            try removeFromPhotosLibrary(path)
        case .tv:
            try removeFromMusicTVLibrary(app: "TV", path: path)
        }
    }

    private static func performImport(path: String, libraryType: LibraryType, playlist: String = "") throws {
        switch libraryType {
        case .music:
            try importViaAppleScript(app: "Music", path: path, playlist: playlist)
        case .photos:
            try importToPhotos(path: path, album: playlist)
        case .tv:
            try importViaAppleScript(app: "TV", path: path, playlist: playlist)
        }
    }

    // MARK: - AppleScript helpers

    @discardableResult
    static func runAppleScript(_ script: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let errorMsg = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            throw ActionError("AppleScript failed: \(errorMsg)")
        }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func appleScriptEscapePath(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func importViaAppleScript(app: String, path: String, playlist: String = "") throws {
        let escapedPath = appleScriptEscapePath(path)
        let playlistClause: String
        if playlist.isEmpty {
            playlistClause = ""
        } else {
            let escapedPlaylist = appleScriptEscapePath(playlist)
            playlistClause = " to playlist \"\(escapedPlaylist)\""
        }
        let script = """
        tell application "\(app)"
            set theFile to (POSIX file "\(escapedPath)") as alias
            add theFile\(playlistClause)
        end tell
        """
        try runAppleScript(script)
    }

    /// AppleScript fragment that matches tracks by byte size *and* filename —
    /// the fallback for copied imports, where Music relocates the file into its
    /// media folder and the original `location` no longer matches.
    ///
    /// Matching by size alone (the original fix for the location problem)
    /// caused a worse bug: any other track in the user's library that happens
    /// to share that exact byte size makes "already imported" detection stick
    /// forever, even after the real match was deleted from the library. Byte
    /// size collisions between unrelated tracks are common (same bitrate +
    /// duration), so we also compare the destination filename — read via
    /// `POSIX path of (location of t)`, since `whose` clauses can't filter on
    /// a computed string directly. The comparison uses `ends with "/name"`
    /// (with the leading separator) rather than exact equality, since
    /// `location` is the full path Music moved the file to.
    ///
    /// Returns `nil` when the source file's size can't be read.
    static func musicTVSizeAndNameCheck(path: String, onMatch: String) -> String? {
        guard let size = fileByteSize(path) else { return nil }
        let suffix = appleScriptEscapePath("/" + (path as NSString).lastPathComponent)
        return """
            try
                repeat with t in (every track whose size is \(size))
                    try
                        if (POSIX path of (location of t)) ends with "\(suffix)" then \(onMatch)
                    end try
                end repeat
            end try
        """
    }

    private static func musicTVLibraryContainsFile(app: String, path: String, launchIfNeeded: Bool) throws -> Bool {
        if !launchIfNeeded && !isAppRunning(app) { return false }
        let escaped = appleScriptEscapePath(path)
        var script = """
        tell application "\(app)"
            set fileRef to (POSIX file "\(escaped)") as alias
            try
                if (count of (every track whose location is fileRef)) > 0 then return true
            end try
        """
        if let sizeAndNameCheck = musicTVSizeAndNameCheck(path: path, onMatch: "return true") {
            script += "\n" + sizeAndNameCheck
        }
        script += """

            return false
        end tell
        """
        let result = try runAppleScript(script)
        return result == "true"
    }

    private static func removeFromMusicTVLibrary(app: String, path: String) throws {
        let escaped = appleScriptEscapePath(path)
        var script = """
        tell application "\(app)"
            set fileRef to (POSIX file "\(escaped)") as alias
            try
                repeat with t in (every track whose location is fileRef)
                    delete t
                end repeat
            end try
        """
        if let sizeAndNameCheck = musicTVSizeAndNameCheck(path: path, onMatch: "delete t") {
            script += "\n" + sizeAndNameCheck
        }
        script += """

        end tell
        """
        try runAppleScript(script)
    }

    // MARK: - Photos import

    #if canImport(Photos)
    /// Builds the fetch predicate used to narrow assets before matching filename
    /// in code. `mediaType` is one of the few keys PhotoKit allows in a
    /// `PHFetchOptions` predicate — `originalFilename` is not, and using it
    /// crashes with `NSInvalidArgumentException` (`PHQuery
    /// _filterPredicateFromFetchOptionsPredicate:`).
    static func photoFetchPredicate(isVideo: Bool) -> NSPredicate {
        let mediaType: PHAssetMediaType = isVideo ? .video : .image
        return NSPredicate(format: "mediaType == %d", mediaType.rawValue)
    }

    /// Local identifiers of assets that match the file at `path`. Matching is by
    /// original filename **and** byte size — the size check prevents `replace`
    /// from deleting an unrelated photo that merely shares a name (e.g. two
    /// different `IMG_0001.jpg`). When the source size is unknown, falls back to
    /// filename only.
    private static func matchingPhotoAssetIds(forFileAt path: String) -> [String] {
        let url = URL(fileURLWithPath: path)
        let filename = url.lastPathComponent
        let sourceSize = fileByteSize(path)

        let isVideo = (try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier)
            .flatMap(UTType.init)?.conforms(to: .movie) ?? false
        let options = PHFetchOptions()
        options.predicate = photoFetchPredicate(isVideo: isVideo)

        let existing = PHAsset.fetchAssets(with: options)
        var ids: [String] = []
        existing.enumerateObjects { asset, _, _ in
            let resources = PHAssetResource.assetResources(for: asset)
            guard resources.contains(where: { $0.originalFilename == filename }) else { return }
            guard let sourceSize else {
                ids.append(asset.localIdentifier)
                return
            }
            let sizeMatches = resources.contains { resource in
                (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value == sourceSize
            }
            if sizeMatches { ids.append(asset.localIdentifier) }
        }
        return ids
    }
    #endif

    private static func photosLibraryContainsFile(_ path: String) -> Bool {
        #if canImport(Photos)
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return false }
        return !matchingPhotoAssetIds(forFileAt: path).isEmpty
        #else
        return false
        #endif
    }

    private static func removeFromPhotosLibrary(_ path: String) throws {
        #if canImport(Photos)
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        let localIds = matchingPhotoAssetIds(forFileAt: path)
        guard !localIds.isEmpty else { return }
        try PHPhotoLibrary.shared().performChangesAndWait {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: localIds, options: nil)
            PHAssetChangeRequest.deleteAssets(assets)
        }
        #endif
    }

    private static func importToPhotos(path: String, album: String = "") throws {
        #if canImport(Photos)
        let url = URL(fileURLWithPath: path)
        var targetAlbum: PHAssetCollection?
        if !album.isEmpty {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "title == %@", album)
            let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options)
            targetAlbum = collections.firstObject
        }
        let isVideo = (try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier)
            .flatMap(UTType.init)?.conforms(to: .movie) ?? false
        try PHPhotoLibrary.shared().performChangesAndWait {
            let request: PHAssetChangeRequest?
            if isVideo {
                request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } else {
                request = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
            }
            if let album = targetAlbum, let placeholder = request?.placeholderForCreatedAsset {
                let albumRequest = PHAssetCollectionChangeRequest(for: album)
                albumRequest?.addAssets([placeholder] as NSArray)
            }
        }
        #else
        throw ActionError("Photos import is not available on this platform")
        #endif
    }

    /// Checks whether Forel has permission to access the given library, triggering
    /// the system permission dialog if the user hasn't decided yet. Returns `nil`
    /// when access is granted, or a user-facing message explaining why it isn't.
    /// Both `plan()` and `execute()` call this — so Dry Run prompts for consent
    /// just as Run Now and the watcher do, except for Music/TV automation
    /// (see `ensureMusicTVAccess`'s `launchIfNeeded`).
    private static func ensureLibraryAccess(libraryType: LibraryType, launchIfNeeded: Bool) -> String? {
        switch libraryType {
        case .photos:
            #if canImport(Photos)
            return ensurePhotosAccess()
            #else
            return "Photos import is not available on this platform."
            #endif
        case .music, .tv:
            return ensureMusicTVAccess(libraryType: libraryType, launchIfNeeded: launchIfNeeded)
        }
    }

    #if canImport(Photos)
    /// Thread-safe holder for the authorization result delivered on an arbitrary
    /// queue; the surrounding semaphore establishes the happens-before ordering.
    private final class AuthStatusBox: @unchecked Sendable {
        var status: PHAuthorizationStatus = .denied
    }
    #endif

    private static func ensurePhotosAccess() -> String? {
        #if canImport(Photos)
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            return nil
        case .denied:
            return "access denied. Grant access in System Settings > Privacy & Security > Photos."
        case .restricted:
            return "access restricted by parental controls."
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            let box = AuthStatusBox()
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                box.status = status
                semaphore.signal()
            }
            semaphore.wait()
            switch box.status {
            case .authorized, .limited:
                return nil
            case .denied:
                return "access denied. Grant access in System Settings > Privacy & Security > Photos."
            case .restricted:
                return "access restricted by parental controls."
            default:
                return "cannot determine access status."
            }
        @unknown default:
            return "cannot determine access status."
        }
        #else
        return "Photos import is not available on this platform."
        #endif
    }

    /// `tell application "X" to ...` launches the app if it isn't already
    /// running, even for the no-op probe command below. When `launchIfNeeded`
    /// is `false` (Dry Run) and the app isn't running, we skip the live check
    /// rather than launch it just to preview a rule — Run Now will surface a
    /// real denial if automation access turns out to be missing.
    private static func ensureMusicTVAccess(libraryType: LibraryType, launchIfNeeded: Bool) -> String? {
        let appName = libraryType == .music ? "Music" : "TV"
        if !launchIfNeeded && !isAppRunning(appName) { return nil }
        do {
            try runAppleScript(automationProbeScript(app: appName))
            return nil
        } catch {
            return "automation access not granted. Allow Forel to control \(appName) in System Settings > Privacy & Security > Automation."
        }
    }

    /// AppleScript used to test whether Forel actually has Automation
    /// permission for `app`. `tell application "X" to get name` is *not*
    /// enough — `name`/`version` are part of every scriptable app's Required
    /// Suite, which macOS answers without enforcing Automation consent at all
    /// (they're treated as harmless metadata, not user data), so that probe
    /// always reports success regardless of the real grant. `count of tracks`
    /// reads actual library data and is the same class of Apple Event the real
    /// import (`add theFile`) sends, so it's gated identically. Shared with
    /// `PermissionsChecker`, which surfaces the same probe in Settings.
    static func automationProbeScript(app: String) -> String {
        "tell application \"\(app)\" to count of tracks"
    }

    /// Reverses a previously executed action using its stored `Undo`.
    public static func revert(_ undo: Undo) throws {
        switch undo {
        case .move(let from, let to):
            if FileManager.default.fileExists(atPath: from) {
                throw ActionError("cannot restore \(from): a file already exists there")
            }
            let parent = (from as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            try FileManager.default.moveItem(atPath: to, toPath: from)
        case .copy(let copy):
            if FileManager.default.fileExists(atPath: copy) {
                try FileManager.default.removeItem(atPath: copy)
            }
        case .addTags(let path, let tags):
            for tag in tags { try FinderTags.apply(path, tag: tag, add: false) }
        case .removeTags(let path, let tags):
            for tag in tags { try FinderTags.apply(path, tag: tag, add: true) }
        case .color(let path, let previous):
            try FinderTags.setColorLabel(path, color: previous)
        case .none:
            throw ActionError("this action cannot be undone")
        }
    }

    public static func preview(_ action: Action, path: String) throws -> String {
        try plan(action, path: path).description
    }

    public static func plan(_ action: Action, path: String) throws -> ActionPlan {
        let fileName = (path as NSString).lastPathComponent

        switch action.kind {
        case .moveToFolder:
            let destDir = action.params[ActionParam.destination]?.stringValue ?? ""

            // A file already directly in its destination folder is a no-op,
            // never a rename-to-avoid-itself collision — and since nothing
            // would change, the chain continues normally for this rule.
            if normalizedPath((path as NSString).deletingLastPathComponent) == normalizedPath(destDir) {
                return ActionPlan(
                    kind: action.kind,
                    description: "Already in destination",
                    sourcePath: path,
                    targetPath: (destDir as NSString).appendingPathComponent(fileName),
                    status: .wouldSkip,
                    finalPath: path,
                    copiedPath: nil,
                    isTerminal: false
                )
            }

            let naiveTarget = (destDir as NSString).appendingPathComponent(fileName)
            let resolution = conflictResolution(action)
            let conflicts = FileManager.default.fileExists(atPath: naiveTarget)

            if conflicts, resolution == .skip {
                return ActionPlan(
                    kind: action.kind,
                    description: "Skip — a file already exists at \(naiveTarget)",
                    sourcePath: path,
                    targetPath: naiveTarget,
                    status: .wouldSkip,
                    finalPath: path,
                    copiedPath: nil,
                    // Conceptually still a terminal move — it just didn't
                    // run — so later actions in *this* rule (e.g. a tag meant
                    // to apply after the move) don't run on a file that
                    // never actually moved.
                    isTerminal: true
                )
            }

            let (target, description) = conflictAwarePlan(verb: "Move", naiveTarget: naiveTarget, destDir: destDir, fileName: fileName, resolution: resolution, conflicts: conflicts)
            return ActionPlan(
                kind: action.kind,
                description: description,
                sourcePath: path,
                targetPath: target,
                status: .wouldRun,
                finalPath: target,
                copiedPath: nil,
                isTerminal: true
            )
        case .copyToFolder:
            let destDir = action.params[ActionParam.destination]?.stringValue ?? ""
            let naiveTarget = (destDir as NSString).appendingPathComponent(fileName)
            let resolution = conflictResolution(action)
            let conflicts = FileManager.default.fileExists(atPath: naiveTarget)

            if conflicts, resolution == .skip {
                return ActionPlan(
                    kind: action.kind,
                    description: "Skip — a file already exists at \(naiveTarget)",
                    sourcePath: path,
                    targetPath: naiveTarget,
                    status: .wouldSkip,
                    finalPath: path,
                    copiedPath: nil,
                    // Unlike moveToFolder, a copy never takes the file out of
                    // this location — later actions in this rule still act
                    // on the original, so this never needs to stop the chain.
                    isTerminal: false
                )
            }

            let (target, description) = conflictAwarePlan(verb: "Copy", naiveTarget: naiveTarget, destDir: destDir, fileName: fileName, resolution: resolution, conflicts: conflicts)
            return ActionPlan(
                kind: action.kind,
                description: description,
                sourcePath: path,
                targetPath: target,
                status: .wouldRun,
                finalPath: path,
                copiedPath: target,
                isTerminal: false
            )
        case .rename:
            let pattern = action.params[ActionParam.pattern]?.stringValue ?? ""
            var newName = try applyRenamePattern(pattern, path: path)
            if action.params[ActionParam.cleanFileName]?.boolValue == true {
                newName = cleanFileName(newName)
            }
            let target = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(newName)
            return ActionPlan(
                kind: action.kind,
                description: "Rename to \(newName)",
                sourcePath: path,
                targetPath: target,
                status: target == path ? .wouldSkip : conflictStatus(target),
                finalPath: target,
                copiedPath: nil,
                isTerminal: false
            )
        case .moveToTrash:
            let target = (try trashDir() as NSString).appendingPathComponent(fileName)
            return ActionPlan(
                kind: action.kind,
                description: "Move to Trash",
                sourcePath: path,
                targetPath: target,
                status: .wouldRun,
                finalPath: target,
                copiedPath: nil,
                isTerminal: true
            )
        case .delete:
            return ActionPlan(
                kind: action.kind,
                description: "Delete permanently",
                sourcePath: path,
                targetPath: nil,
                status: .wouldRun,
                finalPath: path,
                copiedPath: nil,
                isTerminal: true
            )
        case .addTag:
            let tags = paramTags(action)
            let description: String
            if tags.isEmpty { description = "Add tag" }
            else if action.params["tag"] != nil && tags.count == 1 { description = "Add tag '\(tags[0])'" }
            else { description = "Add tag\(tags.count > 1 ? "s" : ""): \(tags.joined(separator: ", "))" }
            return ActionPlan(
                kind: action.kind,
                description: description,
                sourcePath: path,
                targetPath: nil,
                status: wouldChange(action, path: path) ? .wouldRun : .wouldSkip,
                finalPath: path,
                copiedPath: nil,
                isTerminal: false
            )
        case .removeTag:
            let tags = paramTags(action)
            let description: String
            if tags.isEmpty { description = "Remove tag" }
            else if action.params["tag"] != nil && tags.count == 1 { description = "Remove tag '\(tags[0])'" }
            else { description = "Remove tag\(tags.count > 1 ? "s" : ""): \(tags.joined(separator: ", "))" }
            return ActionPlan(
                kind: action.kind,
                description: description,
                sourcePath: path,
                targetPath: nil,
                status: wouldChange(action, path: path) ? .wouldRun : .wouldSkip,
                finalPath: path,
                copiedPath: nil,
                isTerminal: false
            )
        case .setColorLabel:
            let color = action.params[ActionParam.color]?.stringValue ?? ""
            return ActionPlan(
                kind: action.kind,
                description: color.isEmpty ? "Clear color label" : "Set color label to \(color)",
                sourcePath: path,
                targetPath: nil,
                status: wouldChange(action, path: path) ? .wouldRun : .wouldSkip,
                finalPath: path,
                copiedPath: nil,
                isTerminal: false
            )
        case .runScript:
            let script = action.params[ActionParam.script]?.stringValue ?? ""
            let firstLine = script.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            return ActionPlan(
                kind: action.kind,
                description: firstLine.isEmpty ? "Run script" : "Run script: \(firstLine)",
                sourcePath: path,
                targetPath: nil,
                status: .wouldRun,
                finalPath: path,
                copiedPath: nil,
                isTerminal: false
            )
        case .runShortcut:
            let name = action.params[ActionParam.shortcutName]?.stringValue ?? ""
            let inputMode = shortcutInputMode(action)
            return ActionPlan(
                kind: action.kind,
                description: shortcutDescription(name: name, inputMode: inputMode),
                sourcePath: path,
                targetPath: nil,
                status: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .wouldSkip : .wouldRun,
                finalPath: path,
                copiedPath: nil,
                isTerminal: false
            )
        case .importToLibrary:
            let libraryTypeRaw = action.params[ActionParam.libraryType]?.stringValue ?? LibraryType.music.rawValue
            guard let libraryType = LibraryType(rawValue: libraryTypeRaw) else {
                throw ActionError("Import to Library requires a 'library_type' parameter")
            }
            guard canImportToLibrary(path, libraryType: libraryType) else {
                throw ActionError("File format not supported by \(libraryType.label) — requires \(formatDescription(for: libraryType))")
            }

            if let accessMessage = ensureLibraryAccess(libraryType: libraryType, launchIfNeeded: false) {
                return ActionPlan(
                    kind: action.kind,
                    description: "Import to \(libraryType.label) — \(accessMessage)",
                    sourcePath: path,
                    targetPath: nil,
                    status: .needsConfirmation,
                    finalPath: path,
                    copiedPath: nil,
                    isTerminal: false
                )
            }

            let resolution = conflictResolution(action, default: .skip)
            let alreadyExists = try libraryContainsFile(path, libraryType: libraryType, launchIfNeeded: false)

            if alreadyExists && resolution == .skip {
                return ActionPlan(
                    kind: action.kind,
                    description: "Skip — file already exists in \(libraryType.label)",
                    sourcePath: path,
                    targetPath: nil,
                    status: .wouldSkip,
                    finalPath: path,
                    copiedPath: nil,
                    isTerminal: false
                )
            }

            let descSuffix = alreadyExists && resolution == .replace ? " (replacing existing file)" : ""
            return ActionPlan(
                kind: action.kind,
                description: "Import to \(libraryType.label)\(descSuffix)",
                sourcePath: path,
                targetPath: nil,
                status: .wouldRun,
                finalPath: path,
                copiedPath: nil,
                isTerminal: false
            )
        case .uncompress:
            let extraction = try zipExtractionPlan(action, path: path)
            if extraction.conflicts, extraction.resolution == .skip {
                return ActionPlan(
                    kind: action.kind,
                    description: "Skip — a file already exists at \(extraction.target)",
                    sourcePath: path,
                    targetPath: extraction.target,
                    status: .wouldSkip,
                    finalPath: path,
                    copiedPath: nil,
                    isTerminal: true
                )
            }

            let suffix = extraction.conflicts && extraction.resolution == .replace
                ? " (replacing existing file)"
                : extraction.conflicts && extraction.resolution == .rename
                    ? " (renamed to avoid an existing file)"
                    : ""
            return ActionPlan(
                kind: action.kind,
                description: "Uncompress to \(extraction.target)\(suffix)",
                sourcePath: path,
                targetPath: extraction.target,
                status: .wouldRun,
                finalPath: extraction.target,
                copiedPath: nil,
                isTerminal: false
            )
        }
    }

    public static func wouldChange(_ action: Action, path: String) -> Bool {
        switch action.kind {
        case .setColorLabel:
            let target = (action.params[ActionParam.color]?.stringValue ?? "").lowercased()
            return FinderTags.currentColorName(path) != target
        case .addTag:
            let existing = FinderTags.read(path)
            return paramTags(action).contains { !existing.contains($0) }
        case .removeTag:
            let existing = FinderTags.read(path)
            return paramTags(action).contains { existing.contains($0) }
        case .rename:
            let pattern = action.params[ActionParam.pattern]?.stringValue ?? ""
            guard let newName = try? applyRenamePattern(pattern, path: path) else { return true }
            return (path as NSString).lastPathComponent != newName
        case .moveToFolder, .copyToFolder, .moveToTrash, .delete, .runScript, .runShortcut, .importToLibrary, .uncompress:
            return true
        }
    }

    private static func paramTags(_ action: Action) -> [String] {
        if let tags = action.params[ActionParam.tags]?.arrayValue {
            return tags.compactMap(\.stringValue)
        }
        // Legacy single-tag param from older saved rules.
        if let tag = action.params["tag"]?.stringValue {
            return [tag]
        }
        return []
    }

    public static func shortcutInputMode(_ action: Action) -> ShortcutInputMode {
        guard let raw = action.params[ActionParam.shortcutInputMode]?.stringValue else {
            return .matchedFile
        }
        return ShortcutInputMode(rawValue: raw) ?? .matchedFile
    }

    private static func shortcutDescription(name: String, inputMode: ShortcutInputMode) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Run shortcut" }
        switch inputMode {
        case .matchedFile:
            return "Run shortcut: \(trimmed)"
        case .none:
            return "Run shortcut: \(trimmed) with no input"
        }
    }

    private static func shortcutInput(mode: ShortcutInputMode, path: String) throws -> ShortcutRunner.Input {
        switch mode {
        case .matchedFile:
            return .file(path)
        case .none:
            return .none
        }
    }

    private static func conflictStatus(_ target: String) -> DryRunStatus {
        FileManager.default.fileExists(atPath: target) ? .blockedByConflict : .wouldRun
    }

    private static func zipExtractionPlan(_ action: Action, path: String) throws -> ZipExtractionPlan {
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension.lowercased() == "zip" else {
            throw ActionError("Only ZIP archives can be uncompressed right now.")
        }

        let topLevelItems = try zipTopLevelItems(path: path)
        guard !topLevelItems.isEmpty else {
            throw ActionError("ZIP archive is empty.")
        }

        let parent = (path as NSString).deletingLastPathComponent
        let resolution = conflictResolution(action)
        let usesWrapperFolder = topLevelItems.count != 1
        let naiveTarget: String
        if usesWrapperFolder {
            naiveTarget = (parent as NSString).appendingPathComponent(url.deletingPathExtension().lastPathComponent)
        } else {
            naiveTarget = (parent as NSString).appendingPathComponent(topLevelItems[0])
        }

        let conflicts = FileManager.default.fileExists(atPath: naiveTarget)
        let target: String
        if conflicts, resolution == .rename {
            target = uniqueDest(dir: parent, fileName: (naiveTarget as NSString).lastPathComponent)
        } else {
            target = naiveTarget
        }

        return ZipExtractionPlan(
            target: target,
            topLevelItems: topLevelItems,
            usesWrapperFolder: usesWrapperFolder,
            conflicts: conflicts,
            resolution: resolution
        )
    }

    private static func zipTopLevelItems(path: String) throws -> [String] {
        let archive: Archive
        do {
            archive = try Archive(url: URL(fileURLWithPath: path), accessMode: .read, pathEncoding: nil)
        } catch {
            throw ActionError("Could not read ZIP archive: \(error)")
        }

        var items: Set<String> = []
        for entry in archive {
            guard let first = entry.path.split(separator: "/", omittingEmptySubsequences: true).first else {
                continue
            }
            let item = String(first)
            if item == "__MACOSX" { continue }
            if item == "." || item == ".." {
                throw ActionError("ZIP archive contains an invalid entry path.")
            }
            items.insert(item)
        }
        return items.sorted()
    }

    /// Shared by `moveToFolder`/`copyToFolder` planning: the resolved target
    /// path and a human-readable description, for whichever resolution
    /// doesn't just skip outright (that's handled separately by the caller).
    private static func conflictAwarePlan(verb: String, naiveTarget: String, destDir: String, fileName: String, resolution: MoveConflictResolution, conflicts: Bool) -> (target: String, description: String) {
        switch resolution {
        case .rename:
            let target = conflicts ? uniqueDest(dir: destDir, fileName: fileName) : naiveTarget
            let description = conflicts ? "\(verb) to \(target) (renamed to avoid an existing file)" : "\(verb) to \(target)"
            return (target, description)
        case .replace:
            let description = conflicts ? "\(verb) to \(naiveTarget) (replacing existing file)" : "\(verb) to \(naiveTarget)"
            return (naiveTarget, description)
        case .skip:
            // `conflicts` is false here (the conflicting case is returned
            // separately by the caller), so this behaves like a plain move/copy.
            return (naiveTarget, "\(verb) to \(naiveTarget)")
        }
    }

    private static func normalizedPath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    private static func formatFileSize(_ bytes: UInt64) -> String {
        let kb: Double = 1024
        let mb = 1024 * kb
        let gb = 1024 * mb
        let value = Double(bytes)
        if value >= gb { return String(format: "%.1fGB", value / gb) }
        if value >= mb { return String(format: "%.1fMB", value / mb) }
        if value >= kb { return String(format: "%.1fKB", value / kb) }
        return "\(bytes)B"
    }

    /// Substitutes tokens in rename patterns. Supported tokens: `{name}`,
    /// `{extension}`, `{date_created}`, `{date_modified}`, `{current_date}`, `{size}`.
    private static func applyRenamePattern(_ pattern: String, path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let today = Date()

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = .current

        var result = pattern
            .replacingOccurrences(of: "{name}", with: stem)
            .replacingOccurrences(of: "{extension}", with: ext)
            .replacingOccurrences(of: "{current_date}", with: dayFormatter.string(from: today))

        if result.contains("{date_modified}") || result.contains("{date_created}") || result.contains("{size}") {
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let modified = (attrs[.modificationDate] as? Date) ?? Date()
            let created = (attrs[.creationDate] as? Date) ?? Date()
            let size = (attrs[.size] as? UInt64) ?? 0
            result = result
                .replacingOccurrences(of: "{date_modified}", with: dayFormatter.string(from: modified))
                .replacingOccurrences(of: "{date_created}", with: dayFormatter.string(from: created))
                .replacingOccurrences(of: "{size}", with: formatFileSize(size))
        }

        if result.isEmpty {
            throw ActionError("rename pattern produced empty filename")
        }

        try validateMacOSFilename(result)

        // Append the original extension only when the pattern did not place it
        // explicitly (via the {extension} token or by typing it literally).
        let alreadyHasExt = result.lowercased().hasSuffix(".\(ext.lowercased())")
        if ext.isEmpty || pattern.contains("{extension}") || alreadyHasExt {
            return result
        }
        result = "\(result).\(ext)"
        return result
    }

    /// Converts a filename to a universal ASCII slug: transliterates any
    /// script to Latin (Cyrillic, Arabic, CJK…), strips diacritics,
    /// lowercases, replaces spaces and underscores with hyphens, splits
    /// camelCase boundaries, removes remaining non-alphanumeric characters,
    /// and collapses adjacent hyphens.
    public static func cleanFileName(_ name: String) -> String {
        let nsName = name as NSString
        let ext = nsName.pathExtension
        let stem = ext.isEmpty ? (name as NSString).deletingPathExtension : nsName.deletingPathExtension

        // Transliterate any script to Latin, then reduce to ASCII:
        //   "straße" → "strasse",  "Привет" → "Privet",  "中文" → "zhong wen"
        var cleaned = stem
            .applyingTransform(.toLatin, reverse: false)
            .map { (latin: String) -> String in
                let mutable = NSMutableString(string: latin)
                CFStringTransform(mutable, nil, "Latin-ASCII" as NSString, false)
                return mutable as String
            } ?? stem

        cleaned = cleaned
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")

        // Insert hyphen at camelCase boundaries: "myFile" → "my-File"
        var withBoundaries = ""
        for ch in cleaned {
            if ch.isUppercase, let last = withBoundaries.last, last.isLowercase || last.isNumber {
                withBoundaries.append("-")
            }
            withBoundaries.append(ch)
        }
        cleaned = withBoundaries

        // Lowercase
        cleaned = cleaned.lowercased()

        // Remove remaining characters that aren't alphanumeric or hyphens
        cleaned = String(cleaned.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })

        // Collapse and strip hyphens
        while cleaned.contains("--") { cleaned = cleaned.replacingOccurrences(of: "--", with: "-") }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        if cleaned.isEmpty { return name }
        return ext.isEmpty ? cleaned : "\(cleaned).\(ext)"
    }

    /// Returns a destination path that does not yet exist, appending ` (N)` to
    /// the stem when the intended name is already taken.
    private static func uniqueDest(dir: String, fileName: String) -> String {
        let candidate = (dir as NSString).appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: candidate) { return candidate }

        let nsName = fileName as NSString
        let stem = nsName.deletingPathExtension
        let ext = nsName.pathExtension

        var i = 1
        while true {
            let newName = ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)"
            let candidate = (dir as NSString).appendingPathComponent(newName)
            if !FileManager.default.fileExists(atPath: candidate) { return candidate }
            i += 1
        }
    }

    private static func trashDir() throws -> String {
        guard let home = ProcessInfo.processInfo.environment["HOME"] else {
            throw ActionError("HOME not set")
        }
        return (home as NSString).appendingPathComponent(".Trash")
    }

    /// macOS filename rules: no `/` or null, not `.`/`..`, not empty,
    /// no trailing dot/space (silently stripped by the filesystem and
    /// impossible to use afterward), and within the 255-char limit.
    /// Note: empty is already rejected earlier.
    private static func validateMacOSFilename(_ name: String) throws {
        if name.contains("/") {
            throw ActionError("rename pattern produced an invalid filename (contains '/')")
        }
        if name == "." || name == ".." {
            throw ActionError("rename pattern produced an invalid filename ('.' and '..' are not allowed)")
        }
        if name.utf8.count > 255 {
            throw ActionError("rename pattern produced a filename longer than 255 characters")
        }
        if let lastChar = name.last, lastChar == "." || lastChar == " " {
            throw ActionError("rename pattern produced a filename ending with '.' or space — not supported by macOS")
        }
    }
}

public enum ShortcutCatalog {
    public static func availableShortcutNames() -> [String] {
        listOutput().map(parseShortcutList(_:)) ?? []
    }

    static func parseShortcutList(_ output: String) -> [String] {
        var seen = Set<String>()
        return output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    private static func listOutput() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ShortcutRunner.executablePath)
        process.arguments = ["list"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum ShortcutRunner {
    enum Input: Equatable {
        case file(String)
        case none
    }

    static let executablePath = "/usr/bin/shortcuts"
    private static let defaultTimeout: TimeInterval = 60

    static func run(name: String, input: Input, timeout: TimeInterval = defaultTimeout) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ActionError("RunShortcut requires '\(ActionParam.shortcutName)' param")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments(name: trimmedName, input: input)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            group.leave()
        }

        if group.wait(timeout: DispatchTime.now() + timeout) == .timedOut {
            process.terminate()
            _ = group.wait(timeout: DispatchTime.now() + 2)
            throw ActionError("shortcut timed out")
        }

        guard process.terminationStatus == 0 else {
            throw ActionError("shortcut exited with status \(process.terminationStatus)")
        }
    }

    static func arguments(name: String, input: Input) -> [String] {
        var args = ["run", name]
        switch input {
        case .file(let path):
            args.append(contentsOf: ["--input-path", path])
        case .none:
            break
        }
        return args
    }
}
