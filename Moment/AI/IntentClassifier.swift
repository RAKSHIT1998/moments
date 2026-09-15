import Foundation

/// Scores what a unit of text *is*: a promise, a plan, a gift idea, a task…
/// Pattern-driven and explainable. Each signal carries a weight and the phrase that fired.
struct IntentClassifier: Sendable {
    struct Signal: Sendable, Equatable {
        var type: MemoryType
        var weight: Double
        var phrase: String
    }

    struct Classification: Sendable, Equatable {
        var primary: MemoryType
        var secondary: [MemoryType]
        var score: Double
        var signals: [Signal]
        var isMeaningful: Bool { primary != .conversation && primary != .unknown }
    }

    // MARK: Patterns (lowercase text)

    static let promisePatterns: [(String, Double)] = [
        (#"\bremind me (that )?i('ll| will)\b"#, 0.95),
        (#"\bi('ll| will| shall)\s+(send|share|get|give|bring|call|forward|pay|return|text|email|let you know|book|drop|transfer|mail|ship|hand)\b"#, 0.9),
        (#"\bi('ll| will) (do|sort|handle|take care of|check|look into|find|ask)\b"#, 0.7),
        (#"\bi('m| am) going to (send|share|get|give|bring|call|forward|pay|return|text|email)\b"#, 0.75),
        (#"\bi promise\b"#, 0.9),
        (#"\b(he|she|they)\s+(said|promised)\s+(he|she|they)('d| would| will|'ll)\b"#, 0.85),
        (#"\b[a-z]+ (said|promised|told me) (he|she|they)('d| would| will|'ll)\b"#, 0.85),
        (#"\bwill (send|share|get|give|bring|forward|pay|return) (you|me|it)\b"#, 0.7),
        (#"\b(you|he|she|they) owe(s)? me\b"#, 0.85),
        (#"\bi owe (you|him|her|them)\b"#, 0.85),
        (#"\byou promised\b"#, 0.8),
        (#"\bstill waiting (for|on)\b"#, 0.5),
        (#"\blet me (send|share|get|give|check|find|dig up)\b"#, 0.6)
    ]

    static let planPatterns: [(String, Double)] = [
        (#"\blet'?s (go|do|visit|plan|book|try|take|hit)\b"#, 0.85),
        (#"\bwe should (go|visit|do|try|take|plan|hit)\b"#, 0.8),
        (#"\b(wanna|want to|would love to|dying to|planning to|thinking of|thinking about) (go|goa|visit|travel|do|take|see|fly)\b"#, 0.75),
        (#"\btrip\b"#, 0.6),
        (#"\b(vacation|holiday|getaway|road ?trip|weekend away|staycation|honeymoon|trek|hike|camping)\b"#, 0.6),
        (#"\bgo(ing)? to [a-z]+ (in|next|this) (january|february|march|april|may|june|july|august|september|october|november|december|week|month|year|summer|winter)\b"#, 0.6),
        (#"\bbook (a |the )?(flight|flights|hotel|tickets|trip|villa|airbnb|stay)\b"#, 0.7),
        (#"\b(are|you) (in|down|up) (for|to)\b"#, 0.5),
        (#"\bplan(ning)? (a|the|our|for)\b"#, 0.6),
        (#"\bcount me in\b"#, 0.5)
    ]

    static let giftPatterns: [(String, Double)] = [
        (#"\bi (really |so |kinda |kind of |badly |desperately )?(want|need|would love|would like|wish i had|love|like) (these|those|this|that|a|an|the|some|one of)\b"#, 0.85),
        (#"\bi('ve| have) been (wanting|eyeing|dying for|dreaming of)\b"#, 0.85),
        (#"\bon my wishlist\b"#, 0.9),
        (#"\bwishlist\b"#, 0.6),
        (#"\b(gift|present) (idea|for)\b"#, 0.9),
        (#"\b(would|could) be (a )?(great|nice|perfect|good|lovely|cute) (gift|present)\b"#, 0.9),
        (#"\bget (him|her|them|[a-z]+) (this|that|these|those|a|the|some)\b"#, 0.6),
        (#"\b[a-z]+ (wants|would love|would like|has been wanting|is eyeing|loves|likes) (these|those|this|that|a|an|the|some)\b"#, 0.7),
        (#"\bfor (his|her|their) birthday\b"#, 0.6),
        (#"\bso cute\b|\bi need this\b|\btake my money\b"#, 0.5)
    ]

    static let taskPatterns: [(String, Double)] = [
        (#"\b(i|we) (need|have|got|ought) to\b"#, 0.85),
        (#"\bremind me to\b"#, 0.95),
        (#"\bremember to\b"#, 0.9),
        (#"\bdon'?t forget (to|about)\b"#, 0.9),
        (#"\b(i|we) must\b"#, 0.8),
        (#"\bto ?do\b"#, 0.6),
        (#"\bneed to (renew|book|call|pay|buy|send|fix|service|schedule|cancel|return|submit|apply|register|update|check|email|order)\b"#, 0.9),
        (#"^(renew|book|call|pay|buy|send|fix|service|schedule|cancel|return|submit|apply|register|update|check|email|order|pick up|drop off|get)\b"#, 0.7),
        (#"\bdeadline\b|\bdue (on|by|date)\b|\bby (tomorrow|friday|monday|next week|end of)\b"#, 0.6)
    ]

    static let eventPatterns: [(String, Double)] = [
        (#"\bbirthday\b"#, 0.9),
        (#"\banniversary\b"#, 0.9),
        (#"\b(wedding|reception|engagement|baby shower|housewarming|graduation|farewell)\b"#, 0.8),
        (#"\b(dinner|lunch|brunch|coffee|drinks|meeting|call|appointment|interview|concert|show|match|game|flight|party|hangout|catch ?up|movie)\b.*\b(on|at|this|next|tomorrow|tonight|today)\b"#, 0.7),
        (#"\b(rsvp|invite|invited|invitation)\b"#, 0.6)
    ]

    static let placePatterns: [(String, Double)] = [
        (#"\b(restaurant|cafe|café|bar|pub|bakery|hotel|resort|rooftop|brewery|bistro|diner|eatery|omakase|izakaya|pizzeria|trattoria)\b"#, 0.8),
        (#"\b(want|wanted|wants|should|need) to try\b"#, 0.8),
        (#"\btry (this|that|the|a) (place|spot|restaurant|cafe|café|bar|joint)\b"#, 0.85),
        (#"\b(this|that|the) (place|spot) (looks|looked|is|was|seems)\b"#, 0.7),
        (#"\b(best|amazing|great|incredible) (food|ramen|sushi|pizza|coffee|biryani|tacos|pasta|burgers?|dosa|momos)\b"#, 0.6),
        (#"\bmentioned [a-z]+ (while|when|during)\b"#, 0.5),
        (#"\b(sushi|ramen|pizza|tacos|japanese|italian|korean|thai|mexican|chinese|indian|lebanese|mediterranean) (food|place|restaurant|spot)\b"#, 0.7)
    ]

    static let personFactPatterns: [(String, Double)] = [
        (#"\b[a-z]+ (likes|loves|hates|prefers|doesn'?t like|is into|collects|is allergic to|can'?t stand|is obsessed with)\b"#, 0.75),
        (#"\bmy (brother|sister|mom|mother|dad|father|wife|husband|partner|boyfriend|girlfriend|boss|cousin|uncle|aunt|friend|colleague|roommate)\b"#, 0.6),
        (#"\b[a-z]+ (works at|works for|lives in|moved to|is from|just started|got a new|is getting married|is expecting|is moving)\b"#, 0.7),
        (#"\b[a-z]+'s (favou?rite|dog|cat|kid|kids|son|daughter)\b"#, 0.6)
    ]

    static let ideaPatterns: [(String, Double)] = [
        (#"\bwhat if (we|i)\b"#, 0.75),
        (#"\b(idea|thought):?\b"#, 0.7),
        (#"\bwe could\b"#, 0.5),
        (#"\bmaybe (i|we) (should|could)\b"#, 0.6),
        (#"\bwould be (cool|fun|amazing) (to|if)\b"#, 0.65)
    ]

    static let purchasePatterns: [(String, Double)] = [
        (#"\b(ordered|bought|purchased|order (confirmed|placed)|your order|receipt|invoice|paid)\b"#, 0.8),
        (#"\b(₹|rs\.?|\$|€|£)\s?\d"#, 0.4)
    ]

    /// Topics MOMENT refuses to turn into "facts about a person". The capture is still saved as-is,
    /// but no person profile inference is made.
    static let sensitivePatterns: [String] = [
        #"\b(religion|religious|christian|muslim|hindu|jewish|buddhist|sikh|atheist|church|mosque|temple|synagogue|pray|prayer)\b"#,
        #"\b(politic|vote|voting|election|liberal|conservative|leftist|right-wing|bjp|congress|democrat|republican)\b"#,
        #"\b(gay|lesbian|bisexual|trans|transgender|queer|sexuality|sexual orientation)\b"#,
        #"\b(diagnos|cancer|depress|anxiety|therapy|therapist|medication|pregnan|hiv|disease|disorder|hospital|surgery|rehab|addict|bipolar|adhd|autis)\b"#,
        #"\b(salary|debt|bankrupt|broke|loan|credit score|net worth|income)\b"#,
        #"\b(race|ethnic|caste|immigrant|illegal)\b"#,
        #"\b(arrest|convict|jail|prison|criminal|felony)\b"#
    ]

    static func isSensitive(_ text: String) -> Bool {
        sensitivePatterns.contains { text.matches($0) }
    }

    func classify(_ unit: TextUnit, entities: EntityRecognizer.Entities, temporal: TemporalHint?, hasURL: Bool) -> Classification {
        let text = unit.text
        let lower = text.lowercased()
        var signals: [Signal] = []

        func scan(_ patterns: [(String, Double)], _ type: MemoryType) {
            for (pattern, weight) in patterns {
                if let phrase = lower.firstMatch(pattern, group: 0) {
                    signals.append(Signal(type: type, weight: weight, phrase: phrase))
                }
            }
        }
        scan(Self.promisePatterns, .promise)
        scan(Self.planPatterns, .plan)
        scan(Self.giftPatterns, .giftIdea)
        scan(Self.taskPatterns, .task)
        scan(Self.eventPatterns, .event)
        scan(Self.placePatterns, .place)
        scan(Self.personFactPatterns, .personFact)
        scan(Self.ideaPatterns, .idea)
        scan(Self.purchasePatterns, .purchase)

        // Contextual boosts
        var scores: [MemoryType: Double] = [:]
        for s in signals { scores[s.type, default: 0] = max(scores[s.type, default: 0], s.weight) + min(0.1, scores[s.type, default: 0] * 0.1) }

        let speakerIsOther = unit.speaker.name != nil
        let wantsSomething = lower.matches(#"\b(want|wants|would love|wish|need|love|like)\b"#)
        let productLike = ProductRecognizer.looksLikeProduct(text) || (hasURL && ProductRecognizer.object(afterDesireIn: text) != nil)

        // Gift: strongest when another person expresses desire for a product.
        if wantsSomething && productLike {
            scores[.giftIdea, default: 0] += speakerIsOther ? 0.35 : 0.2
        }
        // "I want to go to Goa" is a plan, not a gift.
        if lower.matches(#"\b(want|wanna|would love) to (go|visit|travel|do|try|see)\b"#) {
            scores[.giftIdea] = (scores[.giftIdea] ?? 0) - 0.6
            scores[.plan, default: 0] += 0.3
        }
        // A destination plus a plan verb → plan.
        if !entities.places.isEmpty, scores[.plan, default: 0] > 0 { scores[.plan, default: 0] += 0.2 }
        if !entities.places.isEmpty, temporal != nil, scores[.plan, default: 0] > 0 { scores[.plan, default: 0] += 0.1 }
        // A place noun + "try" → place, not plan.
        if scores[.place, default: 0] >= 0.7, scores[.plan, default: 0] < 0.8 { scores[.plan] = (scores[.plan] ?? 0) - 0.3 }
        // Birthday with a person and a real date → event. Without a date it can't be an event.
        if lower.contains("birthday"), !entities.people.isEmpty, temporal != nil { scores[.event, default: 0] += 0.15 }
        if temporal == nil, let e = scores[.event], e > 0 { scores[.event] = e - 0.45 }
        // "for her birthday" + wanting something → gift.
        if lower.matches(#"\bfor (his|her|their|[a-z]+'s) birthday\b"#), wantsSomething { scores[.giftIdea, default: 0] += 0.3 }
        // Tasks are spoken by the user; if another person says "I need to", it's their intention, not our task.
        if speakerIsOther, scores[.task, default: 0] > 0, !lower.matches(#"\bremind me\b"#) {
            scores[.task] = (scores[.task] ?? 0) - 0.4
            scores[.personFact, default: 0] += 0.2
        }
        // Promise direction sanity: "remind me I'll..." from the user is a task-with-person.
        if !speakerIsOther, unit.speaker == .user, lower.matches(#"\bremind me (that )?i('ll| will)\b"#) {
            scores[.promise, default: 0] += 0.05
        }
        // Sensitive content never becomes a person fact.
        if Self.isSensitive(text) { scores[.personFact] = nil }
        // Sender-only chatter ("ok", "haha") is conversation.
        if text.count < 6 { scores = [:] }
        if hasURL, scores.isEmpty { scores[.link] = 0.6 }

        let ranked = scores.filter { $0.value >= 0.45 }.sorted { $0.value > $1.value }
        guard let top = ranked.first else {
            return Classification(primary: unit.speaker.name != nil ? .conversation : .unknown, secondary: [], score: 0.2, signals: signals)
        }
        let secondary = ranked.dropFirst().filter { $0.value >= 0.55 }.map(\.key)
        return Classification(primary: top.key, secondary: Array(secondary.prefix(2)), score: min(1, top.value), signals: signals.filter { $0.type == top.key })
    }
}
