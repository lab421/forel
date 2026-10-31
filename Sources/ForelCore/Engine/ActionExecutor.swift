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
import Darwin
import ZIPFoundation
import CryptoKit
#if canImport(AppKit)
import AppKit
#endif
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
    case finderLabel(path: String, previous: Int)
    case fileFlag(path: String, key: String, previous: Bool)
    case finderComment(path: String, previous: String?)
    case archive(original: String, trashed: String, archive: String, trashFingerprint: String, archiveFingerprint: String)
    case tagColors(path: String, before: [String], after: [String], beforeLabel: Int, afterLabel: Int)
    case tagState(path: String, before: [String], after: [String], beforeLabel: Int, afterLabel: Int)
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
        case .finderLabel(let path, let previous):
            return .object(["kind": .string("finder_label"), "path": .string(path), "previous": .string(String(previous))])
        case .fileFlag(let path, let key, let previous):
            return .object(["kind": .string("file_flag"), "path": .string(path), "key": .string(key), "previous": .bool(previous)])
        case .finderComment(let path, let previous):
            return .object(["kind": .string("finder_comment"), "path": .string(path), "previous": previous.map(JSONValue.string) ?? .null])
        case .archive(let original, let trashed, let archive, let trashFingerprint, let archiveFingerprint):
            return .object(["kind": .string("archive"), "original": .string(original), "trashed": .string(trashed), "archive": .string(archive), "trash_fingerprint": .string(trashFingerprint), "archive_fingerprint": .string(archiveFingerprint)])
        case .tagColors(let path, let before, let after, let beforeLabel, let afterLabel):
            return .object(["kind": .string("tag_colors"), "path": .string(path), "before": .stringArray(before), "after": .stringArray(after), "before_label": .string(String(beforeLabel)), "after_label": .string(String(afterLabel))])
        case .tagState(let path, let before, let after, let beforeLabel, let afterLabel):
            return .object(["kind": .string("tag_state"), "path": .string(path), "before": .stringArray(before), "after": .stringArray(after), "before_label": .string(String(beforeLabel)), "after_label": .string(String(afterLabel))])
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
        case "finder_label":
            guard let value = json["previous"]?.stringValue.flatMap(Int.init), (0...7).contains(value) else { return .none }
            return .finderLabel(path: json["path"]?.stringValue ?? "", previous: value)
        case "file_flag":
            guard let path = json["path"]?.stringValue, let key = json["key"]?.stringValue,
                  ["locked", "extension_hidden"].contains(key), let previous = json["previous"]?.boolValue else { return .none }
            return .fileFlag(path: path, key: key, previous: previous)
        case "finder_comment":
            guard let path = json["path"]?.stringValue, let previous = json["previous"] else { return .none }
            if case .null = previous { return .finderComment(path: path, previous: nil) }
            guard let text = previous.stringValue else { return .none }
            return .finderComment(path: path, previous: text)
        case "archive":
            guard let original = json["original"]?.stringValue, let trashed = json["trashed"]?.stringValue,
                  let archive = json["archive"]?.stringValue, let trashFingerprint = json["trash_fingerprint"]?.stringValue,
                  let archiveFingerprint = json["archive_fingerprint"]?.stringValue else { return .none }
            return .archive(original: original, trashed: trashed, archive: archive, trashFingerprint: trashFingerprint, archiveFingerprint: archiveFingerprint)
        case "tag_colors", "tag_state":
            guard let path = json["path"]?.stringValue,
                  let before = json["before"]?.arrayValue, let after = json["after"]?.arrayValue,
                  before.allSatisfy({ $0.stringValue != nil }), after.allSatisfy({ $0.stringValue != nil }),
                  let beforeLabel = json["before_label"]?.stringValue.flatMap(Int.init), (0...7).contains(beforeLabel),
                  let afterLabel = json["after_label"]?.stringValue.flatMap(Int.init), (0...7).contains(afterLabel) else { return .none }
            if kind == "tag_state" { return .tagState(path: path, before: before.compactMap(\.stringValue), after: after.compactMap(\.stringValue), beforeLabel: beforeLabel, afterLabel: afterLabel) }
            return .tagColors(path: path, before: before.compactMap(\.stringValue), after: after.compactMap(\.stringValue), beforeLabel: beforeLabel, afterLabel: afterLabel)
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
    public let stopsActionChain: Bool
    public let outputAttributes: [String: JSONValue]

    public init(newPath: String, undo: Undo, copiedPath: String? = nil, stopsActionChain: Bool = false, outputAttributes: [String: JSONValue] = [:]) {
        self.newPath = newPath
        self.undo = undo
        self.copiedPath = copiedPath
        self.stopsActionChain = stopsActionChain
        self.outputAttributes = outputAttributes
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
    case discard

    public var label: String {
        switch self {
        case .rename: return "Rename the file"
        case .replace: return "Replace existing file"
        case .skip: return "Skip the file"
        case .discard: return "Move the new file to Trash"
        }
    }
}

public enum FolderStructureMode: String, CaseIterable, Sendable {
    case none, parent, monitored, root
    public var label: String {
        switch self {
        case .none: return "Do not copy folder structure"
        case .parent: return "Parent folder only"
        case .monitored: return "From watched folder"
        case .root: return "From volume root"
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
    case blocked
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
    public let warning: String?
    public let stopsActionChain: Bool

    public init(
        kind: ActionKind,
        description: String,
        sourcePath: String,
        targetPath: String?,
        status: DryRunStatus,
        finalPath: String,
        copiedPath: String?,
        isTerminal: Bool,
        stopsActionChain: Bool = false,
        warning: String? = nil
    ) {
        self.kind = kind
        self.description = description
        self.sourcePath = sourcePath
        self.targetPath = targetPath
        self.status = status
        self.finalPath = finalPath
        self.copiedPath = copiedPath
        self.isTerminal = isTerminal
        self.warning = warning
        self.stopsActionChain = stopsActionChain
    }
}

public enum ActionExecutor {
    private static func uploadConfiguration(_ action: Action, servers: [UploadServer]) throws -> UploadConfiguration {
        if action.params["upload_server_id"] != nil {
            return try UploadConfiguration(action: action, serverLookup: { id in servers.first { $0.id == id } })
        }
        return try UploadConfiguration(action: action)
    }
    /// Executes the action on the file at `path`, returning the new path and an
    /// `Undo` describing how to reverse it.
    public static func execute(_ action: Action, path: String, contextPath: String? = nil, hazelContext: HazelPatternContext? = nil, platform: any ActionPlatform = MacActionPlatform(), watchedRoot: String? = nil, uploadServers: [UploadServer] = []) throws -> Applied {
        switch action.kind {
        case .hazelContinue, .hazelRecurse:
            throw ActionError("Hazel control actions must be handled by the rule engine")
        case .moveToFolder:
            let base = try action.params[HazelPattern.sortKey]?.boolValue == true
                ? HazelPattern.sortDestination(action, path: path, contextPath: contextPath, context: hazelContext)
                : expandedDestination(stringParam(action, ActionParam.destination, "MoveToFolder"), fileAtPath: path)
            let destDir = try structuredDestination(action, path: path, base: base, watchedRoot: watchedRoot)
            try validateDestinationOutsideSource(path: path, destination: destDir)
            if action.params[ActionParam.discardDuplicates]?.boolValue == true,
               try duplicateAtDestination(path: path, destination: destDir) {
                let trashed = try platform.trash(path: path)
                return Applied(newPath: trashed, undo: .move(from: path, to: trashed), stopsActionChain: true)
            }
            let target = (destDir as NSString).appendingPathComponent((path as NSString).lastPathComponent)
            if conflictResolution(action) == .discard && FileManager.default.fileExists(atPath: target) {
                let trashed = try platform.trash(path: path)
                return Applied(newPath: trashed, undo: .move(from: path, to: trashed), stopsActionChain: true)
            }
            return try moveIntoDir(path: path, destDir: destDir, resolution: conflictResolution(action))
        case .copyToFolder:
            return try copyToFolder(action, path: path, watchedRoot: watchedRoot)
        case .syncToFolder:
            return try syncToFolder(action, path: path)
        case .importError:
            throw ActionError("This imported rule contains unsupported parts")
        case .rename:
            return try renameFile(action, path: path, contextPath: contextPath, hazelContext: hazelContext)
        case .moveToTrash:
            let destination = try platform.trash(path: path)
            return Applied(newPath: destination, undo: .move(from: path, to: destination))
        case .delete:
            try FileManager.default.removeItem(atPath: path)
            return Applied(newPath: path, undo: .none)
        case .addTag:
            return try applyTags(action, path: path, contextPath: contextPath, context: hazelContext, add: true)
        case .removeTag:
            return try applyTags(action, path: path, contextPath: contextPath, context: hazelContext, add: false)
        case .setColorLabel:
            return try setColor(action, path: path)
        case .setFinderLabel:
            return try setFinderLabel(action, path: path)
        case .setLocked, .setExtensionHidden:
            let key = action.kind == .setLocked ? "locked" : "extension_hidden"
            let previous = try readFileFlag(path, key: key)
            try writeFileFlag(path, key: key, value: action.params[ActionParam.enabled]?.boolValue ?? true)
            return Applied(newPath: path, undo: .fileFlag(path: path, key: key, previous: previous))
        case .setFinderComment:
            let previous = try FinderComment.read(path)
            let value = try finderCommentValue(action, path: path, contextPath: contextPath, hazelContext: hazelContext)
            try FinderComment.write(path, value: value)
            return Applied(newPath: path, undo: .finderComment(path: path, previous: previous))
        case .runScript:
            return try runScript(action, path: path)
        case .runHazelShellScript:
            return try runHazelShellScript(action, path: path)
        case .runHazelAppleScript:
            return try runHazelAppleScript(action, path: path)
        case .runHazelOSA:
            let (language, source, names, outputNames) = try osaConfiguration(action)
            let values: [JSONValue] = try names.map { name in
                let url = URL(fileURLWithPath: path)
                switch name {
                case "path": return .string(url.path)
                case "name": return .string(url.deletingPathExtension().lastPathComponent)
                case "fullName": return .string(url.lastPathComponent)
                case "extension": return .string(url.pathExtension)
                case "comment": return .string(try FinderComment.read(path) ?? "")
                case "dateAdded", "dateCreated", "dateModified", "currentDate", "hazelbuiltin:dateTaken":
                    return .object(["__forelDate": .number(try HazelPattern.dateValue(name, path: path).timeIntervalSince1970)])
                default:
                    guard let value = hazelContext?.attributes[name] else { throw ActionError("Script input attribute \(name) is unavailable") }
                    return value
                }
            }
            let result = try HazelOSARunner.run(language: language, source: source, path: path, inputs: values)
            guard result.orderedAttributes.count == outputNames.count else { throw ActionError("Script output attributes do not match the configured attributes") }
            let outputs = Dictionary(uniqueKeysWithValues: zip(outputNames, result.orderedAttributes))
            return Applied(newPath: result.switchPath ?? path, undo: .none, stopsActionChain: result.stop, outputAttributes: outputs)
        case .runWorkflow:
            let workflow = try workflowPath(action)
            try platform.runWorkflow(workflowPath: workflow, inputPath: path)
            return Applied(newPath: path, undo: .none)
        case .upload:
            let upload = try uploadConfiguration(action, servers: uploadServers).withRelativeFolders(folderStructureComponents(action, path: path, watchedRoot: watchedRoot))
            try platform.upload(path: path, configuration: upload)
            return Applied(newPath: path, undo: .none)
        case .runShortcut:
            return try runShortcut(action, path: path)
        case .openApplication:
            let app = action.params[ActionParam.applicationPath]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let app, !app.isEmpty else { throw ActionError("Open Application requires an application") }
            try platform.open(path: path, application: app, passFile: passesFileToApplication(action), bringToFront: action.params[ActionParam.bringToFront]?.boolValue ?? true)
            return Applied(newPath: path, undo: .none)
        case .openDefault:
            try platform.open(path: path, application: nil, passFile: true, bringToFront: action.params[ActionParam.bringToFront]?.boolValue ?? false)
            return Applied(newPath: path, undo: .none)
        case .showInFinder:
            try platform.showInFinder(path: path, bringToFront: action.params[ActionParam.bringToFront]?.boolValue ?? false)
            return Applied(newPath: path, undo: .none)
        case .displayNotification:
            let text = try action.params[HazelPattern.tokensKey] != nil
                ? HazelPattern.render(action, path: path, contextPath: contextPath, context: hazelContext, filename: false)
                : (action.params[ActionParam.notificationText]?.stringValue ?? "")
            try platform.notify(text: text, sound: action.params[ActionParam.notificationSound]?.boolValue ?? false)
            return Applied(newPath: path, undo: .none)
        case .pause:
            let seconds = Double(action.params[ActionParam.durationSeconds]?.stringValue ?? "1") ?? .nan
            guard seconds.isFinite, seconds >= 0, seconds <= 86_400 else { throw ActionError("Pause must be between 0 and 86400 seconds") }
            try platform.pause(seconds: seconds)
            return Applied(newPath: path, undo: .none)
        case .ignore:
            return Applied(newPath: path, undo: .none, stopsActionChain: true)
        case .makeAlias:
            let destination = try stringParam(action, ActionParam.destination, "MakeAlias")
            try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
            let name = (path as NSString).lastPathComponent
            let target = try resolveDestination(naiveDest: (destination as NSString).appendingPathComponent(name), dir: destination, fileName: name, resolution: .rename)
            let data = try URL(fileURLWithPath: path).bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
            try URL.writeBookmarkData(data, to: URL(fileURLWithPath: target))
            return Applied(newPath: path, undo: .none)
        case .archive:
            if isAlreadyZip(path) { return Applied(newPath: path, undo: .none) }
            return try archive(path, platform: platform)
        case .importToLibrary:
            return try importToLibrary(action, path: path)
        case .uncompress:
            return try uncompress(action, path: path, platform: platform)
        }
    }

    private static func stringParam(_ action: Action, _ key: String, _ kind: String) throws -> String {
        guard let value = action.params[key]?.stringValue else {
            throw ActionError("\(kind) requires '\(key)' param")
        }
        return value
    }

    private static func expandedDestination(_ template: String, fileAtPath: String) -> String {
        guard template.contains("{") else { return template }
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileAtPath)
        let date = (attrs?[.creationDate] as? Date) ?? (attrs?[.modificationDate] as? Date) ?? Date()
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        var result = template
        if let year = parts.year { result = result.replacingOccurrences(of: "{year}", with: String(year)) }
        if let month = parts.month { result = result.replacingOccurrences(of: "{month}", with: String(format: "%02d", month)) }
        if let day = parts.day { result = result.replacingOccurrences(of: "{day}", with: String(format: "%02d", day)) }
        return result
    }

    private static func explainingDisconnectedVolume<T>(_ destDir: String, _ body: () throws -> T) throws -> T {
        do { return try body() }
        catch {
            if let volume = VolumePaths.unmountedVolume(of: destDir) { throw ActionError(volumeNotConnectedMessage(volume)) }
            throw error
        }
    }

    private static func volumeNotConnectedMessage(_ volume: String) -> String {
        "“\(volume)” isn't connected. Connect the disk or network share, or choose the destination folder again."
    }

    /// Moves `path` into `destDir` (created if needed). `resolution` decides
    /// what happens if a file with the same name is already there (see
    /// `resolveDestination`). Trash/delete have no user-facing conflict
    /// choice and always use the `.rename` default.
    private static func moveIntoDir(path: String, destDir: String, resolution: MoveConflictResolution = .rename) throws -> Applied {
        return try explainingDisconnectedVolume(destDir) {
        try validateDestinationOutsideSource(path: path, destination: destDir)
        try FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        let fileName = (path as NSString).lastPathComponent
        let naiveDest = (destDir as NSString).appendingPathComponent(fileName)
        if resolution == .replace {
            return try stagedReplace(path: path, target: naiveDest, moving: true)
        }
        let dest = try resolveDestination(naiveDest: naiveDest, dir: destDir, fileName: fileName, resolution: resolution)
        try FileManager.default.moveItem(atPath: path, toPath: dest)
        return Applied(newPath: dest, undo: .move(from: path, to: dest))
        }
    }

    private static func resolvedPathAllowingMissing(_ path: String) throws -> String {
        // Resolve the longest existing prefix: Foundation does not resolve a
        // symlink in the middle of a path whose final component is absent.
        var prefix = URL(fileURLWithPath: path).standardizedFileURL.path
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: prefix) {
            var info = stat()
            if lstat(prefix, &info) == 0 { throw ActionError("Cannot safely resolve destination") }
            let parent = (prefix as NSString).deletingLastPathComponent
            guard parent != prefix else { throw ActionError("Cannot safely resolve destination") }
            missing.append((prefix as NSString).lastPathComponent)
            prefix = parent
        }
        var target = URL(fileURLWithPath: prefix).standardizedFileURL.resolvingSymlinksInPath().path
        for part in missing.reversed() { target = (target as NSString).appendingPathComponent(part) }
        return target
    }

    private static func validateDestinationOutsideSource(path: String, destination: String) throws {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              (attrs[.type] as? FileAttributeType) == .typeDirectory else { return }
        let source = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        let target = try resolvedPathAllowingMissing(destination)
        guard target != source && !target.hasPrefix(source == "/" ? "/" : source + "/") else {
            throw ActionError("The destination cannot be the folder itself or a folder inside it")
        }
    }

    private static func structuredDestination(_ action: Action, path: String, base: String, watchedRoot: String?) throws -> String {
        let components = try folderStructureComponents(action, path: path, watchedRoot: watchedRoot)
        guard !components.isEmpty else { return base }
        guard (base as NSString).isAbsolutePath else { throw ActionError("Folder structure requires an absolute destination") }
        let result = components.reduce(base) { ($0 as NSString).appendingPathComponent($1) }
        let canonicalBase = try resolvedPathAllowingMissing(base)
        let canonicalResult = try resolvedPathAllowingMissing(result)
        guard canonicalResult == canonicalBase || canonicalResult.hasPrefix(canonicalBase == "/" ? "/" : canonicalBase + "/") else {
            throw ActionError("Folder structure would escape the destination through a symbolic link")
        }
        return result
    }

    private static func folderStructureComponents(_ action: Action, path: String, watchedRoot: String?) throws -> [String] {
        let raw = action.params[ActionParam.folderStructure]?.stringValue ?? FolderStructureMode.none.rawValue
        guard let mode = FolderStructureMode(rawValue: raw) else { throw ActionError("Unsupported folder structure option") }
        guard mode != .none else { return [] }
        let parent = URL(fileURLWithPath: path).standardizedFileURL.deletingLastPathComponent()
        let components: [String]
        switch mode {
        case .none: components = []
        case .parent: components = [parent.lastPathComponent]
        case .monitored:
            guard let watchedRoot else { throw ActionError("This folder structure requires a watched folder") }
            let root = (try resolvedPathAllowingMissing(watchedRoot) as NSString).pathComponents
            let parentParts = (try resolvedPathAllowingMissing(parent.path) as NSString).pathComponents
            guard parentParts.count >= root.count, Array(parentParts.prefix(root.count)) == root else { throw ActionError("The item is outside the watched folder") }
            components = Array(parentParts.dropFirst(root.count))
        case .root:
            guard let volume = try? parent.resourceValues(forKeys: [.volumeURLKey]).volume else { throw ActionError("Could not determine the source volume") }
            let rootParts = volume.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            let parentParts = (try resolvedPathAllowingMissing(parent.path) as NSString).pathComponents
            guard parentParts.count >= rootParts.count, Array(parentParts.prefix(rootParts.count)) == rootParts else { throw ActionError("Could not determine the source volume") }
            components = Array(parentParts.dropFirst(rootParts.count))
        }
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\0") && !$0.contains("\n") && !$0.contains("\r") }) else { throw ActionError("Invalid folder structure") }
        return components
    }

    /// Check the same-name destination by content, never by filename alone.
    /// An uncertain comparison is an error rather than a reason to trash.
    private static func duplicateAtDestination(path: String, destination: String) throws -> Bool {
        let target = (destination as NSString).appendingPathComponent((path as NSString).lastPathComponent)
        let sourceCanonical = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        let targetCanonical = URL(fileURLWithPath: target).standardizedFileURL.resolvingSymlinksInPath().path
        guard sourceCanonical != targetCanonical else { throw ActionError("Source and destination are the same file") }

        var sourceInfo = stat()
        guard lstat(path, &sourceInfo) == 0 else { throw ActionError("Cannot inspect the source file") }
        var targetInfo = stat()
        if lstat(target, &targetInfo) != 0 {
            if errno == ENOENT { return false }
            throw ActionError("Cannot inspect the destination file")
        }
        guard (sourceInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              (targetInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw ActionError("Duplicate comparison supports regular files only")
        }
        if sourceInfo.st_size != targetInfo.st_size { return false }
        // The comparison runs synchronously on the watcher queue. Refuse
        // arbitrarily large reads until it has cancellation and a deadline.
        guard sourceInfo.st_size <= 100 * 1024 * 1024 else {
            throw ActionError("Duplicate comparison exceeds the 100 MB safety limit")
        }

        let sourceFD = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceFD >= 0 else { throw ActionError("Cannot read the source file for duplicate comparison") }
        let source = FileHandle(fileDescriptor: sourceFD, closeOnDealloc: true)
        defer { try? source.close() }
        let targetFD = open(target, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard targetFD >= 0 else { throw ActionError("Cannot read the destination file for duplicate comparison") }
        let other = FileHandle(fileDescriptor: targetFD, closeOnDealloc: true)
        defer { try? other.close() }
        var openedSource = stat()
        var openedTarget = stat()
        guard fstat(sourceFD, &openedSource) == 0, fstat(targetFD, &openedTarget) == 0,
              sameFileVersion(sourceInfo, openedSource), sameFileVersion(targetInfo, openedTarget) else {
            throw ActionError("A file changed during duplicate comparison")
        }
        while true {
            let left = try source.read(upToCount: 1_048_576) ?? Data()
            let right = try other.read(upToCount: 1_048_576) ?? Data()
            if left != right { return false }
            if left.isEmpty { break }
        }
        var finalSource = stat()
        var finalTarget = stat()
        var pathSource = stat()
        var pathTarget = stat()
        guard fstat(sourceFD, &finalSource) == 0, fstat(targetFD, &finalTarget) == 0,
              lstat(path, &pathSource) == 0, lstat(target, &pathTarget) == 0,
              sameFileVersion(sourceInfo, finalSource), sameFileVersion(targetInfo, finalTarget),
              sameFileVersion(sourceInfo, pathSource), sameFileVersion(targetInfo, pathTarget) else {
            throw ActionError("A file changed during duplicate comparison")
        }
        return true
    }

    private static func sameFileVersion(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino && first.st_size == second.st_size &&
        first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec &&
        first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }

    /// Copy to a sibling first, then atomically publish it. The old target is
    /// kept at the staging path until it has safely reached the Trash.
    static func stagedReplace(path: String, target: String, moving: Bool, beforePublish: (() throws -> Void)? = nil, trash: ((String) throws -> Void)? = nil) throws -> Applied {
        let fm = FileManager.default
        guard URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path !=
              URL(fileURLWithPath: target).standardizedFileURL.resolvingSymlinksInPath().path else {
            throw ActionError("Source and destination are the same file")
        }
        var original = stat()
        guard lstat(path, &original) == 0 else { throw ActionError("Cannot inspect the source file") }
        let isLink = (original.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK)
        let sourceFD = isLink ? -1 : open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if !isLink {
            guard sourceFD >= 0 else { throw ActionError("Cannot open the source for safe replacement") }
            var opened = stat()
            guard fstat(sourceFD, &opened) == 0, sameFileVersion(original, opened) else {
                close(sourceFD)
                throw ActionError("The source changed while preparing the replacement")
            }
        }
        defer { if sourceFD >= 0 { close(sourceFD) } }
        guard let originalSnapshot = FileReadiness.snapshot(path)?.fingerprint else {
            throw ActionError("Cannot inspect the source contents")
        }
        var previous = stat()
        let hadTarget = lstat(target, &previous) == 0
        if !hadTarget && errno != ENOENT { throw ActionError("Cannot inspect the destination") }
        let staging = ((target as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(".forel-replace-\(UUID().uuidString)")
        var cleanupStaging = true
        defer { if cleanupStaging { try? fm.removeItem(atPath: staging) } }
        try fm.copyItem(atPath: path, toPath: staging)
        var currentSource = stat()
        guard lstat(path, &currentSource) == 0, sameFileVersion(original, currentSource),
              FileReadiness.snapshot(path)?.fingerprint == originalSnapshot else {
            throw ActionError("The source changed while preparing the replacement")
        }
        var staged = stat()
        guard lstat(staging, &staged) == 0 else { throw ActionError("Cannot inspect the staged replacement") }
        try beforePublish?()
        if hadTarget {
            var currentTarget = stat()
            guard lstat(target, &currentTarget) == 0, sameFileVersion(previous, currentTarget) else {
                throw ActionError("The destination changed while preparing the replacement")
            }
            guard renamex_np(staging, target, UInt32(RENAME_SWAP)) == 0 else {
                throw ActionError("Could not publish the replacement: \(String(cString: strerror(errno)))")
            }
            cleanupStaging = false // It now contains the displaced item.
            var displaced = stat()
            var published = stat()
            guard lstat(staging, &displaced) == 0, lstat(target, &published) == 0,
                  previous.st_dev == displaced.st_dev, previous.st_ino == displaced.st_ino,
                  staged.st_dev == published.st_dev, staged.st_ino == published.st_ino else {
                // Preserve both paths if a concurrent writer won the race.
                throw ActionError("The destination changed during replacement; the displaced item is retained at \(staging)")
            }
            do {
                if let trash { try trash(staging) }
                else {
                    let backup = uniqueDest(dir: try trashDir(), fileName: (target as NSString).lastPathComponent)
                    try fm.moveItem(atPath: staging, toPath: backup)
                }
            } catch {
                var stillPublished = stat()
                var stillDisplaced = stat()
                if lstat(target, &stillPublished) == 0, lstat(staging, &stillDisplaced) == 0,
                   staged.st_dev == stillPublished.st_dev, staged.st_ino == stillPublished.st_ino,
                   previous.st_dev == stillDisplaced.st_dev, previous.st_ino == stillDisplaced.st_ino,
                   renamex_np(staging, target, UInt32(RENAME_SWAP)) == 0 {
                    cleanupStaging = true
                    throw ActionError("Could not preserve the old destination in Trash; replacement was rolled back")
                }
                throw ActionError("Could not preserve the old destination in Trash; the displaced item is retained at \(staging)")
            }
        } else {
            guard renamex_np(staging, target, UInt32(RENAME_EXCL)) == 0 else {
                throw ActionError("Could not publish the replacement: \(String(cString: strerror(errno)))")
            }
            cleanupStaging = false
        }
        if moving {
            var stillPublished = stat()
            guard lstat(target, &stillPublished) == 0,
                  staged.st_dev == stillPublished.st_dev, staged.st_ino == stillPublished.st_ino else {
                throw ActionError("The destination changed after publication; the source was retained")
            }
            var opened = stat()
            guard (sourceFD < 0 || (fstat(sourceFD, &opened) == 0 && sameFileVersion(original, opened))),
                  lstat(path, &currentSource) == 0, sameFileVersion(original, currentSource),
                  FileReadiness.snapshot(path)?.fingerprint == originalSnapshot else {
                throw ActionError("Replacement was published, but the source changed and was retained")
            }
            do { try fm.removeItem(atPath: path) }
            catch { throw ActionError("Replacement was published, but source removal failed; the source may be partially retained: \(error)") }
            // Undoing only the incoming move cannot restore a displaced item.
            return Applied(newPath: target, undo: hadTarget ? .none : .move(from: path, to: target))
        }
        return Applied(newPath: path, undo: .none, copiedPath: target)
    }

    /// A sync copies one matched item. For a directory, its destination copy is
    /// mirrored, including deletions; unrelated items in the destination folder
    /// are left alone. It is irreversible because rsync can replace files.
    private static func syncTarget(_ action: Action, path: String) throws -> (destination: String, target: String, isDirectory: Bool) {
        let destination = try stringParam(action, ActionParam.destination, "SyncToFolder")
        guard (destination as NSString).isAbsolutePath, !destination.isEmpty else {
            throw ActionError("Sync requires an absolute destination folder")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let type = attributes[.type] as? FileAttributeType
        guard type == .typeRegular || type == .typeDirectory else {
            throw ActionError("Sync supports regular files and folders")
        }
        let target = (destination as NSString).appendingPathComponent((path as NSString).lastPathComponent)
        let sourceCanonical = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        let targetCanonical = URL(fileURLWithPath: target).standardizedFileURL.resolvingSymlinksInPath().path
        func contains(_ parent: String, _ child: String) -> Bool {
            child == parent || child.hasPrefix(parent == "/" ? "/" : parent + "/")
        }
        guard !contains(sourceCanonical, targetCanonical), !contains(targetCanonical, sourceCanonical) else {
            throw ActionError("Sync source and destination must not overlap")
        }
        if let targetAttributes = try? FileManager.default.attributesOfItem(atPath: target) {
            let targetType = targetAttributes[.type] as? FileAttributeType
            guard targetType == type else { throw ActionError("Sync destination has a different file type") }
        }
        return (destination, target, type == .typeDirectory)
    }

    private static func syncToFolder(_ action: Action, path: String) throws -> Applied {
        let sync = try syncTarget(action, path: path)
        try FileManager.default.createDirectory(atPath: sync.destination, withIntermediateDirectories: true)
        if sync.isDirectory {
            try FileManager.default.createDirectory(atPath: sync.target, withIntermediateDirectories: true)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        let source = sync.isDirectory ? path + "/" : path
        let target = sync.isDirectory ? sync.target + "/" : sync.destination + "/"
        process.arguments = ["-aE", "--checksum"] + (sync.isDirectory ? ["--delete"] : []) + ["--", source, target]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try runSyncProcess(process)
        return Applied(newPath: path, undo: .none)
    }

    static func runSyncProcess(_ process: Process, timeout: TimeInterval = 300) throws {
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(2)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw ActionError("Sync timed out and may be incomplete")
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw ActionError("Sync failed (exit status \(process.terminationStatus)); the destination may be incomplete")
        }
    }

    private static func copyToFolder(_ action: Action, path: String, watchedRoot: String?) throws -> Applied {
        let base = try expandedDestination(stringParam(action, ActionParam.destination, "CopyToFolder"), fileAtPath: path)
        let destDir = try structuredDestination(action, path: path, base: base, watchedRoot: watchedRoot)
        guard conflictResolution(action) != .discard else { throw ActionError("Discard-on-conflict is available only for Move") }
        try validateDestinationOutsideSource(path: path, destination: destDir)
        if action.params[ActionParam.skipDuplicates]?.boolValue == true, try duplicateAtDestination(path: path, destination: destDir) {
            throw ActionError("Skip — an identical item already exists at the destination")
        }
        return try explainingDisconnectedVolume(destDir) {
        try FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        let fileName = (path as NSString).lastPathComponent
        let naiveDest = (destDir as NSString).appendingPathComponent(fileName)
        if conflictResolution(action) == .replace {
            return try stagedReplace(path: path, target: naiveDest, moving: false)
        }
        let dest = try resolveDestination(naiveDest: naiveDest, dir: destDir, fileName: fileName, resolution: conflictResolution(action))
        try FileManager.default.copyItem(atPath: path, toPath: dest)
        return Applied(newPath: path, undo: .none, copiedPath: dest)
        }
    }

    private struct ZipExtractionPlan {
        let target: String
        let topLevelItems: [String]
        let usesWrapperFolder: Bool
        let conflicts: Bool
        let resolution: MoveConflictResolution
    }

    private static func isAlreadyZip(_ path: String) -> Bool {
        guard (path as NSString).pathExtension.lowercased() == "zip" else { return false }
        return (try? Archive(url: URL(fileURLWithPath: path), accessMode: .read)) != nil
    }

    private static func archive(_ path: String, platform: any ActionPlatform) throws -> Applied {
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent + ".zip"
        let target = try resolveDestination(naiveDest: (directory as NSString).appendingPathComponent(name), dir: directory, fileName: name, resolution: .rename)
        let fm = FileManager.default
        let staging = (directory as NSString).appendingPathComponent(".forel-archive-\(UUID().uuidString).zip")
        var ownsTarget = false
        var trashedPath: String?
        do {
            guard let sourceFingerprint = archiveUndoFingerprint(path, contents: false) else { throw ActionError("Could not inspect the item to archive") }
            let quarantine = try SafeArchive.readQuarantine(path: path)
            try fm.zipItem(at: URL(fileURLWithPath: path), to: URL(fileURLWithPath: staging), shouldKeepParent: true)
            try SafeArchive.applyQuarantine(quarantine, to: staging)
            guard archiveUndoFingerprint(path, contents: false) == sourceFingerprint,
                  try SafeArchive.readQuarantine(path: path) == quarantine else { throw ActionError("The item changed while it was being archived") }
            try fm.moveItem(atPath: staging, toPath: target)
            ownsTarget = true
            let trashed = try platform.trash(path: path)
            trashedPath = trashed
            guard let trashFingerprint = archiveUndoFingerprint(trashed, contents: false), let archiveFingerprint = archiveUndoFingerprint(target, contents: true) else {
                throw ActionError("Could not verify archive for undo")
            }
            return Applied(newPath: target, undo: .archive(original: path, trashed: trashed, archive: target, trashFingerprint: trashFingerprint, archiveFingerprint: archiveFingerprint))
        } catch {
            try? fm.removeItem(atPath: staging)
            var originalRestored = trashedPath == nil && fm.fileExists(atPath: path)
            if let trashedPath, !fm.fileExists(atPath: path) {
                do { try fm.moveItem(atPath: trashedPath, toPath: path); originalRestored = true }
                catch { originalRestored = false }
            }
            if ownsTarget && originalRestored { try? fm.removeItem(atPath: target) }
            throw error
        }
    }

    static func archiveUndoFingerprint(_ path: String, contents: Bool) -> String? {
        guard let identity = FileFingerprint.identity(path), let snapshot = FileReadiness.snapshot(path) else { return nil }
        var result = "\(identity.volumeId):\(identity.fileId):\(snapshot.fingerprint)"
        if contents {
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? handle.close() }
            var hash = SHA256()
            do {
                while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { hash.update(data: bytes) }
            } catch { return nil }
            result += ":" + hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return result
    }

    private static func uncompress(_ action: Action, path: String, platform: any ActionPlatform) throws -> Applied {
        let plan = try zipExtractionPlan(action, path: path)
        if plan.conflicts, plan.resolution == .skip {
            throw ActionError("Skip — a file already exists at \(plan.target)")
        }

        let fm = FileManager.default
        let archiveURL = URL(fileURLWithPath: path)
        guard let sourceFingerprint = archiveUndoFingerprint(path, contents: false) else {
            throw ActionError("Could not inspect the archive before extraction")
        }
        let sourceQuarantine = try SafeArchive.readQuarantine(path: path)
        let replacementDir = try fm.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: archiveURL,
            create: true
        ).path
        let tempDir = (replacementDir as NSString).appendingPathComponent(".forel-uncompress-\(UUID().uuidString)")
        try fm.createDirectory(atPath: tempDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(atPath: replacementDir) }

        do {
            let dates = archiveURL.pathExtension.lowercased() == "zip" ? try zipModificationDates(path: path) : nil
            try SafeArchive.extract(path: path, destination: tempDir, zipDates: dates)
        } catch {
            throw ActionError("Could not uncompress archive: \(error)")
        }
        guard archiveUndoFingerprint(path, contents: false) == sourceFingerprint,
              try SafeArchive.readQuarantine(path: path) == sourceQuarantine else {
            throw ActionError("The archive changed while it was being extracted")
        }

        let extracted: String
        if plan.usesWrapperFolder {
            extracted = (replacementDir as NSString).appendingPathComponent("output")
            try fm.createDirectory(atPath: extracted, withIntermediateDirectories: false)
            for item in plan.topLevelItems {
                let itemPath = (tempDir as NSString).appendingPathComponent(item)
                let destination = (extracted as NSString).appendingPathComponent(item)
                try fm.moveItem(atPath: itemPath, toPath: destination)
            }
        } else if let item = plan.topLevelItems.first {
            extracted = (tempDir as NSString).appendingPathComponent(item)
        } else { throw ActionError("Archive is empty") }
        try SafeArchive.applyQuarantine(sourceQuarantine, to: extracted)

        if plan.conflicts, plan.resolution == .replace {
            _ = try stagedReplace(path: extracted, target: plan.target, moving: true)
        } else { try fm.moveItem(atPath: extracted, toPath: plan.target) }

        let displacedTarget = plan.conflicts && plan.resolution == .replace
        let publishedFingerprint = archiveUndoFingerprint(plan.target, contents: false)
        guard archiveUndoFingerprint(path, contents: false) == sourceFingerprint,
              try SafeArchive.readQuarantine(path: path) == sourceQuarantine else {
            if !displacedTarget, let publishedFingerprint,
               archiveUndoFingerprint(plan.target, contents: false) == publishedFingerprint {
                try? fm.removeItem(atPath: plan.target)
            }
            throw ActionError("The archive changed after extraction; the archive was retained and extracted output may remain")
        }
        do { _ = try platform.trash(path: path) }
        catch {
            if !displacedTarget, fm.fileExists(atPath: path), let publishedFingerprint,
               archiveUndoFingerprint(plan.target, contents: false) == publishedFingerprint {
                do {
                    try fm.removeItem(atPath: plan.target)
                    throw ActionError("Could not move the archive to Trash; extracted output was rolled back")
                } catch let failure as ActionError { throw failure }
                catch { throw ActionError("Could not move the archive to Trash; the extracted output and archive were retained") }
            }
            throw ActionError("Could not move the archive to Trash; extracted output was retained and the archive may still exist")
        }
        return Applied(newPath: plan.target, undo: .none)
    }

    /// Resolves the actual path a move/copy should write to, given the
    /// configured conflict resolution: `.rename` numbers the file instead;
    /// `.replace` is handled by stagedReplace; `.skip` also returns
    /// `naiveDest` — planning already turns a real conflict under `.skip`
    /// into `wouldSkip` so this is never reached with one in practice, and
    /// if it somehow is, the caller's move/copy call throws instead of
    /// silently overwriting.
    private static func resolveDestination(naiveDest: String, dir: String, fileName: String, resolution: MoveConflictResolution) throws -> String {
        switch resolution {
        case .rename:
            return uniqueDest(dir: dir, fileName: fileName)
        case .replace:
            throw ActionError("Replacement requires staged publication")
        case .skip, .discard:
            return naiveDest
        }
    }

    static func conflictResolution(_ action: Action, default defaultResolution: MoveConflictResolution = .rename) -> MoveConflictResolution {
        guard let raw = action.params[ActionParam.onConflict]?.stringValue else { return defaultResolution }
        return MoveConflictResolution(rawValue: raw) ?? defaultResolution
    }

    private static func renameFile(_ action: Action, path: String, contextPath: String?, hazelContext: HazelPatternContext?) throws -> Applied {
        let pattern = try stringParam(action, ActionParam.pattern, "Rename")
        var newName = try action.params[HazelPattern.tokensKey] != nil
            ? HazelPattern.render(action, path: path, contextPath: contextPath, context: hazelContext)
            : applyRenamePattern(pattern, path: path)
        if action.params[ActionParam.cleanFileName]?.boolValue == true {
            newName = cleanFileName(newName)
        }
        let dest = (path as NSString).deletingLastPathComponent + "/" + newName
        try FileManager.default.moveItem(atPath: path, toPath: dest)
        return Applied(newPath: dest, undo: .move(from: path, to: dest))
    }

    /// Adds (`add = true`) or removes Finder tags, capturing exactly the tags
    /// that actually changed so the undo only touches those.
    private static func applyTags(_ action: Action, path: String, contextPath: String?, context: HazelPatternContext?, add: Bool) throws -> Applied {
        let existing = try FinderTags.readChecked(path)
        let beforeLabel = try finderLabel(path)
        let names = try renderedTags(action, path: path, contextPath: contextPath, context: context)
        let all = !add && action.params["remove_all_tags"]?.boolValue == true
        var updated = existing
        var changed: [String] = []
        if add {
            for name in names where !updated.contains(where: { tagName($0) == name }) {
                updated.append(name); changed.append(name)
            }
        } else {
            changed = existing.filter { all || names.contains(tagName($0)) }
            updated.removeAll { all || names.contains(tagName($0)) }
        }
        let clearLabel = !add && beforeLabel != 0 && (all || (changed.contains { FinderTags.tagColor($0) == beforeLabel } && !updated.contains { FinderTags.tagColor($0) == beforeLabel }))
        if updated != existing { try FinderTags.write(path, updated) }
        if clearLabel {
            do { try setFinderLabelNumber(path, 0) }
            catch { try? FinderTags.write(path, existing); throw error }
        }
        let after = try FinderTags.readChecked(path)
        let afterLabel = try finderLabel(path)
        let undo: Undo = .tagState(path: path, before: existing, after: after, beforeLabel: beforeLabel, afterLabel: afterLabel)
        return Applied(newPath: path, undo: undo)
    }

    private static func setColor(_ action: Action, path: String) throws -> Applied {
        let color = action.params[ActionParam.color]?.stringValue ?? ""
        let beforeLabel = try finderLabel(path)
        let afterLabel = FinderTags.colorIndex(color) ?? 0
        let before = try FinderTags.readChecked(path).filter { FinderTags.tagColor($0) != nil }
        try FinderTags.setColorLabel(path, color: color)
        let after = try FinderTags.readChecked(path).filter { FinderTags.tagColor($0) != nil }
        do { try setFinderLabelNumber(path, afterLabel) }
        catch {
            try? FinderTags.restoreColors(path, before: before, after: after)
            throw error
        }
        return Applied(newPath: path, undo: .tagColors(path: path, before: before, after: after, beforeLabel: beforeLabel, afterLabel: afterLabel))
    }

    static func finderLabel(_ path: String) throws -> Int {
        guard let value = try URL(fileURLWithPath: path).resourceValues(forKeys: [.labelNumberKey]).labelNumber else {
            throw ActionError("Cannot read the current Finder label")
        }
        return value
    }

    private static func setFinderLabelNumber(_ path: String, _ value: Int) throws {
        try (URL(fileURLWithPath: path) as NSURL).setResourceValue(NSNumber(value: value), forKey: .labelNumberKey)
    }

    private static func finderLabelIndex(_ action: Action) throws -> Int {
        guard let color = action.params[ActionParam.color]?.stringValue else { throw ActionError("Finder label color is missing") }
        if color.isEmpty { return 0 }
        guard let index = FinderTags.colorIndex(color) else { throw ActionError("Finder label color is not recognized") }
        return index
    }

    private static func setFinderLabel(_ action: Action, path: String) throws -> Applied {
        _ = try finderLabelIndex(action)
        return try setColor(action, path: path)
    }

    private static func readFileFlag(_ path: String, key: String) throws -> Bool {
        let url = URL(fileURLWithPath: path)
        let values = try url.resourceValues(forKeys: [key == "locked" ? .isUserImmutableKey : .hasHiddenExtensionKey])
        guard let value = key == "locked" ? values.isUserImmutable : values.hasHiddenExtension else {
            throw ActionError("Cannot read file metadata")
        }
        return value
    }

    private static func finderCommentValue(_ action: Action, path: String, contextPath: String?, hazelContext: HazelPatternContext?) throws -> String {
        if action.params[HazelPattern.tokensKey] != nil {
            return try HazelPattern.render(action, path: path, contextPath: contextPath, context: hazelContext, filename: false)
        }
        let metadataPath = FileManager.default.fileExists(atPath: path) ? path : (hazelContext?.path ?? contextPath ?? path)
        let existing = action.params[ActionParam.includeExistingComment]?.boolValue == true ? (try FinderComment.read(metadataPath) ?? "") : ""
        return existing + (action.params[ActionParam.comment]?.stringValue ?? "")
    }

    private static func writeFileFlag(_ path: String, key: String, value: Bool) throws {
        let resourceKey: URLResourceKey = key == "locked" ? .isUserImmutableKey : .hasHiddenExtensionKey
        try (URL(fileURLWithPath: path) as NSURL).setResourceValue(NSNumber(value: value), forKey: resourceKey)
    }

    private static let scriptDefaultTimeout: TimeInterval = 60

    private static func workflowPath(_ action: Action) throws -> String {
        guard let path = action.params[ActionParam.workflowPath]?.stringValue, path.hasPrefix("/"), !path.contains("\0") else {
            throw ActionError("Automator workflow path must be absolute")
        }
        return path
    }

    static func osaConfiguration(_ action: Action) throws -> (HazelOSARunner.Language, HazelOSARunner.Source, [String], [String]) {
        guard let language = HazelOSARunner.Language(rawValue: action.params[ActionParam.osaLanguage]?.stringValue ?? "AppleScript") else { throw ActionError("Invalid script language") }
        let mode = action.params[ActionParam.osaMode]?.stringValue ?? "embedded"
        let source: HazelOSARunner.Source
        switch mode {
        case "embedded":
            guard let value = action.params[ActionParam.script]?.stringValue, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= 1_000_000, !value.contains("\0") else { throw ActionError("Script source cannot be empty or invalid") }
            source = .embedded(value)
        case "sourceHandler", "legacySource":
            guard let value = action.params[ActionParam.script]?.stringValue, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= 1_000_000, !value.contains("\0") else { throw ActionError("Script source cannot be empty or invalid") }
            if mode == "legacySource" {
                guard language == .appleScript else { throw ActionError("Legacy scripts must use AppleScript") }
                source = .legacySource(value)
            } else { source = .sourceHandler(value) }
        case "external":
            guard let path = action.params[ActionParam.osaPath]?.stringValue, path.hasPrefix("/"), !path.contains("\0") else { throw ActionError("Script path must be absolute") }
            source = .external(path)
        case "compiled":
            guard let value = action.params[ActionParam.compiledAppleScript]?.stringValue,
                  let data = Data(base64Encoded: value), data.count <= 1_000_000,
                  data.starts(with: Data((language == .appleScript ? "Fasd" : "JsOsa").utf8)) else { throw ActionError("Invalid compiled script") }
            source = .compiled(data)
        default: throw ActionError("Invalid script mode")
        }
        func strings(_ key: String) throws -> [String] {
            guard let raw = action.params[key] else { return [] }
            guard let values = raw.arrayValue, values.allSatisfy({ value in
                guard let name = value.stringValue else { return false }
                return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !name.contains("\0")
            }) else { throw ActionError("Invalid script attributes") }
            let result = values.compactMap(\.stringValue)
            if key == ActionParam.osaOutputs, Set(result).count != result.count { throw ActionError("Duplicate output attributes") }
            return result
        }
        return (language, source, try strings(ActionParam.osaInputs), try strings(ActionParam.osaOutputs))
    }

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

    /// Hazel stores source and interpreter separately. Use a source file rather
    /// than shell-specific `-c` so interpreters such as Python and Perl receive
    /// the matched path as their first script argument too.
    private enum HazelShellSource {
        case embedded(source: String, interpreter: String)
        case external(path: String, bookmark: Data?)
    }
    private static func hazelShellScript(_ action: Action) throws -> HazelShellSource {
        let mode = action.params[ActionParam.shellMode]?.stringValue ?? "embedded"
        if mode == "external" {
            guard let path = action.params[ActionParam.shellPath]?.stringValue, path.hasPrefix("/"), !path.contains("\0") else {
                throw ActionError("External shell script path must be absolute")
            }
            var bookmark: Data?
            if let encoded = action.params[ActionParam.shellBookmark]?.stringValue {
                guard let decoded = Data(base64Encoded: encoded), decoded.count <= 1_000_000 else { throw ActionError("Invalid external script bookmark") }
                bookmark = decoded
            }
            return .external(path: path, bookmark: bookmark)
        }
        guard mode == "embedded" else { throw ActionError("Invalid shell script mode") }
        let interpreter = action.params[ActionParam.shell]?.stringValue ?? "/bin/zsh"
        guard let source = action.params[ActionParam.script]?.stringValue, source.utf8.count <= 1_000_000,
              interpreter.hasPrefix("/"), !interpreter.contains("\0"), !source.contains("\0") else {
            throw ActionError("The imported shell script or its interpreter is missing or invalid")
        }
        return .embedded(source: source, interpreter: interpreter)
    }

    private static func runHazelShellScript(_ action: Action, path: String) throws -> Applied {
        let script = try hazelShellScript(action)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("forel-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("script")
        let errorsURL = directory.appendingPathComponent("errors")
        if case .embedded(let source, _) = script { try Data(source.utf8).write(to: sourceURL, options: .atomic) }
        guard FileManager.default.createFile(atPath: errorsURL.path, contents: nil) else {
            throw ActionError("Cannot prepare shell script error output")
        }
        let errorFile = try FileHandle(forWritingTo: errorsURL)
        defer { try? errorFile.close() }
        let process = Process()
        switch script {
        case .embedded(_, let interpreter):
            process.executableURL = URL(fileURLWithPath: interpreter)
            process.arguments = [sourceURL.path, URL(fileURLWithPath: path).standardizedFileURL.path]
        case .external(let executable, let bookmark):
            var url = URL(fileURLWithPath: executable)
            if !FileManager.default.fileExists(atPath: executable), let bookmark {
                var stale = false
                if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) {
                    url = resolved
                }
            }
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw ActionError("External shell script is missing or not executable; choose its current path")
            }
            process.executableURL = url
            process.arguments = [URL(fileURLWithPath: path).standardizedFileURL.path]
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorFile
        do {
            try process.run()
        } catch {
            throw ActionError("Cannot start shell script: \(error.localizedDescription)")
        }
        let start = Date()
        while process.isRunning && Date().timeIntervalSince(start) < scriptDefaultTimeout {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw ActionError("Shell script timed out after \(Int(scriptDefaultTimeout))s")
        }
        process.waitUntilExit()
        try errorFile.close()
        guard process.terminationReason == .exit && process.terminationStatus == 0 else {
            let reader = try FileHandle(forReadingFrom: errorsURL)
            defer { try? reader.close() }
            let data = try reader.read(upToCount: 4096) ?? Data()
            let details = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let status = process.terminationReason == .exit ? "exited with status \(process.terminationStatus)" : "terminated by signal \(process.terminationStatus)"
            throw ActionError("Shell script \(status)\(details.isEmpty ? "" : ": \(details)")")
        }
        return Applied(newPath: path, undo: .none)
    }

    private static func compiledHazelAppleScript(_ action: Action) throws -> Data {
        guard let encoded = action.params[ActionParam.compiledAppleScript]?.stringValue,
              let data = Data(base64Encoded: encoded), data.count <= 1_000_000,
              data.starts(with: Data("Fasd".utf8)) else {
            throw ActionError("The imported AppleScript is missing or invalid")
        }
        return data
    }

    private static func runHazelAppleScript(_ action: Action, path: String) throws -> Applied {
        let data = try compiledHazelAppleScript(action)
        let result = try HazelOSARunner.run(language: .appleScript, source: .legacyCompiled(data), path: path, inputs: [])
        guard result.attributes.isEmpty else { throw ActionError("Legacy script output attributes are not configured") }
        return Applied(newPath: result.switchPath ?? path, undo: .none, stopsActionChain: result.stop)
    }

    private static func runShortcut(_ action: Action, path: String) throws -> Applied {
        let name = try stringParam(action, ActionParam.shortcutName, "RunShortcut")
        let inputMode = shortcutInputMode(action)
        try ShortcutRunner.run(name: name, input: shortcutInput(mode: inputMode, path: path))
        return Applied(newPath: path, undo: .none)
    }

    private static func openApplication(_ action: Action, path: String) throws -> Applied {
        #if canImport(AppKit)
        let appPath = try stringParam(action, ActionParam.applicationPath, "OpenApplication")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appPath.isEmpty else {
            throw ActionError("Open Application requires '\(ActionParam.applicationPath)' param")
        }
        guard FileManager.default.fileExists(atPath: appPath) else {
            throw ActionError("Application not found at \(appPath)")
        }

        let appURL = URL(fileURLWithPath: appPath)
        let configuration = NSWorkspace.OpenConfiguration()
        if passesFileToApplication(action) {
            NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: appURL, configuration: configuration)
        } else {
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        }
        return Applied(newPath: path, undo: .none)
        #else
        throw ActionError("Open Application is not available on this platform")
        #endif
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
        guard resolution != .discard else { throw ActionError("Discard-on-conflict is available only for Move") }
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
        case .finderLabel(let path, let previous):
            guard try !FinderTags.hasExistingTags(path) else { throw ActionError("Cannot restore a Finder label after tags were added") }
            try (URL(fileURLWithPath: path) as NSURL).setResourceValue(NSNumber(value: previous), forKey: .labelNumberKey)
        case .fileFlag(let path, let key, let previous):
            try writeFileFlag(path, key: key, value: previous)
        case .finderComment(let path, let previous):
            try FinderComment.write(path, value: previous)
        case .archive(let original, let trashed, let archive, let trashFingerprint, let archiveFingerprint):
            guard !FileManager.default.fileExists(atPath: original), archiveUndoFingerprint(trashed, contents: false) == trashFingerprint,
                  archiveUndoFingerprint(archive, contents: true) == archiveFingerprint else { throw ActionError("The original or archive changed; cannot safely undo") }
            try FileManager.default.moveItem(atPath: trashed, toPath: original)
            try FileManager.default.removeItem(atPath: archive)
        case .tagColors(let path, let before, let after, let beforeLabel, let afterLabel):
            guard try finderLabel(path) == afterLabel else { throw ActionError("Finder label changed since this action ran") }
            let current = try FinderTags.readChecked(path).filter { FinderTags.tagColor($0) != nil }
            guard current == after else { throw ActionError("Finder color tags changed since this action ran") }
            try setFinderLabelNumber(path, beforeLabel)
            do { try FinderTags.restoreColors(path, before: before, after: after) }
            catch { try? setFinderLabelNumber(path, afterLabel); throw error }
        case .tagState(let path, let before, let after, let beforeLabel, let afterLabel):
            guard try finderLabel(path) == afterLabel, try FinderTags.readChecked(path) == after else { throw ActionError("Finder tags or label changed since this action ran") }
            try setFinderLabelNumber(path, beforeLabel)
            do { try FinderTags.write(path, before) }
            catch { try? setFinderLabelNumber(path, afterLabel); throw error }
        case .none:
            throw ActionError("this action cannot be undone")
        }
    }

    public static func preview(_ action: Action, path: String) throws -> String {
        try plan(action, path: path).description
    }

    public static func plan(_ action: Action, path: String, contextPath: String? = nil, hazelContext: HazelPatternContext? = nil, watchedRoot: String? = nil, uploadServers: [UploadServer] = []) throws -> ActionPlan {
        let fileName = (path as NSString).lastPathComponent

        switch action.kind {
        case .hazelContinue, .hazelRecurse:
            throw ActionError("Hazel control actions must be handled by the rule engine")
        case .importError:
            throw ActionError("This imported rule contains unsupported parts")
        case .moveToFolder:
            let base = try action.params[HazelPattern.sortKey]?.boolValue == true
                ? HazelPattern.sortDestination(action, path: path, contextPath: contextPath, context: hazelContext)
                : expandedDestination(action.params[ActionParam.destination]?.stringValue ?? "", fileAtPath: contextPath ?? path)
            let destDir = try structuredDestination(action, path: path, base: base, watchedRoot: watchedRoot)
            try validateDestinationOutsideSource(path: path, destination: destDir)

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

            if conflicts && resolution == .discard {
                let trash = try trashDir()
                let target = uniqueDest(dir: trash, fileName: fileName)
                return ActionPlan(kind: action.kind, description: "Move new file to Trash because the destination exists", sourcePath: path, targetPath: target, status: .wouldRun, finalPath: target, copiedPath: nil, isTerminal: true, stopsActionChain: true)
            }

            if action.params[ActionParam.discardDuplicates]?.boolValue == true {
                do {
                    if try duplicateAtDestination(path: path, destination: destDir) {
                        let trash = try trashDir()
                        let target = uniqueDest(dir: trash, fileName: fileName)
                        return ActionPlan(kind: action.kind, description: "Move identical file to Trash",
                                          sourcePath: path, targetPath: target, status: .wouldRun,
                                          finalPath: target, copiedPath: nil, isTerminal: true, stopsActionChain: true)
                    }
                } catch {
                    return ActionPlan(kind: action.kind, description: "Cannot check duplicate: \(error)",
                                      sourcePath: path, targetPath: nil, status: .blocked,
                                      finalPath: path, copiedPath: nil, isTerminal: true)
                }
            }

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
                isTerminal: true,
                warning: destinationWarning(destDir)
            )
        case .copyToFolder:
            let base = expandedDestination(action.params[ActionParam.destination]?.stringValue ?? "", fileAtPath: contextPath ?? path)
            let destDir = try structuredDestination(action, path: path, base: base, watchedRoot: watchedRoot)
            try validateDestinationOutsideSource(path: path, destination: destDir)
            let naiveTarget = (destDir as NSString).appendingPathComponent(fileName)
            let resolution = conflictResolution(action)
            guard resolution != .discard else { throw ActionError("Discard-on-conflict is available only for Move") }
            let conflicts = FileManager.default.fileExists(atPath: naiveTarget)

            if action.params[ActionParam.skipDuplicates]?.boolValue == true {
                do {
                    if try duplicateAtDestination(path: path, destination: destDir) {
                        return ActionPlan(kind: action.kind, description: "Skip — an identical item already exists at the destination", sourcePath: path, targetPath: naiveTarget, status: .wouldSkip, finalPath: path, copiedPath: nil, isTerminal: false, stopsActionChain: true)
                    }
                } catch {
                    return ActionPlan(kind: action.kind, description: "Cannot check duplicate: \(error)", sourcePath: path, targetPath: nil, status: .blocked, finalPath: path, copiedPath: nil, isTerminal: false, stopsActionChain: true)
                }
            }

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
                isTerminal: false,
                warning: destinationWarning(destDir)
            )
        case .syncToFolder:
            let sync = try syncTarget(action, path: path)
            let warning = sync.isDirectory ? " (removes destination items missing from the source)" : " (replaces the destination file)"
            return ActionPlan(kind: action.kind, description: "Sync to \(sync.target)\(warning)", sourcePath: path,
                              targetPath: sync.target, status: .wouldRun, finalPath: path, copiedPath: nil, isTerminal: false)
        case .rename:
            let pattern = action.params[ActionParam.pattern]?.stringValue ?? ""
            var newName = try action.params[HazelPattern.tokensKey] != nil
                ? HazelPattern.render(action, path: path, contextPath: contextPath, context: hazelContext)
                : applyRenamePattern(pattern, path: path)
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
            let tags = try renderedTags(action, path: path, contextPath: contextPath, context: hazelContext)
            let description: String
            if tags.isEmpty { description = "Add tag" }
            else if action.params["tag"] != nil && tags.count == 1 { description = "Add tag '\(tags[0])'" }
            else { description = "Add tag\(tags.count > 1 ? "s" : ""): \(tags.joined(separator: ", "))" }
            return ActionPlan(
                kind: action.kind,
                description: description,
                sourcePath: path,
                targetPath: nil,
                status: try tagWouldChange(action, tags: tags, path: FileManager.default.fileExists(atPath: path) ? path : (contextPath ?? path)) ? .wouldRun : .wouldSkip,
                finalPath: path,
                copiedPath: nil,
                isTerminal: false
            )
        case .removeTag:
            let tags = try renderedTags(action, path: path, contextPath: contextPath, context: hazelContext)
            let description: String
            if action.params["remove_all_tags"]?.boolValue == true { description = "Remove all tags" }
            else if tags.isEmpty { description = "Remove tag" }
            else if action.params["tag"] != nil && tags.count == 1 { description = "Remove tag '\(tags[0])'" }
            else { description = "Remove tag\(tags.count > 1 ? "s" : ""): \(tags.joined(separator: ", "))" }
            return ActionPlan(
                kind: action.kind,
                description: description,
                sourcePath: path,
                targetPath: nil,
                status: try tagWouldChange(action, tags: tags, path: FileManager.default.fileExists(atPath: path) ? path : (contextPath ?? path)) ? .wouldRun : .wouldSkip,
                finalPath: path,
                copiedPath: nil,
                isTerminal: false
            )
        case .setColorLabel:
            let color = action.params[ActionParam.color]?.stringValue ?? ""
            let index = FinderTags.colorIndex(color) ?? 0
            let metadataPath = FileManager.default.fileExists(atPath: path) ? path : (contextPath ?? path)
            let colors = try FinderTags.readChecked(metadataPath).compactMap(FinderTags.tagColor)
            let currentLabel = try finderLabel(metadataPath)
            let unchanged = (index == 0 ? colors.isEmpty : !colors.isEmpty && colors.allSatisfy { $0 == index }) && currentLabel == index
            return ActionPlan(
                kind: action.kind,
                description: color.isEmpty ? "Clear color label" : "Set color label to \(color)",
                sourcePath: path,
                targetPath: nil,
                status: unchanged ? .wouldSkip : .wouldRun,
                finalPath: path,
                copiedPath: nil,
                isTerminal: false
            )
        case .setFinderLabel:
            let color = action.params[ActionParam.color]?.stringValue ?? ""
            let index = try finderLabelIndex(action)
            let metadataPath = FileManager.default.fileExists(atPath: path) ? path : (contextPath ?? path)
            let colors = try FinderTags.readChecked(metadataPath).compactMap(FinderTags.tagColor)
            let currentLabel = try finderLabel(metadataPath)
            let unchanged = (index == 0 ? colors.isEmpty : !colors.isEmpty && colors.allSatisfy { $0 == index }) && currentLabel == index
            return ActionPlan(kind: action.kind, description: color.isEmpty ? "Clear Finder color label" : "Set Finder color label to \(color)",
                              sourcePath: path, targetPath: nil, status: unchanged ? .wouldSkip : .wouldRun,
                              finalPath: path, copiedPath: nil, isTerminal: false)
        case .setLocked, .setExtensionHidden:
            let enabled = action.params[ActionParam.enabled]?.boolValue ?? true
            let key = action.kind == .setLocked ? "locked" : "extension_hidden"
            let metadataPath = FileManager.default.fileExists(atPath: path) ? path : (contextPath ?? path)
            let previous = try readFileFlag(metadataPath, key: key)
            let description = action.kind == .setLocked ? (enabled ? "Lock file" : "Unlock file") : (enabled ? "Hide extension" : "Show extension")
            return ActionPlan(kind: action.kind, description: description, sourcePath: path, targetPath: nil,
                              status: previous == enabled ? .wouldSkip : .wouldRun, finalPath: path, copiedPath: nil, isTerminal: false)
        case .setFinderComment:
            let metadataPath = FileManager.default.fileExists(atPath: path) ? path : (hazelContext?.path ?? contextPath ?? path)
            let value = try finderCommentValue(action, path: path, contextPath: contextPath, hazelContext: hazelContext)
            let previous = try FinderComment.read(metadataPath) ?? ""
            return ActionPlan(kind: action.kind, description: "Set Finder comment", sourcePath: path, targetPath: nil,
                              status: previous == value ? .wouldSkip : .wouldRun, finalPath: path, copiedPath: nil, isTerminal: false)
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
        case .runHazelShellScript:
            _ = try hazelShellScript(action)
            return ActionPlan(kind: action.kind, description: "Run imported shell script", sourcePath: path,
                              targetPath: nil, status: .wouldRun, finalPath: path, copiedPath: nil, isTerminal: false)
        case .runHazelAppleScript:
            _ = try compiledHazelAppleScript(action)
            return ActionPlan(kind: action.kind, description: "Run imported AppleScript", sourcePath: path,
                              targetPath: nil, status: .wouldRun, finalPath: path, copiedPath: nil, isTerminal: false)
        case .runHazelOSA:
            _ = try osaConfiguration(action)
            return ActionPlan(kind: action.kind, description: "Run AppleScript or JavaScript", sourcePath: path,
                              targetPath: nil, status: .wouldRun, finalPath: path, copiedPath: nil, isTerminal: false)
        case .runWorkflow:
            let workflow = try workflowPath(action)
            return ActionPlan(kind: action.kind, description: "Run Automator workflow: \((workflow as NSString).lastPathComponent)",
                              sourcePath: path, targetPath: nil, status: .wouldRun, finalPath: path, copiedPath: nil, isTerminal: false)
        case .upload:
            let source = FileManager.default.fileExists(atPath: path) ? path : (contextPath ?? path)
            let upload = try uploadConfiguration(action, servers: uploadServers).withRelativeFolders(folderStructureComponents(action, path: source, watchedRoot: watchedRoot))
            return ActionPlan(kind: action.kind, description: "Upload to \(upload.host)\(upload.effectiveRemotePath)", sourcePath: path,
                              targetPath: nil, status: .wouldRun, finalPath: path, copiedPath: nil, isTerminal: false)
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
        case .openApplication:
            let appPath = action.params[ActionParam.applicationPath]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let appName = appPath.isEmpty ? "" : ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
            let passesFile = passesFileToApplication(action)
            return ActionPlan(
                kind: action.kind,
                description: appName.isEmpty
                    ? "Open application"
                    : passesFile ? "Open \(appName) with file" : "Open \(appName)",
                sourcePath: path,
                targetPath: nil,
                status: appPath.isEmpty ? .wouldSkip : .wouldRun,
                finalPath: path,
                copiedPath: nil,
                isTerminal: false
            )
        case .archive:
            if isAlreadyZip(path) {
                return ActionPlan(kind: action.kind, description: "Already a ZIP archive", sourcePath: path, targetPath: nil, status: .wouldSkip, finalPath: path, copiedPath: nil, isTerminal: false)
            }
            let directory = (path as NSString).deletingLastPathComponent
            let name = fileName + ".zip"
            let naive = (directory as NSString).appendingPathComponent(name)
            let (target, description) = conflictAwarePlan(verb: "Archive", naiveTarget: naive, destDir: directory, fileName: name, resolution: .rename, conflicts: FileManager.default.fileExists(atPath: naive))
            return ActionPlan(kind: action.kind, description: description, sourcePath: path, targetPath: target, status: .wouldRun, finalPath: target, copiedPath: nil, isTerminal: false)
        case .makeAlias:
            let dest = action.params[ActionParam.destination]?.stringValue ?? ""
            let naive = (dest as NSString).appendingPathComponent(fileName)
            let (target, description) = conflictAwarePlan(verb: "Make alias", naiveTarget: naive, destDir: dest, fileName: fileName, resolution: .rename, conflicts: FileManager.default.fileExists(atPath: naive))
            return ActionPlan(kind: action.kind, description: description, sourcePath: path, targetPath: target, status: dest.isEmpty ? .blocked : .wouldRun, finalPath: path, copiedPath: nil, isTerminal: false)
        case .displayNotification:
            let text = try action.params[HazelPattern.tokensKey] != nil
                ? HazelPattern.render(action, path: path, contextPath: contextPath, context: hazelContext, filename: false)
                : (action.params[ActionParam.notificationText]?.stringValue ?? "")
            return ActionPlan(kind: action.kind, description: "Display notification: \(text)", sourcePath: path, targetPath: nil, status: .wouldRun, finalPath: path, copiedPath: nil, isTerminal: false)
        case .ignore:
            return ActionPlan(kind: action.kind, description: action.kind.label, sourcePath: path, targetPath: nil, status: .wouldRun, finalPath: path, copiedPath: nil, isTerminal: true)
        case .openDefault, .showInFinder, .pause:
            if action.kind == .pause {
                let seconds = Double(action.params[ActionParam.durationSeconds]?.stringValue ?? "1") ?? .nan
                guard seconds.isFinite, seconds >= 0, seconds <= 86_400 else { throw ActionError("Pause must be between 0 and 86400 seconds") }
            }
            return ActionPlan(kind: action.kind, description: action.kind.label, sourcePath: path, targetPath: nil, status: .wouldRun, finalPath: path, copiedPath: nil, isTerminal: false)
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
            guard resolution != .discard else { throw ActionError("Discard-on-conflict is available only for Move") }
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
        case .archive, .makeAlias, .openDefault, .showInFinder, .pause, .ignore, .displayNotification:
            return true
        case .hazelContinue, .hazelRecurse:
            return false
        case .setColorLabel:
            let target = FinderTags.colorIndex(action.params[ActionParam.color]?.stringValue ?? "") ?? 0
            guard let tags = try? FinderTags.readChecked(path), let label = try? finderLabel(path) else { return true }
            let colors = tags.compactMap(FinderTags.tagColor)
            return label != target || (target == 0 ? !colors.isEmpty : colors.isEmpty || colors.contains { $0 != target })
        case .addTag:
            guard let tags = try? renderedTags(action, path: path, contextPath: nil, context: nil) else { return true }
            return (try? tagWouldChange(action, tags: tags, path: path)) ?? true
        case .removeTag:
            guard let tags = try? renderedTags(action, path: path, contextPath: nil, context: nil) else { return true }
            return (try? tagWouldChange(action, tags: tags, path: path)) ?? true
        case .rename:
            let pattern = action.params[ActionParam.pattern]?.stringValue ?? ""
            guard let newName = try? applyRenamePattern(pattern, path: path) else { return true }
            return (path as NSString).lastPathComponent != newName
        case .moveToFolder, .copyToFolder, .syncToFolder, .setFinderLabel, .setLocked, .setExtensionHidden, .setFinderComment, .importError, .moveToTrash, .delete, .runScript, .runHazelShellScript, .runHazelAppleScript, .runHazelOSA, .runWorkflow, .upload, .runShortcut, .openApplication, .importToLibrary, .uncompress:
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

    private static func tagName(_ value: String) -> String {
        guard FinderTags.tagColor(value) != nil, let index = value.lastIndex(of: "\n") else { return value }
        return String(value[..<index])
    }

    private static func renderedTags(_ action: Action, path: String, contextPath: String?, context: HazelPatternContext?) throws -> [String] {
        if action.kind == .removeTag && action.params["remove_all_tags"]?.boolValue == true { return [] }
        var tags = paramTags(action)
        if let tokens = action.params[HazelPattern.tokensKey]?.arrayValue {
            let lists = tokens.indices.filter { tokens[$0]["type"]?.stringValue == "attributeList" && tokens[$0]["selection"]?.stringValue == "all" }
            guard lists.count <= 1 else { throw ActionError("A generated tag can expand one list at a time") }
            var variants = [action]
            if let index = lists.first {
                let name = tokens[index]["value"]?.stringValue ?? ""
                guard case .array(let values) = context?.attributes[name], values.count <= 1000,
                      values.allSatisfy({ $0.stringValue != nil }) else { throw ActionError("List attribute \(name) is unavailable or invalid") }
                variants = values.indices.map { position in
                    var copy = action, replacement = tokens
                    if case .object(var token) = replacement[index] {
                        token["selection"] = .string("index"); token["index"] = .string(String(position + 1))
                        replacement[index] = .object(token)
                    }
                    if case .object(var params) = copy.params { params[HazelPattern.tokensKey] = .array(replacement); copy.params = .object(params) }
                    return copy
                }
            }
            for variant in variants {
                let value = try HazelPattern.render(variant, path: path, contextPath: contextPath, context: context, filename: false)
                guard !value.isEmpty, !value.contains("\0"), !value.contains("\n") else { throw ActionError("Invalid generated tag") }
                tags.append(value)
            }
        }
        return tags
    }

    private static func tagWouldChange(_ action: Action, tags: [String], path: String) throws -> Bool {
        let existing = try FinderTags.readChecked(path)
        if action.kind == .removeTag && action.params["remove_all_tags"]?.boolValue == true {
            let label = try finderLabel(path)
            return !existing.isEmpty || label != 0
        }
        let names = existing.map(tagName)
        return action.kind == .addTag ? tags.contains { !names.contains($0) } : tags.contains { names.contains($0) }
    }

    public static func passesFileToApplication(_ action: Action) -> Bool {
        action.params[ActionParam.passFileToApplication]?.boolValue ?? true
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
        let topLevelItems = try url.pathExtension.lowercased() == "zip" ? zipTopLevelItems(path: path) : SafeArchive.topLevelItems(path: path)
        guard !topLevelItems.isEmpty else {
            throw ActionError("Archive is empty.")
        }

        let parent = (path as NSString).deletingLastPathComponent
        let resolution = conflictResolution(action)
        guard resolution != .discard else { throw ActionError("Discard-on-conflict is available only for Move") }
        let usesWrapperFolder = topLevelItems.count != 1
        let naiveTarget: String
        if usesWrapperFolder {
            let filename = url.lastPathComponent
            let compound = [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lzma", ".tar.z"]
            let suffix = compound.first { filename.lowercased().hasSuffix($0) }
            let stem = suffix.map { String(filename.dropLast($0.count)) } ?? url.deletingPathExtension().lastPathComponent
            guard !stem.isEmpty else { throw ActionError("Archive has no usable output folder name") }
            naiveTarget = (parent as NSString).appendingPathComponent(stem)
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
        guard URL(fileURLWithPath: target).standardizedFileURL.path != url.standardizedFileURL.path else {
            throw ActionError("The extracted item would replace its own source archive")
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
        var count = 0
        var total: UInt64 = 0
        for entry in archive {
            count += 1
            guard count <= 100_000, entry.uncompressedSize <= 10 * 1024 * 1024 * 1024 - total else {
                throw ActionError("ZIP archive exceeds extraction limits")
            }
            total += entry.uncompressedSize
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: true)
            guard !entry.path.hasPrefix("/"), !entry.path.contains("\0"),
                  !components.contains(".."), entry.type != .symlink else {
                throw ActionError("ZIP archive contains an unsafe path or symbolic link")
            }
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

    private static func zipModificationDates(path: String) throws -> [String: Date] {
        let archive = try Archive(url: URL(fileURLWithPath: path), accessMode: .read, pathEncoding: nil)
        var dates: [String: Date] = [:]
        var count = 0
        for entry in archive {
            count += 1
            guard count <= 100_000 else { throw ActionError("ZIP archive exceeds extraction limits") }
            let relative = entry.path.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }.joined(separator: "/")
            if let date = entry.fileAttributes[.modificationDate] as? Date { dates[relative] = date }
        }
        return dates
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
        case .skip, .discard:
            // `conflicts` is false here (the conflicting case is returned
            // separately by the caller), so this behaves like a plain move/copy.
            return (naiveTarget, "\(verb) to \(naiveTarget)")
        }
    }

    /// A move/copy creates its destination folder on demand, so what has to
    /// be writable is that folder or, when it doesn't exist yet, its nearest
    /// existing ancestor. A network share that isn't mounted or that Forel
    /// isn't allowed to access shows up here as a missing folder under a
    /// location that can't be written to.
    private static func destinationWarning(_ destDir: String) -> String? {
        guard !destDir.isEmpty else { return nil }
        var candidate = normalizedPath(destDir)
        while !FileManager.default.fileExists(atPath: candidate) {
            let parent = (candidate as NSString).deletingLastPathComponent
            guard parent != candidate, !parent.isEmpty else { break }
            candidate = parent
        }
        guard !FileManager.default.isWritableFile(atPath: candidate) else { return nil }
        if let volume = VolumePaths.unmountedVolume(of: destDir) {
            return volumeNotConnectedMessage(volume)
        }
        return "The destination folder can't be reached or written to right now. Check that the disk or network share is connected and that Forel is allowed to access it."
    }

    private static func normalizedPath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    static func formatFileSize(_ bytes: UInt64) -> String {
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
        if let directory = try TestingTrash.configuredDirectory() { return directory }
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
