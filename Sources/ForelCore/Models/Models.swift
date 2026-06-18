import Foundation

public struct WatchedFolder: Codable, Equatable, Sendable {
    public var id: String
    public var path: String
    public var enabled: Bool
    public var createdAt: String

    public init(id: String = UUID().uuidString, path: String, enabled: Bool = true, createdAt: String = ISO8601DateFormatter().string(from: Date())) {
        self.id = id
        self.path = path
        self.enabled = enabled
        self.createdAt = createdAt
    }
}

public enum ConditionMatch: String, Codable, Equatable, Sendable {
    case all
    case any
}

public enum ConditionKind: String, Codable, Equatable, Sendable {
    case name
    case extension_ = "extension"
    case kind
    case sizeBytes = "size_bytes"
    case tags
    case colorLabel = "color_label"
    case contents
    case createdAt = "created_at"
    case dateModified = "date_modified"
    case dateAdded = "date_added"
    case downloadedFromWebsite = "downloaded_from_website"
    case downloadedWithApp = "downloaded_with_app"
    case rawWhereFromMetadata = "raw_where_from_metadata"

    public init(dbValue: String) {
        self = ConditionKind(rawValue: dbValue) ?? .name
    }
}

public enum Operator: String, Codable, Equatable, Sendable {
    case `is`
    case isNot = "is_not"
    case contains
    case doesNotContain = "does_not_contain"
    case startsWith = "starts_with"
    case endsWith = "ends_with"
    case matchesRegex = "matches_regex"
    case greaterThan = "greater_than"
    case lessThan = "less_than"
    case before
    case after
    case olderThan = "older_than"
    case withinLast = "within_last"

    public init(dbValue: String) {
        self = Operator(rawValue: dbValue) ?? .is
    }
}

public struct Condition: Codable, Equatable, Sendable {
    public var id: String
    public var ruleId: String
    public var kind: ConditionKind
    public var `operator`: Operator
    public var value: String

    public init(id: String = UUID().uuidString, ruleId: String, kind: ConditionKind, operator: Operator, value: String) {
        self.id = id
        self.ruleId = ruleId
        self.kind = kind
        self.operator = `operator`
        self.value = value
    }
}

public enum ActionKind: String, Codable, Equatable, Sendable {
    case moveToFolder = "move_to_folder"
    case copyToFolder = "copy_to_folder"
    case rename
    case moveToTrash = "move_to_trash"
    case delete
    case addTag = "add_tag"
    case removeTag = "remove_tag"
    case setColorLabel = "set_color_label"
    case runScript = "run_script"

    public init(dbValue: String) {
        self = ActionKind(rawValue: dbValue) ?? .moveToFolder
    }
}

/// JSON-encoded parameters specific to each action kind, e.g.
/// `moveToFolder`: {"destination": "/path"}; `rename`: {"pattern": "{name}"}; `addTag`: {"tag": "x"}.
public struct Action: Codable, Equatable, Sendable {
    public var id: String
    public var ruleId: String
    public var kind: ActionKind
    public var params: JSONValue
    public var position: Int64

    public init(id: String = UUID().uuidString, ruleId: String, kind: ActionKind, params: JSONValue, position: Int64) {
        self.id = id
        self.ruleId = ruleId
        self.kind = kind
        self.params = params
        self.position = position
    }
}

public struct Rule: Codable, Equatable, Sendable {
    public var id: String
    public var folderId: String
    public var name: String
    public var enabled: Bool
    public var conditionMatch: ConditionMatch
    /// nil = all subfolders (unlimited), 0 = current folder only, N = N levels deep.
    public var recursionDepth: Int64?
    public var conditions: [Condition]
    public var actions: [Action]
    public var priority: Int64
    public var createdAt: String

    public init(
        id: String = UUID().uuidString,
        folderId: String,
        name: String,
        enabled: Bool = false,
        conditionMatch: ConditionMatch = .all,
        recursionDepth: Int64? = 0,
        conditions: [Condition] = [],
        actions: [Action] = [],
        priority: Int64 = 0,
        createdAt: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.id = id
        self.folderId = folderId
        self.name = name
        self.enabled = enabled
        self.conditionMatch = conditionMatch
        self.recursionDepth = recursionDepth
        self.conditions = conditions
        self.actions = actions
        self.priority = priority
        self.createdAt = createdAt
    }
}

public enum HistoryStatus: String, Codable, Equatable, Sendable {
    case applied
    case undone
    case failed
    case skipped
    case needsConfirmation = "needs_confirmation"
}

/// A single executed action, recorded so it can be reviewed (log) and reversed
/// (undo). Entries from one rule run share a `batchId`.
public struct HistoryEntry: Codable, Equatable, Sendable {
    public var id: String
    public var batchId: String
    public var ruleId: String?
    public var ruleName: String
    public var actionKind: ActionKind
    public var originalPath: String
    public var resultPath: String
    /// Serialised `Undo`.
    public var undo: JSONValue
    public var reversible: Bool
    public var status: HistoryStatus
    public var message: String?
    public var createdAt: String

    public init(
        id: String = UUID().uuidString,
        batchId: String,
        ruleId: String?,
        ruleName: String,
        actionKind: ActionKind,
        originalPath: String,
        resultPath: String,
        undo: JSONValue,
        reversible: Bool,
        status: HistoryStatus = .applied,
        message: String? = nil,
        createdAt: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.id = id
        self.batchId = batchId
        self.ruleId = ruleId
        self.ruleName = ruleName
        self.actionKind = actionKind
        self.originalPath = originalPath
        self.resultPath = resultPath
        self.undo = undo
        self.reversible = reversible
        self.status = status
        self.message = message
        self.createdAt = createdAt
    }
}
