import Foundation

public struct ScopedPath: Sendable {
    public let path: String
    public let depth: Int

    public init(path: String, depth: Int) {
        self.path = path
        self.depth = depth
    }
}

public struct RulePreview: Sendable {
    public let ruleId: String
    public let ruleName: String
    public let conditions: [ConditionPreview]
    public let actions: [ActionPreview]

    public init(ruleId: String, ruleName: String, conditions: [ConditionPreview], actions: [ActionPreview]) {
        self.ruleId = ruleId
        self.ruleName = ruleName
        self.conditions = conditions
        self.actions = actions
    }
}

public struct ConditionPreview: Sendable {
    public let kind: ConditionKind
    public let operator_: Operator
    public let value: String
    public let matched: Bool
    /// Optional secondary line shown in the Dry Run — e.g. for `contents`, which
    /// extraction strategy was used ("PDF text") or why nothing was read.
    public let detail: String?

    public init(kind: ConditionKind, operator_: Operator, value: String, matched: Bool, detail: String? = nil) {
        self.kind = kind
        self.operator_ = operator_
        self.value = value
        self.matched = matched
        self.detail = detail
    }
}

public struct ActionPreview: Hashable, Sendable {
    public let kind: ActionKind
    public let description: String
    public let sourcePath: String
    public let targetPath: String?
    public let status: DryRunStatus

    public init(kind: ActionKind, description: String, sourcePath: String, targetPath: String?, status: DryRunStatus) {
        self.kind = kind
        self.description = description
        self.sourcePath = sourcePath
        self.targetPath = targetPath
        self.status = status
    }
}

public struct FilePreview: Sendable {
    public let path: String
    public let name: String
    public let rules: [RulePreview]

    public init(path: String, name: String, rules: [RulePreview]) {
        self.path = path
        self.name = name
        self.rules = rules
    }
}

public struct PreviewResult: Sendable {
    public let filesScanned: Int
    public let matches: [FilePreview]
    public let matchLimit: Int?
    public let reachedMatchLimit: Bool

    public init(filesScanned: Int, matches: [FilePreview], matchLimit: Int? = nil, reachedMatchLimit: Bool = false) {
        self.filesScanned = filesScanned
        self.matches = matches
        self.matchLimit = matchLimit
        self.reachedMatchLimit = reachedMatchLimit
    }
}

public enum RuleEngine {
    /// Evaluates all enabled rules against `path` and runs matching ones.
    /// Returns the names of rules that matched and the history entries
    /// produced by their actions (grouped under `batchId`).
    ///
    /// Shares its per-action decision (target path, skip/conflict/run
    /// status) with `previewFile` by going through `ActionExecutor.plan`
    /// first, then acting on it — so Dry Run, Run Now, and the watcher can
    /// never see a different outcome for the same file and rules.
    public static func run(path: String, depth: Int, rules: [Rule], batchId: String, root: String? = nil) -> (matched: [String], history: [HistoryEntry]) {
        struct PendingFile {
            let path: String
            let depth: Int
            let startRuleIndex: Int
            let blockedRuleIds: Set<String>
        }

        var matched: [String] = []
        var history: [HistoryEntry] = []
        var pending = [PendingFile(path: path, depth: depth, startRuleIndex: 0, blockedRuleIds: [])]

        while !pending.isEmpty {
            let target = pending.removeFirst()
            var currentPath = target.path
            var currentDepth = target.depth
            var blockedRuleIds = target.blockedRuleIds

            for ruleIndex in target.startRuleIndex..<rules.count {
                let rule = rules[ruleIndex]
                guard !blockedRuleIds.contains(rule.id) else { continue }
                guard rule.enabled, ruleMatches(rule, path: currentPath, depth: currentDepth) else { continue }

                let result = runActions(rule, path: currentPath, batchId: batchId)
                history.append(contentsOf: result.history)
                matched.append(rule.name)

                for copiedPath in result.copiedPaths {
                    let copiedDepth: Int
                    if let root {
                        guard let depth = pathDepth(root: root, path: copiedPath) else { continue }
                        copiedDepth = depth
                    } else {
                        copiedDepth = currentDepth
                    }
                    pending.append(
                        PendingFile(
                            path: copiedPath,
                            depth: copiedDepth,
                            startRuleIndex: ruleIndex + 1,
                            blockedRuleIds: blockedRuleIds.union([rule.id])
                        )
                    )
                }

                // A terminal action (move/trash/delete) takes the file out of
                // this location — even if it didn't actually run (e.g. a
                // skipped/blocked conflict), later actions in this rule and
                // later rules in this pass were written assuming it had, so
                // stop here regardless of whether it ran.
                if result.isTerminal { break }

                // A non-terminal action (e.g. rename) can still change the
                // file's path; follow it so the next rule in the chain sees
                // where the file actually is now, not where it used to be.
                if result.finalPath != currentPath {
                    currentPath = result.finalPath
                    blockedRuleIds.insert(rule.id)
                    if let root, let depth = pathDepth(root: root, path: currentPath) {
                        currentDepth = depth
                    }
                }
            }
        }
        return (matched, history)
    }

    public static func previewFile(path: String, depth: Int, rules: [Rule]) -> FilePreview? {
        struct PendingFile {
            let path: String
            let depth: Int
            let startRuleIndex: Int
            let blockedRuleIds: Set<String>
        }

        var matchedRules: [RulePreview] = []
        var pending = [PendingFile(path: path, depth: depth, startRuleIndex: 0, blockedRuleIds: [])]

        while !pending.isEmpty {
            let target = pending.removeFirst()
            var currentPath = target.path
            var currentDepth = target.depth
            var blockedRuleIds = target.blockedRuleIds

            for ruleIndex in target.startRuleIndex..<rules.count {
                let rule = rules[ruleIndex]
                guard !blockedRuleIds.contains(rule.id) else { continue }
                guard rule.enabled, ruleInScope(rule, depth: currentDepth) else { continue }
                let conditions = conditionPreviews(rule, path: currentPath)
                guard conditionResultsMatch(conditions.map(\.matched), rule.conditionMatch) else { continue }

                let result = previewActions(rule, path: currentPath)
                matchedRules.append(
                    RulePreview(
                        ruleId: rule.id,
                        ruleName: rule.name,
                        conditions: conditions,
                        actions: result.actions
                    )
                )

                for copiedPath in result.copiedPaths {
                    pending.append(
                        PendingFile(
                            path: copiedPath,
                            depth: currentDepth,
                            startRuleIndex: ruleIndex + 1,
                            blockedRuleIds: blockedRuleIds.union([rule.id])
                        )
                    )
                }

                if result.isTerminal { break }

                if result.finalPath != currentPath {
                    currentPath = result.finalPath
                    blockedRuleIds.insert(rule.id)
                    // Preview is intentionally pure: when simulating a rename
                    // to a path that does not exist yet, keep the current depth.
                    currentDepth = target.depth
                }
            }
        }

        guard !matchedRules.isEmpty else { return nil }
        return FilePreview(path: path, name: (path as NSString).lastPathComponent, rules: matchedRules)
    }

    private static func conditionPreviews(_ rule: Rule, path: String) -> [ConditionPreview] {
        rule.conditions.map { condition in
            // `contents` runs the extraction pipeline once and reports which
            // strategy was used, so the Dry Run can show what was actually read.
            if condition.kind == .contents {
                let result = ConditionEvaluator.evaluateContents(condition, path: path)
                let detail: String
                if let message = result.message {
                    detail = "\(result.strategy.label) — \(message)"
                } else {
                    detail = result.strategy.label
                }
                return ConditionPreview(
                    kind: condition.kind,
                    operator_: condition.operator,
                    value: condition.value,
                    matched: result.matched,
                    detail: detail
                )
            }
            return ConditionPreview(
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

    /// Like `ruleInScope` + condition matching combined, but evaluates cheap
    /// conditions first and short-circuits, so an expensive `contents`
    /// extraction (PDF text, OCR, zip parsing, Spotlight) only runs when it
    /// can still change the outcome — e.g. a failing name check in an `.all`
    /// rule skips the OCR entirely. Reordering is safe because `.all` and
    /// `.any` are order-independent. Used by `run`, which only needs a
    /// yes/no answer; `previewFile` keeps the original order and evaluates
    /// every condition on purpose, to show each one's result in the Dry Run.
    private static func ruleMatches(_ rule: Rule, path: String, depth: Int) -> Bool {
        guard ruleInScope(rule, depth: depth) else { return false }
        if rule.conditions.isEmpty { return true }

        let ordered = rule.conditions.sorted { evaluationCost($0.kind) < evaluationCost($1.kind) }
        switch rule.conditionMatch {
        case .all:
            return ordered.allSatisfy { ConditionEvaluator.evaluate($0, path: path) }
        case .any:
            return ordered.contains { ConditionEvaluator.evaluate($0, path: path) }
        }
    }

    /// Relative cost of evaluating a condition, used only to order evaluation so
    /// the cheap checks can short-circuit before the expensive ones. `contents`
    /// can read/parse the whole file (and run OCR), so it is always evaluated last.
    private static func evaluationCost(_ kind: ConditionKind) -> Int {
        kind == .contents ? 1 : 0
    }

    private static func ruleInScope(_ rule: Rule, depth: Int) -> Bool {
        guard let limit = rule.recursionDepth else { return true }
        if limit >= 0 { return depth <= Int(limit) }
        return depth == 0
    }

    public static func pathDepth(root: String, path: String) -> Int? {
        let rootComponents = (root as NSString).pathComponents
        let pathComponents = (path as NSString).pathComponents
        guard pathComponents.count >= rootComponents.count,
              Array(pathComponents.prefix(rootComponents.count)) == rootComponents else {
            return nil
        }
        return max(0, pathComponents.count - rootComponents.count - 1)
    }

    public static func walkEntries(root: String, maxDepth: Int?) -> [ScopedPath] {
        var entries: [ScopedPath] = []
        forEachEntry(root: root, maxDepth: maxDepth) { entry in
            entries.append(entry)
        }
        return entries
    }

    public static func forEachEntry(root: String, maxDepth: Int?, _ visit: (ScopedPath) -> Void) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
            return
        }
        walkEntriesInner(root: root, maxDepth: maxDepth, depth: 0, visit: visit)
    }

    private static func walkEntriesInner(root: String, maxDepth: Int?, depth: Int, visit: (ScopedPath) -> Void) {
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: root) else { return }
        for child in children.sorted() {
            let childPath = (root as NSString).appendingPathComponent(child)
            visit(ScopedPath(path: childPath, depth: depth))

            var isDir: ObjCBool = false
            var isSymlink = false
            if let attrs = try? FileManager.default.attributesOfItem(atPath: childPath) {
                isSymlink = (attrs[.type] as? FileAttributeType) == .typeSymbolicLink
            }
            guard FileManager.default.fileExists(atPath: childPath, isDirectory: &isDir), isDir.boolValue, !isSymlink else {
                continue
            }
            if let limit = maxDepth, depth >= limit { continue }
            walkEntriesInner(root: childPath, maxDepth: maxDepth, depth: depth + 1, visit: visit)
        }
    }

    public static func maxRuleDepth(_ rules: [Rule]) -> Int? {
        let enabledRules = rules.filter(\.enabled)
        guard !enabledRules.isEmpty else { return 0 }
        if enabledRules.contains(where: { $0.recursionDepth == nil }) { return nil }
        return enabledRules.compactMap { rule in
            rule.recursionDepth.map { max(0, Int($0)) }
        }.max()
    }

    /// Runs one rule's actions against `path` in order, deciding each one
    /// the exact same way `previewActions` would (via `ActionExecutor.plan`)
    /// before acting on it — the single place preview and execution can
    /// never disagree.
    private static func runActions(_ rule: Rule, path: String, batchId: String) -> (history: [HistoryEntry], copiedPaths: [String], finalPath: String, isTerminal: Bool) {
        let sorted = rule.actions.sorted { $0.position < $1.position }

        var history: [HistoryEntry] = []
        var copiedPaths: [String] = []
        var current = path
        var stoppedOnTerminal = false

        for action in sorted {
            let original = current
            do {
                let actionPlan = try ActionExecutor.plan(action, path: current)

                switch actionPlan.status {
                case .wouldSkip:
                    // `description` already explains *why* for the
                    // conflict-aware skips (already in destination, or
                    // explicitly configured to skip); everything else is
                    // skipped because it simply wouldn't change the file.
                    let isConflictAwareSkip = actionPlan.description == "Already in destination" || actionPlan.description.hasPrefix("Skip —")
                    history.append(
                        HistoryEntry(
                            batchId: batchId,
                            ruleId: rule.id,
                            ruleName: rule.name,
                            actionKind: action.kind,
                            originalPath: original,
                            resultPath: original,
                            undo: Undo.none.toJSON(),
                            reversible: false,
                            status: .skipped,
                            message: isConflictAwareSkip ? actionPlan.description : "Skipped because the action would not change this file."
                        )
                    )
                case .blockedByConflict:
                    history.append(
                        HistoryEntry(
                            batchId: batchId,
                            ruleId: rule.id,
                            ruleName: rule.name,
                            actionKind: action.kind,
                            originalPath: original,
                            resultPath: original,
                            undo: Undo.none.toJSON(),
                            reversible: false,
                            status: .failed,
                            message: "A file already exists at the destination."
                        )
                    )
                case .needsConfirmation:
                    history.append(
                        HistoryEntry(
                            batchId: batchId,
                            ruleId: rule.id,
                            ruleName: rule.name,
                            actionKind: action.kind,
                            originalPath: original,
                            resultPath: original,
                            undo: Undo.none.toJSON(),
                            reversible: false,
                            status: .needsConfirmation
                        )
                    )
                case .wouldRun:
                    let applied = try ActionExecutor.execute(action, path: current)
                    let resultPath: String
                    if let copiedPath = applied.copiedPath {
                        resultPath = copiedPath
                        copiedPaths.append(copiedPath)
                    } else {
                        resultPath = applied.newPath
                    }
                    let resultIdentity = FileFingerprint.identity(resultPath)
                    history.append(
                        HistoryEntry(
                            batchId: batchId,
                            ruleId: rule.id,
                            ruleName: rule.name,
                            actionKind: action.kind,
                            originalPath: original,
                            resultPath: resultPath,
                            undo: applied.undo.toJSON(),
                            reversible: applied.undo.isReversible,
                            resultVolumeId: resultIdentity?.volumeId,
                            resultFileId: resultIdentity?.fileId
                        )
                    )
                    current = applied.newPath
                }

                if shouldStopActionChain(after: action, plan: actionPlan) {
                    stoppedOnTerminal = true
                    break
                }
            } catch {
                history.append(
                    HistoryEntry(
                        batchId: batchId,
                        ruleId: rule.id,
                        ruleName: rule.name,
                        actionKind: action.kind,
                        originalPath: original,
                        resultPath: original,
                        undo: Undo.none.toJSON(),
                        reversible: false,
                        status: .failed,
                        message: String(describing: error)
                    )
                )
            }
        }
        return (history, copiedPaths, current, stoppedOnTerminal)
    }

    private static func previewActions(_ rule: Rule, path: String) -> (actions: [ActionPreview], copiedPaths: [String], finalPath: String, isTerminal: Bool) {
        let sorted = rule.actions.sorted { $0.position < $1.position }

        var actions: [ActionPreview] = []
        var copiedPaths: [String] = []
        var current = path
        var stoppedOnTerminal = false

        for action in sorted {
            do {
                let plan = try ActionExecutor.plan(action, path: current)
                actions.append(
                    ActionPreview(
                        kind: plan.kind,
                        description: plan.description,
                        sourcePath: plan.sourcePath,
                        targetPath: plan.targetPath,
                        status: plan.status
                    )
                )

                if plan.status == .wouldRun {
                    if let copiedPath = plan.copiedPath {
                        copiedPaths.append(copiedPath)
                    }
                    current = plan.finalPath
                }

                if shouldStopActionChain(after: action, plan: plan) {
                    stoppedOnTerminal = true
                    break
                }
            } catch {
                actions.append(
                    ActionPreview(
                        kind: action.kind,
                        description: "Preview unavailable: \(error)",
                        sourcePath: current,
                        targetPath: nil,
                        status: .wouldSkip
                    )
                )
            }
        }

        return (actions, copiedPaths, current, stoppedOnTerminal)
    }

    private static func shouldStopActionChain(after action: Action, plan: ActionPlan) -> Bool {
        guard plan.isTerminal else { return false }
        return action.kind != .moveToFolder || plan.status != .wouldRun
    }
}
