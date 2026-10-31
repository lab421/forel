import Foundation

public struct CustomDateCondition: Codable, Equatable, Sendable {
    public var name: String = ""
    public var pattern: String = ""
    public var format: String = "yyyy-MM-dd"
    public var source: String = "name"
    public init() {}
    public var encoded: String { (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
    public static func decode(_ value: String) -> Self? {
        guard value.utf8.count <= 16_384, let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    public var validationError: String? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 255,
              !pattern.isEmpty, pattern.utf8.count <= 4096, !format.isEmpty, format.utf8.count <= 256,
              ["name", "fullName", "contents"].contains(source),
              let regex = try? NSRegularExpression(pattern: pattern), regex.numberOfCaptureGroups == 1 else {
            return "Enter a name, date format and regular expression with exactly one capture group"
        }
        return nil
    }
    func evaluate(path: String, existing: [String: JSONValue] = [:], allowOCR: Bool = true) -> (Bool, [String: JSONValue])? {
        guard validationError == nil, FileManager.default.isReadableFile(atPath: path), let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let input: String
        switch source {
        case "name": input = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        case "fullName": input = URL(fileURLWithPath: path).lastPathComponent
        case "contents": guard let text = ContentExtractor.extract(path: path, allowOCR: allowOCR).text, text.utf8.count <= 1_000_000 else { return nil }; input = text
        default: return nil
        }
        let fullRange = NSRange(input.startIndex..., in: input)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = .current
        formatter.isLenient = false; formatter.dateFormat = format
        var selected: [String: JSONValue]?
        var count = 0, exceeded = false
        regex.enumerateMatches(in: input, range: fullRange) { match, _, stop in
            guard let match else { return }
            count += 1
            if count > 10_000 { exceeded = true; stop.pointee = true; return }
            guard let range = Range(match.range(at: 1), in: input), let date = formatter.date(from: String(input[range])) else { return }
            let result: [String: JSONValue] = [name: .object(["__forelDate": .number(date.timeIntervalSince1970)])]
            if CustomAttributeBinding.compatible(result, with: existing) { selected = result; stop.pointee = true }
        }
        if exceeded { return nil }
        return selected.map { (true, $0) } ?? (false, [:])
    }
}
