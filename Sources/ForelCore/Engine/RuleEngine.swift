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

    public init(kind: ConditionKind, operator_: Operator, value: String, matched: Bool) {
        self.kind = kind
        self.operator_ = operator_
        self.value = value
        self.matched = matched
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

    public init(filesScanned: Int, matches: [FilePreview]) {
        self.filesScanned = filesScanned
        self.matches = matches
    }
}

public enum RuleEngine {
    /// Evaluates all enabled rules against `path` and executes matching ones.
    /// Returns the names of rules that matched and the history entries produced
    /// by their actions (grouped under `batchId`).
    public static func evaluateFile(path: String, depth: Int, rules: [Rule], batchId: String, root: String? = nil) -> (matched: [String], history: [HistoryEntry]) {
        struct PendingFile {
            let path: String
            let depth: Int
            let startRuleIndex: Int
        }

        var matched: [String] = []
        var history: [HistoryEntry] = []
        var pending = [PendingFile(path: path, depth: depth, startRuleIndex: 0)]

        while !pending.isEmpty {
            let target = pending.removeFirst()
            var currentPath = target.path
            var currentDepth = target.depth

            for ruleIndex in target.startRuleIndex..<rules.count {
                let rule = rules[ruleIndex]
                guard rule.enabled, ruleMatches(rule, path: currentPath, depth: currentDepth) else { continue }

                let result = executeActions(rule, path: currentPath, batchId: batchId)
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
                    pending.append(PendingFile(path: copiedPath, depth: copiedDepth, startRuleIndex: ruleIndex + 1))
                }

                // A terminal action (move/trash/delete) takes the file out of
                // this location entirely, same as it stops the action chain
                // within a single rule — no further rule in this pass should
                // be evaluated against it.
                if result.isTerminal { break }

                // A non-terminal action (e.g. rename) can still change the
                // file's path; follow it so the next rule in the chain sees
                // where the file actually is now, not where it used to be.
                if result.finalPath != currentPath {
                    currentPath = result.finalPath
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
        }

        var matchedRules: [RulePreview] = []
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

                let result = previewActions(rule, path: currentPath)
                if !result.actions.isEmpty {
                    matchedRules.append(
                        RulePreview(
                            ruleId: rule.id,
                            ruleName: rule.name,
                            conditions: conditions,
                            actions: result.actions
                        )
                    )
                }

                for copiedPath in result.copiedPaths {
                    pending.append(PendingFile(path: copiedPath, depth: currentDepth, startRuleIndex: ruleIndex + 1))
                }

                if result.isTerminal { break }

                if result.finalPath != currentPath {
                    currentPath = result.finalPath
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

    private static func ruleMatches(_ rule: Rule, path: String, depth: Int) -> Bool {
        guard ruleInScope(rule, depth: depth) else { return false }
        if rule.conditions.isEmpty { return true }

        let results = rule.conditions.map { ConditionEvaluator.evaluate($0, path: path) }
        return conditionResultsMatch(results, rule.conditionMatch)
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
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
            return entries
        }
        walkEntriesInner(root: root, maxDepth: maxDepth, depth: 0, entries: &entries)
        return entries
    }

    private static func walkEntriesInner(root: String, maxDepth: Int?, depth: Int, entries: inout [ScopedPath]) {
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: root) else { return }
        for child in children.sorted() {
            let childPath = (root as NSString).appendingPathComponent(child)
            entries.append(ScopedPath(path: childPath, depth: depth))

            var isDir: ObjCBool = false
            var isSymlink = false
            if let attrs = try? FileManager.default.attributesOfItem(atPath: childPath) {
                isSymlink = (attrs[.type] as? FileAttributeType) == .typeSymbolicLink
            }
            guard FileManager.default.fileExists(atPath: childPath, isDirectory: &isDir), isDir.boolValue, !isSymlink else {
                continue
            }
            if let limit = maxDepth, depth >= limit { continue }
            walkEntriesInner(root: childPath, maxDepth: maxDepth, depth: depth + 1, entries: &entries)
        }
    }

    public static func maxRuleDepth(_ rules: [Rule]) -> Int? {
        if rules.contains(where: { $0.recursionDepth == nil }) { return nil }
        return rules.compactMap { rule in
            rule.recursionDepth.map { max(0, Int($0)) }
        }.max()
    }

    private static func executeActions(_ rule: Rule, path: String, batchId: String) -> (history: [HistoryEntry], copiedPaths: [String], finalPath: String, isTerminal: Bool) {
        let sorted = rule.actions.sorted { $0.position < $1.position }

        var history: [HistoryEntry] = []
        var copiedPaths: [String] = []
        var current = path
        var stoppedOnTerminal = false
        for action in sorted {
            let isTerminal = action.kind == .moveToFolder || action.kind == .moveToTrash || action.kind == .delete
            let original = current
            if !ActionExecutor.wouldChange(action, path: current) {
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
                        message: "Skipped because the action would not change this file."
                    )
                )
                continue
            }

            do {
                let applied = try ActionExecutor.execute(action, path: current)
                let resultPath: String
                switch applied.undo {
                case .copy(let copy):
                    resultPath = copy
                    copiedPaths.append(copy)
                default:
                    resultPath = applied.newPath
                }
                history.append(
                    HistoryEntry(
                        batchId: batchId,
                        ruleId: rule.id,
                        ruleName: rule.name,
                        actionKind: action.kind,
                        originalPath: original,
                        resultPath: resultPath,
                        undo: applied.undo.toJSON(),
                        reversible: applied.undo.isReversible
                    )
                )
                current = applied.newPath
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
            if isTerminal {
                stoppedOnTerminal = true
                break
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

                if plan.isTerminal {
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
}
