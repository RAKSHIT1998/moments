import Foundation

/// The things only a Moment made by everyone can do. Pure functions over contributions; no network, no guessing.

/// Two people photographing the same instant. Their eyes, your eyes.
enum TwinFrames {
    struct Pair: Identifiable, Equatable {
        var a: Contribution
        var b: Contribution
        var secondsApart: Int
        var id: String { a.id + "|" + b.id }
    }
    /// Photos by different people within `window` seconds of each other, closest first; each photo appears in at most one pair.
    static func pairs(_ contributions: [Contribution], window: TimeInterval = 20) -> [Pair] {
        let photos = contributions.filter { ($0.kind == .photo || $0.kind == .video) && $0.media != nil }.sorted { ($0.originalTimestamp ?? $0.createdAt) < ($1.originalTimestamp ?? $1.createdAt) }
        var candidates: [Pair] = []
        for i in photos.indices {
            for j in (i + 1)..<photos.count {
                let ta = photos[i].originalTimestamp ?? photos[i].createdAt, tb = photos[j].originalTimestamp ?? photos[j].createdAt
                let gap = tb.timeIntervalSince(ta)
                if gap > window { break }
                if photos[i].authorID != photos[j].authorID { candidates.append(Pair(a: photos[i], b: photos[j], secondsApart: Int(gap.rounded()))) }
            }
        }
        var used: Set<String> = [], out: [Pair] = []
        for p in candidates.sorted(by: { $0.secondsApart < $1.secondsApart }) where !used.contains(p.a.id) && !used.contains(p.b.id) {
            used.insert(p.a.id); used.insert(p.b.id); out.append(p)
        }
        return out.sorted { ($0.a.originalTimestamp ?? $0.a.createdAt) < ($1.a.originalTimestamp ?? $1.a.createdAt) }
    }
}

/// The part of the night nobody has posted yet. The timeline knows; the people who were there can fill it.
enum TimelineGaps {
    struct Gap: Identifiable, Equatable {
        var from: Date
        var to: Date
        /// Who was there before and after — the people most likely to have something from in between.
        var witnesses: [String]
        var id: String { "\(from.timeIntervalSince1970)-\(to.timeIntervalSince1970)" }
        var minutes: Int { Int(to.timeIntervalSince(from) / 60) }
        var label: String { "\(from.formatted(date: .omitted, time: .shortened)) – \(to.formatted(date: .omitted, time: .shortened))" }
    }
    /// Gaps of at least `minGap` between consecutive sides, within a Moment that has at least two sides.
    static func find(_ contributions: [Contribution], minGap: TimeInterval = 45 * 60) -> [Gap] {
        let sorted = contributions.filter { $0.uploadState == .uploaded || $0.uploadState == .pending }.sorted { ($0.originalTimestamp ?? $0.createdAt) < ($1.originalTimestamp ?? $1.createdAt) }
        guard sorted.count >= 2 else { return [] }
        var out: [Gap] = []
        for i in 1..<sorted.count {
            let a = sorted[i - 1], b = sorted[i]
            let ta = a.originalTimestamp ?? a.createdAt, tb = b.originalTimestamp ?? b.createdAt
            if tb.timeIntervalSince(ta) >= minGap {
                var w: [String] = []
                for id in [a.authorID, b.authorID] where !w.contains(id) { w.append(id) }
                out.append(Gap(from: ta, to: tb, witnesses: w))
            }
        }
        return out
    }
    /// The message the app writes for you when you ask someone about a gap. Plain, specific, no invented detail.
    static func question(for gap: Gap, momentTitle: String) -> String {
        "What happened between \(gap.from.formatted(date: .omitted, time: .shortened)) and \(gap.to.formatted(date: .omitted, time: .shortened)) at \(momentTitle)? Nothing's in the Moment for that bit yet."
    }
}

/// A Moment that comes back every week: "Last light, Versova. Every Friday."
enum Rituals {
    static let templateID = "ritual"
    struct Summary: Equatable {
        var weekday: Int          // Calendar weekday of the ritual
        var occurrences: Int      // how many times it has happened
        var streak: Int           // consecutive weeks up to the latest one
        var next: Date            // next scheduled date
        var lastWasThisWeek: Bool
        var weekdayName: String { Calendar.current.weekdaySymbols[weekday - 1] }
    }
    static func isRitual(_ m: SocialMoment) -> Bool { m.templateID == templateID }
    /// Same creator + same title + ritual template = one series. Weekly cadence is inferred from the first occurrence.
    static func series(of moment: SocialMoment, in all: [SocialMoment]) -> [SocialMoment] {
        all.filter { isRitual($0) && $0.creatorID == moment.creatorID && $0.title.lowercased().trimmed == moment.title.lowercased().trimmed }
            .sorted { ($0.startAt ?? $0.createdAt) < ($1.startAt ?? $1.createdAt) }
    }
    static func summary(of moment: SocialMoment, in all: [SocialMoment], now: Date = .now, calendar: Calendar = .current) -> Summary? {
        let s = series(of: moment, in: all)
        guard let first = s.first else { return nil }
        let day = calendar.component(.weekday, from: first.startAt ?? first.createdAt)
        let weeks = s.map { calendar.dateComponents([.weekOfYear, .yearForWeekOfYear], from: $0.startAt ?? $0.createdAt) }
        // Streak: walk back from the latest occurrence week by week.
        var streak = 0
        if let latest = s.last {
            var cursor = latest.startAt ?? latest.createdAt
            while weeks.contains(calendar.dateComponents([.weekOfYear, .yearForWeekOfYear], from: cursor)) {
                streak += 1
                guard let prev = calendar.date(byAdding: .weekOfYear, value: -1, to: cursor) else { break }
                cursor = prev
            }
        }
        let latestDate = s.last.map { $0.startAt ?? $0.createdAt } ?? now
        let thisWeek = calendar.isDate(latestDate, equalTo: now, toGranularity: .weekOfYear)
        var next = calendar.nextDate(after: thisWeek ? latestDate : now, matching: DateComponents(weekday: day), matchingPolicy: .nextTime) ?? now
        if !thisWeek, calendar.isDate(now, inSameDayAs: next) { next = now }
        return Summary(weekday: day, occurrences: s.count, streak: streak, next: next, lastWasThisWeek: thisWeek)
    }
}
