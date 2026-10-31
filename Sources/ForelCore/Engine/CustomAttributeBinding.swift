import Foundation

enum CustomAttributeBinding {
    static func compatible(_ values: [String: JSONValue], with attributes: [String: JSONValue]) -> Bool {
        values.allSatisfy { key, value in attributes[key].map { $0 == value } ?? true }
    }
    static func bind(_ values: [String: JSONValue], to attributes: inout [String: JSONValue]) -> Bool {
        guard compatible(values, with: attributes) else { return false }
        attributes.merge(values) { current, _ in current }
        return true
    }
}
