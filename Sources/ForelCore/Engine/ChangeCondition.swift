import Foundation

enum ChangeCondition {
    static func isChange(_ condition: Condition) -> Bool { condition.operator == .didChange || condition.operator == .didNotChange }
    static func hasNestedChange(_ conditions: [Condition], level: Int = 0) -> Bool {
        guard level < 16 else { return true }
        return conditions.contains { condition in
            guard condition.kind == .conditionGroup, let group = ConditionGroup.decode(condition.value) else { return false }
            return group.conditions.contains(where: isChange) || hasNestedChange(group.conditions, level: level + 1)
        }
    }
    static func containsChange(_ conditions: [Condition], level: Int = 0) -> Bool {
        guard level < 16 else { return false }
        return conditions.contains { condition in
            if isChange(condition) { return true }
            guard condition.kind == .conditionGroup, let group = ConditionGroup.decode(condition.value) else { return false }
            return containsChange(group.conditions, level: level + 1)
        }
    }
    static func containsDidChange(_ conditions: [Condition], negated: Bool = false, level: Int = 0) -> Bool {
        guard level < 16 else { return false }
        return conditions.contains { condition in
            if isChange(condition) { return (condition.operator == .didChange) != negated }
            guard condition.kind == .conditionGroup, let group = ConditionGroup.decode(condition.value) else { return false }
            return containsDidChange(group.conditions, negated: negated != (group.match == .none), level: level + 1)
        }
    }
    static func key(_ condition: Condition) -> String { "\(condition.id):\(condition.kind.rawValue):\(condition.operator.rawValue)" }
    static func value(_ condition: Condition, path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        let value: JSONValue
        switch condition.kind {
        case .name, .nameInsensitive: value = .string(url.deletingPathExtension().lastPathComponent)
        case .fullName, .fullNameInsensitive: value = .string(url.lastPathComponent)
        case .extension_: value = .string(url.pathExtension)
        case .finderComment: value = .string(try FinderComment.read(path) ?? "")
        case .sizeBytes:
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw ActionError("File size is unavailable") }
            value = .string(String(size))
        case .createdAt, .dateModified, .dateAdded:
            let values = try url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .addedToDirectoryDateKey])
            let date = condition.kind == .createdAt ? values.creationDate : condition.kind == .dateModified ? values.contentModificationDate : values.addedToDirectoryDate
            guard let date else { throw ActionError("File date is unavailable") }
            value = .number(date.timeIntervalSince1970)
        default: throw ActionError("This attribute does not support change tracking")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

final class ChangeTracker {
    private let state: any HazelMatchStateStore
    private let store: any HazelChangeBaselineStore
    private let ruleId: String
    private(set) var seeds: [String: [String: String]] = [:]
    private(set) var updates: [String: [String: String]] = [:]
    private(set) var stableUpdates: [String: [String: String]] = [:]
    init?(state: (any HazelMatchStateStore)?, ruleId: String) {
        guard let state, let store = state as? any HazelChangeBaselineStore else { return nil }
        self.state = state; self.store = store; self.ruleId = ruleId
    }
    func evaluate(_ condition: Condition, path: String, negated: Bool = false) throws -> Bool? {
        let item = state.itemKey(path: path), key = ChangeCondition.key(condition)
        let value = try ChangeCondition.value(condition, path: path)
        let prior = try store.changeBaseline(ruleId: ruleId, itemKey: item, conditionKey: key)
        if prior == nil { seeds[item, default: [:]][key] = value }
        let changed = prior.map { $0 != value } ?? false
        if changed {
            updates[item, default: [:]][key] = value
            if (condition.operator == .didNotChange) != negated { stableUpdates[item, default: [:]][key] = value }
        }
        return condition.operator == .didChange ? changed : !changed
    }
    func commit(_ entries: [String: [String: String]]) throws {
        if !entries.isEmpty { try store.setChangeBaselineBatch(entries, ruleId: ruleId) }
    }
}
