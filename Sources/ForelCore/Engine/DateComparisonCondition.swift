import Foundation

public struct DateComparisonCondition: Codable, Equatable, Sendable {
    public enum DateSource: String, Codable, CaseIterable, Sendable {
        case created, modified, added, lastOpened, lastMatched, current, custom, fixed
        public var label: String {
            switch self {
            case .created: return "Date created"
            case .modified: return "Date modified"
            case .added: return "Date added"
            case .lastOpened: return "Date last opened"
            case .lastMatched: return "Date last matched"
            case .current: return "Current time"
            case .custom: return "Custom date attribute"
            case .fixed: return "Fixed date"
            }
        }
    }
    public enum Relation: String, Codable, CaseIterable, Sendable {
        case before, after, sameDay, today, yesterday, tomorrow, thisWeek, thisMonth, thisQuarter, thisYear
        case withinPrevious, withinNext, occursAt, occursBefore, occursAfter
        public var label: String {
            switch self {
            case .before: return "is before"
            case .after: return "is after"
            case .sameDay: return "is on the same day as"
            case .today: return "is today"
            case .yesterday: return "is yesterday"
            case .tomorrow: return "is tomorrow"
            case .thisWeek: return "is this week"
            case .thisMonth: return "is this month"
            case .thisQuarter: return "is this quarter"
            case .thisYear: return "is this year"
            case .withinPrevious: return "is within the previous"
            case .withinNext: return "is within the next"
            case .occursAt: return "occurs at"
            case .occursBefore: return "occurs before"
            case .occursAfter: return "occurs after"
            }
        }
    }
    public enum Unit: String, Codable, CaseIterable, Sendable {
        case minutes, hours, days, weeks, months, years
        public var label: String { rawValue }
        var component: Calendar.Component {
            switch self {
            case .minutes: return .minute
            case .hours: return .hour
            case .days: return .day
            case .weeks: return .weekOfYear
            case .months: return .month
            case .years: return .year
            }
        }
    }
    public var left: DateSource = .modified
    public var right: DateSource = .current
    public var leftAttribute: String = ""
    public var rightAttribute: String = ""
    public var relation: Relation = .before
    public var fixedDate: String = ""
    public var amount: Int = 1
    public var unit: Unit = .days
    public var schedule: String = "09:00"
    public init() {}
    public var encoded: String { (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
    public static func decode(_ text: String) -> Self? {
        guard text.utf8.count <= 8192, let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    public var isValid: Bool {
        guard (1...1_000_000).contains(amount), leftAttribute.utf8.count <= 255, rightAttribute.utf8.count <= 255 else { return false }
        if left == .custom && leftAttribute.isEmpty { return false }
        if [.before, .after, .sameDay].contains(relation) {
            if right == .custom && rightAttribute.isEmpty { return false }
            if right == .fixed && Self.parseFixed(fixedDate) == nil { return false }
        }
        if left == .fixed && Self.parseFixed(fixedDate) == nil { return false }
        if [.occursAt, .occursBefore, .occursAfter].contains(relation), !CurrentTimeCondition.isValid(schedule) { return false }
        return true
    }

    static func parseFixed(_ value: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return date
    }

    func compare(_ leftDate: Date, right rightDate: Date?, now: Date, calendar: Calendar) -> Bool? {
        switch relation {
        case .before: return rightDate.map { leftDate < $0 }
        case .after: return rightDate.map { leftDate > $0 }
        case .sameDay: return rightDate.map { calendar.isDate(leftDate, inSameDayAs: $0) }
        case .today: return calendar.isDate(leftDate, inSameDayAs: now)
        case .yesterday, .tomorrow:
            let offset = relation == .yesterday ? -1 : 1
            guard let reference = calendar.date(byAdding: .day, value: offset, to: now) else { return nil }
            return calendar.isDate(leftDate, inSameDayAs: reference)
        case .thisWeek: return calendar.isDate(leftDate, equalTo: now, toGranularity: .weekOfYear)
        case .thisMonth: return calendar.isDate(leftDate, equalTo: now, toGranularity: .month)
        case .thisQuarter:
            guard let interval = calendar.dateInterval(of: .quarter, for: now) else { return nil }
            return leftDate >= interval.start && leftDate < interval.end
        case .thisYear: return calendar.isDate(leftDate, equalTo: now, toGranularity: .year)
        case .withinPrevious, .withinNext:
            let direction = relation == .withinPrevious ? -1 : 1
            let bound: Date
            switch unit {
            case .minutes, .hours, .days, .weeks:
                let seconds: TimeInterval = unit == .minutes ? 60 : unit == .hours ? 3_600 : unit == .days ? 86_400 : 604_800
                bound = now.addingTimeInterval(Double(direction * amount) * seconds)
            case .months, .years:
                guard let date = calendar.date(byAdding: unit.component, value: direction * amount, to: now) else { return nil }
                bound = date
            }
            return relation == .withinPrevious ? (bound...now).contains(leftDate) : (now...bound).contains(leftDate)
        case .occursAt, .occursBefore, .occursAfter:
            guard var recurrence = CurrentTimeCondition.schedule(schedule) else { return nil }
            recurrence.relation = relation == .occursAt ? .exact : relation == .occursBefore ? .before : .after
            return CurrentTimeCondition.matches(recurrence.encoded, now: leftDate, calendar: calendar)
        }
    }
}
