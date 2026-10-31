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
        case .didChange: return "did change"
        case .didNotChange: return "did not change"
        case .is: return "is"
        case .isNot: return "is not"
        case .contains: return "contains"
        case .containsInsensitive: return "contains (ignore case and accents)"
        case .doesNotContain: return "does not contain"
        case .isBlank: return "is blank"
        case .isNotBlank: return "is not blank"
        case .startsWith: return "starts with"
        case .endsWith: return "ends with"
        case .matchesRegex: return "matches regex"
        case .greaterThan: return "greater than"
        case .lessThan: return "less than"
        case .before: return "is before"
        case .beforeToday: return "is before today"
        case .beforeThisWeek: return "is before this week"
        case .beforeThisMonth: return "is before this month"
        case .notThisWeek: return "is not this week"
        case .notThisMonth: return "is not this month"
        case .afterLastModified: return "is after date modified"
        case .beforeLastModified: return "is before date modified"
        case .after: return "is after"
        case .olderThan: return "is not in the last"
        case .withinLast: return "is within the last"
        case .hazelWithinLast: return "is within the last (Hazel)"
        case .hazelNotWithinLast: return "is not within the last (Hazel)"
        }
    }

    /// True for operators whose value is a relative duration ("7 days") rather
    /// than an absolute date.
    var usesRelativeDateValue: Bool {
        self == .olderThan || self == .withinLast || self == .hazelWithinLast || self == .hazelNotWithinLast
    }
}

// MARK: - Condition value kinds

/// The abstract shape of a condition's value. The UI maps each case to a
/// concrete editor; the `regex` and relative-date editors are selected from the
/// operator (see `RuleSchema.valueKind(for:operator:)`), everything else from
/// the condition kind.
public enum ConditionValueKind: Sendable, Equatable {
    case noValue
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
        case .anyFile: return "Any file or folder"
        case .nameInsensitive: return "Name (ignore case and accents)"
        case .fullName: return "Full filename"
        case .fullNameInsensitive: return "Full filename (ignore case and accents)"
        case .locked: return "Locked"
        case .subfileCount: return "Sub-file/folder count"
        case .conditionGroup: return "Nested conditions"
        case .spotlightAttribute: return "Spotlight attribute"
        case .scriptAttribute: return "Rule attribute"
        case .customTableMatch: return "Custom list or table match"
        case .customDateMatch: return "Custom date match"
        case .customTextMatch: return "Custom text match"
        case .dateComparison: return "Date comparison"
        case .peerRanking: return "Rank among peers"
        case .currentTime: return "Current time"
        case .hazelScriptCondition: return "Script condition"
        case .extension_: return "Extension"
        case .extensionInsensitive: return "Extension (ignore case and accents)"
        case .kind: return "Kind"
        case .contentType: return "Content type"
        case .sizeBytes: return "Size"
        case .subfolderDepth: return "Subfolder depth"
        case .tags: return "Tags"
        case .colorLabel: return "Color label"
        case .finderComment: return "Finder comment"
        case .contents: return "Contents"
        case .contentsWithoutOCR: return "Contents (without text recognition)"
        case .contentsWithOCR: return "Contents (force text recognition)"
        case .contentsWithPassword: return "PDF contents (Keychain password)"
        case .createdAt: return "Date created"
        case .dateModified: return "Date modified"
        case .dateAdded: return "Date added"
        case .dateLastOpened: return "Date last opened"
        case .dateLastMatched: return "Date last matched"
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
            return [.before, .beforeToday, .beforeThisWeek, .beforeThisMonth, .notThisWeek, .notThisMonth, .after, .olderThan, .withinLast, .hazelWithinLast, .hazelNotWithinLast, .didChange, .didNotChange]
        case .dateLastOpened:
            return [.before, .beforeToday, .beforeThisWeek, .beforeThisMonth, .notThisWeek, .notThisMonth, .after, .olderThan, .withinLast, .hazelWithinLast, .hazelNotWithinLast, .afterLastModified]
        case .dateLastMatched:
            return [.isBlank, .isNotBlank, .before, .beforeToday, .beforeThisWeek, .beforeThisMonth, .notThisWeek, .notThisMonth, .after, .olderThan, .withinLast, .hazelWithinLast, .hazelNotWithinLast, .beforeLastModified]
        case .sizeBytes:
            return [.is, .isNot, .greaterThan, .lessThan, .didChange, .didNotChange]
        case .subfolderDepth, .subfileCount:
            return [.is, .isNot, .greaterThan, .lessThan]
        case .conditionGroup, .customTableMatch, .customDateMatch, .customTextMatch, .dateComparison, .currentTime, .hazelScriptCondition, .anyFile: return [.is]
        case .spotlightAttribute, .scriptAttribute: return [.is, .isNot, .contains, .containsInsensitive, .doesNotContain, .startsWith, .endsWith, .greaterThan, .lessThan]
        case .kind, .contentType, .colorLabel, .extensionInsensitive, .locked, .peerRanking:
            return [.is, .isNot]
        case .nameInsensitive, .fullNameInsensitive:
            return [.is, .isNot, .contains, .doesNotContain, .startsWith, .endsWith, .didChange, .didNotChange]
        case .contents, .contentsWithoutOCR, .contentsWithOCR, .contentsWithPassword:
            return [.is, .isNot, .contains, .containsInsensitive, .doesNotContain, .startsWith, .endsWith, .matchesRegex, .isBlank, .isNotBlank]
        case .finderComment:
            return [.is, .isNot, .contains, .containsInsensitive, .doesNotContain, .startsWith, .endsWith, .matchesRegex, .isBlank, .isNotBlank, .didChange, .didNotChange]
        case .name, .fullName, .extension_:
            return [.is, .isNot, .contains, .doesNotContain, .startsWith, .endsWith, .matchesRegex, .didChange, .didNotChange]
        case .tags,
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
        case .anyFile: return .noValue
        case .kind: return .fileKind
        case .sizeBytes: return .size
        case .colorLabel: return .colorLabel
        case .createdAt, .dateModified, .dateAdded, .dateLastOpened, .dateLastMatched: return .absoluteDate
        case .name, .nameInsensitive, .fullName, .fullNameInsensitive, .locked, .subfileCount, .conditionGroup, .spotlightAttribute, .scriptAttribute, .customTableMatch, .customDateMatch, .customTextMatch, .dateComparison, .peerRanking, .currentTime, .hazelScriptCondition, .extension_, .extensionInsensitive, .contentType, .tags, .contents, .contentsWithoutOCR, .contentsWithOCR, .contentsWithPassword, .finderComment, .subfolderDepth,
             .downloadedFromWebsite, .rawWhereFromMetadata: return .text
        case .downloadedWithApp: return .appPicker
        }
    }

    /// SF Symbol for the condition in the kind picker.
    var iconSystemName: String {
        switch self {
        case .name: return "doc"
        case .anyFile: return "doc.on.doc"
        case .nameInsensitive: return "doc"
        case .fullName: return "doc.text"
        case .fullNameInsensitive: return "doc.text"
        case .locked: return "lock"
        case .subfileCount: return "number"
        case .conditionGroup: return "list.bullet.indent"
        case .spotlightAttribute: return "magnifyingglass"
        case .scriptAttribute: return "curlybraces"
        case .customTableMatch: return "tablecells"
        case .customDateMatch: return "calendar"
        case .customTextMatch: return "textformat"
        case .dateComparison: return "calendar.badge.clock"
        case .peerRanking: return "list.number"
        case .currentTime: return "clock"
        case .hazelScriptCondition: return "terminal"
        case .extension_, .extensionInsensitive: return "puzzlepiece.extension"
        case .kind: return "doc.viewfinder"
        case .contentType: return "doc.viewfinder"
        case .sizeBytes: return "externaldrive"
        case .subfolderDepth: return "folder"
        case .tags: return "tag"
        case .colorLabel: return "paintpalette"
        case .finderComment: return "text.bubble"
        case .contents: return "text.viewfinder"
        case .contentsWithoutOCR: return "doc.text.viewfinder"
        case .contentsWithOCR: return "doc.text.viewfinder"
        case .contentsWithPassword: return "lock.doc"
        case .createdAt: return "calendar.badge.plus"
        case .dateModified: return "calendar.badge.clock"
        case .dateAdded: return "calendar.day.timeline.left"
        case .dateLastOpened: return "calendar.badge.clock"
        case .dateLastMatched: return "calendar.badge.checkmark"
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
        case .downloadedFromWebsite, .downloadedWithApp, .rawWhereFromMetadata:
            return "Uses macOS download metadata. Availability depends on the app that created the file."
        case .contents:
            return "Matches text from plain files, PDFs, Word documents, and images via OCR when available."
        case .contentsWithoutOCR:
            return "Matches intrinsic text without running text recognition on images or scanned PDFs."
        case .contentsWithOCR:
            return "Runs text recognition on PDF pages even if they already contain a text layer."
        case .contentsWithPassword:
            return "Reads a PDF using a generic password stored in Keychain. The password is not stored in the rule."
        case .dateLastOpened:
            return "Uses macOS last-opened metadata. If no date is available, the file is treated as never opened."
        case .dateLastMatched:
            return "Uses this rule’s most recent match for the item."
        case .subfolderDepth:
            return "Items directly inside the watched folder have depth 0; each subfolder adds one level."
        case .currentTime:
            return "Matches during the specified local clock minute and selected calendar days."
        case .hazelScriptCondition:
            return "This script runs while evaluating the condition, including in Dry Run previews."
        case .spotlightAttribute:
            return "Uses the selected Spotlight metadata key. Unavailable values do not match."
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
    public static let discardDuplicates = "discard_duplicates"
    public static let skipDuplicates = "skip_duplicates"
    public static let folderStructure = "folder_structure"
    public static let pattern = "pattern"
    public static let tags = "tags"
    public static let color = "color"
    public static let script = "script"
    public static let shell = "shell"
    public static let shellMode = "shell_mode"
    public static let shellPath = "shell_path"
    public static let shellBookmark = "shell_bookmark"
    public static let osaLanguage = "osa_language"
    public static let osaMode = "osa_mode"
    public static let osaPath = "osa_path"
    public static let osaInputs = "osa_inputs"
    public static let osaOutputs = "osa_outputs"
    public static let workflowPath = "workflow_path"
    public static let enabled = "enabled"
    public static let comment = "comment"
    public static let includeExistingComment = "include_existing_comment"
    public static let compiledAppleScript = "compiled_applescript"
    public static let shortcutName = "shortcut_name"
    public static let shortcutInputMode = "shortcut_input_mode"
    public static let applicationPath = "application_path"
    public static let passFileToApplication = "pass_file_to_application"
    public static let bringToFront = "bring_to_front"
    public static let durationSeconds = "duration_seconds"
    public static let notificationText = "notification_text"
    public static let notificationSound = "notification_sound"
    public static let cleanFileName = "clean_file_name"
    public static let libraryType = "library_type"
    public static let targetPlaylist = "target_playlist"
}

/// The abstract shape of an action parameter; the UI maps it to a concrete editor.
public enum ActionParamKind: Sendable, Equatable {
    case folderPath
    case renamePattern
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
        case .moveToFolder: return "Move to folder"
        case .copyToFolder: return "Copy to folder"
        case .syncToFolder: return "Sync to folder"
        case .importError: return "Import error"
        case .rename: return "Rename"
        case .moveToTrash: return "Move to Trash"
        case .delete: return "Delete"
        case .addTag: return "Add tag"
        case .removeTag: return "Remove tag"
        case .setColorLabel: return "Set color label"
        case .setFinderLabel: return "Set Finder color label"
        case .setLocked: return "Set lock"
        case .setExtensionHidden: return "Set extension visibility"
        case .setFinderComment: return "Set Finder comment"
        case .runScript: return "Run script"
        case .runHazelShellScript: return "Run imported shell script"
        case .runHazelAppleScript: return "Run imported AppleScript"
        case .runHazelOSA: return "Run AppleScript or JavaScript"
        case .runWorkflow: return "Run Automator workflow"
        case .upload: return "Upload"
        case .hazelContinue: return "Continue matching rules"
        case .hazelRecurse: return "Run rules on folder contents"
        case .runShortcut: return "Run shortcut"
        case .openApplication: return "Open application"
        case .openDefault: return "Open with default application"
        case .importToLibrary: return "Import to library"
        case .uncompress: return "Uncompress"
        case .archive: return "Archive"
        case .showInFinder: return "Show in Finder"
        case .makeAlias: return "Make alias"
        case .pause: return "Pause"
        case .ignore: return "Ignore"
        case .displayNotification: return "Display notification"
        }
    }

    /// SF Symbol used to represent the action in the UI (e.g. activity history).
    var iconSystemName: String {
        switch self {
        case .moveToFolder: return "arrow.right.doc.on.clipboard"
        case .copyToFolder: return "doc.on.doc"
        case .syncToFolder: return "arrow.triangle.2.circlepath"
        case .importError: return "exclamationmark.triangle"
        case .rename: return "pencil"
        case .moveToTrash, .delete: return "trash"
        case .addTag, .removeTag: return "tag"
        case .setColorLabel: return "paintpalette"
        case .setFinderLabel: return "paintpalette"
        case .setLocked: return "lock"
        case .setExtensionHidden: return "eye"
        case .setFinderComment: return "text.bubble"
        case .runScript: return "terminal"
        case .runHazelShellScript: return "terminal"
        case .runHazelAppleScript: return "applescript"
        case .runHazelOSA: return "applescript"
        case .runWorkflow: return "gearshape.2"
        case .upload: return "icloud.and.arrow.up"
        case .hazelContinue: return "arrow.right"
        case .hazelRecurse: return "folder"
        case .runShortcut: return "square.stack.3d.up"
        case .openApplication: return "app"
        case .openDefault: return "app"
        case .importToLibrary: return "tray.full"
        case .uncompress: return "doc.zipper"
        case .archive: return "doc.zipper"
        case .showInFinder: return "finder"
        case .makeAlias: return "arrow.turn.up.right"
        case .pause: return "pause"
        case .ignore: return "hand.raised"
        case .displayNotification: return "bell"
        }
    }

    /// Whether this action kind has an "Options" popover in the rule editor
    /// (e.g. Move/Copy to Folder's conflict resolution, Run Shortcut's input
    /// mode) — used to hide the options button entirely for actions that
    /// have none, instead of showing an empty "No options" popover.
    var hasOptions: Bool {
        switch self {
        case .moveToFolder, .copyToFolder, .runShortcut, .openApplication, .openDefault, .rename, .importToLibrary, .uncompress, .showInFinder, .upload:
            return true
        case .addTag, .removeTag, .setColorLabel, .setFinderLabel, .setLocked, .setExtensionHidden, .setFinderComment, .runScript, .runHazelShellScript, .runHazelAppleScript, .runHazelOSA, .runWorkflow, .hazelContinue, .hazelRecurse, .moveToTrash, .delete, .syncToFolder, .importError, .archive, .makeAlias, .pause, .ignore, .displayNotification:
            return false
        }
    }

    /// Parameters this action reads from its `params` JSON. Empty for actions
    /// that take none (trash/delete).
    var params: [ActionParamSpec] {
        switch self {
        case .moveToFolder, .copyToFolder, .syncToFolder, .makeAlias:
            return [ActionParamSpec(key: ActionParam.destination, kind: .folderPath)]
        case .rename:
            return [ActionParamSpec(key: ActionParam.pattern, kind: .renamePattern)]
        case .addTag, .removeTag:
            return [ActionParamSpec(key: ActionParam.tags, kind: .tags)]
        case .setColorLabel, .setFinderLabel:
            return [ActionParamSpec(key: ActionParam.color, kind: .colorLabel)]
        case .runScript:
            return [ActionParamSpec(key: ActionParam.script, kind: .script)]
        case .runHazelShellScript:
            return [ActionParamSpec(key: ActionParam.script, kind: .script)]
        case .runShortcut:
            return [ActionParamSpec(key: ActionParam.shortcutName, kind: .shortcut)]
        case .openApplication:
            return [ActionParamSpec(key: ActionParam.applicationPath, kind: .applicationPath)]
        case .importToLibrary:
            return [ActionParamSpec(key: ActionParam.libraryType, kind: .libraryType),
                    ActionParamSpec(key: ActionParam.targetPlaylist, kind: .playlist)]
        case .moveToTrash, .delete, .uncompress, .importError, .runHazelAppleScript, .runHazelOSA, .runWorkflow, .upload, .hazelContinue, .hazelRecurse, .setLocked, .setExtensionHidden, .setFinderComment, .archive, .openDefault, .showInFinder, .pause, .ignore, .displayNotification:
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
            .anyFile, .name, .nameInsensitive, .fullName, .fullNameInsensitive, .extension_, .extensionInsensitive, .kind, .sizeBytes, .subfolderDepth, .subfileCount, .locked, .conditionGroup, .tags, .colorLabel, .contents, .contentsWithoutOCR, .contentsWithOCR, .contentsWithPassword,
            .createdAt, .dateModified, .dateAdded, .dateLastOpened, .dateLastMatched, .finderComment,
        ]),
        ConditionKindGroup(title: "Metadata", kinds: [
            .downloadedFromWebsite, .downloadedWithApp, .contentType, .spotlightAttribute, .scriptAttribute, .customTableMatch, .customDateMatch, .customTextMatch, .dateComparison, .peerRanking, .currentTime, .hazelScriptCondition,
        ]),
    ]

    public static let conditionKinds: [ConditionKind] = conditionKindGroups.flatMap(\.kinds)

    public static let actionKindGroups: [ActionKindGroup] = [
        ActionKindGroup(title: nil, kinds: [.moveToFolder, .copyToFolder, .syncToFolder, .rename, .archive, .uncompress, .makeAlias]),
        ActionKindGroup(title: "Tags", kinds: [.addTag, .removeTag, .setColorLabel, .setFinderComment, .setLocked, .setExtensionHidden]),
        ActionKindGroup(title: "Automation", kinds: [.upload, .runScript, .runHazelShellScript, .runHazelOSA, .runWorkflow, .runShortcut, .openApplication, .openDefault, .showInFinder, .pause, .ignore, .displayNotification]),
        ActionKindGroup(title: "Rule flow", kinds: [.hazelContinue, .hazelRecurse]),
        ActionKindGroup(title: "Disposal", kinds: [.moveToTrash, .delete]),
        ActionKindGroup(title: "Library", kinds: [.importToLibrary]),
    ]

    public static let actionKinds: [ActionKind] = actionKindGroups.flatMap(\.kinds)

    /// Resolves the value editor for a condition, combining the kind's base
    /// value kind with operator-specific overrides (regex / relative date).
    public static func valueKind(for kind: ConditionKind, operator op: Operator) -> ConditionValueKind {
        if op == .didChange || op == .didNotChange { return .noValue }
        if [.beforeToday, .beforeThisWeek, .beforeThisMonth, .notThisWeek, .notThisMonth, .afterLastModified, .beforeLastModified, .isBlank, .isNotBlank].contains(op) { return .noValue }
        if op == .matchesRegex { return .regex }
        if kind.baseValueKind == .absoluteDate && op.usesRelativeDateValue { return .relativeDate }
        return kind.baseValueKind
    }
}
