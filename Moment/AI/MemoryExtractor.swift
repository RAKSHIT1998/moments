import Foundation

/// Turns normalized text into `ExtractedMemory` values. Deterministic, on-device, explainable.
/// Every memory it produces carries the quote it came from (`evidence`), a confidence, and only
/// facts the text supports. Ambiguity lowers confidence; it is never resolved by guessing.
struct MemoryExtractor: Sendable {
    var context: AnalysisContext

    private var recognizer: EntityRecognizer { EntityRecognizer(context: context) }
    private var temporal: TemporalParser { TemporalParser(now: context.now, calendar: context.calendar, userBirthday: context.userBirthday) }
    private let classifier = IntentClassifier()

    func extract(from normalized: NormalizedText, input: CaptureInput) -> AnalysisResult {
        var memories: [ExtractedMemory] = []
        var people: [String: ExtractedPerson] = [:]
        var warnings: [String] = []
        var leftovers: [TextUnit] = []

        let units = normalized.units.flatMap(splitListTasks)

        for unit in units {
            let entities = recognizer.recognize(in: unit.text, speaker: unit.speaker)
            let hint = temporal.primary(in: unit.text)
            let unitURL = normalized.urls.first { unit.text.contains($0.absoluteString) } ?? (units.count == 1 ? normalized.urls.first : nil)
            let classification = classifier.classify(unit, entities: entities, temporal: hint, hasURL: unitURL != nil)

            for (name, rel) in entities.statedRelationships {
                people[name.lowercased(), default: ExtractedPerson(name: name, confidence: 0.8)].statedRelationship = rel
            }
            for name in entities.people {
                let resolved = context.knownPeople.first { $0.allNames.contains(name.lowercased()) }?.id
                var p = people[name.lowercased()] ?? ExtractedPerson(name: name, confidence: resolved != nil ? 0.9 : 0.6)
                p.resolvedPersonID = resolved
                people[name.lowercased()] = p
            }

            guard classification.isMeaningful else { leftovers.append(unit); continue }
            if let memory = build(unit: unit, classification: classification, entities: entities, hint: hint, url: unitURL, normalized: normalized, input: input) {
                memories.append(memory)
                if let bday = memory.event, bday.isAnnual, bday.title.lowercased().contains("birthday"), let who = bday.peopleNames.first {
                    people[who.lowercased(), default: ExtractedPerson(name: who, confidence: 0.8)].birthday = bday.temporal.start
                }
            } else {
                leftovers.append(unit)
            }
        }

        // Nothing actionable? Keep the capture as one honest memory of what it is.
        if memories.isEmpty {
            memories.append(fallbackMemory(normalized: normalized, input: input, units: units))
            if normalized.isChat, normalized.conversationWith == nil {
                warnings.append("Couldn't tell who this conversation was with.")
            }
        }

        // Chat with a known partner: every memory from it involves that person.
        if let partner = normalized.conversationWith {
            people[partner.lowercased(), default: ExtractedPerson(name: partner, confidence: 0.7)].resolvedPersonID = context.knownPeople.first { $0.allNames.contains(partner.lowercased()) }?.id
            for i in memories.indices where !memories[i].peopleNames.contains(where: { $0.lowercased() == partner.lowercased() }) {
                memories[i].peopleNames.append(partner)
            }
        }

        // Unknown speakers in a chat: be honest about it.
        if normalized.isChat, memories.contains(where: { $0.confidence < 0.5 }), normalized.conversationWith == nil {
            warnings.append("I'm not sure who said some of this. You can fix the person before saving.")
        }

        let overall = memories.map(\.confidence).reduce(0, +) / Double(max(1, memories.count)) * (0.6 + 0.4 * input.extractionConfidence)
        return AnalysisResult(
            memories: Array(memories.prefix(AnalysisValidator.maxMemories)),
            people: people.values.sorted { $0.name < $1.name },
            confidence: min(1, overall),
            normalizedText: normalized.cleanedText,
            language: nil,
            warnings: warnings,
            conversationWith: normalized.conversationWith
        )
    }

    // MARK: - Building a memory from a classified unit

    private func build(unit: TextUnit, classification: IntentClassifier.Classification, entities: EntityRecognizer.Entities, hint: TemporalHint?, url: URL?, normalized: NormalizedText, input: CaptureInput) -> ExtractedMemory? {
        let text = unit.text
        let speakerName = unit.speaker.name
        let otherPeople = entities.people.filter { $0.lowercased() != speakerName?.lowercased() }
        var confidence = classification.score * 0.8 + 0.1
        if unit.speaker == .unknown, normalized.isChat { confidence -= 0.15 }
        if !entities.people.isEmpty, entities.people.contains(where: { name in context.knownPeople.contains { $0.allNames.contains(name.lowercased()) } }) { confidence += 0.08 }
        confidence = max(0.15, min(0.98, confidence))

        var memory = ExtractedMemory(
            title: "", summary: "", content: text, memoryType: classification.primary,
            secondaryTypes: classification.secondary, confidence: confidence,
            peopleNames: entities.people, placeNames: entities.places, temporal: hint, tags: [], url: url, evidence: text
        )

        switch classification.primary {
        case .promise:
            guard let promise = buildPromise(text: text, speaker: unit.speaker, otherPeople: otherPeople, hint: hint) else { return nil }
            memory.promise = promise
            let who = promise.personName
            switch promise.direction {
            case .personOwes:
                memory.title = "\(who ?? "Someone") will \(promise.summary)"
                memory.summary = "\(who ?? "They") said they'd \(promise.summary)." + (hint.map { " \($0.description.capitalizedFirst)." } ?? "") + " Pending."
            case .userOwes:
                memory.title = "You'll \(promise.summary)"
                memory.summary = "You said you'd \(promise.summary)" + (who.map { " for \($0)" } ?? "") + "." + (hint.map { " \($0.description.capitalizedFirst)." } ?? "")
            case .unknown:
                memory.title = "Promise: \(promise.summary)"
                memory.summary = "Someone said they'd \(promise.summary). Not sure who owes whom."
                memory.confidence = min(memory.confidence, 0.5)
            }
            if who == nil { memory.confidence = min(memory.confidence, 0.55) }
            memory.tags = ["promise", "follow up"]

        case .plan:
            let destination = entities.places.first
            let planTitle: String
            if let destination {
                planTitle = hint.map { "\(destination) — \($0.description)" } ?? destination
            } else {
                planTitle = cleanClause(text, stripping: [#"^(bro|dude|hey|yo|man|yaar)[,!\s]+"#, #"^(let'?s|we should|wanna|want to)\s+"#]).capitalizedFirst.truncated(70)
            }
            let suggester = speakerName ?? (unit.speaker == .user ? "You" : nil)
            memory.title = planTitle
            memory.summary = [
                suggester.map { "\($0) suggested" } ?? "Suggested",
                destination.map { "going to \($0)" } ?? "“\(text.truncated(80))”",
                hint.map { "in \($0.description)" } ?? nil
            ].compactMap { $0 }.joined(separator: " ") + ". Not confirmed yet."
            memory.plan = ExtractedPlan(title: destination ?? planTitle, destination: destination, temporal: hint, status: .discussed, peopleNames: otherPeople.isEmpty ? (speakerName.map { [$0] } ?? []) : otherPeople + (speakerName.map { [$0] } ?? []))
            memory.tags = ["plan"] + (destination.map { [$0.lowercased()] } ?? [])
            if destination == nil { memory.confidence = min(memory.confidence, 0.6) }

        case .giftIdea:
            let item = ProductRecognizer.object(afterDesireIn: text) ?? url.flatMap(ProductRecognizer.productFromURL)
            guard let item else { return nil }
            // Who wants it? The speaker if they said "I want"; a named subject if "Sarah wants"; else the chat partner.
            let subjectName = text.firstMatch(#"\b([A-Z][a-z]+) (wants|would love|would like|has been wanting|is eyeing|loves|likes)\b"#, caseSensitive: true)
            let wantsItThemselves = text.lowercased().matches(#"\bi (really |so |kinda |badly )?(want|need|would love|would like|wish i had|love|like|'ve been wanting)\b"#) || text.lowercased().matches(#"\bi('ve| have) been (wanting|eyeing)\b"#)
            let forPattern = text.firstMatch(#"\bfor ([A-Z][a-z]+)('s birthday| birthday)?\b"#, caseSensitive: true)
            var forPerson: String? = forPattern.flatMap { recognizer.isPlausiblePersonName($0) ? recognizer.canonicalPersonName($0) : nil }
            if forPerson == nil, let subjectName, recognizer.isPlausiblePersonName(subjectName) { forPerson = recognizer.canonicalPersonName(subjectName) }
            if forPerson == nil, wantsItThemselves { forPerson = speakerName }  // "I want these" said by Sarah → for Sarah
            if forPerson == nil, unit.speaker == .user, wantsItThemselves {
                // The user wants it for themselves: a wish, not a gift for someone.
                memory.memoryType = .purchase
                memory.title = "You want \(item)"
                memory.summary = "You mentioned wanting \(item)."
                memory.tags = ["wishlist"]
                memory.gift = nil
                break
            }
            if forPerson == nil { forPerson = normalized.conversationWith }
            memory.gift = ExtractedGift(item: item, forPersonName: forPerson, url: url, price: text.firstMatch(#"((?:₹|rs\.?|\$|€|£)\s?\d[\d,]*(?:\.\d+)?)"#))
            if let forPerson {
                memory.title = "\(forPerson) wants \(item)"
                memory.summary = "\(forPerson) mentioned wanting \(item). Saved as a gift idea."
                if !memory.peopleNames.contains(where: { $0.lowercased() == forPerson.lowercased() }) { memory.peopleNames.append(forPerson) }
            } else {
                memory.title = "Gift idea: \(item)"
                memory.summary = "Someone mentioned wanting \(item). Add who it's for."
                memory.confidence = min(memory.confidence, 0.5)
            }
            memory.tags = ["gift", "shopping"]

        case .task:
            let action = taskAction(from: text, hint: hint)
            guard !action.isEmpty else { return nil }
            memory.title = action.capitalizedFirst.truncated(80)
            memory.summary = [hint?.description.capitalizedFirst, topic(from: text).map { "About \($0)." }].compactMap { $0 }.joined(separator: ". ")
            // No time, no topic: don't echo the title back as a summary.
            if memory.summary.isEmpty, input.sourceType == .voice { memory.summary = "From a voice note." }
            memory.tags = ["task"]
            if let name = otherPeople.first, action.lowercased().matches(#"^(call|text|ask|tell|meet|email|message|ping)\b"#) { memory.tags.append(name.lowercased()) }

        case .event:
            guard let event = buildEvent(text: text, entities: entities, hint: hint, speaker: unit.speaker) else {
                // Birthday/event mentioned without a date → keep as a person fact/idea rather than inventing a date.
                if text.lowercased().contains("birthday"), let who = otherPeople.first ?? speakerName {
                    memory.memoryType = .personFact
                    memory.title = "\(who)'s birthday came up"
                    memory.summary = "“\(text.truncated(100))”"
                    memory.confidence = min(memory.confidence, 0.5)
                    memory.tags = ["birthday"]
                    return memory
                }
                return nil
            }
            memory.event = event
            memory.title = event.title
            memory.summary = event.isAnnual ? "\(event.temporal.description), every year." : event.temporal.description.capitalizedFirst + (event.location.map { " at \($0)" } ?? "") + "."
            memory.tags = ["event"] + (event.isAnnual ? ["birthday"] : [])
            if event.isAnnual, !event.peopleNames.isEmpty { memory.tags.append("gift") }

        case .place:
            var placeName = entities.places.first(where: { !EntityRecognizer.knownDestinations.contains($0.lowercased()) }) ?? entities.places.first
            let kind = EntityRecognizer.placeKind(for: text)
            // "that new ramen place in Indiranagar" — the venue is described, the proper noun is only its locality.
            let locality = text.firstMatch(#"\b(?:in|at|near|on)\s+([A-Z][a-zA-Z]+(?:\s[A-Z][a-zA-Z]+)?)\b"#, caseSensitive: true)
            let descriptor = text.lowercased().firstMatch(#"\b(?:that|this|the|a|some)?\s*(?:new\s+|cute\s+|little\s+|nice\s+)?((?:[a-z]+\s+)?(?:place|spot|restaurant|cafe|café|bar|joint|bakery|pub|brewery|rooftop))\b"#)
            if let descriptor, placeName == nil || placeName?.lowercased() == locality?.lowercased() {
                let base = descriptor.capitalizedFirst
                placeName = locality.map { "\(base) in \($0)" } ?? base
            }
            if let placeName {
                memory.place = ExtractedPlace(name: placeName, kind: kind)
                memory.title = kind == "unknown" || descriptor != nil ? placeName : "\(placeName) — \(kind)"
                let mentioner = speakerName ?? otherPeople.first
                let verb = text.lowercased().matches(#"\b(want|wants|wanted|would love|should|need) to (try|go|check out|visit)\b"#) ? "wants to try" : "mentioned"
                memory.summary = (mentioner.map { "\($0) \(verb) \(placeName)" } ?? "You saved \(placeName)") + (topic(from: text).map { " while talking about \($0)" } ?? "") + (hint.map { " — \($0.description)" } ?? "") + "."
                if descriptor != nil, let locality { memory.placeNames = [placeName, locality] }
            } else {
                memory.title = cleanClause(text, stripping: [#"^(we|i) (should|need to|want to|wanna|have to) (try|go to|check out|visit)\s+"#]).capitalizedFirst.truncated(70)
                memory.summary = "A place worth trying. Add its name if you know it."
                memory.confidence = min(memory.confidence, 0.55)
            }
            memory.tags = ["place", kind]

        case .personFact:
            let subject = otherPeople.first ?? speakerName
            guard let subject, !IntentClassifier.isSensitive(text) else {
                memory.memoryType = .reference
                memory.title = text.truncated(70)
                memory.summary = "Saved as captured."
                return memory
            }
            memory.title = text.capitalizedFirst.truncated(80)
            memory.summary = "Something to remember about \(subject)."
            memory.tags = ["about \(subject.lowercased())"]
            if let rel = entities.statedRelationships[subject] { memory.tags.append(rel) }

        case .idea:
            memory.title = cleanClause(text, stripping: [#"^(idea|thought):?\s*"#, #"^what if\s+"#]).capitalizedFirst.truncated(80)
            memory.summary = "An idea you had" + (hint.map { " — \($0.description)" } ?? "") + "."
            memory.tags = ["idea"]

        case .purchase:
            memory.title = text.truncated(70)
            memory.summary = "A purchase or receipt."
            memory.tags = ["purchase"]

        case .link:
            memory.title = url.flatMap(ProductRecognizer.productFromURL) ?? url?.host() ?? text.truncated(70)
            memory.summary = "Link saved" + (url?.host().map { " from \($0)" } ?? "") + "."
            memory.tags = ["link"]

        default:
            return nil
        }

        memory.importance = ImportanceEngine.score(memory, now: context.now)
        return memory
    }

    // MARK: - Promise

    private func buildPromise(text: String, speaker: Speaker, otherPeople: [String], hint: TemporalHint?) -> ExtractedPromise? {
        let lower = text.lowercased()
        var direction: PromiseDirection = .unknown
        var personName: String?
        var actionText: String?

        if let action = text.firstMatch(#"\b(?:remind me (?:that )?)?i(?:'ll| will| shall|'m going to| am going to)\s+(.+?)(?:[.!?]|$)"#) {
            actionText = action
            switch speaker {
            case .other(let name): direction = .personOwes; personName = name
            case .user:
                direction = .userOwes
                personName = otherPeople.first
            case .unknown:
                direction = .unknown
                personName = otherPeople.first
            }
        } else if let action = text.firstMatch(#"\b(?:he|she|they) (?:said|promised) (?:he|she|they)(?:'d| would| will|'ll)\s+(.+?)(?:[.!?]|$)"#) {
            actionText = action; direction = .personOwes; personName = otherPeople.first
        } else if let action = text.firstMatch(#"\b([A-Z][a-z]+) (?:said|promised) (?:he|she|they)(?:'d| would| will|'ll)\s+(.+?)(?:[.!?]|$)"#, group: 2, caseSensitive: true) {
            actionText = action; direction = .personOwes; personName = text.firstMatch(#"\b([A-Z][a-z]+) (?:said|promised)"#, caseSensitive: true)
        } else if lower.matches(#"\b(you|he|she|they) owes? me\b"#) {
            actionText = text.firstMatch(#"owes? me\s+(.+?)(?:[.!?]|$)"#).map { "give you \($0)" }
            direction = speaker.name != nil && lower.hasPrefix("you owe") ? .userOwes : .personOwes
            personName = speaker.name ?? otherPeople.first
        } else if lower.matches(#"\bi owe (you|him|her|them)\b"#) {
            actionText = text.firstMatch(#"i owe (?:you|him|her|them)\s+(.+?)(?:[.!?]|$)"#).map { "give \($0)" }
            direction = speaker.name != nil ? .personOwes : .userOwes
            personName = speaker.name ?? otherPeople.first
        } else if let action = text.firstMatch(#"\blet me\s+(.+?)(?:[.!?]|$)"#) {
            actionText = action
            direction = speaker.name != nil ? .personOwes : .userOwes
            personName = speaker.name ?? otherPeople.first
        } else if lower.matches(#"\byou promised\b"#) {
            actionText = text.firstMatch(#"you promised (?:to |me )?(.+?)(?:[.!?]|$)"#)
            direction = speaker.name != nil ? .userOwes : .personOwes
            personName = speaker.name ?? otherPeople.first
        }

        guard var action = actionText?.trimmed, !action.isEmpty else { return nil }
        // Remove the time phrase from the action; it's carried separately.
        if let hint { action = action.replacingOccurrences(of: hint.rawText, with: "", options: .caseInsensitive).collapsedWhitespace }
        action = action.replacingOccurrences(of: #"\s+(lol|haha|😂|🙏|👍)+$"#, with: "", options: .regularExpression).trimmed
        action = action.replacingOccurrences(of: #"[.!?]+$"#, with: "", options: .regularExpression)
        return ExtractedPromise(summary: action, direction: direction, personName: personName, due: hint)
    }

    // MARK: - Event

    private func buildEvent(text: String, entities: EntityRecognizer.Entities, hint: TemporalHint?, speaker: Speaker) -> ExtractedEvent? {
        let lower = text.lowercased()
        if lower.contains("birthday") || lower.contains("anniversary") {
            let isBirthday = lower.contains("birthday")
            let who = text.firstMatch(#"\b([A-Z][a-z]+)'s (birthday|anniversary)"#, caseSensitive: true) ?? entities.people.first ?? (lower.matches(#"\bmy birthday\b"#) ? "My" : nil)
            guard let hint else { return nil }
            guard hint.precision == .day || hint.precision == .exact else { return nil } // "birthday in December" isn't a date we can pin.
            let name = who == "My" ? "Your \(isBirthday ? "birthday" : "anniversary")" : "\(who ?? "Someone")'s \(isBirthday ? "birthday" : "anniversary")"
            let people = who.flatMap { $0 == "My" ? nil : [$0] } ?? []
            return ExtractedEvent(title: name, temporal: hint, isAnnual: true, peopleNames: people, location: nil)
        }
        guard let hint, hint.isFuture else { return nil }
        let kind = lower.firstMatch(#"\b(wedding|reception|engagement|baby shower|housewarming|graduation|farewell|dinner|lunch|brunch|coffee|drinks|meeting|call|appointment|interview|concert|show|match|game|flight|party|hangout|catch ?up|movie)\b"#, group: 1) ?? "event"
        let with = entities.people.filter { $0.lowercased() != speaker.name?.lowercased() }.first ?? speaker.name
        let title = (kind.capitalizedFirst) + (with.map { " with \($0)" } ?? "")
        let location = entities.places.first
        return ExtractedEvent(title: title, temporal: hint, isAnnual: false, peopleNames: with.map { [$0] } ?? [], location: location)
    }

    // MARK: - Tasks

    /// "I need to renew my passport, service the car, call uncle about the shop and book Bali."
    /// → four units, each carrying the task verb.
    private func splitListTasks(_ unit: TextUnit) -> [TextUnit] {
        let lower = unit.text.lowercased()
        guard let prefixRange = lower.range(of: #"\b(i |we )?(need|have|got|ought) to |remind me to |remember to |don'?t forget to "#, options: .regularExpression) else { return [unit] }
        let prefix = String(unit.text[prefixRange])
        let rest = String(unit.text[prefixRange.upperBound...])
        // Real split: on commas and " and " when at least two verb-led clauses exist.
        let clauses = rest
            .replacingOccurrences(of: #"[.!?]+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*(?:,\s*and\s+|,\s*|\s+and\s+then\s+|\s+and\s+|\s*;\s*)"#, with: "\u{1F}", options: .regularExpression)
            .split(separator: "\u{1F}")
            .map { String($0).trimmed }
            .filter { !$0.isEmpty }
        let verbLed = clauses.filter { $0.lowercased().matches(#"^(renew|book|call|pay|buy|send|fix|service|schedule|cancel|return|submit|apply|register|update|check|email|order|pick|drop|get|finish|write|read|clean|wash|visit|go|see|ask|talk|text|message|ping|sort|plan|start|stop|move|transfer|sign|file|print|collect|pack|prepare|cook|bake|water|feed|walk|take|bring|find|look|set|change|replace|install|upgrade|download|upload|back|share|post|reply|respond|confirm|remind|follow)\b"#) }
        guard clauses.count >= 2, verbLed.count >= 2 else { return [unit] }
        // A trailing "and ask about X" belongs to the previous clause (not verb-led as a standalone task).
        var merged: [String] = []
        for c in clauses {
            if c.lowercased().matches(#"^(ask|tell|remind|say|mention|check|see) (about|if|whether|him|her|them)\b"#), var last = merged.popLast() {
                last += " and " + c; merged.append(last)
            } else { merged.append(c) }
        }
        return merged.enumerated().map { TextUnit(text: prefix + $0.element, speaker: unit.speaker, index: unit.index * 10 + $0.offset) }
    }

    private func taskAction(from text: String, hint: TemporalHint?) -> String {
        var action = text.firstMatch(#"\b(?:i |we )?(?:need|have|got|ought) to (.+?)(?:[.!?]|$)"#)
            ?? text.firstMatch(#"\b(?:remind me to|remember to|don'?t forget to|i must|we must) (.+?)(?:[.!?]|$)"#)
            ?? text.replacingOccurrences(of: #"[.!?]+$"#, with: "", options: .regularExpression)
        if let hint { action = action.replacingOccurrences(of: hint.rawText, with: "", options: .caseInsensitive).collapsedWhitespace }
        action = action.replacingOccurrences(of: #"\s+(and )?(ask|talk|check|see) (about|if|whether|with)\b.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        action = action.replacingOccurrences(of: #"^(my|the|our) "#, with: "", options: .regularExpression)
        action = action.replacingOccurrences(of: #"\bmy\b"#, with: "", options: .regularExpression).collapsedWhitespace
        return action.trimmed
    }

    /// "ask about that property" → "property"; "talking about Japanese food" → "Japanese food"
    private func topic(from text: String) -> String? {
        guard let t = text.firstMatch(#"\b(?:about|regarding|re:|on the topic of)\s+([^.!?,]{2,60})"#) else { return nil }
        return t.replacingOccurrences(of: #"\s+(lol|haha|😂)+$"#, with: "", options: .regularExpression).trimmed
    }

    private func cleanClause(_ text: String, stripping patterns: [String]) -> String {
        var t = text
        for p in patterns { t = t.replacingOccurrences(of: p, with: "", options: [.regularExpression, .caseInsensitive]) }
        t = t.strippingEmoji
        return t.replacingOccurrences(of: #"[.!?]+$"#, with: "", options: .regularExpression).trimmed
    }

    // MARK: - Fallback

    private func fallbackMemory(normalized: NormalizedText, input: CaptureInput, units: [TextUnit]) -> ExtractedMemory {
        let type: MemoryType
        switch input.payload {
        case .audio: type = .voiceNote
        case .url: type = .link
        case .image: type = normalized.isChat ? .conversation : .photo
        case .pdf, .file: type = .reference
        default: type = normalized.isChat ? .conversation : .reference
        }
        let best = units.max { $0.text.count < $1.text.count }?.text ?? normalized.cleanedText
        let title: String
        if let partner = normalized.conversationWith { title = "Conversation with \(partner)" }
        else if type == .link, let url = normalized.urls.first { title = ProductRecognizer.productFromURL(url) ?? url.host() ?? url.absoluteString }
        else { title = best.truncated(70) }
        let summary: String
        switch type {
        case .voiceNote: summary = "Voice note: “\(best.truncated(120))”"
        case .link: summary = "Link saved."
        case .conversation: summary = "Saved the conversation. Nothing actionable stood out yet."
        case .photo: summary = normalized.cleanedText.isBlank ? "A photo. No readable text." : "Text found: “\(best.truncated(120))”"
        default: summary = best.truncated(160)
        }
        let people = normalized.conversationWith.map { [$0] } ?? []
        var m = ExtractedMemory(title: title.isBlank ? type.label : title, summary: summary, content: normalized.cleanedText, memoryType: type, confidence: normalized.cleanedText.isBlank ? 0.3 : 0.55, peopleNames: people, url: normalized.urls.first, evidence: best)
        m.importance = ImportanceEngine.score(m, now: context.now)
        return m
    }
}
