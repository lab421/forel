import Foundation

/// A nested condition, encoded in the condition value for database and export
/// compatibility. Child order is preserved.
public struct ConditionGroup: Codable, Equatable, Sendable {
    public enum Match: String, Codable, CaseIterable, Sendable { case all, any, none }
    public enum Target: String, Codable, CaseIterable, Sendable {
        case current, parent, anySibling, allSiblings, anyChild, allChildren
    }
    public var match: Match
    public var target: Target
    public var conditions: [Condition]

    public init(match: Match = .all, target: Target = .current, conditions: [Condition]) {
        self.match = match; self.target = target; self.conditions = conditions
    }

    public var encoded: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    public static func decode(_ value: String) -> ConditionGroup? {
        guard value.utf8.count <= 1_000_000, let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ConditionGroup.self, from: data)
    }
}
