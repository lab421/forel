import Foundation

/// Ranking over visible siblings that pass all explicitly configured filters.
public struct PeerRankingCondition: Codable, Equatable, Sendable {
    public enum Attribute: String, Codable, CaseIterable, Sendable {
        case size, created, modified, added, lastOpened
        public var label: String { switch self { case .size: return "Size"; case .created: return "Date created"; case .modified: return "Date modified"; case .added: return "Date added"; case .lastOpened: return "Date last opened" } }
    }
    public var attribute: Attribute = .modified
    public var descending: Bool = true
    public var count: Int = 1
    public var filters: [Condition] = []
    public init() {}
    public var encoded: String { (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
    public static func decode(_ value: String) -> Self? {
        guard value.utf8.count <= 128_000, let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    public var validationError: String? {
        guard (1...10_000).contains(count), filters.count <= 100,
              filters.allSatisfy({ Self.safeFilter($0, depth: 0) }), RuleValidator.validate(filters).isEmpty else { return "Enter a rank from 1 to 10000 and valid, side-effect-free peer filters" }
        return nil
    }
    private static func safeFilter(_ condition: Condition, depth: Int) -> Bool {
        guard depth < 16, !ChangeCondition.isChange(condition) else { return false }
        if condition.kind == .conditionGroup {
            guard let group = ConditionGroup.decode(condition.value), group.target == .current else { return false }
            return group.conditions.allSatisfy { safeFilter($0, depth: depth + 1) }
        }
        if condition.kind == .dateComparison {
            guard let comparison = DateComparisonCondition.decode(condition.value), comparison.isValid else { return false }
            return ![.custom, .lastMatched].contains(comparison.left) && ![.custom, .lastMatched].contains(comparison.right)
        }
        return ![.peerRanking, .hazelScriptCondition, .customTextMatch, .customDateMatch, .customTableMatch, .scriptAttribute, .dateLastMatched,
                 .contents, .contentsWithoutOCR, .contentsWithOCR, .contentsWithPassword, .spotlightAttribute].contains(condition.kind)
    }
    func evaluate(path: String, depth: Int?, lastOpened: any LastOpenedMetadataProvider, now: Date, additionalFilters: [Condition] = [], allowOCR: Bool = true) throws -> Bool? {
        guard validationError == nil else { throw ActionError("Peer ranking configuration is invalid") }
        guard additionalFilters.allSatisfy({ Self.safeFilter($0, depth: 0) }) else { throw ActionError("Peer ranking cannot use script, content, change-tracking, or context-dependent conditions as peer filters") }
        let target = URL(fileURLWithPath: path).standardizedFileURL
        guard let peers = try? FileManager.default.contentsOfDirectory(at: target.deletingLastPathComponent(), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]), peers.count <= 10_000 else { return nil }
        var ranked: [(String, Double)] = []
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        for peer in peers {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime <= deadline else { return nil }
            if SystemFileFilter.isExcluded(peer.lastPathComponent) { continue }
            var attributes: [String: JSONValue] = [:]
            var eligible = true
            for filter in filters + additionalFilters {
                guard let matched = try ConditionEvaluator.evaluateWithContext(filter, path: peer.path, depth: depth, lastOpened: lastOpened, now: now, requireAvailable: true, attributes: &attributes, allowOCR: allowOCR) else { return nil }
                if !matched { eligible = false; break }
            }
            guard eligible else { continue }
            let values = try? peer.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey, .addedToDirectoryDateKey])
            let metric: Double?
            switch attribute {
            case .size: metric = values?.fileSize.map(Double.init)
            case .created: metric = values?.creationDate?.timeIntervalSince1970
            case .modified: metric = values?.contentModificationDate?.timeIntervalSince1970
            case .added: metric = values?.addedToDirectoryDate?.timeIntervalSince1970
            case .lastOpened: metric = lastOpened.lastOpened(path: peer.path)?.timeIntervalSince1970
            }
            guard let metric, metric.isFinite else { return nil }
            ranked.append((peer.standardizedFileURL.path, metric))
        }
        ranked.sort { left, right in left.1 == right.1 ? left.0 < right.0 : (descending ? left.1 > right.1 : left.1 < right.1) }
        guard let position = ranked.firstIndex(where: { $0.0 == target.path }) else { return nil }
        return position < count
    }
}
