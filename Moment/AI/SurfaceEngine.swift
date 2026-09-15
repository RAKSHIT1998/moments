import Foundation

/// Decides "is this memory useful RIGHT NOW?". Input is plain data; output is a ranked, small set.
/// Never resurfaces something just because it's old.
struct SurfaceEngine: Sendable {
    enum Category: String, Sendable, CaseIterable {
        case followUp = "Follow up"
        case upcoming = "Upcoming"
        case remembered = "Remembered"
        case opportunity = "Opportunity"
        case plan = "Plan"
        case people = "People"
        case today = "Today"
    }

    enum SurfaceType: Sendable { case home, notification, both }

    struct Recommendation: Sendable, Identifiable, Equatable {
        var id: UUID { memoryID }
        var memoryID: UUID
        var category: Category
        var priority: Double            // 0–1
        var headline: String
        var detail: String?
        /// Plain-language "why MOMENT thinks this matters".
        var reason: String
        var surfaceType: SurfaceType
        var recommendedTime: Date?
        var notificationAllowed: Bool
        var personName: String?
        var actionKind: ActionKind
        /// Dominant card on Home. At most one per feed.
        var isHero: Bool = false
    }

    /// Learned preference per category from "useful / not useful" feedback. 1.0 = neutral.
    typealias CategoryWeights = [Category: Double]

    enum ActionKind: String, Sendable { case followUp, viewGift, continuePlan, open, markDone, completeTask }

    /// Everything the engine needs about one memory, flattened.
    struct Candidate: Sendable {
        var memoryID: UUID
        var title: String
        var summary: String
        var type: MemoryType
        var importance: Int
        var createdAt: Date
        var lastSurfacedAt: Date?
        var reminderAt: Date?
        var referencedStart: Date?
        var referencedPrecision: TemporalPrecision?
        var personName: String?
        var personBirthday: Date?
        var promiseStatus: PromiseStatus?
        var promiseDirection: PromiseDirection?
        var promiseDue: Date?
        var planStatus: PlanStatus?
        var planAnchor: Date?
        var giftStatus: GiftStatus?
        var giftItem: String?
        var eventDate: Date?
        var eventIsAnnual: Bool
        var isPinned: Bool
        var userInteractions: Int
        var openGiftIdeasForPerson: Int
        /// "Don't remind me about this."
        var isMuted: Bool = false
        var hasExplicitReminderLanguage: Bool = false
    }

    var now: Date
    var calendar: Calendar

    init(now: Date = .now, calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
    }

    func recommend(_ candidates: [Candidate], limit: Int = 6, weights: CategoryWeights = [:]) -> [Recommendation] {
        var recs: [Recommendation] = []
        for c in candidates where !c.isMuted {
            if var r = evaluate(c) {
                r.priority = min(1, r.priority * (weights[r.category] ?? 1))
                recs.append(r)
            }
        }
        // Sort by priority, then dedupe by person so one person doesn't fill the feed.
        recs.sort { $0.priority > $1.priority }
        var perPerson: [String: Int] = [:]
        var out: [Recommendation] = []
        var heroes = 0
        for var r in recs {
            if let p = r.personName {
                if perPerson[p, default: 0] >= 2 { continue }
                perPerson[p, default: 0] += 1
            }
            if r.priority >= 0.82, heroes < 1, r.category != .remembered { r.isHero = true; heroes += 1 }
            out.append(r)
            if out.count >= limit { break }
        }
        return out
    }

    func evaluate(_ c: Candidate) -> Recommendation? {
        let ageDays = c.createdAt.daysUntil(now)
        let base = Double(c.importance) / 100
        // Rotation, not suppression: something shown for several days in a row slips slightly so
        // fresher items get a turn. Same-day refreshes never change the feed.
        let sinceSurfaced = c.lastSurfacedAt.map { $0.daysUntil(now) } ?? 999
        let recentlyShownPenalty = (1...3).contains(sinceSurfaced) ? 0.06 : 0.0

        // Explicit reminder
        if let r = c.reminderAt {
            let days = now.daysUntil(r)
            if days <= 0 {
                return Recommendation(memoryID: c.memoryID, category: .today, priority: min(1, 0.9 + base * 0.1) - recentlyShownPenalty, headline: c.title, detail: "You asked to be reminded.", reason: "You asked to be reminded about this.", surfaceType: .both, recommendedTime: r, notificationAllowed: true, personName: c.personName, actionKind: .open)
            }
        }

        // Pending promise → follow up
        if c.promiseStatus == .pending {
            var p = 0.55 + base * 0.3
            if ageDays >= 2 { p += 0.1 }
            if let due = c.promiseDue, due < now { p += 0.2 }
            let detail: String
            if let due = c.promiseDue, due < now { detail = "Overdue" } else { detail = ageDays == 0 ? "Today" : "\(c.createdAt.relativeDescription)" }
            let who = c.personName ?? "Someone"
            let headline = c.promiseDirection == .userOwes ? "You said you'd \(c.summaryAction)" : "\(who) said they'd \(c.summaryAction)"
            let why = c.hasExplicitReminderLanguage ? "You explicitly said “remind me”." : (c.promiseDue.map { $0 < now } == true ? "This promise is past its date." : "This promise is still open after \(ageDays) day\(ageDays == 1 ? "" : "s").")
            return Recommendation(memoryID: c.memoryID, category: .followUp, priority: min(1, p) - recentlyShownPenalty, headline: headline, detail: detail, reason: why, surfaceType: ageDays >= 3 ? .both : .home, recommendedTime: nil, notificationAllowed: ageDays >= 3, personName: c.personName, actionKind: .followUp)
        }

        // Upcoming birthday / event
        if let eventDate = c.eventDate {
            let next = c.eventIsAnnual ? nextAnnual(eventDate) : eventDate
            let days = now.daysUntil(next)
            if days >= 0 && days <= 14 {
                var p = 0.6 + (14 - Double(days)) / 14 * 0.35
                if c.openGiftIdeasForPerson > 0 { p += 0.05 }
                let gifts = c.openGiftIdeasForPerson
                let detail = gifts > 0 ? "You have \(gifts) gift idea\(gifts == 1 ? "" : "s") saved." : (days <= 3 ? "Coming up." : nil)
                let when = days == 0 ? "today" : days == 1 ? "tomorrow" : "in \(days) days"
                return Recommendation(memoryID: c.memoryID, category: .upcoming, priority: min(1, p) - recentlyShownPenalty, headline: "\(c.title) is \(when).", detail: detail, reason: "Your saved event is \(when).", surfaceType: (days == 7 || days == 1 || days == 0) ? .both : .home, recommendedTime: calendar.date(bySettingHour: 9, minute: 0, second: 0, of: now), notificationAllowed: days == 7 || days == 1 || days == 0, personName: c.personName, actionKind: gifts > 0 ? .viewGift : .open)
            }
        }

        // Gift idea with a birthday approaching (person birthday known but the event isn't the memory itself)
        if c.giftStatus?.isOpen == true, let bday = c.personBirthday {
            let days = now.daysUntil(nextAnnual(bday))
            if days >= 0 && days <= 21 {
                let p = 0.55 + (21 - Double(days)) / 21 * 0.35
                return Recommendation(memoryID: c.memoryID, category: .opportunity, priority: min(1, p) - recentlyShownPenalty, headline: "\(c.personName ?? "Someone") mentioned \(c.giftItem ?? "something") — \(ageDays == 0 ? "today" : "\(ageDays) days ago").", detail: "Birthday in \(days) days.", reason: "\(c.personName ?? "They") mentioned it directly, and their birthday is in \(days) days.", surfaceType: days == 10 ? .both : .home, recommendedTime: nil, notificationAllowed: days == 10, personName: c.personName, actionKind: .viewGift)
            }
        }

        // Task with a date
        if c.type == .task, let start = c.referencedStart {
            let days = now.daysUntil(start)
            if days <= 1 && days >= -3 {
                let when = days < 0 ? "was due \(start.relativeDescription)" : days == 0 ? "is today" : "is tomorrow"
                return Recommendation(memoryID: c.memoryID, category: .today, priority: min(1, 0.7 + base * 0.25) - recentlyShownPenalty, headline: "\(c.title) \(when).", detail: nil, reason: days < 0 ? "This was due and isn't marked done." : "You gave this a date.", surfaceType: .both, recommendedTime: calendar.date(bySettingHour: 8, minute: 30, second: 0, of: start), notificationAllowed: days >= 0, personName: c.personName, actionKind: .completeTask)
            }
        }

        // Plan approaching, or plan discussed but never advanced
        if let planStatus = c.planStatus, planStatus.isActive {
            if let anchor = c.planAnchor {
                let days = now.daysUntil(anchor)
                if days >= 0 && days <= 45 && planStatus != .planned {
                    let p = 0.45 + (45 - Double(days)) / 45 * 0.35
                    let monthText = c.referencedPrecision == .month ? anchor.formatted(.dateTime.month(.wide)) : anchor.relativeDescription
                    return Recommendation(memoryID: c.memoryID, category: .plan, priority: min(1, p) - recentlyShownPenalty, headline: c.title, detail: "You mentioned \(monthText). Still not planned.", reason: "The time you mentioned is getting close and the plan isn't confirmed.", surfaceType: days == 30 ? .both : .home, recommendedTime: nil, notificationAllowed: days == 30, personName: c.personName, actionKind: .continuePlan)
                }
                if days > 45, ageDays >= 7, ageDays % 21 == 0 {
                    return Recommendation(memoryID: c.memoryID, category: .plan, priority: 0.4 + base * 0.2 - recentlyShownPenalty, headline: c.title, detail: "\(c.personName.map { "Came up with \($0) " } ?? "Came up ")\(c.createdAt.relativeDescription).", reason: "This plan came up but hasn't moved.", surfaceType: .home, recommendedTime: nil, notificationAllowed: false, personName: c.personName, actionKind: .continuePlan)
                }
            } else if ageDays >= 5, ageDays % 10 == 0 {
                return Recommendation(memoryID: c.memoryID, category: .plan, priority: 0.35 + base * 0.2 - recentlyShownPenalty, headline: c.title, detail: "No date yet.", reason: "This plan has no date yet.", surfaceType: .home, recommendedTime: nil, notificationAllowed: false, personName: c.personName, actionKind: .continuePlan)
            }
        }

        // Pinned or very important, recent → keep on home briefly
        if c.isPinned || (c.importance >= 80 && ageDays <= 2) {
            return Recommendation(memoryID: c.memoryID, category: .remembered, priority: 0.35 + base * 0.3 - recentlyShownPenalty, headline: c.title, detail: c.summary.truncated(90), reason: c.isPinned ? "You marked this important." : "This looked important and is recent.", surfaceType: .home, recommendedTime: nil, notificationAllowed: false, personName: c.personName, actionKind: .open)
        }

        // "On this day" — only genuinely notable memories from previous years, never random photos.
        if c.importance >= 50, [.plan, .event, .photo, .place, .idea, .giftIdea].contains(c.type) {
            for yearsAgo in 1...5 {
                guard let then = calendar.date(byAdding: .year, value: -yearsAgo, to: now), abs(c.createdAt.daysUntil(then)) <= 1 else { continue }
                let label = yearsAgo == 1 ? "A year ago today" : "\(yearsAgo) years ago today"
                return Recommendation(memoryID: c.memoryID, category: .remembered, priority: 0.45 + base * 0.2 - recentlyShownPenalty, headline: label, detail: c.title, reason: "You saved this on this day in \(calendar.component(.year, from: c.createdAt)).", surfaceType: .home, recommendedTime: nil, notificationAllowed: false, personName: c.personName, actionKind: .open)
            }
        }

        return nil
    }

    private func nextAnnual(_ date: Date) -> Date {
        var comps = calendar.dateComponents([.month, .day], from: date)
        comps.year = calendar.component(.year, from: now)
        guard let thisYear = calendar.date(from: comps) else { return date }
        if calendar.startOfDay(for: thisYear) >= calendar.startOfDay(for: now) { return thisYear }
        comps.year! += 1
        return calendar.date(from: comps) ?? date
    }
}

private extension SurfaceEngine.Candidate {
    /// "Rahul will send the property contact" → "send the property contact"
    var summaryAction: String {
        let t = title
        if let r = t.range(of: #"^(You'll|You will|\w+ will)\s+"#, options: .regularExpression) { return String(t[r.upperBound...]) }
        return t
    }
}
