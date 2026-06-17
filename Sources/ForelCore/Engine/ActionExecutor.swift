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

public enum ActionExecutor {
    /// Executes the action on the file at `path`, returning the new path and an
    /// `Undo` describing how to reverse it.
    public static func execute(_ action: Action, path: String) throws -> Applied {
        switch action.kind {
        case .moveToFolder:
            let destDir = try stringParam(action, "destination", "MoveToFolder")
            return try moveIntoDir(path: path, destDir: destDir)
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
        }
    }

    private static func stringParam(_ action: Action, _ key: String, _ kind: String) throws -> String {
        guard let value = action.params[key]?.stringValue else {
            throw ActionError("\(kind) requires '\(key)' param")
        }
        return value
    }

    /// Moves `path` into `destDir` (created if needed), avoiding name collisions.
    private static func moveIntoDir(path: String, destDir: String) throws -> Applied {
        try FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        let fileName = (path as NSString).lastPathComponent
        let dest = uniqueDest(dir: destDir, fileName: fileName)
        try FileManager.default.moveItem(atPath: path, toPath: dest)
        return Applied(newPath: dest, undo: .move(from: path, to: dest))
    }

    private static func copyToFolder(_ action: Action, path: String) throws -> Applied {
        let destDir = try stringParam(action, "destination", "CopyToFolder")
        try FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        let fileName = (path as NSString).lastPathComponent
        let dest = uniqueDest(dir: destDir, fileName: fileName)
        try FileManager.default.copyItem(atPath: path, toPath: dest)
        return Applied(newPath: path, undo: .copy(copy: dest))
    }

    private static func renameFile(_ action: Action, path: String) throws -> Applied {
        let pattern = try stringParam(action, "pattern", "Rename")
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
        let color = action.params["color"]?.stringValue ?? ""
        let previous = FinderTags.currentColorName(path)
        try FinderTags.setColorLabel(path, color: color)
        return Applied(newPath: path, undo: .color(path: path, previous: previous))
    }

    private static func runScript(_ action: Action, path: String) throws -> Applied {
        let script = try stringParam(action, "script", "RunScript")
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
        let fileName = (path as NSString).lastPathComponent

        switch action.kind {
        case .moveToFolder:
            let destDir = action.params["destination"]?.stringValue ?? ""
            return "Move to \((destDir as NSString).appendingPathComponent(fileName))"
        case .copyToFolder:
            let destDir = action.params["destination"]?.stringValue ?? ""
            return "Copy to \((destDir as NSString).appendingPathComponent(fileName))"
        case .rename:
            let pattern = action.params["pattern"]?.stringValue ?? ""
            let newName = try applyRenamePattern(pattern, path: path)
            return "Rename to \(newName)"
        case .moveToTrash:
            return "Move to Trash"
        case .delete:
            return "Delete (move to Trash)"
        case .addTag:
            let tags = paramTags(action)
            if tags.isEmpty { return "Add tag" }
            if action.params["tag"] != nil && tags.count == 1 { return "Add tag '\(tags[0])'" }
            return "Add tag\(tags.count > 1 ? "s" : ""): \(tags.joined(separator: ", "))"
        case .removeTag:
            let tags = paramTags(action)
            if tags.isEmpty { return "Remove tag" }
            if action.params["tag"] != nil && tags.count == 1 { return "Remove tag '\(tags[0])'" }
            return "Remove tag\(tags.count > 1 ? "s" : ""): \(tags.joined(separator: ", "))"
        case .setColorLabel:
            let color = action.params["color"]?.stringValue ?? ""
            return color.isEmpty ? "Clear color label" : "Set color label to \(color)"
        case .runScript:
            let script = action.params["script"]?.stringValue ?? ""
            let firstLine = script.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            return firstLine.isEmpty ? "Run script" : "Run script: \(firstLine)"
        }
    }

    public static func wouldChange(_ action: Action, path: String) -> Bool {
        switch action.kind {
        case .setColorLabel:
            let target = (action.params["color"]?.stringValue ?? "").lowercased()
            return FinderTags.currentColorName(path) != target
        case .addTag:
            let existing = FinderTags.read(path)
            return paramTags(action).contains { !existing.contains($0) }
        case .removeTag:
            let existing = FinderTags.read(path)
            return paramTags(action).contains { existing.contains($0) }
        case .rename:
            let pattern = action.params["pattern"]?.stringValue ?? ""
            guard let newName = try? applyRenamePattern(pattern, path: path) else { return true }
            return (path as NSString).lastPathComponent != newName
        case .moveToFolder, .copyToFolder, .moveToTrash, .delete, .runScript:
            return true
        }
    }

    private static func paramTags(_ action: Action) -> [String] {
        if let tags = action.params["tags"]?.arrayValue {
            return tags.compactMap(\.stringValue)
        }
        if let tag = action.params["tag"]?.stringValue {
            return [tag]
        }
        return []
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
