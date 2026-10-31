// Forel - A native macOS file-automation app
// Copyright (C) 2026  Lab421

import Foundation
import CryptoKit
import Darwin

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
        case .invalidNativeFile: return "This Forel rule export is invalid, too large or deeply nested, or from a newer version of Forel."
        }
    }
}

/// File interchange for rules. Forel exports a versioned JSON format and
/// imports both that format and Hazel's keyed archives. Unsupported Hazel
/// predicates and actions are reported instead of guessed.
public enum RuleTransfer {
    public static let maximumFileSize = 20 * 1024 * 1024
    private struct NativeExport: Codable {
        let format: String
        let version: Int
        let rules: [Rule]
    }

    public static func readFile(at url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK)
        guard descriptor >= 0 else { throw RuleTransferError.invalidNativeFile }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_size >= 0, info.st_size <= Int64(maximumFileSize) else { throw RuleTransferError.invalidNativeFile }
        var data = Data()
        while data.count <= maximumFileSize {
            guard let chunk = try file.read(upToCount: min(64 * 1024, maximumFileSize + 1 - data.count)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= maximumFileSize else { throw RuleTransferError.invalidNativeFile }
        return data
    }

    public static func exportForel(_ rules: [Rule]) throws -> Data {
        let sanitized = rules.map { source in
            var rule = source
            rule.conditions = source.conditions.map { clearPDFCredentials($0, depth: 0) }
            rule.actions = source.actions.map { clearUploadServer($0) }
            return rule
        }
        let export = NativeExport(format: "forel-rules", version: 1, rules: sanitized)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(export)
        guard data.count <= maximumFileSize, nativeJSONWithinLimits(data) else { throw RuleTransferError.invalidNativeFile }
        return data
    }

    public static func importRules(from data: Data, folderId: String) throws -> RuleImportResult {
        let content = data.starts(with: [0xef, 0xbb, 0xbf]) ? data.dropFirst(3) : data[...]
        let isJSON = content.drop { [0x20, 0x09, 0x0a, 0x0d].contains($0) }.first.map { $0 == 0x7b || $0 == 0x5b } ?? false
        guard data.count <= maximumFileSize else {
            throw isJSON ? RuleTransferError.invalidNativeFile : RuleTransferError.unsupportedFile
        }
        if isJSON {
            guard nativeJSONWithinLimits(data), let native = try? JSONDecoder().decode(NativeExport.self, from: data) else {
                throw RuleTransferError.invalidNativeFile
            }
            guard native.format == "forel-rules", native.version == 1 else {
                throw RuleTransferError.invalidNativeFile
            }
            var issues: [RuleTransferIssue] = []
            let rules = native.rules.map { source in
                let needsPassword = source.conditions.contains { containsPDFPasswordCondition($0, depth: 0) }
                let needsServer = source.actions.contains { $0.kind == .upload }
                if needsPassword { issues.append(.init(ruleName: source.name, message: "Save the PDF password again before enabling this imported rule.")) }
                if needsServer { issues.append(.init(ruleName: source.name, message: "Choose a saved upload server before enabling this imported rule.")) }
                var copy = source
                copy.conditions = source.conditions.map { clearPDFCredentials($0, depth: 0) }
                copy.actions = source.actions.map { clearUploadServer($0) }
                return remap(copy, folderId: folderId, disabled: needsPassword || needsServer)
            }
            return RuleImportResult(rules: rules, issues: issues)
        }
        return try importHazel(data: data, folderId: folderId)
    }

    private static func clearUploadServer(_ action: Action) -> Action {
        guard action.kind == .upload, case .object(var params) = action.params else { return action }
        let allowed = Set(["upload_remote_path", ActionParam.onConflict, ActionParam.folderStructure])
        params = params.filter { allowed.contains($0.key) }
        var copy = action
        copy.params = .object(params)
        return copy
    }

    private static func nativeJSONWithinLimits(_ data: Data) -> Bool {
        // Bound depth before invoking any recursive Foundation or Codable parser.
        var depth = 0
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped { escaped = false }
                else if byte == 0x5c { escaped = true }
                else if byte == 0x22 { inString = false }
            } else if byte == 0x22 { inString = true }
            else if byte == 0x7b || byte == 0x5b {
                depth += 1
                if depth > 64 { return false }
            } else if byte == 0x7d || byte == 0x5d {
                depth -= 1
                if depth < 0 { return false }
            }
        }
        guard !inString, depth == 0, let root = try? JSONSerialization.jsonObject(with: data) else { return false }
        var pending: [Any] = [root]
        var nodes = 0
        while let value = pending.popLast() {
            nodes += 1
            if nodes > 100_000 { return false }
            if let object = value as? [String: Any] {
                guard nodes + pending.count + object.count <= 100_000 else { return false }
                pending.append(contentsOf: object.values)
            } else if let array = value as? [Any] {
                guard nodes + pending.count + array.count <= 100_000 else { return false }
                pending.append(contentsOf: array)
            }
        }
        return true
    }

    private static func containsPDFPasswordCondition(_ condition: Condition, depth: Int) -> Bool {
        if condition.kind == .contentsWithPassword { return true }
        if depth < 16, condition.kind == .peerRanking, let ranking = PeerRankingCondition.decode(condition.value) {
            return ranking.filters.contains { containsPDFPasswordCondition($0, depth: depth + 1) }
        }
        guard depth < 16, condition.kind == .conditionGroup, let group = ConditionGroup.decode(condition.value) else { return false }
        return group.conditions.contains { containsPDFPasswordCondition($0, depth: depth + 1) }
    }

    private static func clearPDFCredentials(_ condition: Condition, depth: Int) -> Condition {
        var copy = condition
        if condition.kind == .contentsWithPassword {
            var spec = PasswordContentCondition.decode(condition.value) ?? PasswordContentCondition()
            spec.credentialID = ""; copy.value = spec.encoded
        } else if depth < 16, condition.kind == .peerRanking, var ranking = PeerRankingCondition.decode(condition.value) {
            ranking.filters = ranking.filters.map { clearPDFCredentials($0, depth: depth + 1) }
            copy.value = ranking.encoded
        } else if depth < 16, condition.kind == .conditionGroup, var group = ConditionGroup.decode(condition.value) {
            group.conditions = group.conditions.map { clearPDFCredentials($0, depth: depth + 1) }
            copy.value = group.encoded
        }
        return copy
    }

    private static func remap(_ source: Rule, folderId: String, disabled: Bool = false) -> Rule {
        let id = UUID().uuidString
        var rule = Rule(
            id: id,
            folderId: folderId,
            name: source.name,
            enabled: source.enabled && !disabled && source.importError == nil,
            conditionMatch: source.conditionMatch,
            recursionDepth: source.recursionDepth,
            priority: source.priority,
            importError: source.importError,
            isHazelImported: source.isHazelImported
        )
        func remapCondition(_ condition: Condition, depth: Int) -> Condition {
            var value = condition.value
            if depth < 16, condition.kind == .conditionGroup, var group = ConditionGroup.decode(value) {
                group.conditions = group.conditions.map { remapCondition($0, depth: depth + 1) }
                value = group.encoded
            } else if depth < 16, condition.kind == .peerRanking, var ranking = PeerRankingCondition.decode(value) {
                ranking.filters = ranking.filters.map { remapCondition($0, depth: depth + 1) }
                value = ranking.encoded
            }
            return Condition(ruleId: id, kind: condition.kind, operator: condition.operator, value: value)
        }
        rule.conditions = source.conditions.map { remapCondition($0, depth: 0) }
        rule.actions = source.actions.map {
            Action(ruleId: id, kind: $0.kind, params: $0.params, position: $0.position)
        }
        return rule
    }

    static func remapForCopy(_ source: Rule, folderId: String) -> Rule {
        remap(source, folderId: folderId)
    }

    private static func importHazel(data: Data, folderId: String) throws -> RuleImportResult {
        let archive = try HazelArchive(data: data)
        guard let root = archive.root,
              let archivedRules = archive.array(root["rules"]) else {
            throw RuleTransferError.unsupportedFile
        }

        var rules: [Rule] = []
        var issues: [RuleTransferIssue] = []
        for archivedRule in archivedRules {
            guard let object = archivedRule as? [String: Any],
                  ["HazelRule", "ComNoodlesoft_HazelRule"].contains(archive.className(object) ?? ""),
                  let name = archive.string(object["description"]), !name.isEmpty else {
                throw RuleTransferError.unsupportedFile
            }

            var localIssues: [RuleTransferIssue] = []
            var blockingIssues: [String] = []
            func block(_ message: String) {
                localIssues.append(.init(ruleName: name, message: message))
                blockingIssues.append(message)
            }
            var source = Rule(folderId: folderId, name: name, enabled: false)
            source.isHazelImported = true
            let knownRuleFields: Set<String> = ["$class", "__class", "description", "predicateType", "predicateTarget", "criteria", "actions", "customAttributes", "dateLastModified", "identifier", "isActive", "note", "options"]
            for key in object.keys.filter({ !knownRuleFields.contains($0) }).sorted() {
                block("Unrecognized Hazel rule field \(key) was not imported.")
            }
            localIssues.append(.init(ruleName: name, message: "Review this imported rule before enabling it; Hazel behavior may differ."))
            switch archive.number(object["predicateType"]) {
            case 1: source.conditionMatch = .all
            case 2: source.conditionMatch = .any
            default:
                block("Unsupported Hazel condition matching mode.")
            }
            if let target = archive.number(object["predicateTarget"]), target != 0 {
                block("Unsupported Hazel rule condition target.")
            }

            let criteria = archive.array(object["criteria"]) ?? []
            let captures = criteria.compactMap { hazelCapturePattern($0, archive: archive) }
            if archive.array(object["criteria"]) == nil { block("The Hazel conditions could not be read.") }
            for criterion in criteria {
                for field in unknownConditionFields(criterion, archive: archive) {
                    block("Unrecognized Hazel condition field \(field) was not imported.")
                }
                if let condition = hazelCondition(criterion, archive: archive, ruleId: source.id) {
                    source.conditions.append(condition)
                    if containsScriptCondition(condition) {
                        localIssues.append(.init(ruleName: name, message: "Review the imported condition script; it runs during previews and can change files."))
                    }
                    let contentWarning = "Review content matches: Forel and Hazel may extract or index text differently."
                    if condition.kind == .contents, !localIssues.contains(where: { $0.message == contentWarning }) {
                        localIssues.append(.init(ruleName: name, message: contentWarning))
                    }
                    let dateWarning = "Last-opened dates use macOS metadata; an unavailable date is treated as never opened."
                    if condition.kind == .dateLastOpened, !localIssues.contains(where: { $0.message == dateWarning }) {
                        localIssues.append(.init(ruleName: name, message: dateWarning))
                    }
                } else {
                    let object = criterion as? [String: Any]
                    let key = archive.findString(object?["NSLeftExpression"], key: "NSKeyPath")
                    let detail = key.map { " (\($0))" } ?? ""
                    block("Unsupported Hazel condition\(detail) was skipped.")
                }
            }

            if let rawOptions = object["options"] {
                if let options = rawOptions as? [String: Any],
                   archive.className(options)?.hasSuffix("HazelRuleOptions") == true {
                    let known: Set<String> = ["$class", "__class", "textRecognition", "documentPassword", "hasStoredDocumentPasswordStored"]
                    for key in options.keys.filter({ !known.contains($0) }).sorted() {
                        block("Unrecognized Hazel rule option \(key) was not imported.")
                    }
                    if options["documentPassword"] != nil || (options["hasStoredDocumentPasswordStored"] as? Bool) == true {
                        block("Hazel document passwords cannot be imported.")
                    }
                    if let recognition = options["textRecognition"] {
                        if ![0, 1, 2].contains(archive.number(recognition) ?? -1) {
                            block("Unrecognized Hazel text recognition option.")
                        } else if source.conditions.contains(where: { containsContentsCondition($0) }) {
                            block("Hazel text recognition option requires review and is not yet imported.")
                        }
                    }
                } else { block("The Hazel rule options could not be read.") }
            }

            for (position, archivedAction) in (archive.array(object["actions"]) ?? []).enumerated() {
                if let raw = archivedAction as? [String: Any] {
                    let knownActionFields: Set<String> = ["$class", "__class", "options", "parameter"]
                    for key in raw.keys.filter({ !knownActionFields.contains($0) }).sorted() {
                        block("Unrecognized Hazel action field \(key) was not imported.")
                    }
                }
                if var action = hazelAction(archivedAction, archive: archive, ruleId: source.id, position: position) {
                    if case .object(var params) = action.params, params[HazelPattern.tokensKey] != nil {
                        if captures.count == 1, source.conditionMatch == .all, let capture = captures.first {
                            params[HazelPattern.regexKey] = .string(capture.regex)
                        }
                        if !captures.isEmpty {
                            let names = captures.flatMap(\.names).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                            params[HazelPattern.namesKey] = .stringArray(names)
                        }
                        let names = (params[HazelPattern.tokensKey]?.arrayValue ?? []).compactMap { token -> String? in
                            token["type"]?.stringValue == "capture" ? token["value"]?.stringValue : nil
                        }
                        if names.contains(where: { !(captures.flatMap(\.names).contains($0)) }) {
                            block("A Hazel pattern refers to a missing capture.")
                        }
                        let outputs = source.conditions.flatMap { scriptOutputs($0) } + source.actions.flatMap { ($0.params[ActionParam.osaOutputs]?.arrayValue ?? []).compactMap(\.stringValue) }
                        let attributes = (params[HazelPattern.tokensKey]?.arrayValue ?? []).compactMap { token in
                            token["type"]?.stringValue == "attribute" ? token["value"]?.stringValue : (token["type"]?.stringValue == "attributeDate" ? token["source"]?.stringValue : nil)
                        }
                        if attributes.contains(where: { !outputs.contains($0) }) {
                            block("A Hazel pattern refers to an unavailable script attribute.")
                        }
                        action.params = .object(params)
                    }
                    source.actions.append(action)
                    if (action.kind == .moveToFolder && action.params[HazelPattern.sortKey]?.boolValue != true) || action.kind == .moveToTrash {
                        if action.kind == .moveToFolder {
                            localIssues.append(.init(ruleName: name, message: "Check the move destination and conflict behavior before enabling this rule."))
                        }
                        if let rawAction = archivedAction as? [String: Any],
                           let options = archive.dictionary(rawAction["options"]) {
                            for (key, value) in options.sorted(by: { $0.key < $1.key }) {
                                let represented = archive.number(value) == 0 ||
                                    (action.kind == .moveToFolder && key == "throwAwayDupes" && archive.number(value) == 1) ||
                                    (action.kind == .moveToFolder && key == "replaceExisting" && [1.0, 2.0].contains(archive.number(value) ?? -1)) ||
                                    (action.kind == .moveToFolder && key == "keepFolderStructure" && [1.0, 2.0, 3.0].contains(archive.number(value) ?? -1))
                                if !["throwAwayDupes", "replaceExisting", "keepFolderStructure"].contains(key) || !represented {
                                    block("Hazel move option \(key) was not imported.")
                                }
                            }
                        } else if let rawAction = archivedAction as? [String: Any], rawAction["options"] != nil {
                            block("Hazel move options could not be read.")
                        }
                    }
                    if action.kind == .syncToFolder {
                        localIssues.append(.init(ruleName: name, message: "Check the sync destination before enabling; syncing a folder deletes items missing from the source."))
                    }
                    if action.kind == .setFinderLabel {
                        localIssues.append(.init(ruleName: name, message: "Review imported color labels and Finder tag names before enabling this rule."))
                    }
                    if action.kind == .runHazelAppleScript {
                        localIssues.append(.init(ruleName: name, message: "Review the imported AppleScript before enabling it; scripts can control apps and change files."))
                    }
                    if action.kind == .runHazelOSA {
                        localIssues.append(.init(ruleName: name, message: "Review the imported script and its input and output attributes before enabling this rule."))
                    }
                    if action.kind == .runHazelShellScript {
                        localIssues.append(.init(ruleName: name, message: "Review the imported shell script and interpreter before enabling it; scripts can change files and run programs."))
                    }
                    if action.kind == .rename, let rawAction = archivedAction as? [String: Any], rawAction["options"] != nil,
                       archive.dictionary(rawAction["options"])?.isEmpty != true {
                        block("Hazel rename options could not be imported.")
                    }
                } else {
                    let type = archive.className(archivedAction as? [String: Any]) ?? "unknown action"
                    block("Hazel action \(type) was skipped because Forel cannot represent it.")
                }
            }

            if let declarations = object["customAttributes"] {
                if let items = archive.array(declarations) {
                    let outputs = source.conditions.flatMap { scriptOutputs($0) } + source.actions.flatMap { ($0.params[ActionParam.osaOutputs]?.arrayValue ?? []).compactMap(\.stringValue) }
                    for item in items {
                        guard let token = item as? [String: Any], validCustomDeclaration(token, archive: archive, outputs: outputs, captures: captures.flatMap(\.names)) else {
                            block("A Hazel custom attribute declaration is unsupported or contains unrecognized settings.")
                            continue
                        }
                    }
                } else { block("Hazel custom attribute declarations could not be read.") }
            }
            if criteria.isEmpty {
                localIssues.append(.init(ruleName: name, message: "The Hazel rule has no conditions and matches every file."))
            }
            if source.actions.isEmpty {
                block("The Hazel rule has no supported actions.")
            }
            source.importError = blockingIssues.isEmpty ? nil : blockingIssues.joined(separator: "\n")
            source = remap(source, folderId: folderId, disabled: !localIssues.isEmpty)
            rules.append(source)
            issues.append(contentsOf: localIssues)
        }
        guard !rules.isEmpty else { throw RuleTransferError.unsupportedFile }
        return RuleImportResult(rules: rules, issues: issues)
    }

    private static func validCustomDeclaration(_ token: [String: Any], archive: HazelArchive, outputs: [String], captures: [String]) -> Bool {
        let known: Set<String> = ["$class", "__class", "alternateFormatIndex", "textReplacements", "sourceToken", "customTokenType", "case", "valueAdjustment", "integerDigits", "listSelection", "identifier", "defaultValue", "autodetect", "subTokens", "name", "isCaptureToken"]
        guard token.keys.allSatisfy({ known.contains($0) }),
              archive.className(token)?.hasSuffix("HazelMatchToken") == true,
              let name = archive.string(token["name"]), name.hasPrefix("hazelcustomtoken:"),
              (token["isCaptureToken"] as? Bool) == true,
              (token["autodetect"] as? Bool) == false,
              archive.number(token["case"]) == 0, archive.number(token["alternateFormatIndex"]) == 0,
              archive.number(token["integerDigits"]) == 0,
              let selection = archive.number(token["listSelection"]), selection == -2 || selection == Double(Int64.max),
              ["textReplacements", "valueAdjustment", "sourceToken", "defaultValue"].allSatisfy({ token[$0] == nil }) else { return false }
        if archive.number(token["customTokenType"]) == 1, captures.contains(name) {
            return plainCaptureRegex(token, archive: archive) != nil
        }
        return [0.0, 2.0].contains(archive.number(token["customTokenType"]) ?? -1) && token["subTokens"] == nil && outputs.contains(name)
    }

    private static func hazelCondition(_ raw: Any, archive: HazelArchive, ruleId: String, level: Int = 0) -> Condition? {
        guard level < 16, let predicate = raw as? [String: Any] else { return nil }
        let className = archive.className(predicate) ?? ""
        if className == "NSTruePredicate" {
            return Condition(ruleId: ruleId, kind: .anyFile, operator: .is, value: "")
        }
        if className == "NSComparisonPredicate" {
            let known: Set<String> = ["$class", "__class", "NSLeftExpression", "NSRightExpression", "NSPredicateOperator"]
            guard predicate.keys.allSatisfy({ known.contains($0) }) else { return nil }
        }
        if ["NSCompoundPredicate", "HazelCompoundPredicate", "ComNoodlesoft_HazelCompoundPredicate"].contains(className) {
            let known: Set<String> = ["$class", "__class", "NSCompoundPredicateType", "NSSubpredicates", "predicateTarget"]
            guard predicate.keys.allSatisfy({ known.contains($0) }) else { return nil }
            if let target = archive.number(predicate["predicateTarget"]), target != 0 { return nil }
            guard let type = archive.number(predicate["NSCompoundPredicateType"]),
                  let children = archive.array(predicate["NSSubpredicates"]), !children.isEmpty, children.count <= 1000,
                  type != 0 || children.count == 1 else { return nil }
            let match: ConditionGroup.Match
            switch type {
            case 0: match = .none
            case 1: match = .all
            case 2: match = .any
            default: return nil
            }
            let parsed = children.compactMap { hazelCondition($0, archive: archive, ruleId: ruleId, level: level + 1) }
            guard parsed.count == children.count else { return nil }
            let group = ConditionGroup(match: match, conditions: parsed)
            return Condition(ruleId: ruleId, kind: .conditionGroup, operator: .is, value: group.encoded)
        }
        guard
              let key = archive.findString(predicate["NSLeftExpression"], key: "NSKeyPath"),
              let operatorData = predicate["NSPredicateOperator"] as? [String: Any],
              let kind = hazelConditionKind(key) else { return nil }

        if key == "currentDateProxy", archive.className(operatorData) == "NSCustomPredicateOperator",
           archive.string(operatorData["NSSelectorName"]) == "matchesRecurrence:",
           archive.number(operatorData["NSOperatorType"]) == 11, archive.number(operatorData["NSModifier"]) == 0,
           (operatorData["NSNegate"] as? Bool) != true,
           let right = predicate["NSRightExpression"] as? [String: Any],
           let recurrence = right["NSConstantValue"] as? [String: Any],
           archive.className(recurrence)?.hasSuffix("HazelTimeRecurrence") == true,
           recurrence["months"] == nil, archive.number(recurrence["day"]) == 1,
           let weekdays = recurrence["daysOfTheWeek"] as? [String: Any], archive.number(weekdays["NSRangeCount"]) == 0,
           let monthdays = recurrence["daysOfTheMonth"] as? [String: Any], archive.number(monthdays["NSRangeCount"]) == 0,
           let hour = archive.number(recurrence["hour"]), hour.isFinite, hour.rounded(.towardZero) == hour, (0...23).contains(hour),
           let minute = archive.number(recurrence["minute"]), minute.isFinite, minute.rounded(.towardZero) == minute, (0...59).contains(minute) {
            return Condition(ruleId: ruleId, kind: .currentTime, operator: .is,
                             value: String(format: "%02d:%02d", Int(hour), Int(minute)))
        }

        if key == "shellScript", archive.className(operatorData) == "NSCustomPredicateOperator",
           archive.string(operatorData["NSSelectorName"]) == "passesShellScript:",
           archive.number(operatorData["NSOperatorType"]) == 11, archive.number(operatorData["NSModifier"]) == 0,
           (operatorData["NSNegate"] as? Bool) != true,
           let right = predicate["NSRightExpression"] as? [String: Any],
           let script = right["NSConstantValue"] as? [String: Any],
           ["HazelShellScript", "ComNoodlesoft_HazelShellScript"].contains(archive.className(script) ?? ""),
           let interpreter = archive.string(script["shell"]), interpreter.hasPrefix("/"), !interpreter.contains("\0"),
           let source = archive.string(script["script"]) ?? (script["script"] as? [String: Any]).flatMap({ archive.string($0["NS.data"]) }),
           !source.isEmpty, source.utf8.count <= 1_000_000, !source.contains("\0") {
            let spec = HazelScriptCondition(language: .shell, source: source, interpreter: interpreter)
            return Condition(ruleId: ruleId, kind: .hazelScriptCondition, operator: .is, value: spec.encoded)
        }

        if ["subfolderLevel", "subitemCount"].contains(key),
           archive.number(operatorData["NSModifier"]) == 0,
           archive.number(operatorData["NSOptions"]) == 3,
           (operatorData["NSNegate"] as? Bool) != true,
           let right = predicate["NSRightExpression"] as? [String: Any],
           let value = archive.number(right["NSConstantValue"]), value.isFinite,
           value >= 0, value <= 1_000_000, value.rounded(.towardZero) == value,
           let type = archive.number(operatorData["NSOperatorType"]),
           (([0, 2].contains(type) && archive.className(operatorData) == "NSComparisonPredicateOperator" && archive.number(operatorData["NSVariant"]) == 0) ||
            ([4, 5].contains(type) && archive.className(operatorData) == "NSEqualityPredicateOperator")) {
            let op: Operator = type == 0 ? .lessThan : type == 2 ? .greaterThan : type == 4 ? .is : .isNot
            return Condition(ruleId: ruleId, kind: key == "subfolderLevel" ? .subfolderDepth : .subfileCount,
                             operator: op, value: "\(Int(value))")
        }

        if key == "finderLocked", archive.number(operatorData["NSModifier"]) == 0,
           archive.string(operatorData["NSSelectorName"]) == nil,
           let type = archive.number(operatorData["NSOperatorType"]), type == 4 || type == 5,
           let right = predicate["NSRightExpression"] as? [String: Any],
           let value = archive.number(right["NSConstantValue"]), value == 0 || value == 1 {
            return Condition(ruleId: ruleId, kind: .locked, operator: type == 4 ? .is : .isNot,
                             value: value == 1 ? "true" : "false")
        }

        if key == "finderComment", archive.className(operatorData) == "NSCustomPredicateOperator",
           archive.string(operatorData["NSSelectorName"]) == "hazelIsEmpty:",
           archive.number(operatorData["NSOperatorType"]) == 11, archive.number(operatorData["NSModifier"]) == 0 {
            return Condition(ruleId: ruleId, kind: .finderComment,
                             operator: (operatorData["NSNegate"] as? Bool) == true ? .isNotBlank : .isBlank, value: "")
        }

        if key == "dateMatched", archive.className(operatorData) == "NSCustomPredicateOperator",
           archive.string(operatorData["NSSelectorName"]) == "hazelIsEmpty:",
           archive.number(operatorData["NSOperatorType"]) == 11, archive.number(operatorData["NSModifier"]) == 0 {
            return Condition(ruleId: ruleId, kind: .dateLastMatched,
                             operator: (operatorData["NSNegate"] as? Bool) == true ? .isNotBlank : .isBlank, value: "")
        }
        if key == "finderComment", archive.className(operatorData) == "NSCustomPredicateOperator",
           archive.string(operatorData["NSSelectorName"]) == "hazelContainsObject:",
           archive.number(operatorData["NSOperatorType"]) == 11, archive.number(operatorData["NSModifier"]) == 0,
           (operatorData["NSNegate"] as? Bool) != true,
           let value = archive.constantString(predicate["NSRightExpression"]) {
            return Condition(ruleId: ruleId, kind: .finderComment, operator: .containsInsensitive, value: value)
        }

        if key == "typeObject",
           archive.string(operatorData["NSSelectorName"]) == "isType:",
           archive.number(operatorData["NSOperatorType"]) == 11,
           archive.number(operatorData["NSModifier"]) == 0,
           (operatorData["NSNegate"] as? Bool) != true,
           let value = archive.constantString(predicate["NSRightExpression"]) {
            if value.hasPrefix("public.") || value.hasPrefix("com.apple.") || (value.hasPrefix("hazelkind:") && value.count > "hazelkind:".count) {
                return Condition(ruleId: ruleId, kind: .contentType, operator: .is, value: value)
            }
        }

        if key == "displayBasename",
           archive.className(operatorData) == "NSEqualityPredicateOperator",
           archive.number(operatorData["NSModifier"]) == 0,
           archive.number(operatorData["NSOptions"]) == 3,
           let value = archive.constantString(predicate["NSRightExpression"]),
           let type = archive.number(operatorData["NSOperatorType"]),
           (type == 4 || type == 5) {
            return Condition(ruleId: ruleId, kind: .nameInsensitive,
                             operator: type == 4 ? .is : .isNot, value: value)
        }

        if key == "displayName", archive.number(operatorData["NSModifier"]) == 0,
           (operatorData["NSNegate"] as? Bool) != true,
           let value = archive.constantString(predicate["NSRightExpression"]) {
            if archive.className(operatorData) == "NSEqualityPredicateOperator",
               archive.number(operatorData["NSOptions"]) == 3,
               let type = archive.number(operatorData["NSOperatorType"]), type == 4 || type == 5 {
                return Condition(ruleId: ruleId, kind: .fullNameInsensitive, operator: type == 4 ? .is : .isNot, value: value)
            }
            if archive.className(operatorData) == "NSCustomPredicateOperator",
               archive.number(operatorData["NSOperatorType"]) == 11,
               let selector = archive.string(operatorData["NSSelectorName"]),
               selector == "hazelContainsObject:" || selector == "hazelStartsWithString:" {
                return Condition(ruleId: ruleId, kind: .fullNameInsensitive,
                                 operator: selector == "hazelContainsObject:" ? .contains : .startsWith, value: value)
            }
        }

        if key == "displayBasename",
           archive.className(operatorData) == "NSCustomPredicateOperator",
           archive.string(operatorData["NSSelectorName"]) == "hazelContainsObject:",
           archive.number(operatorData["NSModifier"]) == 0,
           let value = archive.constantString(predicate["NSRightExpression"]) {
            return Condition(ruleId: ruleId, kind: .nameInsensitive, operator: .contains, value: value)
        }

        if key == "displayBasename",
           archive.className(operatorData) == "NSCustomPredicateOperator",
           archive.string(operatorData["NSSelectorName"]) == "hazelStartsWithString:",
           archive.number(operatorData["NSModifier"]) == 0,
           archive.number(operatorData["NSOperatorType"]) == 11,
           (operatorData["NSNegate"] as? Bool) != true,
           let value = archive.constantString(predicate["NSRightExpression"]) {
            return Condition(ruleId: ruleId, kind: .nameInsensitive, operator: .startsWith, value: value)
        }

        if key == "displayBasename",
           archive.className(operatorData) == "NSSubstringPredicateOperator",
           archive.number(operatorData["NSModifier"]) == 0,
           archive.number(operatorData["NSFlags"]) == 3,
           (operatorData["NSPosition"] == nil || archive.number(operatorData["NSPosition"]) == 0),
           archive.number(operatorData["NSOperatorType"]) == 8,
           let value = archive.constantString(predicate["NSRightExpression"]) {
            return Condition(ruleId: ruleId, kind: .nameInsensitive, operator: .startsWith, value: value)
        }

        if let capture = hazelCapturePattern(raw, archive: archive) {
            guard capture.names.allSatisfy({ !$0.contains(",") }) else { return nil }
            var custom = CustomTextCondition(); custom.names = capture.names.joined(separator: ","); custom.pattern = capture.regex
            return Condition(ruleId: ruleId, kind: .customTextMatch, operator: .is, value: custom.encoded)
        }
        if key == "displayExtensions",
           archive.className(operatorData) == "NSEqualityPredicateOperator",
           archive.number(operatorData["NSModifier"]) == 2,
           archive.number(operatorData["NSOptions"]) == 3,
           archive.number(operatorData["NSOperatorType"]) == 4,
           (operatorData["NSNegate"] as? Bool) != true,
           let value = archive.constantString(predicate["NSRightExpression"]),
           !value.isEmpty, value != ".", !value.dropFirst().contains(".") {
            return Condition(ruleId: ruleId, kind: .extensionInsensitive, operator: .is, value: value)
        }

        if key == "textContent",
           archive.className(operatorData) == "NSCustomPredicateOperator",
           archive.string(operatorData["NSSelectorName"]) == "containsText:",
           archive.number(operatorData["NSModifier"]) == 0,
           archive.number(operatorData["NSOperatorType"]) == 11,
           (operatorData["NSNegate"] as? Bool) != true,
           let value = archive.constantString(predicate["NSRightExpression"]), !value.isEmpty {
            return Condition(ruleId: ruleId, kind: .contents, operator: .containsInsensitive, value: value)
        }

        if ["dateAdded", "dateCreated", "dateModified", "dateAccessed", "dateMatched"].contains(key),
           archive.string(operatorData["NSSelectorName"]) == "hazelIsInTheLast:",
           archive.number(operatorData["NSModifier"]) == 0,
           (operatorData["NSNegate"] as? Bool) != true,
           let right = predicate["NSRightExpression"] as? [String: Any],
           let duration = right["NSConstantValue"] as? [String: Any],
           let amount = archive.number(duration["amount"]), amount.isFinite,
           amount >= 0, amount <= 1_000_000, amount.rounded(.towardZero) == amount,
           let unit = duration["unit"] as? [String: Any],
           let dimension = archive.string(unit["dimension"]),
           let unitName = archive.string(unit["name"])?.lowercased(),
           ((dimension == "time" && ["minute", "hour", "day", "week"].contains(unitName)) ||
            (dimension == "calendar" && unitName == "month")) {
            return Condition(ruleId: ruleId, kind: kind, operator: .hazelWithinLast, value: "\(Int(amount)) \(unitName)")
        }

        if ["dateAdded", "dateCreated", "dateModified", "dateAccessed", "dateMatched"].contains(key),
           archive.className(operatorData) == "NSComparisonPredicateOperator",
           archive.number(operatorData["NSOperatorType"]) == 0,
           archive.number(operatorData["NSModifier"]) == 0,
           archive.number(operatorData["NSVariant"]) == 0,
           archive.findString(predicate["NSRightExpression"], key: "NSKeyPath") == "today" {
            return Condition(ruleId: ruleId, kind: kind, operator: .beforeToday, value: "")
        }

        if ["dateAdded", "dateCreated", "dateModified", "dateAccessed", "dateMatched"].contains(key),
           archive.number(operatorData["NSModifier"]) == 0,
           archive.number(operatorData["NSOptions"]) == 3,
           archive.className(predicate["NSRightExpression"] as? [String: Any]) == "NSKeyPathExpression",
           let period = archive.findString(predicate["NSRightExpression"], key: "NSKeyPath"),
           ["thisWeek", "thisMonth"].contains(period) {
            let op: Operator?
            if archive.className(operatorData) == "NSComparisonPredicateOperator",
               archive.number(operatorData["NSOperatorType"]) == 0,
               archive.number(operatorData["NSVariant"]) == 0,
               (operatorData["NSNegate"] as? Bool) != true {
                op = period == "thisWeek" ? .beforeThisWeek : .beforeThisMonth
            } else if archive.className(operatorData) == "NSEqualityPredicateOperator",
                      archive.number(operatorData["NSOperatorType"]) == 5,
                      (operatorData["NSNegate"] as? Bool) == true {
                op = period == "thisWeek" ? .notThisWeek : .notThisMonth
            } else {
                op = nil
            }
            if let op { return Condition(ruleId: ruleId, kind: kind, operator: op, value: "") }
        }

        if key == "dateAccessed",
           archive.className(operatorData) == "NSComparisonPredicateOperator",
           archive.number(operatorData["NSModifier"]) == 0,
           archive.number(operatorData["NSOptions"]) == 3,
           archive.number(operatorData["NSOperatorType"]) == 2,
           archive.number(operatorData["NSVariant"]) == 2,
           (operatorData["NSNegate"] as? Bool) != true,
           archive.className(predicate["NSRightExpression"] as? [String: Any]) == "NSKeyPathExpression",
           archive.findString(predicate["NSRightExpression"], key: "NSKeyPath") == "dateModified" {
            return Condition(ruleId: ruleId, kind: .dateLastOpened, operator: .afterLastModified, value: "")
        }

        if key == "dateMatched", archive.className(operatorData) == "NSComparisonPredicateOperator",
           archive.number(operatorData["NSModifier"]) == 0, archive.number(operatorData["NSOptions"]) == 3,
           archive.number(operatorData["NSOperatorType"]) == 0, archive.number(operatorData["NSVariant"]) == 0,
           (operatorData["NSNegate"] as? Bool) != true,
           archive.className(predicate["NSRightExpression"] as? [String: Any]) == "NSKeyPathExpression",
           archive.findString(predicate["NSRightExpression"], key: "NSKeyPath") == "dateModified" {
            return Condition(ruleId: ruleId, kind: .dateLastMatched, operator: .beforeLastModified, value: "")
        }

        guard let value = archive.constantString(predicate["NSRightExpression"]),
              let operatorType = archive.number(operatorData["NSOperatorType"]) else { return nil }
        let negated = (operatorData["NSNegate"] as? Bool) == true
        if key == "displayExtension",
           archive.className(operatorData) == "NSCustomPredicateOperator",
           archive.string(operatorData["NSSelectorName"]) == "hazelContainsObject:",
           archive.number(operatorData["NSModifier"]) == 0 {
            return Condition(ruleId: ruleId, kind: .extension_, operator: .contains, value: value)
        }
        // Hazel's custom selectors, modifiers and comparison options cannot
        // generally be represented by Forel's operators. Only map the scalar
        // extension equality seen in real exports; leave the rest for review.
        guard key == "displayExtension", archive.string(operatorData["NSSelectorName"]) == nil,
              archive.number(operatorData["NSModifier"]) == 0, operatorType == 4 else { return nil }
        let op: Operator?
        switch operatorType {
        case 4: op = negated ? .isNot : .is
        default: op = nil
        }
        guard let op else { return nil }
        return Condition(ruleId: ruleId, kind: kind, operator: op, value: value)
    }

    private static func hazelConditionKind(_ key: String) -> ConditionKind? {
        switch key {
        case "displayBasename": return .name
        case "displayName": return .fullName
        case "currentDateProxy": return .currentTime
        case "shellScript": return .hazelScriptCondition
        case "typeObject": return .contentType
        case "displayExtension", "displayExtensions", "extension": return .extension_
        case "dateCreated": return .createdAt
        case "dateModified": return .dateModified
        case "dateAdded": return .dateAdded
        case "dateAccessed": return .dateLastOpened
        case "dateMatched": return .dateLastMatched
        case "textContent": return .contents
        case "fileSize", "logicalSize": return .sizeBytes
        case "subfolderLevel": return .subfolderDepth
        case "subitemCount": return .subfileCount
        case "finderLocked": return .locked
        case "comment", "finderComment": return .finderComment
        case "path", "filePath": return ConditionKind(rawValue: "file_path")
        case "tags", "tagNames": return .tags
        default: return nil
        }
    }

    private static func containsScriptCondition(_ condition: Condition, level: Int = 0) -> Bool {
        if condition.kind == .hazelScriptCondition { return true }
        guard level < 16, condition.kind == .conditionGroup, let group = ConditionGroup.decode(condition.value) else { return false }
        return group.conditions.contains { containsScriptCondition($0, level: level + 1) }
    }

    private static func containsContentsCondition(_ condition: Condition, level: Int = 0) -> Bool {
        if condition.kind == .contents || condition.kind == .contentsWithoutOCR { return true }
        guard level < 16, condition.kind == .conditionGroup, let group = ConditionGroup.decode(condition.value) else { return false }
        return group.conditions.contains { containsContentsCondition($0, level: level + 1) }
    }

    private static func scriptOutputs(_ condition: Condition, level: Int = 0) -> [String] {
        if condition.kind == .hazelScriptCondition { return HazelScriptCondition.decode(condition.value)?.outputNames ?? [] }
        guard level < 16, condition.kind == .conditionGroup, let group = ConditionGroup.decode(condition.value) else { return [] }
        return group.conditions.flatMap { scriptOutputs($0, level: level + 1) }
    }

    private static func unknownConditionFields(_ raw: Any, archive: HazelArchive, level: Int = 0) -> [String] {
        guard level < 16, let predicate = raw as? [String: Any] else { return [] }
        let type = archive.className(predicate) ?? ""
        let common: Set<String> = ["$class", "__class"]
        var unknown: [String] = []
        if type == "NSTruePredicate" {
            unknown += predicate.keys.filter { !common.contains($0) }.map { "predicate.\($0)" }
        } else if type == "NSComparisonPredicate" || predicate["NSPredicateOperator"] != nil {
            let known = common.union(["NSLeftExpression", "NSRightExpression", "NSPredicateOperator"])
            unknown += predicate.keys.filter { !known.contains($0) }.map { "predicate.\($0)" }
            if let op = predicate["NSPredicateOperator"] as? [String: Any] {
                let knownOperator = common.union(["NSSelectorName", "NSModifier", "NSFlags", "NSOptions", "NSOperatorType", "NSNegate", "NSVariant", "NSPosition"])
                unknown += op.keys.filter { !knownOperator.contains($0) }.map { "operator.\($0)" }
            }
        } else if type.hasSuffix("CompoundPredicate") {
            let known = common.union(["NSCompoundPredicateType", "NSSubpredicates", "predicateTarget"])
            unknown += predicate.keys.filter { !known.contains($0) }.map { "group.\($0)" }
            if let children = archive.array(predicate["NSSubpredicates"]) {
                unknown += children.flatMap { unknownConditionFields($0, archive: archive, level: level + 1) }
            }
        }
        return Array(Set(unknown)).sorted()
    }

    private static func plainCaptureRegex(_ token: [String: Any], archive: HazelArchive) -> String? {
        guard archive.className(token)?.hasSuffix("HazelMatchToken") == true,
              archive.string(token["name"])?.hasPrefix("hazelcustomtoken:") == true,
              (token["isCaptureToken"] as? Bool) == true,
              archive.number(token["customTokenType"]) == 1,
              let children = archive.array(token["subTokens"]), children.count == 1,
              let child = children[0] as? [String: Any],
              archive.className(child)?.hasSuffix("HazelMatchToken") == true,
              let childName = archive.string(child["name"]),
              ["anything", "word", "number"].contains(childName),
              (child["isCaptureToken"] as? Bool) == false,
              archive.number(child["customTokenType"]) == 0 else { return nil }
        for part in [token, child] {
            guard archive.number(part["case"]) == 0,
                  archive.number(part["alternateFormatIndex"]) == 0,
                  archive.number(part["integerDigits"]) == 0,
                  let selection = archive.number(part["listSelection"]), selection == -2 || selection == Double(Int64.max),
                  ["textReplacements", "valueAdjustment", "sourceToken"].allSatisfy({ part[$0] == nil }) else { return nil }
        }
        guard child["subTokens"] == nil else { return nil }
        switch childName {
        case "anything": return "(.*?)"
        case "word": return "((?:\\p{L}\\p{M}*+)+)"
        case "number":
            let formatter = NumberFormatter(); formatter.locale = .current
            let grouping = NSRegularExpression.escapedPattern(for: formatter.groupingSeparator ?? ",")
            let decimal = NSRegularExpression.escapedPattern(for: formatter.decimalSeparator ?? ".")
            return "((?:(?:\\p{N}{1,3}(?:\(grouping)\\p{N}{3})+)|\\p{N}+)(?:\(decimal)\\p{N}+)?)"
        default: return nil
        }
    }

    private static func hazelCapturePattern(_ raw: Any, archive: HazelArchive) -> (regex: String, names: [String])? {
        guard let predicate = raw as? [String: Any],
              archive.findString(predicate["NSLeftExpression"], key: "NSKeyPath") == "displayBasename",
              let op = predicate["NSPredicateOperator"] as? [String: Any],
              archive.className(op) == "NSCustomPredicateOperator",
              archive.string(op["NSSelectorName"]) == "hazelMatchesPattern:",
              archive.number(op["NSModifier"]) == 0, archive.number(op["NSOperatorType"]) == 11,
              (op["NSNegate"] as? Bool) != true,
              let right = predicate["NSRightExpression"] as? [String: Any],
              let tokens = archive.array(right["NSConstantValue"]), !tokens.isEmpty else { return nil }
        var regex = "(?is)^"
        var names: [String] = []
        for token in tokens {
            if let text = archive.string(token) { regex += NSRegularExpression.escapedPattern(for: text); continue }
            guard let object = token as? [String: Any], let tokenRegex = plainCaptureRegex(object, archive: archive),
                  let name = archive.string(object["name"]), !names.contains(name) else { return nil }
            names.append(name)
            regex += tokenRegex
        }
        guard !names.isEmpty else { return nil }
        return (regex + "$", names)
    }

    private static func hazelAction(_ raw: Any, archive: HazelArchive, ruleId: String, position: Int) -> Action? {
        guard let object = raw as? [String: Any], let type = archive.className(object) else { return nil }
        let params = object["parameter"]
        let normalizedType = type.hasPrefix("ComNoodlesoft_") ? String(type.dropFirst("ComNoodlesoft_".count)) : type
        switch normalizedType {
        case "HazelAutomatorAction":
            guard Set(object.keys).isSubset(of: ["$class", "__class", "parameter", "options"]),
                  (object["options"] == nil || archive.dictionary(object["options"])?.isEmpty == true),
                  let alias = params as? [String: Any], archive.className(alias)?.hasSuffix("NoodleFileAlias") == true,
                  Set(alias.keys).isSubset(of: ["$class", "__class", "path", "type", "volumeIdentifier", "volumeUUIDNotAvailable", "bookmark"]),
                  let path = archive.string(alias["path"]), (path as NSString).isAbsolutePath,
                  !path.contains("\0"), (path as NSString).pathExtension.lowercased() == "workflow" else { return nil }
            return Action(ruleId: ruleId, kind: .runWorkflow, params: .object([ActionParam.workflowPath: .string(path)]), position: Int64(position))
        case "HazelShortcutAction":
            guard Set(object.keys).isSubset(of: ["$class", "__class", "parameter", "options"]),
                  (object["options"] == nil || archive.dictionary(object["options"])?.isEmpty == true),
                  let shortcut = params as? [String: Any], archive.className(shortcut)?.hasSuffix("HazelShortcutsEventsShortcut") == true,
                  Set(shortcut.keys).isSubset(of: ["$class", "__class", "identifier", "name"]),
                  let identifier = archive.string(shortcut["identifier"]), UUID(uuidString: identifier) != nil,
                  shortcut["name"] == nil || archive.string(shortcut["name"]) != nil else { return nil }
            return Action(ruleId: ruleId, kind: .runShortcut, params: .object([ActionParam.shortcutName: .string(identifier)]), position: Int64(position))
        case "HazelPhotosAction", "HazelTVAction", "HazeliTunesAction":
            guard Set(object.keys).isSubset(of: ["$class", "__class", "parameter", "options"]), params == nil,
                  (object["options"] == nil || archive.dictionary(object["options"])?.isEmpty == true) else { return nil }
            let library = normalizedType == "HazelPhotosAction" ? "photos" : normalizedType == "HazelTVAction" ? "tv" : "music"
            return Action(ruleId: ruleId, kind: .importToLibrary, params: .object([
                ActionParam.libraryType: .string(library), ActionParam.onConflict: .string(MoveConflictResolution.rename.rawValue)
            ]), position: Int64(position))
        case "HazelRevealAction":
            guard Set(object.keys).isSubset(of: ["$class", "__class", "parameter", "options"]), params == nil,
                  let options = archive.dictionary(object["options"]), Set(options.keys) == ["bringFront"],
                  let front = archive.number(options["bringFront"]), front == 0 || front == 1 else { return nil }
            return Action(ruleId: ruleId, kind: .showInFinder, params: .object([ActionParam.bringToFront: .bool(front == 1)]), position: Int64(position))
        case "HazelPauseAction":
            guard Set(object.keys).isSubset(of: ["$class", "__class", "parameter", "options"]),
                  (object["options"] == nil || archive.dictionary(object["options"])?.isEmpty == true),
                  let measurement = params as? [String: Any], archive.className(measurement)?.hasSuffix("NoodleMeasurement") == true,
                  Set(measurement.keys).isSubset(of: ["$class", "__class", "amount", "unit"]),
                  let amount = archive.number(measurement["amount"]), amount.isFinite, amount >= 0,
                  let unit = measurement["unit"] as? [String: Any], archive.className(unit)?.hasSuffix("NoodleUnit") == true,
                  Set(unit.keys).isSubset(of: ["$class", "__class", "name", "dimension"]),
                  archive.string(unit["dimension"]) == "time", let name = archive.string(unit["name"]),
                  let multiplier = ["Second": 1.0, "Minute": 60.0, "Hour": 3600.0, "Day": 86400.0, "Week": 604800.0][name] else { return nil }
            let seconds = amount * multiplier
            guard seconds.isFinite, seconds <= 86_400 else { return nil }
            return Action(ruleId: ruleId, kind: .pause, params: .object([ActionParam.durationSeconds: .string(String(seconds))]), position: Int64(position))
        case "HazelArchiveAction", "HazelUnarchiveAction", "HazelNullAction":
            guard Set(object.keys).isSubset(of: ["$class", "__class", "parameter", "options"]), params == nil,
                  (object["options"] == nil || archive.dictionary(object["options"])?.isEmpty == true) else { return nil }
            let kind: ActionKind = normalizedType == "HazelArchiveAction" ? .archive : normalizedType == "HazelUnarchiveAction" ? .uncompress : .ignore
            return Action(ruleId: ruleId, kind: kind, params: .object([:]), position: Int64(position))
        case "HazelCreateAliasAction":
            guard Set(object.keys).isSubset(of: ["$class", "__class", "parameter", "options"]), let folder = params as? [String: Any],
                  ["HazelConcreteFolder", "ComNoodlesoft_HazelConcreteFolder"].contains(archive.className(folder) ?? ""),
                  let storedPath = archive.string(folder["path"]), !storedPath.isEmpty,
                  (object["options"] == nil || archive.dictionary(object["options"])?.isEmpty == true) else { return nil }
            let destination = (storedPath as NSString).expandingTildeInPath
            guard (destination as NSString).isAbsolutePath else { return nil }
            return Action(ruleId: ruleId, kind: .makeAlias, params: .object([ActionParam.destination: .string(destination)]), position: Int64(position))
        case "HazelNotifyAction":
            guard let rawTokens = archive.array(params), !rawTokens.isEmpty,
                  (object["options"] == nil || archive.dictionary(object["options"])?.isEmpty == true) else { return nil }
            var tokens: [JSONValue] = []
            for raw in rawTokens {
                if let token = raw as? [String: Any], archive.className(token)?.hasSuffix("HazelLogMessageFormatToken") == true {
                    let known: Set<String> = ["$class", "__class", "name", "case", "alternateFormatIndex", "integerDigits", "listSelection", "textReplacements", "valueAdjustment", "defaultValue", "pathSeparator", "valueDiscriminator", "sourceToken", "subTokens"]
                    guard token.keys.allSatisfy({ known.contains($0) }), archive.string(token["name"]) == "rule",
                          archive.number(token["case"]) == 0, archive.number(token["alternateFormatIndex"]) == 0,
                          archive.number(token["integerDigits"]) == 0, archive.number(token["listSelection"]) == -2,
                          ["textReplacements", "valueAdjustment", "defaultValue", "pathSeparator", "valueDiscriminator", "sourceToken", "subTokens"].allSatisfy({ token[$0] == nil }) else { return nil }
                    tokens.append(.object(["type": .string("rule")]))
                } else {
                    guard let part = hazelFormatTokens(["NS.objects": [raw]], archive: archive), part.count == 1,
                          part[0]["type"]?.stringValue != "counter", part[0]["type"]?.stringValue != "pathSeparator" else { return nil }
                    tokens.append(part[0])
                }
            }
            return Action(ruleId: ruleId, kind: .displayNotification, params: .object([HazelPattern.tokensKey: .array(tokens)]), position: Int64(position))
        case "HazelOpenAction":
            guard Set(object.keys).isSubset(of: ["$class", "__class", "parameter", "options"]), let app = params as? [String: Any],
                  let options = archive.dictionary(object["options"]), Set(options.keys) == ["bringFront"],
                  let bringFront = archive.number(options["bringFront"]), bringFront == 0 || bringFront == 1 else { return nil }
            let appType = archive.className(app) ?? ""
            if ["HazelDefaultAppData", "ComNoodlesoft_HazelDefaultAppData"].contains(appType), Set(app.keys).isSubset(of: ["$class", "__class"]) {
                return Action(ruleId: ruleId, kind: .openDefault,
                              params: .object([ActionParam.bringToFront: .bool(bringFront == 1)]), position: Int64(position))
            }
            guard ["HazelAppData", "ComNoodlesoft_HazelAppData"].contains(appType),
                  Set(app.keys).isSubset(of: ["$class", "__class", "alias"]),
                  let alias = app["alias"] as? [String: Any], archive.className(alias)?.hasSuffix("NoodleFileAlias") == true,
                  Set(alias.keys).isSubset(of: ["$class", "__class", "path", "type", "volumeIdentifier", "volumeUUIDNotAvailable", "bookmark"]),
                  let application = archive.string(alias["path"]), (application as NSString).isAbsolutePath,
                  !application.contains("\0") else { return nil }
            return Action(ruleId: ruleId, kind: .openApplication, params: .object([
                ActionParam.applicationPath: .string(application), ActionParam.passFileToApplication: .bool(true),
                ActionParam.bringToFront: .bool(bringFront == 1)
            ]), position: Int64(position))
        case "HazelAddFinderCommentAction":
            guard let tokens = hazelFormatTokens(params, archive: archive),
                  !tokens.contains(where: { $0["type"]?.stringValue == "pathSeparator" }),
                  (object["options"] == nil || archive.dictionary(object["options"])?.isEmpty == true) else { return nil }
            return Action(ruleId: ruleId, kind: .setFinderComment,
                          params: .object([HazelPattern.tokensKey: .array(tokens)]), position: Int64(position))
        case "HazelShellScriptAction":
            if let alias = params as? [String: Any], archive.className(alias)?.hasSuffix("NoodleFileAlias") == true {
                guard let path = archive.string(alias["path"]), path.hasPrefix("/"), !path.contains("\0"),
                      let bookmarkObject = alias["bookmark"] as? [String: Any],
                      let bookmark = bookmarkObject["NS.data"] as? Data, bookmark.count <= 1_000_000,
                      (object["options"] == nil || archive.dictionary(object["options"])?.isEmpty == true) else { return nil }
                return Action(ruleId: ruleId, kind: .runHazelShellScript,
                              params: .object([ActionParam.shellMode: .string("external"), ActionParam.shellPath: .string(path),
                                               ActionParam.shellBookmark: .string(bookmark.base64EncodedString())]), position: Int64(position))
            }
            guard let stored = params as? [String: Any],
                  ["HazelShellScript", "ComNoodlesoft_HazelShellScript"].contains(archive.className(stored) ?? ""),
                  let shell = archive.string(stored["shell"]), shell.hasPrefix("/"), !shell.contains("\0"),
                  let source = archive.string(stored["script"]) ?? (stored["script"] as? [String: Any]).flatMap({ archive.string($0["NS.data"]) }),
                  source.utf8.count <= 1_000_000, !source.contains("\0"),
                  Set(stored.keys).isSubset(of: ["$class", "__class", "shell", "script"]),
                  (object["options"] == nil || archive.dictionary(object["options"])?.isEmpty == true) else { return nil }
            return Action(ruleId: ruleId, kind: .runHazelShellScript,
                          params: .object([ActionParam.script: .string(source), ActionParam.shell: .string(shell)]), position: Int64(position))
        case "HazelContinueAction", "HazelRecurseAction":
            guard params == nil, (object["options"] == nil || archive.dictionary(object["options"])?.isEmpty == true) else { return nil }
            return Action(ruleId: ruleId, kind: normalizedType == "HazelContinueAction" ? .hazelContinue : .hazelRecurse,
                          params: .object([:]), position: Int64(position))
        case "HazelAppleScriptAction", "HazelJavaScriptAction":
            if let stored = params as? [String: Any],
               archive.className(stored)?.hasSuffix("HazelOSAScript") == true {
                guard stored["alias"] == nil,
                      let data = stored["data"] as? Data, data.count <= 1_000_000,
                      data.starts(with: Data((normalizedType == "HazelAppleScriptAction" ? "Fasd" : "JsOsa").utf8)),
                      let inputRaw = archive.array(stored["inputAttributes"]),
                      let outputRaw = archive.array(stored["outputAttributes"]),
                      (object["options"] == nil || archive.dictionary(object["options"])?.isEmpty == true) else { return nil }
                func attributeNames(_ values: [Any], output: Bool) -> [String]? {
                    var names: [String] = []
                    for value in values {
                        guard let token = value as? [String: Any], let name = archive.string(token["name"]),
                              archive.number(token["case"]) == 0, archive.number(token["alternateFormatIndex"]) == 0,
                              token["textReplacements"] == nil, token["valueAdjustment"] == nil else { return nil }
                        if output {
                            guard name.hasPrefix("hazelcustomtoken:") else { return nil }
                            names.append(name)
                        } else {
                            let supported = ["displayBasename": "name", "displayName": "fullName", "displayExtension": "extension", "path": "path", "comment": "comment", "dateAdded": "dateAdded", "dateCreated": "dateCreated", "dateModified": "dateModified", "currentDate": "currentDate", "hazelbuiltin:dateTaken": "hazelbuiltin:dateTaken"]
                            guard let mapped = supported[name] ?? (name.hasPrefix("hazelcustomtoken:") ? name : nil) else { return nil }
                            names.append(mapped)
                        }
                    }
                    return Set(names).count == names.count ? names : nil
                }
                guard let inputs = attributeNames(inputRaw, output: false), let outputs = attributeNames(outputRaw, output: true) else { return nil }
                return Action(ruleId: ruleId, kind: .runHazelOSA, params: .object([
                    ActionParam.osaLanguage: .string(normalizedType == "HazelAppleScriptAction" ? "AppleScript" : "JavaScript"),
                    ActionParam.osaMode: .string("compiled"), ActionParam.compiledAppleScript: .string(data.base64EncodedString()),
                    ActionParam.osaInputs: .stringArray(inputs), ActionParam.osaOutputs: .stringArray(outputs)
                ]), position: Int64(position))
            }
            guard normalizedType == "HazelAppleScriptAction" else { return nil }
            // Version 15 embedded scripts use hazelProcessFile(theFile).
            // Keep the compiled bytes inert until the rule is enabled.
            guard archive.number(archive.root?["version"]) == 15,
                  let compiled = params as? [String: Any],
                  let data = compiled["NS.data"] as? Data,
                  data.count <= 1_000_000, data.starts(with: Data("Fasd".utf8)) else { return nil }
            if let options = object["options"] {
                guard let entries = archive.dictionary(options),
                      Set(entries.keys).isSubset(of: ["exportTokens"]),
                      entries["exportTokens"] == nil || archive.array(entries["exportTokens"])?.isEmpty == true else { return nil }
            }
            return Action(ruleId: ruleId, kind: .runHazelAppleScript,
                          params: .object([ActionParam.compiledAppleScript: .string(data.base64EncodedString())]), position: Int64(position))
        case "HazelLabelAction":
            guard let value = archive.number(params), value.rounded(.towardZero) == value,
                  value >= 0, value <= 7,
                  (object["options"] == nil || archive.dictionary(object["options"])?.isEmpty == true) else { return nil }
            // Hazel archives its color-menu index, whose order differs from
            // NSURLLabelNumberKey. Keep the color name in the action instead.
            let colors = ["", "Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"]
            return Action(ruleId: ruleId, kind: .setFinderLabel,
                          params: .object([ActionParam.color: .string(colors[Int(value)])]), position: Int64(position))
        case "HazelFinderLockAction", "HazelHideExtensionAction":
            guard let value = archive.number(params), value == 0 || value == 1,
                  (object["options"] == nil || archive.dictionary(object["options"])?.isEmpty == true) else { return nil }
            let lock = normalizedType == "HazelFinderLockAction"
            return Action(ruleId: ruleId, kind: lock ? .setLocked : .setExtensionHidden,
                          params: .object([ActionParam.enabled: .bool(value == 1)]), position: Int64(position))
        case "HazelAddTagsAction", "HazelRemoveTagsAction":
            guard let items = archive.array(params), !items.isEmpty,
                  (object["options"] == nil || archive.dictionary(object["options"])?.isEmpty == true) else { return nil }
            let names = items.compactMap { archive.string($0) }
            guard names.count == items.count, names.allSatisfy({ !$0.isEmpty && !$0.contains("\n") && !$0.contains("\0") }) else { return nil }
            return Action(ruleId: ruleId, kind: normalizedType == "HazelAddTagsAction" ? .addTag : .removeTag,
                          params: .object([ActionParam.tags: .stringArray(names)]), position: Int64(position))
        case "HazelSyncAction":
            guard let folder = params as? [String: Any],
                  ["HazelConcreteFolder", "ComNoodlesoft_HazelConcreteFolder"].contains(archive.className(folder) ?? ""),
                  let storedPath = archive.string(folder["path"]), !storedPath.isEmpty,
                  (object["options"] == nil || archive.dictionary(object["options"])?.isEmpty == true) else { return nil }
            let destination = (storedPath as NSString).expandingTildeInPath
            guard (destination as NSString).isAbsolutePath else { return nil }
            return Action(ruleId: ruleId, kind: .syncToFolder, params: .object([ActionParam.destination: .string(destination)]), position: Int64(position))
        case "HazelMoveAction", "HazelCopyAction":
            guard Set(object.keys).isSubset(of: ["$class", "__class", "parameter", "options"]) else { return nil }
            let options: [String: Any]
            if let rawOptions = object["options"] {
                guard let parsed = archive.dictionary(rawOptions), parsed.allSatisfy({
                    ["throwAwayDupes", "replaceExisting", "keepFolderStructure"].contains($0.key) &&
                    (archive.number($0.value) == 0 || ($0.key == "throwAwayDupes" && archive.number($0.value) == 1) ||
                     ($0.key == "replaceExisting" && [1.0, 2.0].contains(archive.number($0.value) ?? -1)) ||
                     ($0.key == "keepFolderStructure" && [1.0, 2.0, 3.0].contains(archive.number($0.value) ?? -1)))
                }) else { return nil }
                options = parsed
            } else { options = [:] }
            let folderClass = archive.className(params as? [String: Any]) ?? ""
            if folderClass == "HazelTrashFolder" || folderClass == "ComNoodlesoft_HazelTrashFolder" {
                guard normalizedType == "HazelMoveAction", options.values.allSatisfy({ archive.number($0) == 0 }) else { return nil }
                return Action(ruleId: ruleId, kind: .moveToTrash, params: .object([:]), position: Int64(position))
            }
            guard folderClass == "HazelConcreteFolder" || folderClass == "ComNoodlesoft_HazelConcreteFolder",
                  let folder = params as? [String: Any],
                  let storedPath = archive.string(folder["path"]), !storedPath.isEmpty else { return nil }
            let destination = (storedPath as NSString).expandingTildeInPath
            guard (destination as NSString).isAbsolutePath else { return nil }
            var parameters: [String: JSONValue] = [ActionParam.destination: .string(destination)]
            if archive.number(options["throwAwayDupes"]) == 1 {
                parameters[normalizedType == "HazelCopyAction" ? ActionParam.skipDuplicates : ActionParam.discardDuplicates] = .bool(true)
            }
            if archive.number(options["replaceExisting"]) == 1 { parameters[ActionParam.onConflict] = .string(MoveConflictResolution.replace.rawValue) }
            if archive.number(options["replaceExisting"]) == 2 { parameters[ActionParam.onConflict] = .string(normalizedType == "HazelCopyAction" ? MoveConflictResolution.skip.rawValue : MoveConflictResolution.discard.rawValue) }
            if archive.number(options["keepFolderStructure"]) == 1 { parameters[ActionParam.folderStructure] = .string(FolderStructureMode.parent.rawValue) }
            if archive.number(options["keepFolderStructure"]) == 2 { parameters[ActionParam.folderStructure] = .string(FolderStructureMode.monitored.rawValue) }
            if archive.number(options["keepFolderStructure"]) == 3 { parameters[ActionParam.folderStructure] = .string(FolderStructureMode.root.rawValue) }
            return Action(ruleId: ruleId, kind: normalizedType == "HazelCopyAction" ? .copyToFolder : .moveToFolder, params: .object(parameters), position: Int64(position))
        case "HazelTrashAction":
            return Action(ruleId: ruleId, kind: .moveToTrash, params: .object([:]), position: Int64(position))
        case "HazelCreateFolderAction":
            guard let tokens = hazelFormatTokens(params, archive: archive), !tokens.isEmpty,
                  let options = archive.dictionary(object["options"]),
                  options.allSatisfy({ ["throwAwayDupes", "replaceExisting", "keepFolderStructure"].contains($0.key) &&
                      (archive.number($0.value) == 0 || ($0.key == "throwAwayDupes" && archive.number($0.value) == 1)) }) else { return nil }
            var folderParams: [String: JSONValue] = [
                ActionParam.destination: .string("."), HazelPattern.sortKey: .bool(true), HazelPattern.tokensKey: .array(tokens)
            ]
            if archive.number(options["throwAwayDupes"]) == 1 { folderParams[ActionParam.discardDuplicates] = .bool(true) }
            return Action(ruleId: ruleId, kind: .moveToFolder, params: .object(folderParams), position: Int64(position))
        case "HazelRenameAction":
            if let tokens = hazelFormatTokens(params, archive: archive), !tokens.isEmpty,
               !tokens.contains(where: { $0["type"]?.stringValue == "pathSeparator" }) {
                return Action(ruleId: ruleId, kind: .rename, params: .object([
                    ActionParam.pattern: .string("Hazel pattern"), HazelPattern.tokensKey: .array(tokens)
                ]), position: Int64(position))
            }
            // These patterns appear in the public Statements and Bjango exports.
            // Other token arrangements and date formats need explicit review.
            guard let tokens = archive.array(params), tokens.count == 3,
                  let extensionToken = tokens[2] as? [String: Any],
                  plainFilenameToken(extensionToken, named: "extension", archive: archive) else { return nil }
            let literal: String
            let pattern: String
            if let text = archive.string(tokens[0]), let token = tokens[1] as? [String: Any],
               plainFilenameToken(token, named: "name", archive: archive) {
                literal = text
                pattern = text + "{name}"
            } else if let token = tokens[0] as? [String: Any], let text = archive.string(tokens[1]),
                      plainFilenameToken(token, named: "name", archive: archive) {
                literal = text
                pattern = "{name}" + text
            } else {
                return nil
            }
            guard !literal.contains("{"), !literal.contains("}"), !literal.contains("/") else { return nil }
            return Action(ruleId: ruleId, kind: .rename,
                          params: .object([ActionParam.pattern: .string(pattern)]), position: Int64(position))
        default:
            return nil
        }
    }

    private static func plainFilenameToken(_ token: [String: Any], named: String, archive: HazelArchive) -> Bool {
        guard archive.className(token) == "ComNoodlesoft_HazelFilenameFormatToken",
              archive.string(token["name"]) == named,
              archive.number(token["case"]) == 0,
              archive.number(token["alternateFormatIndex"]) == 0,
              archive.number(token["integerDigits"]) == 0,
              archive.number(token["listSelection"]) == -2 else { return false }
        return ["textReplacements", "valueAdjustment", "subTokens", "sourceToken"].allSatisfy { token[$0] == nil }
    }

    private static func hazelFormatTokens(_ raw: Any?, archive: HazelArchive) -> [JSONValue]? {
        guard let tokens = archive.array(raw) else { return nil }
        var result: [JSONValue] = []
        for token in tokens {
            if let text = archive.string(token) {
                result.append(.object(["type": .string("literal"), "value": .string(text)])); continue
            }
            if let counter = token as? [String: Any], archive.className(counter)?.hasSuffix("HazelCounterFormatToken") == true {
                let known: Set<String> = ["$class", "__class", "name", "case", "alternateFormatIndex", "integerDigits", "listSelection", "textReplacements", "valueAdjustment", "defaultValue", "pathSeparator", "valueDiscriminator", "sourceToken", "subTokens", "behavior", "sequenceType"]
                guard counter.keys.allSatisfy({ known.contains($0) }), archive.string(counter["name"]) == "counter",
                      archive.number(counter["case"]) == 0, archive.number(counter["alternateFormatIndex"]) == 0,
                      archive.number(counter["behavior"]) == 0, archive.number(counter["sequenceType"]) == 0,
                      let digits = archive.number(counter["integerDigits"]), digits.isFinite, digits.rounded(.towardZero) == digits, (0...20).contains(digits),
                      let selection = archive.number(counter["listSelection"]), selection == -2 || selection == Double(Int64.max),
                      ["valueAdjustment", "defaultValue", "pathSeparator", "valueDiscriminator", "sourceToken", "subTokens"].allSatisfy({ counter[$0] == nil }),
                      counter["textReplacements"] == nil || archive.array(counter["textReplacements"])?.isEmpty == true else { return nil }
                result.append(.object(["type": .string("counter"), "digits": .string("\(Int(digits))")]))
                continue
            }
            guard let object = token as? [String: Any],
                  let className = archive.className(object), className.hasSuffix("HazelFilenameFormatToken"),
                  let name = archive.string(object["name"]), let caseCode = archive.number(object["case"]), [0, 1, 2, 3].contains(caseCode),
                  archive.number(object["alternateFormatIndex"]) == 0,
                  archive.number(object["integerDigits"]) == 0,
                  let selection = archive.number(object["listSelection"]), selection == -2 || selection == Double(Int64.max),
                  ["textReplacements", "valueAdjustment", "defaultValue", "pathSeparator", "valueDiscriminator"].allSatisfy({ object[$0] == nil }) else { return nil }
            let knownFields: Set<String> = ["$class", "__class", "name", "case", "alternateFormatIndex", "integerDigits", "listSelection", "textReplacements", "valueAdjustment", "defaultValue", "pathSeparator", "valueDiscriminator", "sourceToken", "subTokens"]
            guard object.keys.allSatisfy({ knownFields.contains($0) }) else { return nil }
            func appendToken(_ fields: [String: JSONValue]) {
                var fields = fields
                if caseCode == 1 { fields["case"] = .string("title") }
                if caseCode == 2 { fields["case"] = .string("lower") }
                if caseCode == 3 { fields["case"] = .string("upper") }
                result.append(.object(fields))
            }
            if name == "name" || name == "extension" || name == "comment" || name == "pathSeparator" {
                guard object["sourceToken"] == nil, object["subTokens"] == nil else { return nil }
                guard name != "pathSeparator" || caseCode == 0 else { return nil }
                appendToken(["type": .string(name)]); continue
            }
            var isCustomDate = false
            if name.hasPrefix("hazelcustomtoken:") {
                guard let source = object["sourceToken"] as? [String: Any],
                      archive.string(source["name"]) == name else { return nil }
                if plainCaptureRegex(source, archive: archive) != nil {
                    guard object["subTokens"] == nil else { return nil }
                    appendToken(["type": .string("capture"), "value": .string(name)])
                    continue
                } else if archive.number(source["customTokenType"]) == 2, source["subTokens"] == nil {
                    isCustomDate = true
                } else {
                    guard archive.number(source["customTokenType"]) == 0, source["subTokens"] == nil, object["subTokens"] == nil else { return nil }
                    appendToken(["type": .string("attribute"), "value": .string(name)])
                    continue
                }
            }
            if !isCustomDate {
                guard ["dateAdded", "dateCreated", "dateModified", "currentDate", "hazelbuiltin:dateTaken"].contains(name),
                      object["sourceToken"] == nil else { return nil }
            }
            if name == "dateAdded", object["subTokens"] == nil {
                appendToken(["type": .string("date"), "source": .string(name), "value": .string("yyyy-MM-dd")])
                continue
            }
            guard let parts = archive.array(object["subTokens"]), !parts.isEmpty else { return nil }
            var format = ""
            for part in parts {
                if let literal = archive.string(part) {
                    format += "'" + literal.replacingOccurrences(of: "'", with: "''") + "'"; continue
                }
                guard let field = part as? [String: Any], archive.className(field)?.hasSuffix("HazelDateFormatToken") == true,
                      let fieldName = archive.string(field["name"]),
                      let digits = archive.number(field["digitCount"]), digits == 1 || digits == 2 || digits == 4,
                      archive.number(field["alternateFormatIndex"]) == 0,
                      ["textReplacements", "valueAdjustment", "sourceToken", "subTokens", "defaultValue", "pathSeparator", "valueDiscriminator"].allSatisfy({ field[$0] == nil }) else { return nil }
                let dateFields: Set<String> = ["$class", "__class", "name", "case", "alternateFormatIndex", "integerDigits", "listSelection", "textReplacements", "valueAdjustment", "defaultValue", "pathSeparator", "valueDiscriminator", "sourceToken", "subTokens", "digitCount", "usesAlternateFormat"]
                guard field.keys.allSatisfy({ dateFields.contains($0) }), archive.number(field["case"]) == 0,
                      archive.number(field["integerDigits"]) == 0 else { return nil }
                let alternate = field["usesAlternateFormat"] as? Bool == true
                switch (fieldName, Int(digits), alternate) {
                case ("year", 4, false): format += "yyyy"
                case ("year", 2, false): format += "yy"
                case ("month", 2, false): format += "MM"
                case ("month", 4, false): format += "MMMM"
                case ("dayOfMonth", 1, false): format += "d"
                case ("dayOfMonth", 2, false): format += "dd"
                case ("hour", 2, true): format += "HH"
                case ("hour", 2, false): format += "hh"
                case ("minute", 2, false): format += "mm"
                case ("second", 2, false): format += "ss"
                case ("am/pm", 2, false): format += "aa"
                default: return nil
                }
            }
            appendToken(["type": .string(isCustomDate ? "attributeDate" : "date"), "source": .string(name), "value": .string(format)])
        }
        return result
    }
}

/// A deliberately non-executing reader for an NSKeyedArchiver plist. It
/// resolves plist values and class labels without instantiating Hazel classes.
private struct HazelArchive {
    private static let maximumArchiveSize = 20 * 1024 * 1024
    private static let maximumObjectCount = 100_000
    private static let maximumResolveDepth = 128
    private static let maximumResolveNodes = 1_000_000

    let objects: [Any]
    let root: [String: Any]?

    init(data: Data) throws {
        guard data.count <= Self.maximumArchiveSize else { throw RuleTransferError.unsupportedFile }
        let payload: Data
        if data.starts(with: Data("HZLR".utf8)) {
            // Hazel sync archives use a version field and a SHA-256 digest.
            // Accept only the format verified against a public archive.
            guard data.count > 40, data.dropFirst(4).prefix(4).elementsEqual([0, 0, 0, 27]) else {
                throw RuleTransferError.unsupportedFile
            }
            payload = Data(data.dropFirst(40))
            guard data.dropFirst(8).prefix(32).elementsEqual(SHA256.hash(data: payload)) else {
                throw RuleTransferError.unsupportedFile
            }
        } else {
            payload = data
        }
        guard let plist = try PropertyListSerialization.propertyList(from: payload, options: [], format: nil) as? [String: Any],
              plist["$archiver"] as? String == "NSKeyedArchiver",
              let objects = plist["$objects"] as? [Any],
              objects.count <= Self.maximumObjectCount,
              let top = plist["$top"] as? [String: Any] else {
            throw RuleTransferError.unsupportedFile
        }
        self.objects = objects
        var remaining = Self.maximumResolveNodes
        guard let root = try Self.resolve(top["root"], objects: objects, remaining: &remaining) as? [String: Any] else {
            throw RuleTransferError.unsupportedFile
        }
        self.root = root
    }

    func array(_ value: Any?) -> [Any]? {
        guard let dict = value as? [String: Any] else { return value as? [Any] }
        return dict["NS.objects"] as? [Any]
    }

    func className(_ value: [String: Any]?) -> String? { value?["__class"] as? String }

    func dictionary(_ value: Any?) -> [String: Any]? {
        guard let object = value as? [String: Any],
              let keys = object["NS.keys"] as? [Any],
              let values = object["NS.objects"] as? [Any], keys.count == values.count else { return nil }
        var result: [String: Any] = [:]
        for (key, value) in zip(keys, values) {
            guard let key = string(key) else { return nil }
            result[key] = value
        }
        return result
    }

    func string(_ value: Any?) -> String? {
        if let string = value as? String, string != "$null" { return string }
        if let data = value as? Data { return String(data: data, encoding: .utf8) }
        return nil
    }

    func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        if let decimal = value as? [String: Any], let data = decimal["NS.mantissa"] as? Data {
            let mantissa = data.prefix(8).enumerated().reduce(UInt64(0)) { partial, byte in
                partial | (UInt64(byte.element) << UInt64(byte.offset * 8))
            }
            let exponent = (decimal["NS.exponent"] as? NSNumber)?.intValue ?? 0
            let sign = decimal["NS.negative"] as? Bool == true ? -1.0 : 1.0
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
            for child in dict.values {
                if let found = findString(child, key: key) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = findString(child, key: key) { return found }
            }
        }
        return nil
    }

    private static func resolve(
        _ value: Any?,
        objects: [Any],
        visiting: Set<Int> = [],
        depth: Int = 0,
        remaining: inout Int
    ) throws -> Any? {
        guard let value, depth <= maximumResolveDepth, remaining > 0 else { throw RuleTransferError.unsupportedFile }
        remaining -= 1
        if let uid = uidValue(value) {
            guard objects.indices.contains(uid) else { throw RuleTransferError.unsupportedFile }
            if uid == 0 { return nil }
            guard !visiting.contains(uid) else { throw RuleTransferError.unsupportedFile }
            var nextVisiting = visiting
            nextVisiting.insert(uid)
            return try resolve(objects[uid], objects: objects, visiting: nextVisiting, depth: depth + 1, remaining: &remaining)
        }
        if let dict = value as? [String: Any] {
            if dict["CF$UID"] != nil { throw RuleTransferError.unsupportedFile }
            var resolved: [String: Any] = [:]
            for (key, child) in dict {
                resolved[key] = try resolve(child, objects: objects, visiting: visiting, depth: depth + 1, remaining: &remaining)
            }
            if let classObject = resolved["$class"] as? [String: Any],
               let name = classObject["$classname"] as? String {
                resolved["__class"] = name
            }
            return resolved
        }
        if let array = value as? [Any] {
            var resolved: [Any] = []
            for child in array {
                resolved.append(try resolve(child, objects: objects, visiting: visiting, depth: depth + 1, remaining: &remaining) ?? NSNull())
            }
            return resolved
        }
        return value
    }

    /// Binary plists surface keyed-archive references as Foundation's private
    /// UID object, while XML fixtures use the public `CF$UID` dictionary.
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
