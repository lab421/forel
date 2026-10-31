import Foundation

enum HazelNumericTransforms {
    static func validationError(_ token: JSONValue) -> String? {
        for key in ["numericAdjustment", "minimumDigits", "groupingSeparator"] where token[key] != nil && token[key]?.stringValue == nil { return "Invalid numeric format" }
        if let adjustment = token["numericAdjustment"]?.stringValue, !adjustment.isEmpty,
           Double(adjustment).map({ $0.isFinite }) != true { return "Enter a finite numeric adjustment" }
        if let digits = token["minimumDigits"]?.stringValue, !digits.isEmpty,
           Int(digits).map({ (0...20).contains($0) }) != true { return "Minimum numeric digits must be between 0 and 20" }
        if let separator = token["groupingSeparator"]?.stringValue, separator.utf8.count > 16 { return "Grouping separator is too long" }
        return nil
    }

    static func apply(_ input: String, token: JSONValue) throws -> String {
        guard validationError(token) == nil else { throw ActionError("Invalid numeric format") }
        let adjustment = token["numericAdjustment"]?.stringValue ?? ""
        let digits = token["minimumDigits"]?.stringValue ?? ""
        let separator = token["groupingSeparator"]?.stringValue ?? ""
        guard !adjustment.isEmpty || !digits.isEmpty || !separator.isEmpty else { return input }
        let locale = Locale(identifier: "en_US_POSIX")
        guard let numeric = Double(input), numeric.isFinite, let value = Decimal(string: input, locale: locale),
              let offset = Decimal(string: adjustment.isEmpty ? "0" : adjustment, locale: locale) else { throw ActionError("Numeric formatting requires a finite number") }
        let sum = NSDecimalNumber(decimal: value).adding(NSDecimalNumber(decimal: offset))
        guard sum != .notANumber else { throw ActionError("Numeric adjustment is out of range") }
        var text = sum.stringValue
        guard !text.lowercased().contains("e") else { throw ActionError("Numeric value is outside supported formatting range") }
        let negative = text.hasPrefix("-")
        if negative { text.removeFirst() }
        let components = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        var integer = String(components[0]); let width = Int(digits) ?? 0
        integer = String(repeating: "0", count: max(0, width - integer.count)) + integer
        if !separator.isEmpty {
            var grouped = ""
            for (index, char) in integer.reversed().enumerated() {
                if index > 0 && index % 3 == 0 { grouped = separator + grouped }
                grouped = String(char) + grouped
            }
            integer = grouped
        }
        return (negative ? "-" : "") + integer + (components.count == 2 ? "." + String(components[1]) : "")
    }
}
