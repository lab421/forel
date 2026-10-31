// Forel - A native macOS file-automation app
// Copyright (C) 2026 Lab421

import Foundation
import ImageIO
import Darwin

/// Values used by Hazel tokens, captured before the first action in a rule.
public struct HazelPatternContext: Sendable {
    let path: String
    let dates: [String: Date]
    let spotlight: [String: JSONValue]
    public var attributes: [String: JSONValue] = [:]
    public var counterValue: Int64?
    public var ruleName: String?

    public init(path: String) {
        self.init(path: path, sources: ["dateCreated", "dateModified", "dateAdded", "currentDate", "hazelbuiltin:dateTaken"], spotlightKeys: [], spotlightReader: SpotlightToken.read)
    }

    public init(path: String, actions: [Action]) {
        self.init(path: path, actions: actions, spotlightReader: SpotlightToken.read)
    }

    init(path: String, actions: [Action], spotlightReader: (String, String) -> JSONValue?) {
        let sources = Set(actions.flatMap { ($0.params[HazelPattern.tokensKey]?.arrayValue ?? []).compactMap { token in
            token["type"]?.stringValue == "date" ? token["source"]?.stringValue : nil
        } })
        let keys = Set(actions.flatMap { ($0.params[HazelPattern.tokensKey]?.arrayValue ?? []).compactMap { token in
            token["type"]?.stringValue == "spotlight" ? token["source"]?.stringValue : nil
        } })
        self.init(path: path, sources: sources, spotlightKeys: keys, spotlightReader: spotlightReader)
    }

    private init(path: String, sources: Set<String>, spotlightKeys: Set<String>, spotlightReader: (String, String) -> JSONValue?) {
        self.path = path
        var values: [String: Date] = [:]
        for source in sources {
            values[source] = try? HazelPattern.dateValue(source, path: path)
        }
        self.dates = values
        var metadata: [String: JSONValue] = [:]
        for key in spotlightKeys { metadata[key] = spotlightReader(key, path) }
        self.spotlight = metadata
    }
}

/// Rendering for the subset of Hazel format tokens that Forel can represent.
/// Captures are taken from the original matched basename, even after a move.
enum HazelPattern {
    static let tokensKey = "hazel_pattern_tokens"
    static let regexKey = "hazel_capture_regex"
    static let namesKey = "hazel_capture_names"
    static let sortKey = "hazel_sort_subfolder"

    static func validationError(_ action: Action) -> String? {
        guard let tokens = action.params[tokensKey]?.arrayValue, !tokens.isEmpty else { return "Hazel pattern needs at least one token" }
        let names = (action.params[namesKey]?.arrayValue ?? []).compactMap(\.stringValue)
        let allocations = Set(tokens.filter { $0["type"]?.stringValue == "counter" }.map { $0["allocation"]?.stringValue ?? "increment" })
        if allocations.count > 1 { return "Counter tokens in one pattern must use the same allocation mode" }
        for (index, token) in tokens.enumerated() {
            guard let type = token["type"]?.stringValue else { return "Invalid Hazel pattern token" }
            if let error = HazelTextTransforms.validationError(token) { return error }
            if let error = HazelNumericTransforms.validationError(token) { return error }
            if token["pathSplit"] != nil, token["pathSplit"]?.stringValue == nil { return "Invalid folder path separator" }
            if let separator = token["pathSplit"]?.stringValue, !separator.isEmpty,
               (action.params[sortKey]?.boolValue != true || separator.count != 1 || type == "pathSeparator") { return "Path splitting requires a single separator in a folder pattern" }
            if type == "date" || type == "attributeDate" || (type == "spotlight" && token["valueType"]?.stringValue == "date") {
                for key in ["adjustYears", "adjustMonths", "adjustDays", "adjustHours", "adjustMinutes"] {
                    if let text = token[key]?.stringValue, Int(text).map({ (-10_000...10_000).contains($0) }) != true { return "Date adjustments must be whole numbers between -10000 and 10000" }
                }
            }
            if let casing = token["case"]?.stringValue, !["title", "lower", "upper"].contains(casing) { return "Unsupported token case transformation" }
            switch type {
            case "literal", "name", "extension", "extensionBare", "size", "comment", "fullName", "rule": break
            case "extensionIfMissing":
                guard action.kind == .rename, index == tokens.count - 1 else { return "Place the optional original extension at the end of a rename pattern" }
            case "attribute":
                guard token["value"]?.stringValue?.isEmpty == false else { return "Choose a script attribute" }
            case "attributeList":
                guard token["value"]?.stringValue?.isEmpty == false,
                      let selection = token["selection"]?.stringValue,
                      ["all", "first", "last", "index"].contains(selection) else { return "Choose a list attribute and selection" }
                if selection == "index" {
                    guard let text = token["index"]?.stringValue, let index = Int(text), index != 0, (-10_000...10_000).contains(index) else { return "List position must be between -10000 and -1 or 1 and 10000" }
                }
            case "attributeNumber":
                guard token["value"]?.stringValue?.isEmpty == false,
                      let adjustment = token["adjustment"]?.stringValue,
                      let number = Double(adjustment), number.isFinite else { return "Choose a number attribute and a finite adjustment" }
            case "spotlight":
                guard let key = token["source"]?.stringValue, !key.isEmpty, key.utf8.count <= 255,
                      key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.-")).contains($0) }),
                      let type = token["valueType"]?.stringValue, ["text", "number", "date", "list", "boolean"].contains(type) else { return "Choose a Spotlight key and type" }
                if type == "date", token["value"]?.stringValue?.isEmpty != false { return "Choose a date format" }
                if type == "list" {
                    let selection = token["selection"]?.stringValue ?? "all"
                    if !["all", "first", "last", "index"].contains(selection) { return "Choose a list selection" }
                    if selection == "index" {
                        guard let text = token["index"]?.stringValue, let index = Int(text), index != 0, (-10_000...10_000).contains(index) else { return "Choose a valid list position" }
                    }
                }
            case "capture":
                guard let value = token["value"]?.stringValue, names.contains(value) else {
                    return "Choose a capture from the matching condition"
                }
                if let regex = action.params[regexKey]?.stringValue, (try? NSRegularExpression(pattern: regex)) == nil { return "Invalid capture pattern" }
            case "date":
                guard let source = token["source"]?.stringValue,
                      ["dateAdded", "dateCreated", "dateModified", "currentDate", "hazelbuiltin:dateTaken"].contains(source),
                      let format = token["value"]?.stringValue, !format.isEmpty else { return "Choose a date source and format" }
            case "attributeDate":
                guard token["source"]?.stringValue?.isEmpty == false, token["value"]?.stringValue?.isEmpty == false else { return "Choose a script date attribute and format" }
            case "counter":
                guard let text = token["digits"]?.stringValue, let digits = Int(text), (0...20).contains(digits) else { return "Counter digits must be between 0 and 20" }
                if let format = token["numberFormat"]?.stringValue, !["numeric", "lowercase", "uppercase"].contains(format) { return "Choose a counter format" }
                if let allocation = token["allocation"]?.stringValue, !["increment", "lowest"].contains(allocation) || (allocation == "lowest" && action.kind != .rename) { return "Lowest available is only supported when renaming" }
            case "pathSeparator":
                guard action.params[sortKey]?.boolValue == true, index > 0, index + 1 < tokens.count,
                      tokens[index - 1]["type"]?.stringValue != "pathSeparator" else { return "Place folder separators between folder names" }
            default: return "Unsupported Hazel pattern token"
            }
        }
        return nil
    }

    static func render(_ action: Action, path: String, contextPath: String?, context: HazelPatternContext? = nil, filename: Bool = true) throws -> String {
        if let error = validationError(action) { throw ActionError(error) }
        guard let tokens = action.params[tokensKey]?.arrayValue else { throw ActionError("Missing Hazel pattern") }
        let original = context?.path ?? contextPath ?? path
        let basename = URL(fileURLWithPath: original).deletingPathExtension().lastPathComponent
        var captures: [String: String] = [:]
        let names = (action.params[namesKey]?.arrayValue ?? []).compactMap(\.stringValue)
        for name in names {
            if case .string(let value) = context?.attributes[name] { captures[name] = value }
        }
        if captures.count < names.count, let regex = action.params[regexKey]?.stringValue {
            let re = try NSRegularExpression(pattern: regex, options: [.caseInsensitive])
            let range = NSRange(basename.startIndex..., in: basename)
            if let match = re.firstMatch(in: basename, range: range), match.numberOfRanges == names.count + 1 {
                for (index, name) in names.enumerated() {
                    if let range = Range(match.range(at: index + 1), in: basename) { captures[name] = String(basename[range]) }
                }
            }
        }
        var result = ""
        for token in tokens {
            guard let type = token["type"]?.stringValue else { throw ActionError("Invalid Hazel pattern token") }
            let value = token["value"]?.stringValue ?? ""
            var part = ""
            switch type {
            case "literal": part += value
            case "rule":
                guard let name = context?.ruleName else { part += try missingValue(token, message: "The rule name is unavailable"); break }
                part += name
            case "fullName": part += URL(fileURLWithPath: path).lastPathComponent
            case "comment":
                let metadataPath = FileManager.default.fileExists(atPath: path) ? path : original
                part += try FinderComment.read(metadataPath) ?? ""
            case "name": part += URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            case "extension":
                let ext = URL(fileURLWithPath: path).pathExtension
                if !ext.isEmpty { part += "." + ext }
            case "extensionBare": part += URL(fileURLWithPath: path).pathExtension
            case "extensionIfMissing":
                let ext = URL(fileURLWithPath: path).pathExtension
                if !ext.isEmpty && !result.lowercased().hasSuffix("." + ext.lowercased()) { part += "." + ext }
            case "size":
                let metadataPath = FileManager.default.fileExists(atPath: path) ? path : original
                let attributes = try FileManager.default.attributesOfItem(atPath: metadataPath)
                part += ActionExecutor.formatFileSize((attributes[.size] as? UInt64) ?? 0)
            case "capture":
                part += try captures[value] ?? missingValue(token, message: "Missing captured value: \(value)")
            case "attribute":
                guard let attribute = context?.attributes[value] else { part += try missingValue(token, message: "Rule attribute \(value) is unavailable"); break }
                switch attribute {
                case .string(let text): part += text
                case .number(let number):
                    guard number.isFinite else { throw ActionError("Rule number attribute is invalid") }
                    part += NSDecimalNumber(value: number).stringValue
                case .bool(let flag): part += flag ? "true" : "false"
                default: throw ActionError("Script attribute \(value) cannot be used in text")
                }
            case "spotlight":
                let key = token["source"]?.stringValue ?? ""
                let metadata: JSONValue?
                if let context { metadata = context.spotlight[key] } else { metadata = SpotlightToken.read(key: key, path: original) }
                guard let metadata else { part += try missingValue(token, message: "Spotlight attribute \(key) is unavailable"); break }
                switch (token["valueType"]?.stringValue, metadata) {
                case ("text", .string(let text)): part += text
                case ("number", .number(let number)):
                    guard number.isFinite else { throw ActionError("Spotlight number is invalid") }
                    part += NSDecimalNumber(value: number).stringValue
                case ("boolean", .bool(let flag)): part += flag ? "true" : "false"
                case ("date", .object(let data)):
                    guard case .number(let seconds) = data["__forelDate"], seconds.isFinite else { throw ActionError("Spotlight date is invalid") }
                    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = .current; formatter.dateFormat = value
                    part += formatter.string(from: try adjustedDate(Date(timeIntervalSince1970: seconds), token: token))
                case ("list", .array(let items)):
                    let strings = items.compactMap(\.stringValue)
                    guard strings.count == items.count else { throw ActionError("Spotlight list contains non-text values") }
                    switch token["selection"]?.stringValue ?? "all" {
                    case "all": part += strings.joined(separator: token["separator"]?.stringValue ?? ", ")
                    case "first": part += try strings.first ?? missingValue(token, message: "Spotlight list is empty")
                    case "last": part += try strings.last ?? missingValue(token, message: "Spotlight list is empty")
                    case "index":
                        guard let text = token["index"]?.stringValue, let index = Int(text), index != 0, (-10_000...10_000).contains(index) else { throw ActionError("Invalid Spotlight list position") }
                        guard abs(index) <= strings.count else { part += try missingValue(token, message: "Spotlight list position is unavailable"); break }
                        part += strings[index > 0 ? index - 1 : strings.count + index]
                    default: throw ActionError("Unsupported Spotlight list selection")
                    }
                default: throw ActionError("Spotlight attribute \(key) has an unexpected type")
                }
            case "attributeList":
                guard case .array(let list) = context?.attributes[value] else { part += try missingValue(token, message: "List attribute \(value) is unavailable"); break }
                let strings = try list.map { item -> String in
                    guard case .string(let text) = item else { throw ActionError("List attribute \(value) contains a non-text item") }
                    return text
                }
                switch token["selection"]?.stringValue {
                case "all": part += strings.joined(separator: token["separator"]?.stringValue ?? ", ")
                case "first": part += try strings.first ?? missingValue(token, message: "List attribute \(value) is empty")
                case "last": part += try strings.last ?? missingValue(token, message: "List attribute \(value) is empty")
                case "index":
                    guard let text = token["index"]?.stringValue, let index = Int(text), index != 0,
                          (-10_000...10_000).contains(index), abs(index) <= strings.count else { part += try missingValue(token, message: "List position is unavailable"); break }
                    part += strings[index > 0 ? index - 1 : strings.count + index]
                default: throw ActionError("Unsupported list selection")
                }
            case "attributeNumber":
                guard case .number(let number) = context?.attributes[value], number.isFinite,
                      let adjustment = token["adjustment"]?.stringValue,
                      let offset = Double(adjustment), offset.isFinite,
                      let input = Decimal(string: String(number), locale: Locale(identifier: "en_US_POSIX")),
                      let delta = Decimal(string: adjustment, locale: Locale(identifier: "en_US_POSIX")) else {
                    part += try missingValue(token, message: "Number attribute \(value) or its adjustment is unavailable"); break
                }
                let sum = NSDecimalNumber(decimal: input).adding(NSDecimalNumber(decimal: delta))
                guard sum != NSDecimalNumber.notANumber else { throw ActionError("Number adjustment is out of range") }
                part += sum.stringValue
            case "date":
                let source = token["source"]?.stringValue ?? ""
                let date: Date
                if let context {
                    guard let captured = context.dates[source] else { part += try missingValue(token, message: "The Hazel date value is unavailable"); break }
                    date = captured
                } else {
                    let metadataPath = FileManager.default.fileExists(atPath: path) ? path : original
                    guard let available = try? dateValue(source, path: metadataPath) else { part += try missingValue(token, message: "The Hazel date value is unavailable"); break }
                    date = available
                }
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.timeZone = .current
                formatter.dateFormat = value
                part += formatter.string(from: try adjustedDate(date, token: token))
            case "attributeDate":
                let source = token["source"]?.stringValue ?? ""
                guard case .number(let seconds) = context?.attributes[source]?["__forelDate"] else {
                    part += try missingValue(token, message: "Rule date attribute \(source) is unavailable"); break
                }
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.timeZone = .current
                formatter.dateFormat = value
                guard seconds.isFinite else { throw ActionError("Script date attribute \(source) is invalid") }
                part += formatter.string(from: try adjustedDate(Date(timeIntervalSince1970: seconds), token: token))
            case "counter":
                guard let number = context?.counterValue, number > 0,
                      let text = token["digits"]?.stringValue, let digits = Int(text), (0...20).contains(digits) else {
                    throw ActionError("The folder counter or its digit width is unavailable")
                }
                switch token["numberFormat"]?.stringValue ?? "numeric" {
                case "numeric":
                    let numberText = String(number)
                    part += String(repeating: "0", count: max(0, digits - numberText.count)) + numberText
                case "lowercase", "uppercase":
                    var remaining = number
                    var characters: [Character] = []
                    let base: UInt8 = token["numberFormat"]?.stringValue == "uppercase" ? 65 : 97
                    while remaining > 0 {
                        remaining -= 1
                        characters.append(Character(UnicodeScalar(base + UInt8(remaining % 26))))
                        remaining /= 26
                    }
                    part += String(characters.reversed())
                default: throw ActionError("Unsupported counter format")
                }
            default: throw ActionError("Unsupported Hazel pattern token")
            }
            if part.isEmpty, let fallback = token["defaultValue"]?.stringValue { part = fallback }
            part = try HazelNumericTransforms.apply(part, token: token)
            part = try HazelTextTransforms.apply(part, token: token)
            switch token["case"]?.stringValue {
            case nil: break
            case "title": part = part.capitalized
            case "lower": part = part.lowercased()
            case "upper": part = part.uppercased()
            default: throw ActionError("Unsupported Hazel token case transformation")
            }
            part = HazelTextTransforms.truncate(part, token: token)
            result += part
        }
        if filename { try validateComponent(result) }
        return result
    }

    private static func missingValue(_ token: JSONValue, message: String) throws -> String {
        guard let value = token["defaultValue"]?.stringValue else { throw ActionError(message) }
        return value
    }

    static func validateComponent(_ value: String) throws {
        guard !value.isEmpty, value != ".", value != "..", !value.contains("/"), !value.contains("\0"),
              value.utf8.count <= 255, !value.hasSuffix("."), !value.hasSuffix(" ") else {
            throw ActionError("Hazel pattern produced an invalid filename or folder name")
        }
    }

    private static func adjustedDate(_ date: Date, token: JSONValue) throws -> Date {
        var components = DateComponents()
        for (key, component) in [("adjustYears", Calendar.Component.year), ("adjustMonths", .month), ("adjustDays", .day), ("adjustHours", .hour), ("adjustMinutes", .minute)] {
            guard let text = token[key]?.stringValue else { continue }
            guard let amount = Int(text), (-10_000...10_000).contains(amount) else { throw ActionError("Invalid date adjustment") }
            components.setValue(amount, for: component)
        }
        guard let adjusted = Calendar.current.date(byAdding: components, to: date) else { throw ActionError("Date adjustment is out of range") }
        return adjusted
    }

    static func sortDestination(_ action: Action, path: String, contextPath: String?, context: HazelPatternContext? = nil) throws -> String {
        guard let tokens = action.params[tokensKey]?.arrayValue, !tokens.isEmpty,
              case .object(let parameters) = action.params else { throw ActionError("Missing Hazel folder pattern") }
        var segments: [String] = [""]
        for token in tokens {
            if token["type"]?.stringValue == "pathSeparator" { segments.append(""); continue }
            var partAction = action
            var fields = parameters; fields[tokensKey] = .array([token]); partAction.params = .object(fields)
            let text = try render(partAction, path: path, contextPath: contextPath, context: context, filename: false)
            if let separator = token["pathSplit"]?.stringValue, !separator.isEmpty {
                let pieces = text.components(separatedBy: separator)
                guard pieces.allSatisfy({ !$0.isEmpty }) else { throw ActionError("A split folder pattern contains an empty component") }
                segments[segments.count - 1] += pieces[0]
                segments.append(contentsOf: pieces.dropFirst())
            } else { segments[segments.count - 1] += text }
            guard segments.count <= 32 else { throw ActionError("Too many generated folders") }
        }
        guard segments.count <= 32, segments.allSatisfy({ !$0.isEmpty }) else { throw ActionError("Invalid Hazel folder pattern") }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        var target = parent
        for component in segments {
            try validateComponent(component)
            target.appendPathComponent(component, isDirectory: true)
            var info = stat()
            if lstat(target.path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) {
                throw ActionError("A generated folder is a symbolic link")
            }
        }
        return target.path
    }

    static func dateValue(_ source: String, path: String) throws -> Date {
        let url = URL(fileURLWithPath: path)
        let date: Date?
        switch source {
        case "dateCreated": date = try url.resourceValues(forKeys: [.creationDateKey]).creationDate
        case "dateModified": date = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        case "dateAdded": date = try url.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate
        case "currentDate": date = Date()
        case "hazelbuiltin:dateTaken":
            if let image = CGImageSourceCreateWithURL(url as CFURL, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
               let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
               let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.timeZone = .current
                formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
                date = formatter.date(from: text)
            } else { date = VideoDateTaken.read(path: path) }
        default: throw ActionError("Unsupported Hazel date source")
        }
        guard let date else { throw ActionError("The Hazel date value is unavailable") }
        return date
    }
}
