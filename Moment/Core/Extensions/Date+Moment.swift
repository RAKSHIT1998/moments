import Foundation

extension Date {
    /// "2 days ago", "Yesterday", "in 9 days" — human, not database-y.
    var relativeDescription: String {
        let cal = Calendar.current
        let now = Date.now
        if cal.isDateInToday(self) { return "Today" }
        if cal.isDateInYesterday(self) { return "Yesterday" }
        if cal.isDateInTomorrow(self) { return "Tomorrow" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: self)).day ?? 0
        if days < 0 {
            if days > -7 { return "\(-days) days ago" }
            if days > -31 { return "\(-days / 7) week\(-days / 7 == 1 ? "" : "s") ago" }
            return self.formatted(.dateTime.month(.abbreviated).day())
        } else {
            if days < 7 { return "in \(days) days" }
            if days < 31 { return "in \(days / 7) week\(days / 7 == 1 ? "" : "s")" }
            return self.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    var shortDate: String { formatted(.dateTime.month(.abbreviated).day()) }
    var mediumDate: String { formatted(date: .abbreviated, time: .omitted) }
    var monthYear: String { formatted(.dateTime.month(.wide).year()) }

    func daysUntil(_ other: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: self), to: calendar.startOfDay(for: other)).day ?? 0
    }

    func adding(days: Int, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: days, to: self) ?? self
    }
}

/// Describes an approximate time window the way a person would say it.
enum TemporalFormatter {
    static func describe(start: Date?, end: Date?, precision: TemporalPrecision?) -> String? {
        guard let start else { return nil }
        switch precision ?? .day {
        case .exact: return start.formatted(date: .abbreviated, time: .shortened)
        case .day: return start.mediumDate
        case .week: return "week of \(start.shortDate)"
        case .month: return start.formatted(.dateTime.month(.wide).year())
        case .season, .year: return start.formatted(.dateTime.year())
        case .vague: return "sometime"
        }
    }
}
