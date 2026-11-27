// Forel - A native macOS file-automation app
// Copyright (C) 2026  Lab421

import Foundation
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
        case .unsupportedFile: return "This file is not a Forel rule export."
        case .invalidNativeFile: return "This Forel rule export is invalid or from a newer version of Forel."
        }
    }
}

/// File interchange for Forel's versioned JSON rule format.
public enum RuleTransfer {
    public static let maximumFileSize = 20 * 1024 * 1024
    private struct NativeExport: Codable {
        let format: String
        let version: Int
        let rules: [Rule]
    }

    public static func exportForel(_ rules: [Rule]) throws -> Data {
        let export = NativeExport(format: "forel-rules", version: 1, rules: rules)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(export)
        guard data.count <= maximumFileSize, nativeJSONWithinLimits(data) else { throw RuleTransferError.invalidNativeFile }
        return data
    }

    /// Read at most the import limit, even if a selected file changes while read.
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

    public static func importRules(from data: Data, folderId: String) throws -> RuleImportResult {
        guard data.count <= maximumFileSize, nativeJSONWithinLimits(data) else { throw RuleTransferError.invalidNativeFile }
        if let native = try? JSONDecoder().decode(NativeExport.self, from: data) {
            guard native.format == "forel-rules", native.version == 1 else {
                throw RuleTransferError.invalidNativeFile
            }
            return RuleImportResult(rules: native.rules.map { remap($0, folderId: folderId) }, issues: [])
        }
        throw RuleTransferError.invalidNativeFile
    }

    private static func nativeJSONWithinLimits(_ data: Data) -> Bool {
        var depth = 0, inString = false, escaped = false
        for byte in data {
            if inString {
                if escaped { escaped = false }
                else if byte == 0x5c { escaped = true }
                else if byte == 0x22 { inString = false }
            } else if byte == 0x22 { inString = true }
            else if byte == 0x7b || byte == 0x5b {
                depth += 1; if depth > 64 { return false }
            } else if byte == 0x7d || byte == 0x5d {
                depth -= 1; if depth < 0 { return false }
            }
        }
        guard !inString, depth == 0, let root = try? JSONSerialization.jsonObject(with: data) else { return false }
        var pending: [Any] = [root], nodes = 0
        while let value = pending.popLast() {
            nodes += 1; if nodes > 100_000 { return false }
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
        rule.conditions = source.conditions.map {
            Condition(ruleId: id, kind: $0.kind, operator: $0.operator, value: $0.value)
        }
        rule.actions = source.actions.map {
            Action(ruleId: id, kind: $0.kind, params: $0.params, position: $0.position)
        }
        return rule
    }

}
