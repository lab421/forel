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

// Central, declarative catalog of every feature the rule engine exposes:
// which condition kinds exist, which operators each one accepts, what kind of
// value it takes, and which actions exist with their parameters.
//
// This is the single source of truth. The rule editor UI reads it to build its
// pickers and value editors, and the engine references the same parameter keys
// — so adding a condition, operator, or action means editing this file (plus
// the matching `case` in `ConditionEvaluator`/`ActionExecutor`), instead of
// keeping several scattered lists in sync by hand. `RuleSchemaTests` enforces
// that the engine actually handles everything declared here.

import Foundation

// MARK: - Operators

public extension Operator {
    /// Human-readable label shown in the rule editor.
    var label: String {
        switch self {
        case .isTrue: return String(localized: "true", bundle: .forelStrings, comment: "Rule condition operator, as in “Name contains …”")
        case .isFalse: return String(localized: "false", bundle: .forelStrings, comment: "Rule condition operator, as in “Name contains …”")
        case .is: return String(localized: "is", bundle: .forelStrings, comment: "Rule condition operator, as in “Name contains …”")
        case .isNot: return String(localized: "is not", bundle: .forelStrings, comment: "Rule condition operator, as in “Name contains …”")
        case .contains: return String(localized: "contains", bundle: .forelStrings, comment: "Rule condition operator, as in “Name contains …”")
        case .doesNotContain: return String(localized: "does not contain", bundle: .forelStrings, comment: "Rule condition operator, as in “Name contains …”")
        case .startsWith: return String(localized: "starts with", bundle: .forelStrings, comment: "Rule condition operator, as in “Name contains …”")
        case .endsWith: return String(localized: "ends with", bundle: .forelStrings, comment: "Rule condition operator, as in “Name contains …”")
        case .matchesRegex: return String(localized: "matches regex", bundle: .forelStrings, comment: "Rule condition operator, as in “Name contains …”")
        case .greaterThan: return String(localized: "greater than", bundle: .forelStrings, comment: "Rule condition operator, as in “Name contains …”")
        case .lessThan: return String(localized: "less than", bundle: .forelStrings, comment: "Rule condition operator, as in “Name contains …”")
        case .before: return String(localized: "is before", bundle: .forelStrings, comment: "Rule condition operator, as in “Name contains …”")
        case .after: return String(localized: "is after", bundle: .forelStrings, comment: "Rule condition operator, as in “Name contains …”")
        case .olderThan: return String(localized: "is not in the last", bundle: .forelStrings, comment: "Rule condition operator, as in “Name contains …”")
        case .withinLast: return String(localized: "is within the last", bundle: .forelStrings, comment: "Rule condition operator, as in “Name contains …”")
        }
    }

    /// True for operators whose value is a relative duration ("7 days") rather
    /// than an absolute date.
    var usesRelativeDateValue: Bool {
        self == .olderThan || self == .withinLast
    }
}

// MARK: - Condition value kinds

/// The abstract shape of a condition's value. The UI maps each case to a
/// concrete editor; the `regex` and relative-date editors are selected from the
/// operator (see `RuleSchema.valueKind(for:operator:)`), everything else from
/// the condition kind.
public enum ConditionValueKind: Sendable, Equatable {
    /// The operator itself specifies the condition; no value editor is needed.
    case none
    case text
    case regex
    case size
    case absoluteDate
    case relativeDate
    case fileKind
    case colorLabel
    /// Free text combined with a suggestion list (e.g. installed apps) —
    /// still a plain string value underneath, just with autocomplete.
    case appPicker
}

// MARK: - Condition kinds

public extension ConditionKind {
    var label: String {
        switch self {
        case .name: return String(localized: "Name", bundle: .forelStrings, comment: "Rule condition: the file property it checks")
        case .comment: return String(localized: "Comment", bundle: .forelStrings, comment: "Rule condition: the file property it checks")
        case .locked: return String(localized: "Locked", bundle: .forelStrings, comment: "Rule condition: the file property it checks")
        case .extension_: return String(localized: "Extension", bundle: .forelStrings, comment: "Rule condition: the file property it checks")
        case .kind: return String(localized: "Kind", bundle: .forelStrings, comment: "Rule condition: the file property it checks")
        case .sizeBytes: return String(localized: "Size", bundle: .forelStrings, comment: "Rule condition: the file property it checks")
        case .tags: return String(localized: "Tags", bundle: .forelStrings, comment: "Rule condition: the file property it checks")
        case .colorLabel: return String(localized: "Color label", bundle: .forelStrings, comment: "Rule condition: the file property it checks")
        case .contents: return String(localized: "Contents", bundle: .forelStrings, comment: "Rule condition: the file property it checks")
        case .createdAt: return String(localized: "Date created", bundle: .forelStrings, comment: "Rule condition: the file property it checks")
        case .dateModified: return String(localized: "Date modified", bundle: .forelStrings, comment: "Rule condition: the file property it checks")
        case .dateAdded: return String(localized: "Date added", bundle: .forelStrings, comment: "Rule condition: the file property it checks")
        case .dateLastOpened: return String(localized: "Date last opened", bundle: .forelStrings, comment: "Rule condition: the file property it checks")
        case .downloadedFromWebsite: return String(localized: "Downloaded from website", bundle: .forelStrings, comment: "Rule condition: the file property it checks")
        case .downloadedWithApp: return String(localized: "Downloaded with app", bundle: .forelStrings, comment: "Rule condition: the file property it checks")
        case .rawWhereFromMetadata: return String(localized: "Raw where-from metadata", bundle: .forelStrings, comment: "Rule condition: the file property it checks")
        }
    }

    /// Operators offered for this condition, in display order. This is also the
    /// exact set the evaluator is expected to handle for the kind — enforced by
    /// `RuleSchemaTests`.
    var validOperators: [Operator] {
        switch self {
        case .locked:
            return [.isTrue, .isFalse]
        case .createdAt, .dateModified, .dateAdded, .dateLastOpened:
            return [.before, .after, .olderThan, .withinLast]
        case .sizeBytes:
            return [.is, .isNot, .greaterThan, .lessThan]
        case .kind, .colorLabel:
            return [.is, .isNot]
        case .name, .comment, .extension_, .tags, .contents,
             .downloadedFromWebsite, .rawWhereFromMetadata:
            return [.is, .isNot, .contains, .doesNotContain, .startsWith, .endsWith, .matchesRegex]
        case .downloadedWithApp:
            return [.is]
        }
    }

    var defaultOperator: Operator {
        validOperators.first ?? .is
    }

    /// Value editor used for this condition under a "plain" operator, before the
    /// operator-specific overrides for regex and relative dates.
    var baseValueKind: ConditionValueKind {
        switch self {
        case .locked: return .none
        case .kind: return .fileKind
        case .sizeBytes: return .size
        case .colorLabel: return .colorLabel
        case .createdAt, .dateModified, .dateAdded, .dateLastOpened: return .absoluteDate
        case .name, .comment, .extension_, .tags, .contents,
             .downloadedFromWebsite, .rawWhereFromMetadata: return .text
        case .downloadedWithApp: return .appPicker
        }
    }

    /// SF Symbol for the condition in the kind picker.
    var iconSystemName: String {
        switch self {
        case .name: return "doc"
        case .comment: return "text.bubble"
        case .locked: return "lock"
        case .extension_: return "puzzlepiece.extension"
        case .kind: return "doc.viewfinder"
        case .sizeBytes: return "externaldrive"
        case .tags: return "tag"
        case .colorLabel: return "paintpalette"
        case .contents: return "text.viewfinder"
        case .createdAt: return "calendar.badge.plus"
        case .dateModified: return "calendar.badge.clock"
        case .dateAdded: return "calendar.day.timeline.left"
        case .dateLastOpened: return "clock.arrow.circlepath"
        case .downloadedFromWebsite: return "globe"
        case .downloadedWithApp: return "macwindow"
        case .rawWhereFromMetadata: return "curlybraces"
        }
    }

    /// Short explanatory note shown as a hoverable info icon next to the row,
    /// for conditions whose behavior isn't obvious from the label alone.
    /// `nil` for everything that doesn't need one — most conditions don't.
    var helpText: String? {
        switch self {
        case .locked:
            return String(localized: "Matches the Locked checkbox in Finder's Get Info window, independently of read and write permissions.", bundle: .forelStrings, comment: "Help shown next to a rule condition")
        case .comment:
            return String(localized: "Matches the Finder comment shown in Get Info. Files without a comment are treated as having an empty comment.", bundle: .forelStrings, comment: "Help shown next to a rule condition")
        case .dateLastOpened:
            return String(localized: "Uses the last-opened date recorded by macOS, not the last filesystem access. Items without this date do not match.", bundle: .forelStrings, comment: "Help shown next to a rule condition")
        case .tags:
            return String(localized: "Matches the Finder tags shown in Get Info, not other file metadata.", bundle: .forelStrings, comment: "Help shown next to a rule condition")
        case .downloadedFromWebsite:
            return String(localized: "Matches only http and https addresses from the file's download metadata. For other sources, such as blob: addresses, use Raw where-from metadata.", bundle: .forelStrings, comment: "Help shown next to a rule condition")
        case .downloadedWithApp:
            return String(localized: "Matches the app that macOS recorded as having downloaded the file, such as Safari or Firefox. Availability depends on that app.", bundle: .forelStrings, comment: "Help shown next to a rule condition")
        case .rawWhereFromMetadata:
            return String(localized: "Matches every value of the file's download metadata, as Finder shows it in Get Info under Where from. Availability depends on the app that created the file.", bundle: .forelStrings, comment: "Help shown next to a rule condition")
        case .contents:
            return String(localized: "Matches text from plain files, PDFs, Word documents, and images via OCR when available.", bundle: .forelStrings, comment: "Help shown next to a rule condition")
        default:
            return nil
        }
    }
}

// MARK: - File kinds (for the `kind` condition)

public enum FileKindCatalog {
    /// `(value, folderName)` pairs in picker order. `value` matches the
    /// strings `ConditionEvaluator.detectKind` produces. `folderName` is what
    /// the `{kind}` destination token writes to disk: it stays in English
    /// whatever the app's language, so a rule keeps filing into the same
    /// folders when the language changes.
    public static let all: [(value: String, folderName: String)] = [
        ("image", "Image"),
        ("movie", "Movie"),
        ("music", "Music"),
        ("pdf", "PDF"),
        ("text", "Text"),
        ("document", "Document"),
        ("presentation", "Presentation"),
        ("archive", "Archive"),
        ("disk_image", "Disk Image"),
        ("folder", "Folder"),
        ("application", "Application"),
    ]

    /// The file kind's name in the picker, in the app's language.
    public static func label(for value: String) -> String {
        switch value {
        case "image": return String(localized: "Image", bundle: .forelStrings, comment: "File kind")
        case "movie": return String(localized: "Movie", bundle: .forelStrings, comment: "File kind")
        case "music": return String(localized: "Music", bundle: .forelStrings, comment: "File kind")
        case "pdf": return String(localized: "PDF", bundle: .forelStrings, comment: "File kind")
        case "text": return String(localized: "Text", bundle: .forelStrings, comment: "File kind")
        case "document": return String(localized: "Document", bundle: .forelStrings, comment: "File kind")
        case "presentation": return String(localized: "Presentation", bundle: .forelStrings, comment: "File kind")
        case "archive": return String(localized: "Archive", bundle: .forelStrings, comment: "File kind")
        case "disk_image": return String(localized: "Disk Image", bundle: .forelStrings, comment: "File kind")
        case "folder": return String(localized: "Folder", bundle: .forelStrings, comment: "File kind")
        case "application": return String(localized: "Application", bundle: .forelStrings, comment: "File kind")
        default: return value
        }
    }
}

// MARK: - Action parameters

/// Canonical parameter keys stored in an action's `params` JSON. Referenced by
/// both the editor and `ActionExecutor`, so the key exists in one place only.
public enum ActionParam {
    public static let destination = "destination"
    public static let onConflict = "on_conflict"
    public static let syncDeletePolicy = "sync_delete_policy"
    public static let pattern = "pattern"
    public static let archiveName = "archive_name"
    public static let deleteSourceAfterCompression = "delete_source_after_compression"
    public static let tags = "tags"
    public static let color = "color"
    public static let locked = "locked"
    public static let extensionHidden = "extension_hidden"
    public static let script = "script"
    public static let shortcutName = "shortcut_name"
    public static let shortcutInputMode = "shortcut_input_mode"
    public static let applicationPath = "application_path"
    public static let passFileToApplication = "pass_file_to_application"
    public static let cleanFileName = "clean_file_name"
    public static let libraryType = "library_type"
    public static let targetPlaylist = "target_playlist"
}

/// The abstract shape of an action parameter; the UI maps it to a concrete editor.
public enum ActionParamKind: Sendable, Equatable {
    case boolean
    case folderPath
    case renamePattern
    case archiveName
    case tags
    case colorLabel
    case script
    case shortcut
    case applicationPath
    case libraryType
    case playlist
}

public struct ActionParamSpec: Sendable, Equatable {
    public let key: String
    public let kind: ActionParamKind

    public init(key: String, kind: ActionParamKind) {
        self.key = key
        self.kind = kind
    }
}

// MARK: - Action kinds

public extension ActionKind {
    var label: String {
        switch self {
        case .moveToFolder: return String(localized: "Move to folder", bundle: .forelStrings, comment: "Rule action")
        case .copyToFolder: return String(localized: "Copy to folder", bundle: .forelStrings, comment: "Rule action")
        case .syncFolders: return String(localized: "Sync folders", bundle: .forelStrings, comment: "Rule action")
        case .rename: return String(localized: "Rename", bundle: .forelStrings, comment: "Rule action")
        case .moveToTrash: return String(localized: "Move to Trash", bundle: .forelStrings, comment: "Rule action")
        case .delete: return String(localized: "Delete", bundle: .forelStrings, comment: "Rule action")
        case .addTag: return String(localized: "Add tag", bundle: .forelStrings, comment: "Rule action")
        case .removeTag: return String(localized: "Remove tag", bundle: .forelStrings, comment: "Rule action")
        case .setColorLabel: return String(localized: "Set color label", bundle: .forelStrings, comment: "Rule action")
        case .toggleLock: return String(localized: "Toggle lock", bundle: .forelStrings, comment: "Rule action")
        case .toggleExtension: return String(localized: "Toggle extension", bundle: .forelStrings, comment: "Rule action")
        case .runScript: return String(localized: "Run script", bundle: .forelStrings, comment: "Rule action")
        case .runShortcut: return String(localized: "Run shortcut", bundle: .forelStrings, comment: "Rule action")
        case .openApplication: return String(localized: "Open application", bundle: .forelStrings, comment: "Rule action")
        case .importToLibrary: return String(localized: "Import to library", bundle: .forelStrings, comment: "Rule action")
        case .compress: return String(localized: "Compress", bundle: .forelStrings, comment: "Rule action")
        case .uncompress: return String(localized: "Uncompress", bundle: .forelStrings, comment: "Rule action")
        }
    }

    /// SF Symbol used to represent the action in the UI (e.g. activity history).
    var iconSystemName: String {
        switch self {
        case .moveToFolder: return "arrow.right.doc.on.clipboard"
        case .copyToFolder: return "doc.on.doc"
        case .syncFolders: return "arrow.triangle.2.circlepath"
        case .rename: return "pencil"
        case .moveToTrash, .delete: return "trash"
        case .addTag, .removeTag: return "tag"
        case .setColorLabel: return "paintpalette"
        case .toggleLock: return "lock"
        case .toggleExtension: return "doc.badge.ellipsis"
        case .runScript: return "terminal"
        case .runShortcut: return "square.stack.3d.up"
        case .openApplication: return "app"
        case .importToLibrary: return "tray.full"
        case .compress: return "archivebox"
        case .uncompress: return "doc.zipper"
        }
    }

    /// Whether this action kind has an "Options" popover in the rule editor
    /// (e.g. Move/Copy to Folder's conflict resolution, Run Shortcut's input
    /// mode) — used to hide the options button entirely for actions that
    /// have none, instead of showing an empty "No options" popover.
    var hasOptions: Bool {
        switch self {
        case .moveToFolder, .copyToFolder, .syncFolders, .runShortcut, .openApplication, .rename, .importToLibrary, .uncompress, .compress:
            return true
        case .addTag, .removeTag, .setColorLabel, .toggleLock, .toggleExtension, .runScript, .moveToTrash, .delete:
            return false
        }
    }

    /// Parameters this action reads from its `params` JSON. Empty for actions
    /// that take none (trash/delete).
    var params: [ActionParamSpec] {
        switch self {
        case .moveToFolder, .copyToFolder, .syncFolders:
            return [ActionParamSpec(key: ActionParam.destination, kind: .folderPath)]
        case .rename:
            return [ActionParamSpec(key: ActionParam.pattern, kind: .renamePattern)]
        case .addTag, .removeTag:
            return [ActionParamSpec(key: ActionParam.tags, kind: .tags)]
        case .setColorLabel:
            return [ActionParamSpec(key: ActionParam.color, kind: .colorLabel)]
        case .toggleLock:
            return [ActionParamSpec(key: ActionParam.locked, kind: .boolean)]
        case .toggleExtension:
            return [ActionParamSpec(key: ActionParam.extensionHidden, kind: .boolean)]
        case .runScript:
            return [ActionParamSpec(key: ActionParam.script, kind: .script)]
        case .runShortcut:
            return [ActionParamSpec(key: ActionParam.shortcutName, kind: .shortcut)]
        case .openApplication:
            return [ActionParamSpec(key: ActionParam.applicationPath, kind: .applicationPath)]
        case .importToLibrary:
            return [ActionParamSpec(key: ActionParam.libraryType, kind: .libraryType),
                    ActionParamSpec(key: ActionParam.targetPlaylist, kind: .playlist)]
        case .compress:
            return [ActionParamSpec(key: ActionParam.archiveName, kind: .archiveName),
                    ActionParamSpec(key: ActionParam.destination, kind: .folderPath)]
        case .moveToTrash, .delete, .uncompress:
            return []
        }
    }
}

// MARK: - Catalog entry points

/// A labeled group of condition kinds, for rendering the kind picker as
/// sections (e.g. a "Metadata" group) instead of one flat list.
public struct ConditionKindGroup: Sendable {
    /// `nil` for the default, unlabeled group.
    public let title: String?
    public let kinds: [ConditionKind]

    public init(title: String?, kinds: [ConditionKind]) {
        self.title = title
        self.kinds = kinds
    }
}

/// Same as `ConditionKindGroup` but for action kinds.
public struct ActionKindGroup: Sendable {
    public let title: String?
    public let kinds: [ActionKind]

    public init(title: String?, kinds: [ActionKind]) {
        self.title = title
        self.kinds = kinds
    }
}

/// Convenience lists, in display order, for building UI pickers.
public enum RuleSchema {
    public static let conditionKindGroups: [ConditionKindGroup] = [
        ConditionKindGroup(title: nil, kinds: [
            .name, .extension_, .kind, .sizeBytes, .tags, .colorLabel, .locked, .contents,
            .createdAt, .dateModified, .dateAdded, .dateLastOpened,
        ]),
        ConditionKindGroup(title: String(localized: "Metadata", bundle: .forelStrings, comment: "Section of the condition picker"), kinds: [
            .comment, .downloadedFromWebsite, .downloadedWithApp,
        ]),
    ]

    public static let conditionKinds: [ConditionKind] = conditionKindGroups.flatMap(\.kinds)

    public static let actionKindGroups: [ActionKindGroup] = [
        ActionKindGroup(title: nil, kinds: [.moveToFolder, .copyToFolder, .syncFolders, .rename, .compress, .uncompress]),
        ActionKindGroup(title: String(localized: "Tags", bundle: .forelStrings, comment: "Section of the action picker"), kinds: [.addTag, .removeTag, .setColorLabel]),
        ActionKindGroup(title: String(localized: "Finder", bundle: .forelStrings, comment: "Section of the action picker"), kinds: [.toggleLock, .toggleExtension]),
        ActionKindGroup(title: String(localized: "Automation", bundle: .forelStrings, comment: "Section of the action picker"), kinds: [.runScript, .runShortcut, .openApplication]),
        ActionKindGroup(title: String(localized: "Disposal", bundle: .forelStrings, comment: "Section of the action picker"), kinds: [.moveToTrash, .delete]),
        ActionKindGroup(title: String(localized: "Library", bundle: .forelStrings, comment: "Section of the action picker"), kinds: [.importToLibrary]),
    ]

    public static let actionKinds: [ActionKind] = actionKindGroups.flatMap(\.kinds)

    /// Resolves the value editor for a condition, combining the kind's base
    /// value kind with operator-specific overrides (regex / relative date).
    public static func valueKind(for kind: ConditionKind, operator op: Operator) -> ConditionValueKind {
        if op == .matchesRegex { return .regex }
        if kind.baseValueKind == .absoluteDate && op.usesRelativeDateValue { return .relativeDate }
        return kind.baseValueKind
    }
}
