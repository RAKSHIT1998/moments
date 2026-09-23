import Foundation

/// When a creator is willing to take calls. Kept deliberately small: a weekly pattern in the creator's
/// own time zone, how much notice they want, and how far ahead people may book. Everything a buyer sees
/// is derived from this — there is no separate "calendar" to drift out of sync with.
struct CreatorAvailability: Codable, Sendable, Equatable, Hashable {
    /// One window on one weekday, in minutes from midnight, in `timeZoneID`.
    struct Window: Codable, Sendable, Equatable, Hashable, Identifiable {
        /// 1 = Sunday, matching `Calendar.component(.weekday:)`.
        var weekday: Int
        var startMinute: Int
        var endMinute: Int
        var id: String { "\(weekday)-\(startMinute)-\(endMinute)" }

        var isValid: Bool { (1...7).contains(weekday) && startMinute >= 0 && endMinute > startMinute && endMinute <= 24 * 60 }

        func label(_ locale: Locale = .current) -> String {
            "\(Self.dayName(weekday, locale)) · \(Self.clock(startMinute, locale))–\(Self.clock(endMinute, locale))"
        }
        static func dayName(_ weekday: Int, _ locale: Locale = .current) -> String {
            var c = Calendar(identifier: .gregorian); c.locale = locale
            let i = max(0, min(6, weekday - 1))
            return c.weekdaySymbols[i]
        }
        static func clock(_ minute: Int, _ locale: Locale = .current) -> String {
            var c = DateComponents(); c.hour = minute / 60; c.minute = minute % 60
            let ref = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2000, month: 1, day: 1, hour: c.hour, minute: c.minute)) ?? .now
            return ref.formatted(.dateTime.hour().minute().locale(locale))
        }
    }

    var creatorID: String = ""
    var windows: [Window] = []
    /// The creator's own zone, so a window means the same thing wherever the buyer is.
    var timeZoneID: String = TimeZone.current.identifier
    /// How much warning they want before a call starts.
    var minNoticeHours: Int = 12
    /// How far out the calendar opens.
    var maxDaysAhead: Int = 14
    /// A gap after each call so a back-to-back booking can't land on the minute the last one ends.
    var bufferMinutes: Int = 5
    /// Off without deleting the windows — one switch for "not this week".
    var acceptingBookings: Bool = true

    var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }
    var isOpen: Bool { acceptingBookings && windows.contains(where: \.isValid) }
}

/// Turns a creator's weekly pattern into the actual start times a buyer can pick, with the ones that
/// are already taken removed. Pure and total: same inputs, same slots, no clock of its own.
enum CallSlots {
    /// Bookable start times, soonest first.
    /// - Parameters:
    ///   - taken: bookings that already hold time (any status that still means the creator is busy).
    ///   - limit: stop after this many; the picker never needs more.
    static func slots(availability: CreatorAvailability,
                      minutes: Int,
                      taken: [Booking] = [],
                      now: Date = .now,
                      limit: Int = 60) -> [Date] {
        guard availability.isOpen, minutes > 0, availability.maxDaysAhead > 0 else { return [] }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = availability.timeZone

        let earliest = now.addingTimeInterval(Double(max(0, availability.minNoticeHours) * 3600))
        let latest = now.addingTimeInterval(Double(availability.maxDaysAhead) * 86400)
        let step = Double(minutes + max(0, availability.bufferMinutes)) * 60

        // Busy windows, from the bookings that still hold the creator's time.
        let busy: [(start: Date, end: Date)] = taken
            .filter { $0.holdsTime }
            .map { ($0.startsAt, $0.startsAt.addingTimeInterval(Double(max(1, $0.minutes)) * 60)) }

        var out: [Date] = []
        var day = cal.startOfDay(for: now)
        let lastDay = cal.startOfDay(for: latest)

        while day <= lastDay, out.count < limit {
            let weekday = cal.component(.weekday, from: day)
            for w in availability.windows.filter({ $0.isValid && $0.weekday == weekday }).sorted(by: { $0.startMinute < $1.startMinute }) {
                guard let windowStart = cal.date(byAdding: .minute, value: w.startMinute, to: day),
                      let windowEnd = cal.date(byAdding: .minute, value: w.endMinute, to: day) else { continue }
                var t = windowStart
                while t.addingTimeInterval(Double(minutes) * 60) <= windowEnd, out.count < limit {
                    defer { t = t.addingTimeInterval(step) }
                    guard t >= earliest, t <= latest else { continue }
                    let end = t.addingTimeInterval(Double(minutes) * 60)
                    let clashes = busy.contains { $0.start < end && t < $0.end }
                    if !clashes { out.append(t) }
                }
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return out.sorted()
    }

    /// The slots grouped by day, for a picker that shows a day at a time.
    static func byDay(_ slots: [Date], timeZone: TimeZone) -> [(day: Date, slots: [Date])] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let groups = Dictionary(grouping: slots) { cal.startOfDay(for: $0) }
        return groups.keys.sorted().map { (day: $0, slots: groups[$0]?.sorted() ?? []) }
    }
}

/// The paid clock for one call. The rule people are actually buying: **the clock starts when the two of
/// you are connected**, not when the slot was scheduled — so a creator running five minutes late costs
/// them nothing and a buyer who joins late loses nothing either.
///
/// Both phones start it on the same event (the peer connection reaching `connected`), so the two
/// countdowns agree to within the network's round trip. Neither side's clock is authoritative over the
/// other's: the call simply ends when either one runs out, which is the reading that can't be gamed.
struct CallClock: Sendable, Equatable {
    /// What was paid for.
    let paidSeconds: Int
    /// Nil until the media actually connects.
    var connectedAt: Date?
    /// Time bought mid-call and confirmed, added on top.
    var extraSeconds: Int = 0

    var totalSeconds: Int { paidSeconds + extraSeconds }

    init(minutes: Int, connectedAt: Date? = nil, extraSeconds: Int = 0) {
        self.paidSeconds = max(0, minutes) * 60
        self.connectedAt = connectedAt
        self.extraSeconds = extraSeconds
    }

    func elapsed(at now: Date = .now) -> Int {
        guard let connectedAt else { return 0 }
        return max(0, Int(now.timeIntervalSince(connectedAt)))
    }
    func remaining(at now: Date = .now) -> Int {
        guard connectedAt != nil else { return totalSeconds }
        return max(0, totalSeconds - elapsed(at: now))
    }
    /// The last minute, where the UI warns instead of surprising someone.
    func isEnding(at now: Date = .now) -> Bool { connectedAt != nil && remaining(at: now) <= 60 }
    /// Paid time is used up. The call still gets `graceSeconds` to say goodbye.
    func isOver(at now: Date = .now) -> Bool { connectedAt != nil && remaining(at: now) == 0 }
    func isHardOver(at now: Date = .now, graceSeconds: Int = 30) -> Bool {
        guard let connectedAt else { return false }
        return Int(now.timeIntervalSince(connectedAt)) >= totalSeconds + graceSeconds
    }

    static func label(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
