import Foundation

/// Status of a single planned action. Mirrors `DryRunStatus` but is the
/// vocabulary the core planner/validator/executor agree on, independent of
/// any one UI's preview rendering.
public enum PlanActionStatus: String, Codable, Equatable, Sendable {
    case wouldRun = "would_run"
    case wouldSkip = "would_skip"
    case blocked
    case needsConfirmation = "needs_confirmation"
}

/// A single action the planner decided on for one file, at one point in its
/// rule chain.
public struct PlannedAction: Equatable, Sendable {
    public let ruleId: String
    public let ruleName: String
    public let actionKind: ActionKind
    /// The full action definition (with params), so the executor can run it
    /// later without going back to the rules table. Also carries the
    /// action's own `id`.
    public let action: Action
    public let description: String
    public let sourcePath: String
    public let targetPath: String?
    public let resultPath: String
    public let status: PlanActionStatus
    public let skipReason: String?
    public let conflictReason: String?
    public let isTerminal: Bool

    public init(
        ruleId: String,
        ruleName: String,
        actionKind: ActionKind,
        action: Action,
        description: String,
        sourcePath: String,
        targetPath: String?,
        resultPath: String,
        status: PlanActionStatus,
        skipReason: String? = nil,
        conflictReason: String? = nil,
        isTerminal: Bool
    ) {
        self.ruleId = ruleId
        self.ruleName = ruleName
        self.actionKind = actionKind
        self.action = action
        self.description = description
        self.sourcePath = sourcePath
        self.targetPath = targetPath
        self.resultPath = resultPath
        self.status = status
        self.skipReason = skipReason
        self.conflictReason = conflictReason
        self.isTerminal = isTerminal
    }
}

/// All the actions one rule contributed for one file, plus the condition
/// evaluation that made it match.
public struct PlannedRule: Equatable, Sendable {
    public let ruleId: String
    public let ruleName: String
    public let conditions: [ConditionPreview]
    public let actions: [PlannedAction]

    public init(ruleId: String, ruleName: String, conditions: [ConditionPreview] = [], actions: [PlannedAction]) {
        self.ruleId = ruleId
        self.ruleName = ruleName
        self.conditions = conditions
        self.actions = actions
    }
}

/// Everything the planner decided for one file, plus the filesystem identity
/// it observed at planning time so later revalidation can detect staleness.
public struct PlannedFile: Equatable, Sendable {
    public let path: String
    public let volumeId: Int64?
    public let fileId: Int64?
    public let contentFingerprint: String?
    public let rules: [PlannedRule]

    public init(path: String, volumeId: Int64?, fileId: Int64?, contentFingerprint: String?, rules: [PlannedRule]) {
        self.path = path
        self.volumeId = volumeId
        self.fileId = fileId
        self.contentFingerprint = contentFingerprint
        self.rules = rules
    }
}

public struct PlanWarning: Equatable, Sendable {
    public let path: String
    public let message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

public struct PlanConflict: Equatable, Sendable {
    public let path: String
    public let message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

public enum PlanStatus: String, Codable, Equatable, Sendable {
    /// Computed for a Dry Run, not (yet) intended for execution.
    case previewed
    /// Computed for Run Now/watcher, ready to feed the executor.
    case ready
    /// The filesystem has changed since this plan was computed.
    case stale
}

/// Re-checks a `PlannedFile`'s filesystem snapshot against the filesystem
/// right now. Shared by `PlanExecutor` (refuses to act on a stale file) and
/// `PlanValidator` (surfaces staleness as a conflict before execution).
public enum PlanStaleness {
    public static func reason(for file: PlannedFile) -> String? {
        guard FileManager.default.fileExists(atPath: file.path) else {
            return "Source file no longer exists"
        }
        if let expected = file.contentFingerprint, FileFingerprint.current(file.path) != expected {
            return "Source file changed since it was planned"
        }
        if let volumeId = file.volumeId, let fileId = file.fileId,
           let actual = FileFingerprint.identity(file.path),
           actual != FileIdentity(volumeId: volumeId, fileId: fileId) {
            return "Source file identity changed since it was planned"
        }
        return nil
    }
}

/// The single source of truth for "what would Forel do" — computed once by
/// `RulePlanner` and consumed identically by Dry Run, Run Now and the
/// watcher.
public struct ExecutionPlan: Sendable {
    public let id: String
    public let folderId: String?
    public let createdAt: String
    public let status: PlanStatus
    public let files: [PlannedFile]
    public let warnings: [PlanWarning]
    public let conflicts: [PlanConflict]

    public init(
        id: String = UUID().uuidString,
        folderId: String? = nil,
        createdAt: String = ISO8601DateFormatter().string(from: Date()),
        status: PlanStatus,
        files: [PlannedFile],
        warnings: [PlanWarning] = [],
        conflicts: [PlanConflict] = []
    ) {
        self.id = id
        self.folderId = folderId
        self.createdAt = createdAt
        self.status = status
        self.files = files
        self.warnings = warnings
        self.conflicts = conflicts
    }
}
