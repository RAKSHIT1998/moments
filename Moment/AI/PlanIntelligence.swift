import Foundation

/// What a plan still needs, and the one next thing to do. Derived only from stored data.
struct PlanIntelligence: Sendable {
    struct Assessment: Sendable, Equatable {
        var missing: [String]
        var nextAction: String
        var stage: String
        var relatedCount: Int
        var isComingTogether: Bool { relatedCount >= 3 }
    }

    static func assess(status: PlanStatus, hasDate: Bool, exactDate: Bool, peopleCount: Int, memoryTexts: [String], relatedCount: Int) -> Assessment {
        let text = memoryTexts.joined(separator: " ").lowercased()
        let mentionsFlights = text.matches(#"\b(flight|flights|fly|airline|tickets?)\b"#)
        let mentionsStay = text.matches(#"\b(hotel|airbnb|villa|resort|stay|hostel)\b"#)
        var missing: [String] = []
        if !exactDate { missing.append(hasDate ? "Exact dates" : "Dates") }
        if peopleCount == 0 { missing.append("Who's coming") }
        if !mentionsFlights { missing.append("Flights") }
        if !mentionsStay { missing.append("Hotel") }

        let next: String
        switch status {
        case .completed: next = "Done"
        case .cancelled: next = "Let it go"
        case .planned: next = mentionsStay ? "Enjoy it" : "Book a place to stay"
        default:
            if !exactDate { next = "Choose dates" }
            else if !mentionsFlights { next = "Look at flights" }
            else if !mentionsStay { next = "Find a hotel" }
            else { next = "Confirm the plan" }
        }
        let stage: String
        switch status {
        case .idea: stage = "Idea"
        case .discussed: stage = peopleCount > 0 ? "People added" : "Discussed"
        case .tentative: stage = hasDate ? "Dates discussed" : "Taking shape"
        case .planned: stage = "Confirmed"
        case .completed: stage = "Completed"
        case .cancelled: stage = "Cancelled"
        }
        return Assessment(missing: status.isActive ? missing : [], nextAction: next, stage: stage, relatedCount: relatedCount)
    }
}

/// Plain-language observations about a person, computed from what the user captured. Never inferred traits.
enum PersonInsights {
    static func sentences(name: String, memories: [MemorySnapshot], pendingPromises: Int, openGifts: Int, birthdayInDays: Int?, activePlans: [String]) -> [String] {
        var out: [String] = []
        if let d = birthdayInDays, d >= 0, d <= 30 { out.append(d == 0 ? "\(name)'s birthday is today." : "\(name)'s birthday is in \(d) day\(d == 1 ? "" : "s").") }
        if pendingPromises > 0 { out.append(pendingPromises == 1 ? "There's one open promise between you." : "There are \(pendingPromises) open promises between you.") }
        let recent = memories.filter { $0.createdAt.daysUntil(.now) <= 30 }
        let places = Set(recent.flatMap(\.placeNames))
        if places.count >= 2 { out.append("Recently you've talked about \(places.sorted().prefix(3).joined(separator: ", ")) with \(name).") }
        let restaurants = recent.filter { $0.memoryType == .place }.count
        if restaurants >= 2 { out.append("\(name) has mentioned \(restaurants) places to try.") }
        if !activePlans.isEmpty { out.append("You have \(activePlans.count == 1 ? "a plan" : "\(activePlans.count) plans") together: \(activePlans.prefix(2).joined(separator: ", ")).") }
        if openGifts > 0 { out.append("You've saved \(openGifts) gift idea\(openGifts == 1 ? "" : "s") for \(name).") }
        return Array(out.prefix(3))
    }

    /// The single next best action for a person.
    static func nextAction(pendingPromiseSummary: String?, birthdayInDays: Int?, openGifts: Int, activePlan: String?) -> String? {
        if let p = pendingPromiseSummary { return "Follow up: \(p)" }
        if let d = birthdayInDays, d <= 14, openGifts > 0 { return "Review the gift idea" }
        if let d = birthdayInDays, d <= 14 { return "Think of a gift" }
        if let plan = activePlan { return "Continue planning \(plan)" }
        return nil
    }
}

/// Routes free-form input from the search field: remember/remind → capture, questions → search, lists → screens.
enum CommandRouter {
    enum Command: Equatable {
        case capture(String)
        case search(String)
        case promises
        case gifts
        case plans
        case person(String)
        /// "Tell me about my Goa trip", "Summarize everything I know about Goa".
        case tell(String)
    }

    static func route(_ raw: String) -> Command {
        let text = raw.trimmed
        let lower = text.lowercased()
        if lower.matches(#"^(remember|note|save) (that |this:? )?"#) || lower.matches(#"^remind me\b"#) {
            let content = text.replacingOccurrences(of: #"^(?i)(remember|note|save) (that |this:? )?"#, with: "", options: .regularExpression)
            return .capture(content.isBlank ? text : content)
        }
        if lower.matches(#"^(who owes me|what do people owe me|what do i owe|pending promises|my promises)"#) { return .promises }
        if lower.matches(#"^(gift ideas|what gifts|show gifts)"#) { return .gifts }
        if lower.matches(#"^(my plans|show plans|upcoming plans)$"#) { return .plans }
        if let name = text.firstMatch(#"^(?:show|tell me) everything about ([A-Z][a-z]+)$"#, caseSensitive: true) { return .person(name) }
        if let subject = text.firstMatch(#"^(?:tell me about|summari[sz]e|the story of|story of)\s+(?:my |our |the |everything (?:i know )?about )?(.+?)(?: trip| plan)?[?.!]?$"#) { return .tell(subject.trimmed) }
        return .search(text)
    }
}
