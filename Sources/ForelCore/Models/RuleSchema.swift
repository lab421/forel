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
        case .is: return "is"
        case .isNot: return "is not"
        case .contains: return "contains"
        case .doesNotContain: return "does not contain"
        case .startsWith: return "starts with"
        case .endsWith: return "ends with"
        case .matchesRegex: return "matches regex"
        case .greaterThan: return "greater than"
        case .lessThan: return "less than"
        case .before: return "is before"
        case .after: return "is after"
        case .olderThan: return "is older than"
        case .withinLast: return "is within the last"
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
        case .name: return "Name"
        case .extension_: return "Extension"
        case .kind: return "Kind"
        case .sizeBytes: return "Size"
        case .tags: return "Tags"
        case .colorLabel: return "Color label"
        case .contents: return "Contents"
        case .createdAt: return "Date created"
        case .dateModified: return "Date modified"
        case .dateAdded: return "Date added"
        case .downloadedFromWebsite: return "Downloaded from website"
        case .downloadedWithApp: return "Downloaded with app"
        case .rawWhereFromMetadata: return "Raw where-from metadata"
        }
    }

    /// Operators offered for this condition, in display order. This is also the
    /// exact set the evaluator is expected to handle for the kind — enforced by
    /// `RuleSchemaTests`.
    var validOperators: [Operator] {
        switch self {
        case .createdAt, .dateModified, .dateAdded:
            return [.before, .after, .olderThan, .withinLast]
        case .sizeBytes:
            return [.is, .isNot, .greaterThan, .lessThan]
        case .kind, .colorLabel:
            return [.is, .isNot]
        case .name, .extension_, .tags, .contents,
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
        case .kind: return .fileKind
        case .sizeBytes: return .size
        case .colorLabel: return .colorLabel
        case .createdAt, .dateModified, .dateAdded: return .absoluteDate
        case .name, .extension_, .tags, .contents,
             .downloadedFromWebsite, .rawWhereFromMetadata: return .text
        case .downloadedWithApp: return .appPicker
        }
    }

    /// Short explanatory note shown as a hoverable info icon next to the row,
    /// for conditions whose behavior isn't obvious from the label alone.
    /// `nil` for everything that doesn't need one — most conditions don't.
    var helpText: String? {
        switch self {
        case .downloadedFromWebsite, .downloadedWithApp, .rawWhereFromMetadata:
            return "Uses macOS download metadata. Availability depends on the app that created the file."
        case .contents:
            return "Matches text from plain files, PDFs, Word documents, and images via OCR when available."
        default:
            return nil
        }
    }
}

// MARK: - File kinds (for the `kind` condition)

public enum FileKindCatalog {
    /// `(value, label)` pairs for the file-kind picker. `value` matches the
    /// strings `ConditionEvaluator.detectKind` produces.
    public static let all: [(value: String, label: String)] = [
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
}

// MARK: - Action parameters

/// Canonical parameter keys stored in an action's `params` JSON. Referenced by
/// both the editor and `ActionExecutor`, so the key exists in one place only.
public enum ActionParam {
    public static let destination = "destination"
    public static let onConflict = "on_conflict"
    public static let pattern = "pattern"
    public static let tags = "tags"
    public static let color = "color"
    public static let script = "script"
    public static let shortcutName = "shortcut_name"
    public static let shortcutInputMode = "shortcut_input_mode"
    public static let cleanFileName = "clean_file_name"
}

/// The abstract shape of an action parameter; the UI maps it to a concrete editor.
public enum ActionParamKind: Sendable, Equatable {
    case folderPath
    case renamePattern
    case tags
    case colorLabel
    case script
    case shortcut
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
        case .moveToFolder: return "Move to folder"
        case .copyToFolder: return "Copy to folder"
        case .rename: return "Rename"
        case .moveToTrash: return "Move to Trash"
        case .delete: return "Delete"
        case .addTag: return "Add tag"
        case .removeTag: return "Remove tag"
        case .setColorLabel: return "Set color label"
        case .runScript: return "Run script"
        case .runShortcut: return "Run shortcut"
        }
    }

    /// SF Symbol used to represent the action in the UI (e.g. activity history).
    var iconSystemName: String {
        switch self {
        case .moveToFolder: return "arrow.right.doc.on.clipboard"
        case .copyToFolder: return "doc.on.doc"
        case .rename: return "pencil"
        case .moveToTrash, .delete: return "trash"
        case .addTag, .removeTag: return "tag"
        case .setColorLabel: return "paintpalette"
        case .runScript: return "terminal"
        case .runShortcut: return "square.stack.3d.up"
        }
    }

    /// Whether this action kind has an "Options" popover in the rule editor
    /// (e.g. Move/Copy to Folder's conflict resolution, Run Shortcut's input
    /// mode) — used to hide the options button entirely for actions that
    /// have none, instead of showing an empty "No options" popover.
    var hasOptions: Bool {
        switch self {
        case .moveToFolder, .copyToFolder, .runShortcut, .rename:
            return true
        case .addTag, .removeTag, .setColorLabel, .runScript, .moveToTrash, .delete:
            return false
        }
    }

    /// Parameters this action reads from its `params` JSON. Empty for actions
    /// that take none (trash/delete).
    var params: [ActionParamSpec] {
        switch self {
        case .moveToFolder, .copyToFolder:
            return [ActionParamSpec(key: ActionParam.destination, kind: .folderPath)]
        case .rename:
            return [ActionParamSpec(key: ActionParam.pattern, kind: .renamePattern)]
        case .addTag, .removeTag:
            return [ActionParamSpec(key: ActionParam.tags, kind: .tags)]
        case .setColorLabel:
            return [ActionParamSpec(key: ActionParam.color, kind: .colorLabel)]
        case .runScript:
            return [ActionParamSpec(key: ActionParam.script, kind: .script)]
        case .runShortcut:
            return [ActionParamSpec(key: ActionParam.shortcutName, kind: .shortcut)]
        case .moveToTrash, .delete:
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

/// Convenience lists, in display order, for building UI pickers.
public enum RuleSchema {
    public static let conditionKindGroups: [ConditionKindGroup] = [
        ConditionKindGroup(title: nil, kinds: [
            .name, .extension_, .kind, .sizeBytes, .tags, .colorLabel, .contents,
            .createdAt, .dateModified, .dateAdded,
        ]),
        ConditionKindGroup(title: "Metadata", kinds: [
            .downloadedFromWebsite, .downloadedWithApp,
        ]),
    ]

    public static let conditionKinds: [ConditionKind] = conditionKindGroups.flatMap(\.kinds)

    public static let actionKinds: [ActionKind] = [
        .moveToFolder, .copyToFolder, .rename, .moveToTrash, .delete,
        .addTag, .removeTag, .setColorLabel, .runScript, .runShortcut,
    ]

    /// Resolves the value editor for a condition, combining the kind's base
    /// value kind with operator-specific overrides (regex / relative date).
    public static func valueKind(for kind: ConditionKind, operator op: Operator) -> ConditionValueKind {
        if op == .matchesRegex { return .regex }
        if kind.baseValueKind == .absoluteDate && op.usesRelativeDateValue { return .relativeDate }
        return kind.baseValueKind
    }
}
