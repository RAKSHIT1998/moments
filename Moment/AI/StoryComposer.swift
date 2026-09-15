import Foundation

/// Flattened memory for story composition (Sendable; no SwiftData objects).
struct StoryMemory: Sendable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var summary: String
    var content: String
    var type: MemoryType
    var createdAt: Date
    var importance: Int
    var isPinned: Bool
    var peopleNames: [String]
    var placeNames: [String]
    var imageRef: String?
    var sourceType: SourceType
    var planTitle: String?
    var planStatus: PlanStatus?
    var promiseSummary: String?
    var promiseStatus: PromiseStatus?
    var promiseDirection: PromiseDirection?
    var taskDone: Bool
    var giftItem: String?
    var eventTitle: String?
    var interactions: Int
}

/// A line someone actually said, pulled from a chat capture.
struct Quote: Sendable, Equatable {
    var text: String
    var speaker: String?
    var date: Date
    var memoryID: UUID
    var isJoke: Bool
}

/// Composes Moments (slides + stats) from memories. Every line comes from stored data —
/// counts, names, dates and quotes the user captured. Nothing is written by the engine
/// except connective phrasing that is true by construction.
struct StoryComposer: Sendable {
    struct Output: Sendable, Equatable {
        var title: String
        var subtitle: String
        var slides: [StorySlide]
        var stats: [String: String]
        var peopleNames: [String]
    }

    var now: Date = .now
    var calendar: Calendar = .current
    var userName: String?

    func compose(template: MomentTemplate, memories: [StoryMemory], periodLabel: String? = nil, person: String? = nil, fallbackTitle: String? = nil) -> Output {
        let sorted = memories.sorted { $0.createdAt < $1.createdAt }
        let people = rankedPeople(sorted)
        let places = rankedPlaces(sorted)
        let quotes = extractQuotes(sorted)
        let photos = bestPhotos(sorted)
        let plans = sorted.filter { $0.planTitle != nil || $0.type == .plan }
        let tasks = sorted.filter { $0.type == .task }
        let promises = sorted.filter { $0.promiseSummary != nil }
        let year = calendar.component(.year, from: sorted.last?.createdAt ?? now)
        let dominantPlace = places.first?.name
        let title = template.resolvedTitle(year: year, month: periodLabel, place: dominantPlace.map { "\($0) '\(String(year).suffix(2))" }, person: person, fallback: fallbackTitle ?? periodLabel ?? dominantPlace ?? "Moments")

        var stats: [String: String] = [:]
        stats["memories"] = String(sorted.count)
        stats["people"] = String(people.count)
        stats["places"] = String(places.count)
        stats["photos"] = String(photos.count)
        stats["plans"] = String(plans.count)
        stats["plansDone"] = String(plans.filter { $0.planStatus == .completed }.count)
        stats["promises"] = String(promises.count)
        stats["promisesKept"] = String(promises.filter { $0.promiseStatus == .completed }.count)
        stats["jokes"] = String(quotes.filter(\.isJoke).count)
        if let first = sorted.first, let last = sorted.last { stats["span"] = "\(first.createdAt.shortDate) – \(last.createdAt.shortDate)" }
        if let day = mostPhotographedDay(sorted) { stats["mostPhotographedDay"] = day.mediumDate }
        if let p = people.first { stats["topPerson"] = p.name }
        if let pl = places.first { stats["topPlace"] = pl.name }

        var subtitleParts: [String] = ["\(sorted.count) memor\(sorted.count == 1 ? "y" : "ies")"]
        if !people.isEmpty { subtitleParts.append("\(people.count) \(people.count == 1 ? "person" : "people")") }
        if !places.isEmpty { subtitleParts.append("\(places.count) place\(places.count == 1 ? "" : "s")") }
        let jokeCount = quotes.filter(\.isJoke).count
        if jokeCount > 0 { subtitleParts.append("\(jokeCount) inside joke\(jokeCount == 1 ? "" : "s")") }
        let subtitle = subtitleParts.joined(separator: " · ")

        var slides: [StorySlide] = []
        for section in template.sections {
            switch section {
            case .cover:
                slides.append(StorySlide(kind: .cover, title: title, body: subtitle, mediaRef: photos.first?.imageRef, date: sorted.first?.createdAt, items: subtitleParts))
            case .bestPhotos:
                for m in photos.prefix(template.style == .polaroid ? 8 : 5) {
                    slides.append(StorySlide(kind: .photo, title: isGenericPhotoTitle(m.title) ? "" : m.title, mediaRef: m.imageRef, date: m.createdAt, caption: m.placeNames.first ?? m.peopleNames.first, memoryID: m.id))
                }
            case .quotes:
                for q in quotes.filter({ !$0.isJoke }).prefix(3) {
                    slides.append(StorySlide(kind: .quote, title: q.text, body: q.speaker ?? "", date: q.date, memoryID: q.memoryID))
                }
            case .jokes:
                let jokes = quotes.filter(\.isJoke).prefix(3)
                if !jokes.isEmpty {
                    slides.append(StorySlide(kind: .list, title: jokes.count == 1 ? "Inside joke" : "Inside jokes", items: jokes.map { q in q.speaker.map { "\($0): \(q.text)" } ?? q.text }))
                }
            case .people:
                if !people.isEmpty {
                    slides.append(StorySlide(kind: .people, title: people.count == 1 ? "The person" : "The people", body: person != nil ? "" : "\(people.count) people in these memories", items: people.prefix(6).map { "\($0.name)|\($0.count)" }))
                }
            case .places:
                if !places.isEmpty {
                    slides.append(StorySlide(kind: .places, title: places.count == 1 ? "The place" : "The places", items: places.prefix(6).map { "\($0.name)|\($0.count)" }))
                }
            case .plansSaid:
                let said = (plans + tasks).prefix(6).map { m -> String in
                    let name = m.planTitle ?? m.title
                    let status: String
                    if m.planStatus == .completed || m.taskDone { status = "Done" }
                    else if m.planStatus == .cancelled { status = "Let go" }
                    else if m.planStatus == .planned { status = "Planned" }
                    else { status = "Still talking about it" }
                    return "\(name)|\(status)"
                }
                if !said.isEmpty { slides.append(StorySlide(kind: .list, title: "Things we said we'd do", items: Array(said))) }
            case .plansDone:
                let done = plans.filter { $0.planStatus == .completed }.map { $0.planTitle ?? $0.title } + tasks.filter(\.taskDone).map(\.title)
                if !done.isEmpty { slides.append(StorySlide(kind: .list, title: "Things we actually did", items: Array(done.prefix(6).map { "\($0)|Done" }))) }
            case .promisesKept:
                let kept = promises.filter { $0.promiseStatus == .completed }
                if !kept.isEmpty { slides.append(StorySlide(kind: .list, title: "Promises kept", items: kept.prefix(5).map { ($0.promiseDirection == .userOwes ? "You: " : ($0.peopleNames.first.map { "\($0): " } ?? "")) + ($0.promiseSummary ?? "") })) }
            case .timeline:
                let dated = sorted.filter { !isGenericPhotoTitle($0.title) }
                let step = max(1, dated.count / 7)
                let picks = stride(from: 0, to: dated.count, by: step).map { dated[$0] }.prefix(8)
                if picks.count >= 2 { slides.append(StorySlide(kind: .timeline, title: "How it happened", items: picks.map { "\($0.createdAt.shortDate)|\($0.title)" })) }
            case .stats:
                var pairs: [String] = ["\(sorted.count)|memories"]
                if !people.isEmpty { pairs.append("\(people.count)|people") }
                if !places.isEmpty { pairs.append("\(places.count)|places") }
                if !plans.isEmpty { pairs.append("\(plans.count)|plans") }
                let kept = promises.filter { $0.promiseStatus == .completed }.count
                if kept > 0 { pairs.append("\(kept)|promises kept") }
                if photos.count > 0 { pairs.append("\(photos.count)|photos") }
                slides.append(StorySlide(kind: .stats, title: periodLabel ?? title, body: [stats["topPerson"].map { "Most memorable person: \($0)" }, stats["topPlace"].map { "Most mentioned place: \($0)" }].compactMap { $0 }.joined(separator: "\n"), items: pairs))
            case .mostPhotographedDay:
                if let day = mostPhotographedDay(sorted) { slides.append(StorySlide(kind: .list, title: "Most photographed day", items: [day.formatted(.dateTime.weekday(.wide).month(.wide).day())])) }
            case .unfinishedPlan:
                if let p = plans.first(where: { $0.planStatus?.isActive ?? false }) {
                    slides.append(StorySlide(kind: .list, title: "Still unfinished", body: "You talked about it. It hasn't happened yet.", items: [p.planTitle ?? p.title], memoryID: p.id))
                }
            case .newPeople:
                let fresh = people.filter { $0.firstSeen >= (sorted.first?.createdAt ?? now) }
                if !fresh.isEmpty { slides.append(StorySlide(kind: .people, title: "New people", items: fresh.prefix(6).map { "\($0.name)|\($0.count)" })) }
            case .closing:
                slides.append(StorySlide(kind: .closing, title: closingLine(count: sorted.count, people: people.count, plansDone: plans.filter { $0.planStatus == .completed }.count, plansOpen: plans.filter { $0.planStatus?.isActive ?? false }.count), body: "Made with MOMENT"))
            }
        }
        return Output(title: title, subtitle: subtitle, slides: slides, stats: stats, peopleNames: people.map(\.name))
    }

    // MARK: - Narrative ("Tell me about my Goa trip")

    func narrative(about subject: String, memories: [StoryMemory], plan: (title: String, status: PlanStatus, createdAt: Date, anchor: Date?)? = nil) -> [String] {
        let sorted = memories.sorted { $0.createdAt < $1.createdAt }
        guard !sorted.isEmpty else { return [] }
        var out: [String] = []
        let people = rankedPeople(sorted).map(\.name)
        if let plan {
            var s = "You talked about \(plan.title)"
            if !people.isEmpty { s += " with \(people.prefix(3).joined(separator: ", "))" }
            s += " starting \(plan.createdAt.formatted(.dateTime.month(.wide).day()))."
            out.append(s)
            if let anchor = plan.anchor { let days = plan.createdAt.daysUntil(anchor); if days > 0 { out.append("You first mentioned it \(days) days before \(anchor.formatted(.dateTime.month(.wide).day())).") } }
            switch plan.status {
            case .completed: out.append("It happened.")
            case .planned: out.append("It's confirmed.")
            case .cancelled: out.append("You let it go.")
            default: out.append("It hasn't happened yet.")
            }
        } else {
            out.append("\(subject.capitalizedFirst) comes up in \(sorted.count) memor\(sorted.count == 1 ? "y" : "ies") between \(sorted.first!.createdAt.shortDate) and \(sorted.last!.createdAt.shortDate)." + (people.isEmpty ? "" : " Mostly with \(people.prefix(3).joined(separator: ", "))."))
        }
        for m in sorted where m.type == .promise || m.type == .giftIdea || m.type == .place {
            if out.count >= 7 { break }
            out.append(m.title.hasSuffix(".") ? m.title : m.title + ".")
        }
        if let day = mostPhotographedDay(sorted) { out.append("Your most photographed day was \(day.formatted(.dateTime.month(.wide).day())).") }
        let photos = sorted.filter { $0.imageRef != nil }.count
        if photos > 0 { out.append("You saved \(sorted.count) memories\(photos > 0 ? ", \(photos) with photos" : "").") }
        if let q = extractQuotes(sorted).first(where: \.isJoke) ?? extractQuotes(sorted).first {
            out.append("Your most memorable saved message was: “\(q.text)”" + (q.speaker.map { " — \($0)" } ?? ""))
        }
        return out
    }

    // MARK: - Pieces

    struct RankedName: Sendable, Equatable { var name: String; var count: Int; var firstSeen: Date }

    func rankedPeople(_ memories: [StoryMemory]) -> [RankedName] {
        var counts: [String: (Int, Date)] = [:]
        for m in memories { for p in m.peopleNames { let e = counts[p] ?? (0, m.createdAt); counts[p] = (e.0 + 1, min(e.1, m.createdAt)) } }
        return counts.map { RankedName(name: $0.key, count: $0.value.0, firstSeen: $0.value.1) }.sorted { $0.count > $1.count || ($0.count == $1.count && $0.name < $1.name) }
    }

    func rankedPlaces(_ memories: [StoryMemory]) -> [RankedName] {
        var counts: [String: (Int, Date)] = [:]
        for m in memories { for p in m.placeNames { let e = counts[p] ?? (0, m.createdAt); counts[p] = (e.0 + 1, min(e.1, m.createdAt)) } }
        return counts.map { RankedName(name: $0.key, count: $0.value.0, firstSeen: $0.value.1) }.sorted { $0.count > $1.count || ($0.count == $1.count && $0.name < $1.name) }
    }

    func bestPhotos(_ memories: [StoryMemory]) -> [StoryMemory] {
        memories.filter { $0.imageRef != nil }.sorted { a, b in
            let sa = a.importance + (a.isPinned ? 40 : 0) + a.interactions * 5
            let sb = b.importance + (b.isPinned ? 40 : 0) + b.interactions * 5
            return sa == sb ? a.createdAt < b.createdAt : sa > sb
        }
    }

    /// Lines people actually said, from chat captures ("Sarah: I really want these 😍").
    func extractQuotes(_ memories: [StoryMemory]) -> [Quote] {
        var out: [Quote] = []
        var seen = Set<String>()
        for m in memories {
            for line in m.content.components(separatedBy: .newlines) {
                let trimmed = line.trimmed
                guard trimmed.count >= 12, trimmed.count <= 110 else { continue }
                var speaker: String? = nil
                var text = trimmed
                if let s = trimmed.firstMatch(#"^([A-Z][a-zA-Z .'-]{1,30}):\s+(.+)$"#, group: 1, caseSensitive: true), let t = trimmed.firstMatch(#"^[A-Z][a-zA-Z .'-]{1,30}:\s+(.+)$"#, group: 1, caseSensitive: true) {
                    speaker = (s.lowercased() == "you" || s.lowercased() == "me") ? (userName ?? "You") : s
                    text = t
                } else if m.sourceType != .screenshot { continue }
                guard !text.matches(#"^(ok|okay|yes|no|yeah|haha|lol|hmm|k)\b"#) else { continue }
                let key = text.lowercased()
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                let joke = text.matches(#"😂|🤣|💀|\blol\b|\bhaha|\blmao\b|😭"#)
                out.append(Quote(text: text, speaker: speaker, date: m.createdAt, memoryID: m.id, isJoke: joke))
            }
        }
        return out.sorted { a, b in
            let sa = (a.isJoke ? 2 : 0) + (a.text.contains("!") ? 1 : 0) + (a.text.count < 60 ? 1 : 0)
            let sb = (b.isJoke ? 2 : 0) + (b.text.contains("!") ? 1 : 0) + (b.text.count < 60 ? 1 : 0)
            return sa > sb
        }
    }

    func mostPhotographedDay(_ memories: [StoryMemory]) -> Date? {
        let photos = memories.filter { $0.imageRef != nil }
        guard !photos.isEmpty else { return nil }
        let byDay = Dictionary(grouping: photos) { calendar.startOfDay(for: $0.createdAt) }
        return byDay.max { $0.value.count < $1.value.count || ($0.value.count == $1.value.count && $0.key > $1.key) }?.key
    }

    private func isGenericPhotoTitle(_ t: String) -> Bool {
        t.isBlank || t.lowercased().hasPrefix("photo") || t.lowercased().hasPrefix("saved ")
    }

    private func closingLine(count: Int, people: Int, plansDone: Int, plansOpen: Int) -> String {
        if plansDone > 0 && plansOpen == 0 { return "You said you'd do it. You did." }
        if plansOpen > 0 && plansDone == 0 { return "Some of it is still waiting to happen." }
        if people >= 3 { return "\(count) memories. \(people) people. Worth remembering." }
        return "\(count) memor\(count == 1 ? "y" : "ies") worth remembering."
    }
}

/// Recaps: the month or year that just happened, from stored data only.
struct RecapEngine: Sendable {
    var calendar: Calendar = .current

    func monthMemories(_ all: [StoryMemory], containing date: Date) -> [StoryMemory] {
        guard let interval = calendar.dateInterval(of: .month, for: date) else { return [] }
        return all.filter { interval.contains($0.createdAt) }
    }

    func yearMemories(_ all: [StoryMemory], year: Int) -> [StoryMemory] {
        all.filter { calendar.component(.year, from: $0.createdAt) == year }
    }

    /// Enough substance to be worth a recap: at least 5 memories.
    func isWorthRecapping(_ memories: [StoryMemory]) -> Bool { memories.count >= 5 }

    func composeMonth(_ all: [StoryMemory], for date: Date, userName: String?) -> StoryComposer.Output? {
        let ms = monthMemories(all, containing: date)
        guard isWorthRecapping(ms), let t = MomentTemplate.find("month.recap") else { return nil }
        return StoryComposer(calendar: calendar, userName: userName).compose(template: t, memories: ms, periodLabel: date.formatted(.dateTime.month(.wide)), fallbackTitle: date.formatted(.dateTime.month(.wide)))
    }

    func composeYear(_ all: [StoryMemory], year: Int, userName: String?) -> StoryComposer.Output? {
        let ms = yearMemories(all, year: year)
        guard isWorthRecapping(ms), let t = MomentTemplate.find("year.full") else { return nil }
        return StoryComposer(calendar: calendar, userName: userName).compose(template: t, memories: ms, periodLabel: String(year), fallbackTitle: "Your \(year)")
    }
}

/// "This looks like a core memory." Signals only; the user decides.
enum CoreMemoryDetector {
    struct Verdict: Sendable, Equatable { var isLikely: Bool; var reasons: [String] }

    static func assess(_ m: StoryMemory, relatedCount: Int, mentionsOfSamePlace: Int) -> Verdict {
        var reasons: [String] = []
        if m.isPinned { reasons.append("You marked it important.") }
        if m.importance >= 75 { reasons.append("It scored high on importance.") }
        if m.peopleNames.count >= 2 { reasons.append("\(m.peopleNames.count) people are part of it.") }
        if relatedCount >= 3 { reasons.append("\(relatedCount) other memories connect to it.") }
        if mentionsOfSamePlace >= 3 { reasons.append("The place comes up again and again.") }
        if m.content.matches(#"😂|🤣|😭|❤️|🔥|best (night|day|trip)|never forget|core memory"#) { reasons.append("The words in it are emotional.") }
        if m.planStatus == .completed { reasons.append("A plan that actually happened.") }
        if m.interactions >= 3 { reasons.append("You keep coming back to it.") }
        return Verdict(isLikely: reasons.count >= 2, reasons: reasons)
    }
}
