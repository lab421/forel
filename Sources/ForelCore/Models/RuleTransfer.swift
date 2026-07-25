// Forel - A native macOS file-automation app
// Copyright (C) 2026  Lab421

import Foundation

/// A non-fatal incompatibility discovered while reading another app's rules.
/// Rules with one or more issues are imported disabled so they can be reviewed
/// before Forel ever runs them.
public struct RuleTransferIssue: Equatable, Sendable {
    public let ruleName: String
    public let message: String

    public init(ruleName: String, message: String) {
        self.ruleName = ruleName
        self.message = message
    }
}

public struct RuleImportResult: Sendable {
    public let rules: [Rule]
    public let issues: [RuleTransferIssue]

    public init(rules: [Rule], issues: [RuleTransferIssue]) {
        self.rules = rules
        self.issues = issues
    }
}

public enum RuleTransferError: LocalizedError {
    case unsupportedFile
    case invalidNativeFile

    public var errorDescription: String? {
        switch self {
        case .unsupportedFile: return "This file is not a Forel or Hazel rule export."
        case .invalidNativeFile: return "This Forel rule export is invalid or from a newer version of Forel."
        }
    }
}

/// File interchange for rules. Forel exports a documented JSON format
/// (`.forelrules`) and imports both that format and Hazel's `.hazelrules`
/// keyed archives. Hazel's format is proprietary, therefore unsupported
/// predicates and actions are surfaced as issues instead of guessed.
public enum RuleTransfer {
    private struct NativeExport: Codable {
        let format: String
        let version: Int
        let rules: [Rule]
    }

    public static func exportForel(_ rules: [Rule]) throws -> Data {
        let export = NativeExport(format: "forel-rules", version: 1, rules: rules)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(export)
    }

    public static func importRules(from data: Data, folderId: String) throws -> RuleImportResult {
        if let native = try? JSONDecoder().decode(NativeExport.self, from: data) {
            guard native.format == "forel-rules", native.version == 1 else { throw RuleTransferError.invalidNativeFile }
            return RuleImportResult(rules: native.rules.map { remap($0, folderId: folderId) }, issues: [])
        }
        return try importHazel(data: data, folderId: folderId)
    }

    private static func remap(_ source: Rule, folderId: String, disabled: Bool = false) -> Rule {
        let id = UUID().uuidString
        var rule = Rule(
            id: id,
            folderId: folderId,
            name: source.name,
            enabled: source.enabled && !disabled,
            conditionMatch: source.conditionMatch,
            recursionDepth: source.recursionDepth,
            priority: source.priority
        )
        rule.conditions = source.conditions.enumerated().map {
            Condition(ruleId: id, kind: $0.element.kind, operator: $0.element.operator, value: $0.element.value)
        }
        rule.actions = source.actions.enumerated().map {
            Action(ruleId: id, kind: $0.element.kind, params: $0.element.params, position: Int64($0.offset))
        }
        return rule
    }

    private static func importHazel(data: Data, folderId: String) throws -> RuleImportResult {
        let archive = try HazelArchive(data: data)
        guard let root = archive.root,
              let archivedRules = archive.array(root["rules"]) else { throw RuleTransferError.unsupportedFile }

        var rules: [Rule] = []
        var issues: [RuleTransferIssue] = []
        for archivedRule in archivedRules {
            guard let object = archivedRule as? [String: Any],
                  archive.className(object) == "HazelRule",
                  let name = archive.string(object["description"]), !name.isEmpty else { continue }
            var localIssues: [RuleTransferIssue] = []
            var source = Rule(folderId: folderId, name: name, enabled: true)
            source.conditionMatch = (archive.number(object["predicateType"]) == 0) ? .any : .all

            let criteria = archive.array(object["criteria"]) ?? []
            for criterion in criteria {
                if let condition = hazelCondition(criterion, archive: archive, ruleId: source.id) {
                    source.conditions.append(condition)
                } else {
                    localIssues.append(.init(ruleName: name, message: "Unsupported Hazel condition was skipped."))
                }
            }

            for (position, archivedAction) in (archive.array(object["actions"]) ?? []).enumerated() {
                if let action = hazelAction(archivedAction, archive: archive, ruleId: source.id, position: position) {
                    source.actions.append(action)
                } else {
                    let type = archive.className(archivedAction as? [String: Any]) ?? "unknown action"
                    localIssues.append(.init(ruleName: name, message: "Hazel action \(type) was skipped because Forel cannot represent it."))
                }
            }
            if criteria.isEmpty { localIssues.append(.init(ruleName: name, message: "The Hazel rule has no conditions and matches every file.")) }
            if source.actions.isEmpty { localIssues.append(.init(ruleName: name, message: "The Hazel rule has no supported actions.")) }
            source.enabled = localIssues.isEmpty
            source = remap(source, folderId: folderId, disabled: !localIssues.isEmpty)
            rules.append(source)
            issues.append(contentsOf: localIssues)
        }
        guard !rules.isEmpty else { throw RuleTransferError.unsupportedFile }
        return RuleImportResult(rules: rules, issues: issues)
    }

    private static func hazelCondition(_ raw: Any, archive: HazelArchive, ruleId: String) -> Condition? {
        guard let predicate = raw as? [String: Any],
              let key = archive.findString(predicate["NSLeftExpression"], key: "NSKeyPath"),
              let value = archive.constantString(predicate["NSRightExpression"]),
              let operatorType = archive.number((predicate["NSPredicateOperator"] as? [String: Any])?["NSOperatorType"]) else { return nil }
        let kind: ConditionKind
        switch key {
        case "displayBasename", "displayName": kind = .name
        case "displayExtensions", "extension": kind = .extension_
        case "dateCreated": kind = .createdAt
        case "dateModified": kind = .dateModified
        case "fileSize", "logicalSize": kind = .sizeBytes
        case "comment": kind = .finderComment
        case "path", "filePath": kind = .filePath
        case "tags", "tagNames": kind = .tags
        default: return nil
        }
        let negated = ((predicate["NSPredicateOperator"] as? [String: Any])?["NSNegate"] as? Bool) == true
        let op: Operator?
        switch operatorType {
        case 0: op = .lessThan
        case 2: op = .greaterThan
        case 4: op = negated ? .isNot : .is
        case 5: op = .isNot
        case 6: op = negated ? nil : .matchesRegex
        case 8: op = negated ? nil : .startsWith
        case 9: op = negated ? nil : .endsWith
        case 10, 11: op = negated ? .doesNotContain : .contains
        default: op = nil
        }
        guard let op else { return nil }
        return Condition(ruleId: ruleId, kind: kind, operator: op, value: value)
    }

    private static func hazelAction(_ raw: Any, archive: HazelArchive, ruleId: String, position: Int) -> Action? {
        guard let object = raw as? [String: Any], let type = archive.className(object) else { return nil }
        let params = object["parameter"]
        switch type {
        case "HazelMoveAction":
            if archive.className(params as? [String: Any]) == "HazelTrashFolder" {
                return Action(ruleId: ruleId, kind: .moveToTrash, params: .object([:]), position: Int64(position))
            }
            guard let destination = archive.findPath(params) else { return nil }
            return Action(ruleId: ruleId, kind: .moveToFolder, params: .object([ActionParam.destination: .string(destination)]), position: Int64(position))
        case "HazelCopyAction":
            guard let destination = archive.findPath(params) else { return nil }
            return Action(ruleId: ruleId, kind: .copyToFolder, params: .object([ActionParam.destination: .string(destination)]), position: Int64(position))
        case "HazelTrashAction":
            return Action(ruleId: ruleId, kind: .moveToTrash, params: .object([:]), position: Int64(position))
        case "HazelPauseAction":
            guard let seconds = archive.number((params as? [String: Any])?["amount"]) else { return nil }
            return Action(ruleId: ruleId, kind: .pause, params: .object([ActionParam.pauseSeconds: .number(seconds)]), position: Int64(position))
        case "HazelShellScriptAction":
            guard let script = archive.string((params as? [String: Any])?["script"]) else { return nil }
            let shell = archive.string((params as? [String: Any])?["shell"]) ?? "/bin/zsh"
            return Action(ruleId: ruleId, kind: .runScript, params: .object(["script": .string(script), "shell": .string(shell)]), position: Int64(position))
        default: return nil
        }
    }
}

/// Small, deliberately non-executing reader for an NSKeyedArchiver plist.
/// It resolves only plist values and class labels; it never instantiates Hazel
/// classes from an untrusted import file.
private struct HazelArchive {
    let objects: [Any]
    let root: [String: Any]?

    init(data: Data) throws {
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              plist["$archiver"] as? String == "NSKeyedArchiver",
              let objects = plist["$objects"] as? [Any],
              let top = plist["$top"] as? [String: Any] else { throw RuleTransferError.unsupportedFile }
        self.objects = objects
        self.root = HazelArchive.resolve(top["root"], objects: objects) as? [String: Any]
    }

    func array(_ value: Any?) -> [Any]? {
        guard let dict = value as? [String: Any] else { return value as? [Any] }
        return dict["NS.objects"] as? [Any]
    }

    func className(_ value: [String: Any]?) -> String? { value?["__class"] as? String }
    func string(_ value: Any?) -> String? {
        if let string = value as? String, string != "$null" { return string }
        if let data = value as? Data { return String(data: data, encoding: .utf8) }
        return nil
    }
    func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        if let decimal = value as? [String: Any],
           let data = decimal["NS.mantissa"] as? Data {
            let mantissa = data.prefix(8).enumerated().reduce(UInt64(0)) { partial, byte in
                partial | (UInt64(byte.element) << UInt64(byte.offset * 8))
            }
            let exponent = (decimal["NS.exponent"] as? NSNumber)?.intValue ?? 0
            let sign = (decimal["NS.negative"] as? Bool) == true ? -1.0 : 1.0
            return sign * Double(mantissa) * pow(10, Double(exponent))
        }
        return nil
    }
    func constantString(_ value: Any?) -> String? {
        guard let dict = value as? [String: Any] else { return string(value) }
        return string(dict["NSConstantValue"]) ?? findString(value, key: "NSConstantValue")
    }
    func findString(_ value: Any?, key: String) -> String? {
        guard let value else { return nil }
        if let dict = value as? [String: Any] {
            if let found = string(dict[key]) { return found }
            for child in dict.values where findString(child, key: key) != nil { return findString(child, key: key) }
        } else if let array = value as? [Any] {
            for child in array where findString(child, key: key) != nil { return findString(child, key: key) }
        }
        return nil
    }
    func findPath(_ value: Any?) -> String? {
        findString(value, key: "path") ?? findString(value, key: "displayName") ?? findString(value, key: "bookmark")
    }

    private static func resolve(_ value: Any?, objects: [Any]) -> Any? {
        guard let value else { return nil }
        if let uid = uidValue(value), objects.indices.contains(uid) {
            if uid == 0 { return nil }
            return resolve(objects[uid], objects: objects)
        }
        if let dict = value as? [String: Any] {
            var resolved = dict.compactMapValues { resolve($0, objects: objects) }
            if let classObject = resolve(dict["$class"], objects: objects) as? [String: Any],
               let name = classObject["$classname"] as? String { resolved["__class"] = name }
            return resolved
        }
        if let array = value as? [Any] { return array.compactMap { resolve($0, objects: objects) } }
        return value
    }

    /// Binary plists surface keyed-archive references as Foundation's private
    /// UID object, while XML fixtures use the public `CF$UID` dictionary.
    /// Read its numeric value only; no archived class is ever instantiated.
    private static func uidValue(_ value: Any) -> Int? {
        if let dict = value as? [String: Any], let number = dict["CF$UID"] as? NSNumber {
            return number.intValue
        }
        guard let object = value as? NSObject,
              object.description.hasPrefix("<CFKeyedArchiverUID") else { return nil }
        let description = object.description
        guard let range = description.range(of: "value = ") else { return nil }
        let digits = description[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }
}
