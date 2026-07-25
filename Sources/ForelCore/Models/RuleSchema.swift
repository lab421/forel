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
    case number
    case spotlightMetadata
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
        case .finderComment: return "Finder comment"
        case .filePath: return "File path"
        case .itemCount: return "Number of items"
        case .lastOpened: return "Last opened"
        case .imageWidth: return "Image width"
        case .imageHeight: return "Image height"
        case .photoDateTaken: return "Photo date taken"
        case .pdfPageCount: return "PDF page count"
        case .spotlightMetadata: return "Spotlight metadata"
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
        case .createdAt, .dateModified, .dateAdded, .lastOpened, .photoDateTaken:
            return [.before, .after, .olderThan, .withinLast]
        case .sizeBytes, .itemCount, .imageWidth, .imageHeight, .pdfPageCount:
            return [.is, .isNot, .greaterThan, .lessThan]
        case .kind, .colorLabel:
            return [.is, .isNot]
        case .name, .extension_, .tags, .contents, .finderComment, .filePath, .spotlightMetadata,
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
        case .itemCount, .imageWidth, .imageHeight, .pdfPageCount: return .number
        case .colorLabel: return .colorLabel
        case .createdAt, .dateModified, .dateAdded, .lastOpened, .photoDateTaken: return .absoluteDate
        case .spotlightMetadata: return .spotlightMetadata
        case .name, .extension_, .tags, .contents, .finderComment, .filePath,
             .downloadedFromWebsite, .rawWhereFromMetadata: return .text
        case .downloadedWithApp: return .appPicker
        }
    }

    /// SF Symbol for the condition in the kind picker.
    var iconSystemName: String {
        switch self {
        case .name: return "doc"
        case .extension_: return "puzzlepiece.extension"
        case .kind: return "doc.viewfinder"
        case .sizeBytes: return "externaldrive"
        case .tags: return "tag"
        case .colorLabel: return "paintpalette"
        case .contents: return "text.viewfinder"
        case .createdAt: return "calendar.badge.plus"
        case .dateModified: return "calendar.badge.clock"
        case .dateAdded: return "calendar.day.timeline.left"
        case .finderComment: return "text.bubble"
        case .filePath: return "point.topleft.down.curvedto.point.bottomright.up"
        case .itemCount: return "folder.badge.plus"
        case .lastOpened: return "clock.arrow.circlepath"
        case .imageWidth, .imageHeight: return "aspectratio"
        case .photoDateTaken: return "camera"
        case .pdfPageCount: return "doc.richtext"
        case .spotlightMetadata: return "magnifyingglass"
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
        case .spotlightMetadata:
            return "Enter a Spotlight key (for example kMDItemAuthors) and the value to match. Availability depends on macOS indexing."
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
    public static let applicationPath = "application_path"
    public static let passFileToApplication = "pass_file_to_application"
    public static let cleanFileName = "clean_file_name"
    public static let libraryType = "library_type"
    public static let targetPlaylist = "target_playlist"
    public static let pauseSeconds = "pause_seconds"
    public static let subfolder = "subfolder"
    public static let uploadURL = "upload_url"
    public static let comment = "comment"
    public static let aliasDestination = "alias_destination"
    public static let workflowPath = "workflow_path"
    public static let notificationTitle = "notification_title"
    public static let notificationBody = "notification_body"
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
    case duration
    case text
    case filePath
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
        case .sortIntoSubfolder: return "Sort into subfolder"
        case .syncToFolder: return "Sync to folder"
        case .upload: return "Upload"
        case .moveToTrash: return "Move to Trash"
        case .delete: return "Delete"
        case .addTag: return "Add tag"
        case .removeTag: return "Remove tag"
        case .setColorLabel: return "Set color label"
        case .addComment: return "Add comment"
        case .toggleExtension: return "Toggle extension"
        case .toggleLock: return "Toggle lock"
        case .archive: return "Archive"
        case .runScript: return "Run shell script"
        case .runShortcut: return "Run shortcut"
        case .runAppleScript: return "Run AppleScript"
        case .runJavaScript: return "Run JavaScript"
        case .runAutomatorWorkflow: return "Run Automator workflow"
        case .openApplication: return "Open application"
        case .open: return "Open"
        case .showInFinder: return "Show in Finder"
        case .makeAlias: return "Make alias"
        case .importToLibrary: return "Import to library"
        case .uncompress: return "Uncompress"
        case .pause: return "Pause"
        case .runRulesOnFolderContents: return "Run rules on folder contents"
        case .continueMatchingRules: return "Continue matching rules"
        case .displayNotification: return "Display notification"
        case .ignore: return "Ignore"
        }
    }

    /// SF Symbol used to represent the action in the UI (e.g. activity history).
    var iconSystemName: String {
        switch self {
        case .moveToFolder: return "arrow.right.doc.on.clipboard"
        case .copyToFolder: return "doc.on.doc"
        case .rename: return "pencil"
        case .sortIntoSubfolder: return "folder.badge.gearshape"
        case .syncToFolder: return "arrow.triangle.2.circlepath"
        case .upload: return "arrow.up.circle"
        case .moveToTrash, .delete: return "trash"
        case .addTag, .removeTag: return "tag"
        case .setColorLabel: return "paintpalette"
        case .addComment: return "text.bubble"
        case .toggleExtension: return "textformat.abc"
        case .toggleLock: return "lock"
        case .archive: return "archivebox"
        case .runScript: return "terminal"
        case .runShortcut: return "square.stack.3d.up"
        case .runAppleScript: return "applescript"
        case .runJavaScript: return "curlybraces"
        case .runAutomatorWorkflow: return "gearshape.2"
        case .openApplication: return "app"
        case .open: return "arrow.up.forward.app"
        case .showInFinder: return "folder"
        case .makeAlias: return "arrowshape.turn.up.right"
        case .importToLibrary: return "tray.full"
        case .uncompress: return "doc.zipper"
        case .pause: return "pause.circle"
        case .runRulesOnFolderContents: return "folder.badge.play"
        case .continueMatchingRules: return "arrow.right.circle"
        case .displayNotification: return "bell"
        case .ignore: return "eye.slash"
        }
    }

    /// Whether this action kind has an "Options" popover in the rule editor
    /// (e.g. Move/Copy to Folder's conflict resolution, Run Shortcut's input
    /// mode) — used to hide the options button entirely for actions that
    /// have none, instead of showing an empty "No options" popover.
    var hasOptions: Bool {
        switch self {
        case .moveToFolder, .copyToFolder, .sortIntoSubfolder, .syncToFolder, .runShortcut, .openApplication, .rename, .importToLibrary, .uncompress:
            return true
        case .upload, .addTag, .removeTag, .setColorLabel, .addComment, .toggleExtension, .toggleLock, .archive, .runScript, .runAppleScript, .runJavaScript, .runAutomatorWorkflow, .open, .showInFinder, .makeAlias, .moveToTrash, .delete, .pause, .runRulesOnFolderContents, .continueMatchingRules, .displayNotification, .ignore:
            return false
        }
    }

    /// Parameters this action reads from its `params` JSON. Empty for actions
    /// that take none (trash/delete).
    var params: [ActionParamSpec] {
        switch self {
        case .moveToFolder, .copyToFolder:
            return [ActionParamSpec(key: ActionParam.destination, kind: .folderPath)]
        case .syncToFolder:
            return [ActionParamSpec(key: ActionParam.destination, kind: .folderPath)]
        case .sortIntoSubfolder:
            return [ActionParamSpec(key: ActionParam.subfolder, kind: .text)]
        case .upload:
            return [ActionParamSpec(key: ActionParam.uploadURL, kind: .text)]
        case .rename:
            return [ActionParamSpec(key: ActionParam.pattern, kind: .renamePattern)]
        case .addTag, .removeTag:
            return [ActionParamSpec(key: ActionParam.tags, kind: .tags)]
        case .setColorLabel:
            return [ActionParamSpec(key: ActionParam.color, kind: .colorLabel)]
        case .addComment:
            return [ActionParamSpec(key: ActionParam.comment, kind: .text)]
        case .runScript, .runAppleScript, .runJavaScript:
            return [ActionParamSpec(key: ActionParam.script, kind: .script)]
        case .runAutomatorWorkflow:
            return [ActionParamSpec(key: ActionParam.workflowPath, kind: .filePath)]
        case .runShortcut:
            return [ActionParamSpec(key: ActionParam.shortcutName, kind: .shortcut)]
        case .openApplication:
            return [ActionParamSpec(key: ActionParam.applicationPath, kind: .applicationPath)]
        case .makeAlias:
            return [ActionParamSpec(key: ActionParam.aliasDestination, kind: .folderPath)]
        case .importToLibrary:
            return [ActionParamSpec(key: ActionParam.libraryType, kind: .libraryType),
                    ActionParamSpec(key: ActionParam.targetPlaylist, kind: .playlist)]
        case .pause:
            return [ActionParamSpec(key: ActionParam.pauseSeconds, kind: .duration)]
        case .displayNotification:
            return [ActionParamSpec(key: ActionParam.notificationTitle, kind: .text),
                    ActionParamSpec(key: ActionParam.notificationBody, kind: .text)]
        case .moveToTrash, .delete, .toggleExtension, .toggleLock, .archive, .open, .showInFinder, .uncompress, .runRulesOnFolderContents, .continueMatchingRules, .ignore:
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
            .name, .extension_, .kind, .sizeBytes, .tags, .colorLabel, .contents,
            .createdAt, .dateModified, .dateAdded, .finderComment, .filePath, .itemCount,
            .lastOpened, .imageWidth, .imageHeight, .photoDateTaken, .pdfPageCount,
        ]),
        ConditionKindGroup(title: "Metadata", kinds: [
            .downloadedFromWebsite, .downloadedWithApp, .spotlightMetadata,
        ]),
    ]

    public static let conditionKinds: [ConditionKind] = conditionKindGroups.flatMap(\.kinds)

    public static let actionKindGroups: [ActionKindGroup] = [
        ActionKindGroup(title: nil, kinds: [.moveToFolder, .copyToFolder, .rename, .sortIntoSubfolder, .syncToFolder, .upload, .archive, .uncompress]),
        ActionKindGroup(title: "Tags", kinds: [.addTag, .removeTag, .setColorLabel]),
        ActionKindGroup(title: "Finder", kinds: [.addComment, .toggleExtension, .toggleLock, .open, .showInFinder, .makeAlias]),
        ActionKindGroup(title: "Automation", kinds: [.runShortcut, .runAppleScript, .runJavaScript, .runAutomatorWorkflow, .runScript, .openApplication, .pause]),
        ActionKindGroup(title: "Rule flow", kinds: [.runRulesOnFolderContents, .continueMatchingRules, .displayNotification, .ignore]),
        ActionKindGroup(title: "Disposal", kinds: [.moveToTrash, .delete]),
        ActionKindGroup(title: "Library", kinds: [.importToLibrary]),
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

/// Encodes the key and comparison value for the advanced Spotlight metadata
/// condition in the existing single string column used by `Condition`.
public enum SpotlightMetadataCondition {
    private static let separator = "\u{1F}"

    public static func parse(_ storedValue: String) -> (key: String, value: String)? {
        let parts = storedValue.components(separatedBy: separator)
        guard parts.count == 2,
              !parts[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    public static func make(key: String, value: String) -> String {
        "\(key)\(separator)\(value)"
    }
}
