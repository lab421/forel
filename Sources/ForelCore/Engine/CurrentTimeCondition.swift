import Foundation

public enum CurrentTimeCondition {
    public enum Relation: String, Codable, CaseIterable, Sendable { case exact, before, after }
    public struct Schedule: Codable, Equatable, Sendable {
        public var time: String
        /// Missing in older schedules and imported archives means an exact minute.
        public var relation: Relation?
        /// Empty lists mean every value; weekdays use Calendar's 1=Sunday.
        public var weekdays: String
        public var monthdays: String
        public var months: String
        public init(time: String, weekdays: String = "", monthdays: String = "", months: String = "", relation: Relation? = nil) {
            self.time = time; self.weekdays = weekdays; self.monthdays = monthdays; self.months = months; self.relation = relation
        }
        public var encoded: String { (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
    }

    public static func schedule(_ value: String) -> Schedule? {
        if components(value) != nil { return Schedule(time: value) }
        guard value.utf8.count <= 1024, let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Schedule.self, from: data)
    }

    private static func list(_ value: String, range: ClosedRange<Int>) -> Set<Int>? {
        if value.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count <= 31 else { return nil }
        var values: Set<Int> = []
        for part in parts {
            let text = part.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(text), range.contains(number) else { return nil }
            values.insert(number)
        }
        return values
    }

    public static func isValid(_ value: String) -> Bool {
        guard let schedule = schedule(value), components(schedule.time) != nil,
              list(schedule.weekdays, range: 1...7) != nil, list(schedule.monthdays, range: 1...31) != nil,
              list(schedule.months, range: 1...12) != nil else { return false }
        return true
    }
    public static func components(_ text: String) -> (hour: Int, minute: Int)? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let hour = Int(parts[0]), let minute = Int(parts[1]), (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }
    public static func matches(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let schedule = schedule(text), let expected = components(schedule.time),
              let weekdays = list(schedule.weekdays, range: 1...7),
              let monthdays = list(schedule.monthdays, range: 1...31),
              let months = list(schedule.months, range: 1...12) else { return false }
        let actual = calendar.dateComponents([.hour, .minute, .weekday, .day, .month], from: now)
        guard let weekday = actual.weekday, let day = actual.day, let month = actual.month,
              let hour = actual.hour, let minute = actual.minute else { return false }
        let currentMinute = hour * 60 + minute
        let expectedMinute = expected.hour * 60 + expected.minute
        let timeMatches: Bool
        switch schedule.relation ?? .exact {
        case .exact: timeMatches = currentMinute == expectedMinute
        case .before: timeMatches = currentMinute < expectedMinute
        case .after: timeMatches = currentMinute > expectedMinute
        }
        return timeMatches &&
            (weekdays.isEmpty || weekdays.contains(weekday)) && (monthdays.isEmpty || monthdays.contains(day)) &&
            (months.isEmpty || months.contains(month))
    }
}
