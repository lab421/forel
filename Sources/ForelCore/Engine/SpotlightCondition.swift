import Foundation
import CoreServices

/// A typed comparison against a Spotlight attribute. A missing or unsupported
/// attribute remains unknown, including inside a negated nested condition.
public struct SpotlightCondition: Codable, Equatable, Sendable {
    public enum ValueType: String, Codable, CaseIterable, Sendable { case text, number, date, boolean }
    public var key: String
    public var type: ValueType
    public var operand: String
    public init(key: String, type: ValueType, operand: String) {
        self.key = key; self.type = type; self.operand = operand
    }
    public var encoded: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    public static func decode(_ value: String) -> SpotlightCondition? {
        guard value.utf8.count <= 4096, let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SpotlightCondition.self, from: data)
    }
    public func validationError(for op: Operator, scriptAttribute: Bool = false) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.-"))
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, key.utf8.count <= 255,
              scriptAttribute || key.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return "Enter a valid attribute name" }
        guard !operand.isEmpty else { return "Enter a Spotlight comparison value" }
        let comparisons: [Operator] = [.is, .isNot, .greaterThan, .lessThan]
        switch type {
        case .text:
            guard [.is, .isNot, .contains, .containsInsensitive, .doesNotContain, .startsWith, .endsWith].contains(op) else { return "This operator cannot compare text attributes" }
        case .number:
            guard comparisons.contains(op), let n = Double(operand), n.isFinite else { return "Enter a finite number and numeric comparison" }
        case .date:
            guard comparisons.contains(op), ISO8601DateFormatter().date(from: operand) != nil else { return "Enter a date in ISO 8601 format and a date comparison" }
        case .boolean:
            guard [.is, .isNot].contains(op), ["true", "false"].contains(operand) else { return "Choose true or false" }
        }
        return nil
    }

    static func evaluate(_ condition: Condition, path: String) -> Bool? {
        guard let spec = decode(condition.value), spec.validationError(for: condition.operator) == nil,
              let item = MDItemCreate(kCFAllocatorDefault, path as CFString),
              let value = MDItemCopyAttribute(item, spec.key as CFString) else { return nil }
        return spec.compare(value, operator: condition.operator)
    }

    static func evaluateScriptAttribute(_ condition: Condition, attributes: [String: JSONValue]) -> Bool? {
        guard let spec = decode(condition.value), spec.validationError(for: condition.operator, scriptAttribute: true) == nil,
              let value = attributes[spec.key], let converted = scriptValue(value) else { return nil }
        return spec.compare(converted, operator: condition.operator)
    }

    private static func scriptValue(_ value: JSONValue) -> Any? {
        switch value {
        case .string(let text): return text
        case .number(let number): return NSNumber(value: number)
        case .bool(let flag): return NSNumber(value: flag)
        case .array(let values):
            guard values.count <= 10_000 else { return nil }
            let converted = values.compactMap { scriptValue($0) }
            return converted.count == values.count ? converted : nil
        case .object(let object):
            guard object.count == 1, case .number(let seconds) = object["__forelDate"], seconds.isFinite else { return nil }
            return Date(timeIntervalSince1970: seconds)
        default: return nil
        }
    }

    func compare(_ attribute: Any, operator op: Operator) -> Bool? {
        let values = (attribute as? [Any]) ?? [attribute]
        guard !values.isEmpty, values.count <= 10_000 else { return nil }
        let negative = op == .isNot || op == .doesNotContain
        let positive: Operator = op == .isNot ? .is : op == .doesNotContain ? .contains : op
        var matched = false
        var unknown = false
        for value in values {
            guard let result = compareOne(value, operator: positive) else { unknown = true; continue }
            matched = matched || result
        }
        if matched { return !negative }
        if unknown { return nil }
        return negative
    }

    private func compareOne(_ value: Any, operator positive: Operator) -> Bool? {
            let result: Bool
            switch type {
            case .text:
                guard let text = value as? String else { return nil }
                switch positive {
                case .is: result = text == operand
                case .contains: result = text.contains(operand)
                case .containsInsensitive: result = text.range(of: operand, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                case .startsWith: result = text.hasPrefix(operand)
                case .endsWith: result = text.hasSuffix(operand)
                default: return nil
                }
            case .number:
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      let wanted = Double(operand), wanted.isFinite, number.doubleValue.isFinite else { return nil }
                switch positive {
                case .is: result = number.doubleValue == wanted
                case .greaterThan: result = number.doubleValue > wanted
                case .lessThan: result = number.doubleValue < wanted
                default: return nil
                }
            case .date:
                guard let date = value as? Date, let wanted = ISO8601DateFormatter().date(from: operand) else { return nil }
                switch positive {
                case .is: result = date == wanted
                case .greaterThan: result = date > wanted
                case .lessThan: result = date < wanted
                default: return nil
                }
            case .boolean:
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID(), ["true", "false"].contains(operand) else { return nil }
                result = number.boolValue == (operand == "true")
            }
            return result
    }
}
