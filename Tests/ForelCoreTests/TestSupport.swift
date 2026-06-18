import Foundation
import Darwin
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

/// Writes a `kMDItemWhereFroms`-style xattr (a binary-plist-encoded
/// `[String]`), the same shape macOS browsers/downloaders write.
func setWhereFroms(_ path: String, _ values: [String]) throws {
    let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
    let result = data.withUnsafeBytes { bytes in
        setxattr(path, "com.apple.metadata:kMDItemWhereFroms", bytes.baseAddress, data.count, 0, 0)
    }
    guard result == 0 else {
        struct XattrWriteError: Error {}
        throw XattrWriteError()
    }
}

/// Writes a `com.apple.quarantine`-style xattr with the given responsible
/// app name in its agent-name field, matching the real format macOS uses:
/// `<flags>;<timestamp-hex>;<agent name>;<event UUID>`.
func setQuarantineAgent(_ path: String, agent: String) throws {
    let raw = "0083;00000000;\(agent);00000000-0000-0000-0000-000000000000"
    let data = Data(raw.utf8)
    let result = data.withUnsafeBytes { bytes in
        setxattr(path, "com.apple.quarantine", bytes.baseAddress, data.count, 0, 0)
    }
    guard result == 0 else {
        struct XattrWriteError: Error {}
        throw XattrWriteError()
    }
}
