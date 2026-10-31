import Foundation
import CoreServices

enum SpotlightToken {
    static func read(key: String, path: String) -> JSONValue? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString),
              let value = MDItemCopyAttribute(item, key as CFString) else { return nil }
        var budget = 1_000_000
        return convert(value, depth: 0, budget: &budget)
    }
    private static func convert(_ value: Any, depth: Int, budget: inout Int) -> JSONValue? {
        guard depth <= 1, budget > 0 else { return nil }
        if let text = value as? String {
            guard text.utf8.count <= budget else { return nil }; budget -= text.utf8.count; return .string(text)
        }
        if let date = value as? Date { guard budget >= 16 else { return nil }; budget -= 16; return .object(["__forelDate": .number(date.timeIntervalSince1970)]) }
        if let number = value as? NSNumber {
            guard budget >= 16 else { return nil }; budget -= 16
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            guard number.doubleValue.isFinite else { return nil }; return .number(number.doubleValue)
        }
        if let values = value as? [Any], values.count <= 10_000 {
            let converted = values.compactMap { convert($0, depth: depth + 1, budget: &budget) }
            return converted.count == values.count ? .array(converted) : nil
        }
        return nil
    }
}
