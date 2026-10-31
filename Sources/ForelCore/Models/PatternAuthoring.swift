import Foundation

/// Switches the visible editor mode while preserving both drafts in the action.
public enum PatternAuthoring {
    private static let draftKey = "forel_structured_pattern_draft"
    private static let basicDraftKey = "forel_basic_rename_draft"
    public static func setStructured(_ enabled: Bool, on action: inout Action) {
        guard action.kind == .rename || action.kind == .moveToFolder, case .object(var params) = action.params else { return }
        let sorting = action.kind == .moveToFolder
        if enabled {
            if params[HazelPattern.tokensKey] == nil {
                if !sorting { params[basicDraftKey] = .string(params[ActionParam.pattern]?.stringValue ?? "") }
                if let draft = params[draftKey]?.arrayValue { params[HazelPattern.tokensKey] = .array(draft) }
                else if sorting { params[HazelPattern.tokensKey] = .array([.object(["type": .string("name")])]) }
                else {
                    let basic = params[ActionParam.pattern]?.stringValue ?? ""
                    params[HazelPattern.tokensKey] = .array(tokens(for: basic.isEmpty ? "{name}" : basic))
                }
            }
            if sorting { params[HazelPattern.sortKey] = .bool(true) }
            else if params[ActionParam.pattern]?.stringValue?.isEmpty != false { params[ActionParam.pattern] = .string("{name}.{extension}") }
        } else {
            if let tokens = params[HazelPattern.tokensKey]?.arrayValue { params[draftKey] = .array(tokens) }
            params[HazelPattern.tokensKey] = nil
            if sorting { params[HazelPattern.sortKey] = nil }
            else if let basic = params[basicDraftKey]?.stringValue { params[ActionParam.pattern] = .string(basic) }
            else if params[ActionParam.pattern]?.stringValue == "Hazel pattern" { params[ActionParam.pattern] = .string("{name}.{extension}") }
        }
        action.params = .object(params)
    }

    static func tokens(for basic: String) -> [JSONValue] {
        let mappings: [String: [String: JSONValue]] = [
            "name": ["type": .string("name")], "extension": ["type": .string("extensionBare")],
            "date_created": ["type": .string("date"), "source": .string("dateCreated"), "value": .string("yyyy-MM-dd")],
            "date_modified": ["type": .string("date"), "source": .string("dateModified"), "value": .string("yyyy-MM-dd")],
            "current_date": ["type": .string("date"), "source": .string("currentDate"), "value": .string("yyyy-MM-dd")],
            "size": ["type": .string("size")]
        ]
        let regex = try! NSRegularExpression(pattern: "\\{(name|extension|date_created|date_modified|current_date|size)\\}")
        let full = NSRange(basic.startIndex..., in: basic)
        var result: [JSONValue] = [], cursor = basic.startIndex
        for match in regex.matches(in: basic, range: full) {
            guard let whole = Range(match.range(at: 0), in: basic), let key = Range(match.range(at: 1), in: basic) else { continue }
            if cursor < whole.lowerBound { result.append(.object(["type": .string("literal"), "value": .string(String(basic[cursor..<whole.lowerBound]))])) }
            if let token = mappings[String(basic[key])] { result.append(.object(token)) }
            cursor = whole.upperBound
        }
        if cursor < basic.endIndex { result.append(.object(["type": .string("literal"), "value": .string(String(basic[cursor...]))])) }
        if !basic.contains("{extension}") { result.append(.object(["type": .string("extensionIfMissing")])) }
        return result.isEmpty ? [.object(["type": .string("literal"), "value": .string("")])] : result
    }
}
