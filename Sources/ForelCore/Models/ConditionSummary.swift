import Foundation

public extension Condition {
    /// User-facing value for detail and preview surfaces. Never exposes script
    /// source, serialized configuration or Keychain references.
    var displayValue: String {
        switch kind {
        case .hazelScriptCondition: return "Script condition"
        case .contentsWithPassword:
            guard let spec = PasswordContentCondition.decode(value) else { return "Invalid PDF condition" }
            return spec.operand.isEmpty ? "PDF with saved password" : "PDF text: \(spec.operand)"
        case .conditionGroup:
            guard let group = ConditionGroup.decode(value) else { return "Invalid nested conditions" }
            return "\(group.match.rawValue.capitalized) of \(group.conditions.count) nested conditions"
        case .currentTime:
            guard let schedule = CurrentTimeCondition.schedule(value) else { return "Invalid schedule" }
            return Self.scheduleSummary(schedule)
        case .spotlightAttribute, .scriptAttribute:
            guard let spec = SpotlightCondition.decode(value) else { return "Invalid attribute comparison" }
            return "\(spec.key): \(spec.operand)"
        case .customTextMatch:
            guard let spec = CustomTextCondition.decode(value) else { return "Invalid text match" }
            return "\(spec.collectAllMatches == true ? "Collect" : "Capture") \(spec.names) from \(spec.source)"
        case .customDateMatch:
            guard let spec = CustomDateCondition.decode(value) else { return "Invalid date match" }
            return "Capture \(spec.name) from \(spec.source) as \(spec.format)"
        case .customTableMatch:
            guard let spec = CustomTableCondition.decode(value) else { return "Invalid table match" }
            return "Match \(spec.matchColumn) from \(spec.filePath == nil ? "an inline table" : "a table file") in \(spec.source)"
        case .dateComparison:
            guard let spec = DateComparisonCondition.decode(value) else { return "Invalid date comparison" }
            func source(_ value: DateComparisonCondition.DateSource, attribute: String) -> String {
                if value == .custom { return "\(value.label) \(attribute)" }
                if value == .fixed { return spec.fixedDate }
                return value.label
            }
            var summary = "\(source(spec.left, attribute: spec.leftAttribute)) \(spec.relation.label)"
            if [.before, .after, .sameDay].contains(spec.relation) { summary += " \(source(spec.right, attribute: spec.rightAttribute))" }
            if [.withinPrevious, .withinNext].contains(spec.relation) { summary += " \(spec.amount) \(spec.unit.label)" }
            if [.occursAt, .occursBefore, .occursAfter].contains(spec.relation), let schedule = CurrentTimeCondition.schedule(spec.schedule) { summary += " \(Self.scheduleSummary(schedule))" }
            return summary
        case .peerRanking:
            guard let spec = PeerRankingCondition.decode(value) else { return "Invalid peer ranking" }
            return "\(spec.count) \(spec.descending ? "highest" : "lowest") by \(spec.attribute.label); \(spec.filters.count) peer filters"
        default: return value
        }
    }
    private static func scheduleSummary(_ schedule: CurrentTimeCondition.Schedule) -> String {
        let relation = schedule.relation == .before ? "before " : schedule.relation == .after ? "after " : ""
        var parts = [relation + schedule.time]
        if !schedule.weekdays.isEmpty { parts.append("weekdays \(schedule.weekdays)") }
        if !schedule.monthdays.isEmpty { parts.append("days \(schedule.monthdays)") }
        if !schedule.months.isEmpty { parts.append("months \(schedule.months)") }
        return parts.joined(separator: ", ")
    }
}
