import Foundation

/// Understands "tomorrow", "next Friday", "December", "in two weeks", "sometime next year".
/// Produces a window + precision. If the text is ambiguous it stores an approximate window;
/// it never fabricates an exact date.
struct TemporalParser: Sendable {
    var now: Date
    var calendar: Calendar
    var userBirthday: Date?

    init(now: Date = .now, calendar: Calendar = .current, userBirthday: Date? = nil) {
        self.now = now
        self.calendar = calendar
        self.userBirthday = userBirthday
    }

    private static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
    private static let monthAbbrev = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec"]
    private static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    private static let numberWords: [String: Int] = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "couple": 2, "few": 3]

    /// All temporal references found in the text, in order of appearance.
    func parse(_ text: String) -> [TemporalHint] {
        var hints: [TemporalHint] = []
        let lower = text.lowercased()

        func add(_ h: TemporalHint?) { if let h, !hints.contains(where: { $0.rawText == h.rawText }) { hints.append(h) } }

        // Relative days
        if lower.matches(#"\b(day after tomorrow)\b"#) { add(day(offset: 2, raw: "day after tomorrow")) }
        else if lower.matches(#"\btomorrow\b"#) { add(dayWithOptionalTime(offset: 1, raw: "tomorrow", in: lower)) }
        if lower.matches(#"\b(today|tonight)\b"#) { add(dayWithOptionalTime(offset: 0, raw: lower.matches(#"\btonight\b"#) ? "tonight" : "today", in: lower)) }
        if lower.matches(#"\byesterday\b"#) { add(day(offset: -1, raw: "yesterday")) }

        // Weekdays: "next friday", "this friday", "on friday", "friday"
        for (index, name) in Self.weekdays.enumerated() {
            if let raw = lower.firstMatch(#"\b((next|this|on|by|coming)\s+)?(\#(name))\b"#, group: 0) {
                let isNext = raw.hasPrefix("next")
                add(weekday(index + 1, next: isNext, raw: raw))
            }
        }

        // "next week / month / year", "this weekend", "next weekend"
        if let raw = lower.firstMatch(#"\b(next|this|coming)\s+weekend\b"#, group: 0) { add(weekend(next: raw.hasPrefix("next"), raw: raw)) }
        if let raw = lower.firstMatch(#"\b(next|this)\s+week\b"#, group: 0) {
            let start = raw.hasPrefix("next") ? startOfNextWeek() : startOfWeek(now)
            add(TemporalHint(start: start, end: start.adding(days: 6, calendar: calendar), precision: .week, rawText: raw, isFuture: true))
        }
        if let raw = lower.firstMatch(#"\b(next|this)\s+month\b"#, group: 0) {
            let base = raw.hasPrefix("next") ? (calendar.date(byAdding: .month, value: 1, to: now) ?? now) : now
            add(monthHint(of: base, raw: raw))
        }
        if let raw = lower.firstMatch(#"\b((sometime|early|late|later)\s+)?(next|this)\s+year\b"#, group: 0) {
            let year = calendar.component(.year, from: now) + (raw.contains("next") ? 1 : 0)
            add(yearHint(year, raw: raw, vague: raw.contains("sometime")))
        }

        // "in two weeks", "in 3 days", "in a month", "in a couple of weeks"
        if let raw = lower.firstMatch(#"\bin\s+(a|an|\d+|one|two|three|four|five|six|seven|eight|nine|ten|couple|few)(\s+of)?\s+(days?|weeks?|months?|years?)\b"#, group: 0) {
            let parts = raw.split(separator: " ").map(String.init)
            let n = Int(parts[1]) ?? Self.numberWords[parts[1]] ?? 1
            let unit = parts.last ?? "days"
            let comp: Calendar.Component = unit.hasPrefix("day") ? .day : unit.hasPrefix("week") ? .weekOfYear : unit.hasPrefix("month") ? .month : .year
            if let date = calendar.date(byAdding: comp, value: n, to: now) {
                let precision: TemporalPrecision = comp == .day ? .day : comp == .weekOfYear ? .week : comp == .month ? .month : .year
                let end = precision == .day ? date : (calendar.date(byAdding: comp, value: 1, to: date) ?? date)
                add(TemporalHint(start: calendar.startOfDay(for: date), end: end, precision: precision, rawText: raw, isFuture: true))
            }
        }

        // Month names, optionally with day and/or year: "december", "dec 14", "september 22nd", "22 sept", "in december 2027"
        add(monthMention(in: lower))

        // Numeric dates "22/09", "09/22/2026", "2026-09-22"
        if hints.isEmpty, let detected = dataDetectorDate(in: text) { add(detected) }

        // Seasons
        for season in ["summer", "winter", "spring", "autumn", "fall"] where lower.matches(#"\b(this|next|in|for)\s+\#(season)\b"#) {
            add(seasonHint(season, raw: season))
        }

        // "end of the month/year"
        if let raw = lower.firstMatch(#"\bend of (the )?(month|year)\b"#, group: 0) {
            let comp: Calendar.Component = raw.hasSuffix("month") ? .month : .year
            if let interval = calendar.dateInterval(of: comp, for: now) {
                let start = calendar.date(byAdding: .day, value: -7, to: interval.end) ?? interval.end
                add(TemporalHint(start: start, end: interval.end, precision: comp == .month ? .week : .month, rawText: raw, isFuture: true))
            }
        }

        // "my birthday"
        if lower.matches(#"\bmy birthday\b"#), let bday = userBirthday {
            var comps = calendar.dateComponents([.month, .day], from: bday)
            comps.year = calendar.component(.year, from: now)
            if let d = calendar.date(from: comps) {
                let next = d < now ? (calendar.date(byAdding: .year, value: 1, to: d) ?? d) : d
                add(TemporalHint(start: calendar.startOfDay(for: next), end: next, precision: .day, rawText: "my birthday", isFuture: true))
            }
        }

        // Vague
        if hints.isEmpty, let raw = lower.firstMatch(#"\b(sometime|someday|later|soon|eventually|one day|at some point)\b"#, group: 0) {
            add(TemporalHint(start: now, end: calendar.date(byAdding: .month, value: 6, to: now) ?? now, precision: .vague, rawText: raw, isFuture: true))
        }

        return hints
    }

    /// The single most useful reference: the first future one, else the first.
    func primary(in text: String) -> TemporalHint? {
        let all = parse(text)
        return all.first(where: \.isFuture) ?? all.first
    }

    // MARK: - Builders

    private func day(offset: Int, raw: String) -> TemporalHint {
        let d = calendar.startOfDay(for: now.adding(days: offset, calendar: calendar))
        return TemporalHint(start: d, end: d, precision: .day, rawText: raw, isFuture: offset >= 0)
    }

    private func dayWithOptionalTime(offset: Int, raw: String, in lower: String) -> TemporalHint {
        var hint = day(offset: offset, raw: raw)
        if let time = timeOfDay(in: lower, near: raw) {
            hint.start = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: hint.start) ?? hint.start
            hint.end = hint.start
            hint.precision = .exact
            hint.rawText = "\(raw) at \(time.raw)"
        }
        return hint
    }

    private func timeOfDay(in lower: String, near anchor: String) -> (hour: Int, minute: Int, raw: String)? {
        guard let m = lower.firstMatch(#"\#(anchor)[^.\n]{0,20}?\bat\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b"#, group: 0) else { return nil }
        guard let hStr = m.firstMatch(#"at\s+(\d{1,2})"#), var hour = Int(hStr) else { return nil }
        let minute = Int(m.firstMatch(#":(\d{2})"#) ?? "0") ?? 0
        let ampm = m.firstMatch(#"(am|pm)"#)
        if ampm == "pm", hour < 12 { hour += 12 }
        if ampm == "am", hour == 12 { hour = 0 }
        if ampm == nil, hour < 7 { hour += 12 } // "at 5" almost always means 5pm in conversation
        return (hour, minute, m.firstMatch(#"at\s+(.*)"#) ?? "")
    }

    private func weekday(_ weekday: Int, next: Bool, raw: String) -> TemporalHint? {
        var comps = DateComponents()
        comps.weekday = weekday
        guard var date = calendar.nextDate(after: now, matching: comps, matchingPolicy: .nextTime) else { return nil }
        if next {
            // "next friday" — if the coming one is within this calendar week, skip to the following.
            let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)
            if let thisWeek, thisWeek.contains(date) {
                date = calendar.date(byAdding: .weekOfYear, value: 1, to: date) ?? date
            }
        }
        let d = calendar.startOfDay(for: date)
        return TemporalHint(start: d, end: d, precision: .day, rawText: raw, isFuture: true)
    }

    private func weekend(next: Bool, raw: String) -> TemporalHint? {
        var comps = DateComponents(); comps.weekday = 7
        guard var sat = calendar.nextDate(after: now, matching: comps, matchingPolicy: .nextTime) else { return nil }
        if next, let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now), thisWeek.contains(sat) {
            sat = calendar.date(byAdding: .weekOfYear, value: 1, to: sat) ?? sat
        }
        let start = calendar.startOfDay(for: sat)
        return TemporalHint(start: start, end: start.adding(days: 1, calendar: calendar), precision: .week, rawText: raw, isFuture: true)
    }

    private func startOfWeek(_ date: Date) -> Date { calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date }
    private func startOfNextWeek() -> Date { calendar.date(byAdding: .weekOfYear, value: 1, to: startOfWeek(now)) ?? now }

    private func monthHint(of date: Date, raw: String) -> TemporalHint? {
        guard let interval = calendar.dateInterval(of: .month, for: date) else { return nil }
        return TemporalHint(start: interval.start, end: interval.end.adding(days: -1, calendar: calendar), precision: .month, rawText: raw, isFuture: interval.end > now)
    }

    private func yearHint(_ year: Int, raw: String, vague: Bool) -> TemporalHint? {
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let end = calendar.date(from: DateComponents(year: year, month: 12, day: 31)) else { return nil }
        return TemporalHint(start: start, end: end, precision: vague ? .vague : .year, rawText: raw, isFuture: end > now)
    }

    private func seasonHint(_ season: String, raw: String) -> TemporalHint? {
        let year = calendar.component(.year, from: now)
        let (m1, m2): (Int, Int) = switch season {
        case "spring": (3, 5)
        case "summer": (6, 8)
        case "autumn", "fall": (9, 11)
        default: (12, 2)
        }
        guard var start = calendar.date(from: DateComponents(year: year, month: m1, day: 1)) else { return nil }
        if start < now, let n = calendar.date(byAdding: .year, value: 1, to: start) { start = n }
        let endYear = m2 < m1 ? calendar.component(.year, from: start) + 1 : calendar.component(.year, from: start)
        guard let end = calendar.date(from: DateComponents(year: endYear, month: m2 + 1, day: 1)) else { return nil }
        return TemporalHint(start: start, end: end.adding(days: -1, calendar: calendar), precision: .season, rawText: raw, isFuture: true)
    }

    private func monthMention(in lower: String) -> TemporalHint? {
        let monthPattern = "(" + (Self.months + Self.monthAbbrev).joined(separator: "|") + ")"
        // "22 september", "22nd sept 2026"
        let dayFirst = #"\b(\d{1,2})(?:st|nd|rd|th)?\s+\#(monthPattern)\.?(?:,?\s+(\d{4}))?\b"#
        // "september 22", "sept 22nd, 2026", "december"
        let monthFirst = #"\b\#(monthPattern)\.?(?:\s+(\d{1,2})(?:st|nd|rd|th)?)?(?:,?\s+(\d{4}))?\b"#

        var monthName: String?
        var day: Int?
        var year: Int?
        var raw = ""

        if let regex = try? NSRegularExpression(pattern: dayFirst, options: .caseInsensitive),
           let m = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           let r0 = Range(m.range(at: 0), in: lower), let r1 = Range(m.range(at: 1), in: lower), let r2 = Range(m.range(at: 2), in: lower) {
            raw = String(lower[r0]); day = Int(lower[r1]); monthName = String(lower[r2])
            if m.range(at: 3).location != NSNotFound, let r3 = Range(m.range(at: 3), in: lower) { year = Int(lower[r3]) }
        } else if let regex = try? NSRegularExpression(pattern: monthFirst, options: .caseInsensitive),
                  let m = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
                  let r0 = Range(m.range(at: 0), in: lower), let r1 = Range(m.range(at: 1), in: lower) {
            raw = String(lower[r0]); monthName = String(lower[r1])
            if m.range(at: 2).location != NSNotFound, let r2 = Range(m.range(at: 2), in: lower) { day = Int(lower[r2]) }
            if m.range(at: 3).location != NSNotFound, let r3 = Range(m.range(at: 3), in: lower) { year = Int(lower[r3]) }
        }
        guard let monthName else { return nil }
        // "may" is a common verb; only accept when it's clearly a month.
        if monthName == "may", day == nil, year == nil, !lower.matches(#"\b(in|by|until|till|for|next|this|early|late|mid)\s+may\b"#) { return nil }
        let monthIndex = Self.months.firstIndex(of: monthName) ?? Self.monthAbbrev.firstIndex(where: { $0 == monthName }).map { $0 >= 9 ? $0 - 1 : $0 } // "sept" shares sep's index
        guard let monthIndex else { return nil }
        let month = monthIndex + 1
        var comps = DateComponents(year: year ?? calendar.component(.year, from: now), month: month, day: day ?? 1)
        guard var start = calendar.date(from: comps) else { return nil }
        // If no year given and the month has fully passed, people usually mean next year.
        if year == nil {
            let monthEnd = calendar.dateInterval(of: .month, for: start)?.end ?? start
            let reference = day == nil ? monthEnd : start.adding(days: 1, calendar: calendar)
            if reference <= now, let next = calendar.date(byAdding: .year, value: 1, to: start) {
                start = next
                comps.year = calendar.component(.year, from: start)
            }
        }
        if day != nil {
            let d = calendar.startOfDay(for: start)
            return TemporalHint(start: d, end: d, precision: .day, rawText: raw, isFuture: d >= calendar.startOfDay(for: now))
        }
        return monthHint(of: start, raw: raw)
    }

    private func dataDetectorDate(in text: String) -> TemporalHint? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard let m = matches.first(where: { $0.date != nil }), let date = m.date, let r = Range(m.range, in: text) else { return nil }
        let raw = String(text[r])
        // Only accept explicit numeric-looking dates here; word forms were handled above.
        guard raw.matches(#"\d"#) else { return nil }
        let hasTime = !(m.timeZone == nil && calendar.component(.hour, from: date) == 12 && calendar.component(.minute, from: date) == 0)
        let start = hasTime ? date : calendar.startOfDay(for: date)
        return TemporalHint(start: start, end: start, precision: hasTime ? .exact : .day, rawText: raw, isFuture: start >= calendar.startOfDay(for: now))
    }
}
