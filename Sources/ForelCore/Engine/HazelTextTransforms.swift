import Foundation

/// Applies the editable per-token pipeline: default, ordered replacements, length.
enum HazelTextTransforms {
    static func validationError(_ token: JSONValue) -> String? {
        if token["defaultValue"] != nil, token["defaultValue"]?.stringValue == nil { return "Invalid default value" }
        if token["maxLength"] != nil, token["maxLength"]?.stringValue == nil { return "Invalid maximum length" }
        if let limit = token["maxLength"]?.stringValue, (!limit.isEmpty && Int(limit).map({ (0...10_000).contains($0) }) != true) { return "Maximum length must be between 0 and 10000" }
        guard let replacements = token["replacements"]?.arrayValue else { return token["replacements"] == nil ? nil : "Invalid text replacements" }
        guard replacements.count <= 50 else { return "Too many text replacements" }
        for item in replacements {
            guard let find = item["find"]?.stringValue, !find.isEmpty, find.utf8.count <= 4096,
                  let replace = item["replace"]?.stringValue, replace.utf8.count <= 4096 else { return "Enter text to find and replace" }
            if item["regex"]?.boolValue == true, (try? NSRegularExpression(pattern: find)) == nil { return "Enter a valid replacement regular expression" }
        }
        return nil
    }
    static func apply(_ input: String, token: JSONValue) throws -> String {
        guard validationError(token) == nil else { throw ActionError("Invalid text transformations") }
        var result = input.isEmpty ? (token["defaultValue"]?.stringValue ?? input) : input
        guard result.utf8.count <= 1_000_000 else { throw ActionError("Transformed text is too large") }
        for item in token["replacements"]?.arrayValue ?? [] {
            guard let find = item["find"]?.stringValue, let replacement = item["replace"]?.stringValue else { throw ActionError("Invalid replacement") }
            if item["regex"]?.boolValue == true {
                let regex = try NSRegularExpression(pattern: find)
                var estimate = result.utf8.count, excessive = false
                regex.enumerateMatches(in: result, range: NSRange(result.startIndex..., in: result)) { match, _, stop in
                    guard let match else { return }
                    let largest = (0..<match.numberOfRanges).map { match.range(at: $0).length }.filter { $0 != NSNotFound }.max() ?? 0
                    let multiplier = replacement.contains("$") ? min(1_000_001, largest * 4 + 1) : 1
                    let (addition, overflow) = replacement.utf8.count.multipliedReportingOverflow(by: multiplier)
                    let (sum, sumOverflow) = estimate.addingReportingOverflow(addition)
                    if overflow || sumOverflow || sum > 1_000_000 { excessive = true; stop.pointee = true } else { estimate = sum }
                }
                guard !excessive else { throw ActionError("Replacement could produce too much text") }
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: replacement)
            } else {
                var cursor = result.startIndex, estimate = result.utf8.count
                while let range = result.range(of: find, range: cursor..<result.endIndex) {
                    let (next, overflow) = estimate.addingReportingOverflow(replacement.utf8.count)
                    guard !overflow, next <= 1_000_000 else { throw ActionError("Replacement could produce too much text") }
                    estimate = next; cursor = range.upperBound
                }
                result = result.replacingOccurrences(of: find, with: replacement)
            }
            guard result.utf8.count <= 1_000_000 else { throw ActionError("Transformed text is too large") }
        }
        return result
    }
    static func truncate(_ input: String, token: JSONValue) -> String {
        guard let text = token["maxLength"]?.stringValue, let limit = Int(text), (0...10_000).contains(limit) else { return input }
        return String(input.prefix(limit))
    }
}
