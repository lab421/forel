import Foundation

/// A bounded, editable table whose matching row becomes named rule attributes.
public struct CustomTableCondition: Codable, Equatable, Sendable {
    public var prefix: String = ""
    public var table: String = ""
    public var matchColumn: String = ""
    public var source: String = "name"
    public var mode: String = "contains"
    public var filePath: String?
    public var separator: String?
    public var trimCells: Bool?
    public init() {}
    public var encoded: String { (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
    public static func decode(_ value: String) -> Self? {
        guard value.utf8.count <= 128_000, let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    private var rows: [[String]]? {
        if let filePath {
            guard !filePath.isEmpty else { return nil }
            guard let result = CustomTableFile.read(path: filePath, separator: separator ?? ",") else { return nil }
            return trimCells == true ? result.map { $0.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } } : result
        }
        var lines = table.components(separatedBy: "\n")
        while lines.count > 1 && lines.last == "" { lines.removeLast() }
        return lines.map { $0.components(separatedBy: "\t") }
    }
    public var validationError: String? {
        guard let data = rows else { return "The table file cannot be read or parsed" }
        return validationError(rows: data)
    }
    private func validationError(rows data: [[String]]) -> String? {
        guard !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prefix.utf8.count <= 100,
              ["name", "fullName", "contents"].contains(source), ["is", "contains"].contains(mode),
              data.count >= 2, data.count <= 1001, let headers = data.first, !headers.isEmpty, headers.count <= 50,
              headers.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 100 }), Set(headers).count == headers.count,
              headers.contains(matchColumn), data.dropFirst().allSatisfy({ $0.count == headers.count && !$0.contains(where: { $0.utf8.count > 4096 }) }) else {
            return "Enter a prefix, a tab-separated header and rows, and a valid match column"
        }
        return nil
    }
    func evaluate(path: String, existing: [String: JSONValue] = [:], allowOCR: Bool = true, loadRows: (() -> [[String]]?)? = nil) -> (Bool, [String: JSONValue])? {
        let snapshot: [[String]]?
        if let loadRows { snapshot = loadRows() } else { snapshot = rows }
        guard let data = snapshot, validationError(rows: data) == nil,
              FileManager.default.fileExists(atPath: path), FileManager.default.isReadableFile(atPath: path) else { return nil }
        let headers = data[0]
        guard let index = headers.firstIndex(of: matchColumn) else { return nil }
        let input: String
        switch source {
        case "name": input = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        case "fullName": input = URL(fileURLWithPath: path).lastPathComponent
        case "contents": guard let text = ContentExtractor.extract(path: path, allowOCR: allowOCR).text else { return nil }; input = text
        default: return nil
        }
        for row in data.dropFirst() {
            let candidate = row[index]
            guard !candidate.isEmpty else { continue }
            let matched = mode == "is" ? input == candidate : input.contains(candidate)
            if matched {
                let result = Dictionary(uniqueKeysWithValues: zip(headers.map { "\(prefix).\($0)" }, row.map(JSONValue.string)))
                if CustomAttributeBinding.compatible(result, with: existing) { return (true, result) }
            }
        }
        return (false, [:])
    }
}
