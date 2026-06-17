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
    public let actions: [String]

    public init(ruleId: String, ruleName: String, actions: [String]) {
        self.ruleId = ruleId
        self.ruleName = ruleName
        self.actions = actions
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
            for ruleIndex in target.startRuleIndex..<rules.count {
                let rule = rules[ruleIndex]
                guard rule.enabled, ruleMatches(rule, path: target.path, depth: target.depth) else { continue }

                let result = executeActions(rule, path: target.path, batchId: batchId)
                history.append(contentsOf: result.history)
                matched.append(rule.name)

                for copiedPath in result.copiedPaths {
                    let copiedDepth: Int
                    if let root {
                        guard let depth = pathDepth(root: root, path: copiedPath) else { continue }
                        copiedDepth = depth
                    } else {
                        copiedDepth = target.depth
                    }
                    pending.append(PendingFile(path: copiedPath, depth: copiedDepth, startRuleIndex: ruleIndex + 1))
                }
            }
        }
        return (matched, history)
    }

    public static func previewFile(path: String, depth: Int, rules: [Rule]) -> FilePreview? {
        var matchedRules: [RulePreview] = []

        for rule in rules where rule.enabled {
            guard ruleMatches(rule, path: path, depth: depth) else { continue }
            let sorted = rule.actions.sorted { $0.position < $1.position }
            let actions = sorted
                .filter { ActionExecutor.wouldChange($0, path: path) }
                .map { action -> String in
                    (try? ActionExecutor.preview(action, path: path)) ?? "preview unavailable"
                }
            if actions.isEmpty { continue }
            matchedRules.append(RulePreview(ruleId: rule.id, ruleName: rule.name, actions: actions))
        }

        guard !matchedRules.isEmpty else { return nil }
        return FilePreview(path: path, name: (path as NSString).lastPathComponent, rules: matchedRules)
    }

    private static func ruleMatches(_ rule: Rule, path: String, depth: Int) -> Bool {
        guard ruleInScope(rule, depth: depth) else { return false }
        if rule.conditions.isEmpty { return true }

        let results = rule.conditions.map { ConditionEvaluator.evaluate($0, path: path) }
        switch rule.conditionMatch {
        case .all: return results.allSatisfy { $0 }
        case .any: return results.contains(true)
        }
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

    private static func executeActions(_ rule: Rule, path: String, batchId: String) -> (history: [HistoryEntry], copiedPaths: [String]) {
        let sorted = rule.actions.sorted { $0.position < $1.position }

        var history: [HistoryEntry] = []
        var copiedPaths: [String] = []
        var current = path
        for action in sorted {
            let isTerminal = action.kind == .moveToFolder || action.kind == .moveToTrash || action.kind == .delete
            let original = current
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
                // Logged by the caller; a failed action does not abort the rest of the rule run.
            }
            if isTerminal { break }
        }
        return (history, copiedPaths)
    }
}
