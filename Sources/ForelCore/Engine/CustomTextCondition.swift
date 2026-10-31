import Foundation

public struct CustomTextCondition: Codable, Equatable, Sendable {
    public var names: String = ""
    public var pattern: String = ""
    public var source: String = "name"
    public var collectAllMatches: Bool?
    public init() {}
    public var encoded: String { (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
    public static func decode(_ value: String) -> Self? {
        guard value.utf8.count <= 16_384, let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    private var captureNames: [String] { names.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
    public var validationError: String? {
        let values = captureNames
        guard !values.isEmpty, values.count <= 50, values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 255 }), Set(values).count == values.count,
              !pattern.isEmpty, pattern.utf8.count <= 4096, ["name", "fullName", "contents", "tags"].contains(source),
              let regex = try? NSRegularExpression(pattern: pattern), regex.numberOfCaptureGroups == values.count else {
            return "Enter unique comma-separated names and a regular expression with one capture group per name"
        }
        return nil
    }
    func evaluate(path: String, existing: [String: JSONValue] = [:], allowOCR: Bool = true) -> (Bool, [String: JSONValue])? {
        guard validationError == nil, FileManager.default.isReadableFile(atPath: path), let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let inputs: [String]
        switch source {
        case "name": inputs = [URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent]
        case "fullName": inputs = [URL(fileURLWithPath: path).lastPathComponent]
        case "contents": guard let text = ContentExtractor.extract(path: path, allowOCR: allowOCR).text, text.utf8.count <= 1_000_000 else { return nil }; inputs = [text]
        case "tags":
            guard let tags = try? FinderTags.readChecked(path), tags.count <= 10_000 else { return nil }
            inputs = tags.map { $0.split(separator: "\n").first.map(String.init) ?? $0 }
        default: return nil
        }
        var selected: [String: JSONValue]?
        var lists: [String: [JSONValue]] = Dictionary(uniqueKeysWithValues: captureNames.map { ($0, []) })
        var invalid = false, count = 0, capturedBytes = 0
        for input in inputs {
        guard input.utf8.count <= 1_000_000 else { return nil }
        regex.enumerateMatches(in: input, range: NSRange(input.startIndex..., in: input)) { match, _, stop in
            guard let match else { return }
            count += 1
            if count > 10_000 { invalid = true; stop.pointee = true; return }
            var result: [String: JSONValue] = [:]
            for (index, name) in captureNames.enumerated() {
                guard let range = Range(match.range(at: index + 1), in: input) else { invalid = true; stop.pointee = true; return }
                let text = String(input[range]); capturedBytes += text.utf8.count
                if capturedBytes > 1_000_000 { invalid = true; stop.pointee = true; return }
                result[name] = .string(text)
            }
            if collectAllMatches == true {
                for (name, value) in result { lists[name, default: []].append(value) }
            } else if CustomAttributeBinding.compatible(result, with: existing) { selected = result; stop.pointee = true }
        }
        if invalid || selected != nil { break }
        }
        if invalid { return nil }
        if collectAllMatches == true {
            guard count > 0 else { return (false, [:]) }
            let result = lists.mapValues { JSONValue.array($0) }
            return CustomAttributeBinding.compatible(result, with: existing) ? (true, result) : (false, [:])
        }
        return selected.map { (true, $0) } ?? (false, [:])
    }
}
