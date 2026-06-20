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

public struct ConditionPreview: Equatable, Sendable {
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

/// Filesystem scanning and scope helpers shared by `RulePlanner`, Run Now and
/// the watcher. Rule matching/execution itself lives in `RulePlanner` and
/// `PlanExecutor` — this type no longer runs rules directly.
public enum RuleEngine {
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
        let enabledRules = rules.filter(\.enabled)
        guard !enabledRules.isEmpty else { return 0 }
        if enabledRules.contains(where: { $0.recursionDepth == nil }) { return nil }
        return enabledRules.compactMap { rule in
            rule.recursionDepth.map { max(0, Int($0)) }
        }.max()
    }
}
