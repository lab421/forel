import Foundation

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
}

/// How `moveToFolder` resolves a destination that already has a file with
/// the same name. `rename` (the default) keeps both files; `replace` keeps
/// only the moved file, sending the one it displaces to the Trash rather
/// than deleting it outright; `skip` leaves the source file where it is,
/// so nothing is moved and no duplicate is created.
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
        case .moveToTrash, .delete:
            return try moveIntoDir(path: path, destDir: try trashDir())
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
        }
    }

    private static func stringParam(_ action: Action, _ key: String, _ kind: String) throws -> String {
        guard let value = action.params[key]?.stringValue else {
            throw ActionError("\(kind) requires '\(key)' param")
        }
        return value
    }

    /// Moves `path` into `destDir` (created if needed). `resolution` decides
    /// what happens if a file with the same name is already there: `.rename`
    /// (the default, also used by the Trash/delete paths which have no user-
    /// facing conflict choice) numbers the moved file instead; `.replace`
    /// sends the existing file to the Trash first so it stays recoverable.
    private static func moveIntoDir(path: String, destDir: String, resolution: MoveConflictResolution = .rename) throws -> Applied {
        try FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        let fileName = (path as NSString).lastPathComponent
        let naiveDest = (destDir as NSString).appendingPathComponent(fileName)

        let dest: String
        switch resolution {
        case .rename:
            dest = uniqueDest(dir: destDir, fileName: fileName)
        case .replace:
            if FileManager.default.fileExists(atPath: naiveDest) {
                let displaced = uniqueDest(dir: try trashDir(), fileName: fileName)
                try FileManager.default.moveItem(atPath: naiveDest, toPath: displaced)
            }
            dest = naiveDest
        case .skip:
            // Planning turns a real conflict into `wouldSkip` so this is
            // never reached with one in practice; if it somehow is,
            // `moveItem` below throws instead of silently overwriting.
            dest = naiveDest
        }

        try FileManager.default.moveItem(atPath: path, toPath: dest)
        return Applied(newPath: dest, undo: .move(from: path, to: dest))
    }

    static func conflictResolution(_ action: Action) -> MoveConflictResolution {
        guard let raw = action.params[ActionParam.onConflict]?.stringValue else { return .rename }
        return MoveConflictResolution(rawValue: raw) ?? .rename
    }

    private static func copyToFolder(_ action: Action, path: String) throws -> Applied {
        let destDir = try stringParam(action, ActionParam.destination, "CopyToFolder")
        try FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        let fileName = (path as NSString).lastPathComponent
        let dest = uniqueDest(dir: destDir, fileName: fileName)
        try FileManager.default.copyItem(atPath: path, toPath: dest)
        return Applied(newPath: path, undo: .copy(copy: dest))
    }

    private static func renameFile(_ action: Action, path: String) throws -> Applied {
        let pattern = try stringParam(action, ActionParam.pattern, "Rename")
        let newName = try applyRenamePattern(pattern, path: path)
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

    private static func runScript(_ action: Action, path: String) throws -> Applied {
        let script = try stringParam(action, ActionParam.script, "RunScript")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        var env = ProcessInfo.processInfo.environment
        env["FOREL_FILE"] = path
        process.environment = env
        try process.run()
        process.waitUntilExit()
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

    public static func plan(_ action: Action, path: String) throws -> ActionPlan {
        let fileName = (path as NSString).lastPathComponent

        switch action.kind {
        case .moveToFolder:
            let destDir = action.params[ActionParam.destination]?.stringValue ?? ""
            let naiveTarget = (destDir as NSString).appendingPathComponent(fileName)
            let resolution = conflictResolution(action)
            let conflicts = FileManager.default.fileExists(atPath: naiveTarget)

            if conflicts && resolution == .skip {
                return ActionPlan(
                    kind: action.kind,
                    description: "Skip — a file already exists at \(naiveTarget)",
                    sourcePath: path,
                    targetPath: naiveTarget,
                    status: .wouldSkip,
                    finalPath: path,
                    copiedPath: nil,
                    // Conceptually still a terminal move — it just didn't run.
                    // This stops later actions in the *same* rule (e.g. a tag
                    // meant to apply after the move) from running on a file
                    // that never actually moved.
                    isTerminal: true
                )
            }

            let target: String
            let description: String
            switch resolution {
            case .rename:
                target = conflicts ? uniqueDest(dir: destDir, fileName: fileName) : naiveTarget
                description = conflicts ? "Move to \(target) (renamed to avoid an existing file)" : "Move to \(target)"
            case .replace:
                target = naiveTarget
                description = conflicts ? "Move to \(target) (replacing existing file)" : "Move to \(target)"
            case .skip:
                // `conflicts` is false here (the conflicting case returned
                // above), so this behaves like a plain move.
                target = naiveTarget
                description = "Move to \(target)"
            }

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
            let target = (destDir as NSString).appendingPathComponent(fileName)
            return ActionPlan(
                kind: action.kind,
                description: "Copy to \(target)",
                sourcePath: path,
                targetPath: target,
                status: conflictStatus(target),
                finalPath: path,
                copiedPath: target,
                isTerminal: false
            )
        case .rename:
            let pattern = action.params[ActionParam.pattern]?.stringValue ?? ""
            let newName = try applyRenamePattern(pattern, path: path)
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
                status: conflictStatus(target),
                finalPath: target,
                copiedPath: nil,
                isTerminal: true
            )
        case .delete:
            let target = (try trashDir() as NSString).appendingPathComponent(fileName)
            return ActionPlan(
                kind: action.kind,
                description: "Delete (move to Trash)",
                sourcePath: path,
                targetPath: target,
                status: conflictStatus(target),
                finalPath: target,
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
        case .moveToFolder, .copyToFolder, .moveToTrash, .delete, .runScript, .runShortcut:
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

        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let modified = (attrs[.modificationDate] as? Date) ?? Date()
        let created = (attrs[.creationDate] as? Date) ?? Date()
        let size = (attrs[.size] as? UInt64) ?? 0
        let today = Date()

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = .current

        var result = pattern
            .replacingOccurrences(of: "{name}", with: stem)
            .replacingOccurrences(of: "{extension}", with: ext)
            .replacingOccurrences(of: "{date_modified}", with: dayFormatter.string(from: modified))
            .replacingOccurrences(of: "{date_created}", with: dayFormatter.string(from: created))
            .replacingOccurrences(of: "{current_date}", with: dayFormatter.string(from: today))
            .replacingOccurrences(of: "{size}", with: formatFileSize(size))

        if result.isEmpty {
            throw ActionError("rename pattern produced empty filename")
        }

        // Append the original extension only when the pattern did not place it
        // explicitly (via the {extension} token or by typing it literally).
        let alreadyHasExt = result.lowercased().hasSuffix(".\(ext.lowercased())")
        if ext.isEmpty || pattern.contains("{extension}") || alreadyHasExt {
            return result
        }
        result = "\(result).\(ext)"
        return result
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
