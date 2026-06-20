import Foundation

/// Computes the `ExecutionPlan` Forel would apply for a set of files and
/// rules, without touching the filesystem. This is the single planning
/// implementation shared by Dry Run, Run Now and the watcher (per
/// `plans/pr-00-shared-core-pipeline.md`).
public enum RulePlanner {
    /// Plans every entry, dropping files that no enabled rule matches.
    public static func plan(
        entries: [ScopedPath],
        rules: [Rule],
        root: String?,
        folderId: String? = nil,
        status: PlanStatus = .ready
    ) -> ExecutionPlan {
        let files = entries.compactMap { entry in
            planFile(path: entry.path, depth: entry.depth, rules: rules, root: root)
        }
        return ExecutionPlan(folderId: folderId, status: status, files: files)
    }

    /// Plans a single file through every enabled, in-scope rule, following
    /// renames and re-evaluating copies, the same traversal `RuleEngine`
    /// uses for actual execution. Returns `nil` if no rule produced any
    /// planned action for this file.
    public static func planFile(path: String, depth: Int, rules: [Rule], root: String?) -> PlannedFile? {
        struct PendingFile {
            let path: String
            let depth: Int
            let startRuleIndex: Int
        }

        var plannedRules: [PlannedRule] = []
        var pending = [PendingFile(path: path, depth: depth, startRuleIndex: 0)]

        while !pending.isEmpty {
            let target = pending.removeFirst()
            var currentPath = target.path
            var currentDepth = target.depth

            for ruleIndex in target.startRuleIndex..<rules.count {
                let rule = rules[ruleIndex]
                guard rule.enabled, ruleInScope(rule, depth: currentDepth) else { continue }
                let conditions = conditionPreviews(rule, path: currentPath)
                guard conditionResultsMatch(conditions.map(\.matched), rule.conditionMatch) else { continue }

                let result = planActions(rule, path: currentPath)
                if !result.actions.isEmpty {
                    plannedRules.append(PlannedRule(ruleId: rule.id, ruleName: rule.name, conditions: conditions, actions: result.actions))
                }

                for copiedPath in result.copiedPaths {
                    pending.append(PendingFile(path: copiedPath, depth: currentDepth, startRuleIndex: ruleIndex + 1))
                }

                if result.isTerminal { break }

                if result.finalPath != currentPath {
                    currentPath = result.finalPath
                    if let root, let newDepth = RuleEngine.pathDepth(root: root, path: currentPath) {
                        currentDepth = newDepth
                    }
                }
            }
        }

        guard !plannedRules.isEmpty else { return nil }
        let identity = FileFingerprint.identity(path)
        return PlannedFile(
            path: path,
            volumeId: identity?.volumeId,
            fileId: identity?.fileId,
            contentFingerprint: FileFingerprint.current(path),
            rules: plannedRules
        )
    }

    private static func planActions(_ rule: Rule, path: String) -> (actions: [PlannedAction], copiedPaths: [String], finalPath: String, isTerminal: Bool) {
        let sorted = rule.actions.sorted { $0.position < $1.position }

        var actions: [PlannedAction] = []
        var copiedPaths: [String] = []
        var current = path
        var stoppedOnTerminal = false

        for action in sorted {
            if let target = alreadyInDestinationTarget(action, path: current) {
                actions.append(
                    PlannedAction(
                        ruleId: rule.id,
                        ruleName: rule.name,
                        actionKind: action.kind,
                        action: action,
                        description: "Already in destination",
                        sourcePath: current,
                        targetPath: target,
                        resultPath: current,
                        status: .wouldSkip,
                        skipReason: "alreadyInDestination",
                        isTerminal: false
                    )
                )
                // The file never actually moves, so the action chain for
                // this rule continues exactly as if this action were absent.
                continue
            }

            do {
                let actionPlan = try ActionExecutor.plan(action, path: current)
                let status = planStatus(for: actionPlan.status)
                actions.append(
                    PlannedAction(
                        ruleId: rule.id,
                        ruleName: rule.name,
                        actionKind: action.kind,
                        action: action,
                        description: actionPlan.description,
                        sourcePath: current,
                        targetPath: actionPlan.targetPath,
                        resultPath: actionPlan.finalPath,
                        status: status,
                        skipReason: status == .wouldSkip ? "noChange" : nil,
                        conflictReason: status == .blocked ? "destinationExists" : nil,
                        isTerminal: actionPlan.isTerminal
                    )
                )

                if status == .wouldRun || status == .needsConfirmation {
                    if let copiedPath = actionPlan.copiedPath {
                        copiedPaths.append(copiedPath)
                    }
                    current = actionPlan.finalPath
                }

                if actionPlan.isTerminal && status == .wouldRun {
                    stoppedOnTerminal = true
                    break
                }
            } catch {
                actions.append(
                    PlannedAction(
                        ruleId: rule.id,
                        ruleName: rule.name,
                        actionKind: action.kind,
                        action: action,
                        description: "Preview unavailable: \(error)",
                        sourcePath: current,
                        targetPath: nil,
                        resultPath: current,
                        status: .blocked,
                        conflictReason: String(describing: error),
                        isTerminal: false
                    )
                )
            }
        }

        return (actions, copiedPaths, current, stoppedOnTerminal)
    }

    /// The anti-recursion invariant: a `moveToFolder` whose destination is
    /// the directory the file is already directly in is always a no-op,
    /// never a rename-to-avoid-collision.
    private static func alreadyInDestinationTarget(_ action: Action, path: String) -> String? {
        guard action.kind == .moveToFolder else { return nil }
        guard let destDir = action.params[ActionParam.destination]?.stringValue, !destDir.isEmpty else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        guard normalizedPath(parent) == normalizedPath(destDir) else { return nil }
        let fileName = (path as NSString).lastPathComponent
        return (destDir as NSString).appendingPathComponent(fileName)
    }

    private static func normalizedPath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    private static func planStatus(for status: DryRunStatus) -> PlanActionStatus {
        switch status {
        case .wouldRun: return .wouldRun
        case .wouldSkip: return .wouldSkip
        case .blockedByConflict: return .blocked
        case .needsConfirmation: return .needsConfirmation
        }
    }

    private static func conditionPreviews(_ rule: Rule, path: String) -> [ConditionPreview] {
        rule.conditions.map { condition in
            ConditionPreview(
                kind: condition.kind,
                operator_: condition.operator,
                value: condition.value,
                matched: ConditionEvaluator.evaluate(condition, path: path)
            )
        }
    }

    private static func conditionResultsMatch(_ results: [Bool], _ match: ConditionMatch) -> Bool {
        if results.isEmpty { return true }
        switch match {
        case .all: return results.allSatisfy { $0 }
        case .any: return results.contains(true)
        }
    }

    private static func ruleInScope(_ rule: Rule, depth: Int) -> Bool {
        guard let limit = rule.recursionDepth else { return true }
        if limit >= 0 { return depth <= Int(limit) }
        return depth == 0
    }
}
