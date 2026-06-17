import Foundation
@testable import ForelCore

final class TempDir {
    let path: String

    init() {
        path = NSTemporaryDirectory().appending("forel-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: path)
    }

    func file(_ name: String, contents: String = "") -> String {
        let filePath = (path as NSString).appendingPathComponent(name)
        try! contents.write(toFile: filePath, atomically: true, encoding: .utf8)
        return filePath
    }

    func dir(_ name: String) -> String {
        let dirPath = (path as NSString).appendingPathComponent(name)
        try! FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
        return dirPath
    }
}

func makeCondition(_ kind: ConditionKind, _ op: Operator, _ value: String, ruleId: String = "rule") -> Condition {
    Condition(ruleId: ruleId, kind: kind, operator: op, value: value)
}

func makeAction(_ kind: ActionKind, _ params: JSONValue, position: Int64 = 0, ruleId: String = "rule") -> Action {
    Action(ruleId: ruleId, kind: kind, params: params, position: position)
}

func makeRule(folderId: String = "folder", name: String, enabled: Bool = true, conditionMatch: ConditionMatch = .all, conditions: [Condition] = [], actions: [Action] = [], recursionDepth: Int64? = 0) -> Rule {
    Rule(folderId: folderId, name: name, enabled: enabled, conditionMatch: conditionMatch, recursionDepth: recursionDepth, conditions: conditions, actions: actions)
}
