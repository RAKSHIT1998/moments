import Foundation
import NaturalLanguage

/// Semantic signal from averaged *word* embeddings. Word-vector lookups are microseconds;
/// NLEmbedding's sentence model costs ~100 ms per string, which is unusable over a shortlist.
final class EmbeddingCache: @unchecked Sendable {
    static let shared = EmbeddingCache()
    private let cache = NSCache<NSString, NSArray>()
    private let lock = NSLock()
    /// Loaded once per process (a few hundred ms); nil when the OS has no English word embedding.
    let embedding: NLEmbedding? = NLEmbedding.wordEmbedding(for: .english)
    init() { cache.countLimit = 20_000 }

    private static let skip: Set<String> = ["the", "a", "an", "and", "or", "of", "to", "in", "on", "at", "for", "with", "about", "is", "was", "you", "your", "i", "me", "my", "we", "our", "it", "that", "this", "he", "she", "they", "them", "his", "her", "their", "did", "do", "does", "what", "when", "who", "where", "how"]

    /// Mean vector of the known content words; nil when nothing is in the vocabulary.
    func meanVector(tokens: [String], key: String) -> [Double]? {
        guard let embedding else { return nil }
        let k = key as NSString
        lock.lock(); let hit = cache.object(forKey: k); lock.unlock()
        if let hit { return hit as? [Double] }
        var sum: [Double] = []
        var n = 0
        for t in tokens where !Self.skip.contains(t) && t.count > 2 {
            guard let v = embedding.vector(for: t) else { continue }
            if sum.isEmpty { sum = v } else { for i in v.indices { sum[i] += v[i] } }
            n += 1
        }
        guard n > 0 else { return nil }
        let mean = sum.map { $0 / Double(n) }
        lock.lock(); cache.setObject(mean as NSArray, forKey: k); lock.unlock()
        return mean
    }
}

/// A memory prepared for scoring: stemmed term frequencies and the raw token set.
final class IndexedDocument {
    let tokenSet: Set<String>
    let tf: [String: Double]
    let length: Int
    /// Tokens of title + summary, used for the semantic re-rank.
    let semanticTokens: [String]
    let key: String
    init(tokens: [String], semanticTokens: [String], key: String, stem: (String) -> String) {
        self.semanticTokens = semanticTokens
        self.key = key
        tokenSet = Set(tokens)
        var t: [String: Double] = [:]
        for tok in tokens { t[stem(tok), default: 0] += 1 }
        tf = t
        length = tokens.count
    }
}

/// Indexed documents keyed by memory id + content fingerprint, so a query is dictionary lookups only.
final class DocumentTokenCache: @unchecked Sendable {
    static let shared = DocumentTokenCache()
    private let cache = NSCache<NSString, IndexedDocument>()
    private let lock = NSLock()
    init() { cache.countLimit = 20_000 }

    func document(for m: MemorySnapshot, tokenize: (String) -> [String], stem: (String) -> String) -> IndexedDocument {
        let key = "\(m.id.uuidString)|\(m.title.hashValue)|\(m.summary.count)|\(m.content.count)|\(m.peopleNames.count)" as NSString
        lock.lock(); let hit = cache.object(forKey: key); lock.unlock()
        if let hit { return hit }
        let doc = IndexedDocument(tokens: tokenize(m.searchableText), semanticTokens: tokenize(m.title + " " + m.summary), key: key as String, stem: stem)
        lock.lock(); cache.setObject(doc, forKey: key); lock.unlock()
        return doc
    }
}

/// Retrieval-first local search. Keyword scoring + sentence embeddings (when the OS provides them),
/// then a template answer built *only* from the retrieved memories, with citations.
struct SearchEngine: Sendable {
    var context: AnalysisContext

    static let semanticRerankLimit = 200

    struct ParsedQuery: Sendable, Equatable {
        var intent: QueryIntent
        var people: [String]
        var terms: [String]
        var types: [MemoryType]
        var timeframe: TemporalHint?
    }

    private static let stopwords: Set<String> = ["a", "an", "the", "and", "or", "of", "to", "in", "on", "at", "for", "with", "about", "what", "when", "who", "where", "did", "do", "does", "i", "me", "my", "we", "our", "you", "your", "is", "was", "were", "are", "be", "that", "this", "it", "he", "she", "they", "them", "his", "her", "their", "say", "said", "want", "wanted", "wants", "mention", "mentioned", "talk", "talked", "know", "have", "has", "had", "get", "got", "which", "any", "some", "there", "here", "like", "really", "just", "into", "from", "by", "as", "so", "if", "then", "than", "up", "out", "all", "how", "much", "many", "again", "ever", "last", "time", "thing", "things", "stuff", "need", "needed", "should", "would", "could", "can", "will", "s", "t", "ll", "d", "re", "ve", "m", "promise", "promised", "save", "saved", "remember"]

    // MARK: Query understanding

    func parse(_ query: String) -> ParsedQuery {
        let lower = query.lowercased()
        var intent: QueryIntent = .general
        var types: [MemoryType] = []

        if lower.matches(#"\bwhat do i know about\b|\btell me about\b|\bwho is\b"#) { intent = .whatDoIKnowAbout }
        else if lower.matches(#"\bpromise|owe|said (he|she|they)'?d|supposed to (send|give|get)\b"#) { intent = .whatDidPersonPromise; types = [.promise] }
        else if lower.matches(#"\bwhen did\b|\bwhen was\b|\bwhen (we|i)\b"#) { intent = .whenDidWeTalkAbout }
        else if lower.matches(#"\bwho (mentioned|said|talked|wants|wanted)\b"#) { intent = .whoMentioned }
        else if lower.matches(#"\b(want|wanted|wish|gift|birthday|like|liked)\b"#), lower.matches(#"\bwhat\b"#) { intent = .whatDidPersonWant; types = [.giftIdea, .purchase, .personFact] }
        else if lower.matches(#"\b(need|needed|have) to do\b|\bmy (tasks|to ?dos?)\b|\bwhat did i say i\b"#) { intent = .myTasks; types = [.task] }
        else if lower.matches(#"\b(restaurants?|places?|cafes?|bars?|hotels?)\b"#) { intent = .listOfType; types = [.place] }
        else if lower.matches(#"\b(plans?|trips?)\b"#) { intent = .listOfType; types = [.plan] }
        else if lower.matches(#"\b(links?|articles?)\b"#) { intent = .listOfType; types = [.link] }
        else if lower.matches(#"\b(ideas?)\b"#) { intent = .listOfType; types = [.idea] }
        else if lower.matches(#"\b(events?|birthdays?)\b"#) { intent = .listOfType; types = [.event] }

        let recognizer = EntityRecognizer(context: context)
        let people = recognizer.recognize(in: query, speaker: .user).people
            .filter { !["I", "Me", "You"].contains($0) }
        var terms = tokens(query).filter { !Self.stopwords.contains($0) && $0.count > 1 }
        let peopleTokens = Set(people.flatMap { tokens($0) })
        terms.removeAll { peopleTokens.contains($0) }
        let timeframe = TemporalParser(now: context.now, calendar: context.calendar).parse(query).first
        return ParsedQuery(intent: intent, people: people, terms: terms, types: types, timeframe: timeframe)
    }

    // MARK: Retrieval

    func search(_ query: String, in candidates: [MemorySnapshot], limit: Int = 12) -> SearchResult {
        let parsed = parse(query)
        guard !candidates.isEmpty else { return .empty(query) }

        let queryVector = EmbeddingCache.shared.meanVector(tokens: parsed.terms + parsed.people.map { $0.lowercased() }, key: "q|" + query.lowercased())

        var hits: [SearchResult.Hit] = []
        let docs = candidates.map { ($0, DocumentTokenCache.shared.document(for: $0, tokenize: tokens, stem: stemmed)) }
        let avgLen = Double(docs.map { $0.1.length }.reduce(0, +)) / Double(max(1, docs.count))
        let N = Double(docs.count)
        let queryStems = parsed.terms.map { ($0, stemmed($0)) }
        var df: [String: Double] = [:]
        for (_, stem) in queryStems { df[stem] = Double(docs.reduce(0) { $0 + ($1.1.tf[stem] != nil ? 1 : 0) }) }
        let peopleLower = parsed.people.map { $0.lowercased() }

        for (memory, doc) in docs {
            var score = 0.0
            var reasons: [String] = []

            // People match is the strongest signal.
            let memoryPeople = Set(memory.peopleNames.map { $0.lowercased() })
            var personMatched = false
            for (i, p) in peopleLower.enumerated() where memoryPeople.contains(p) || doc.tokenSet.contains(p) {
                score += 3.0; personMatched = true; reasons.append("Mentions \(parsed.people[i])")
            }
            if !parsed.people.isEmpty, !personMatched, parsed.intent != .general { score -= 1.5 }

            // BM25-ish keyword score
            var matchedTerms: [String] = []
            for (term, stem) in queryStems {
                let f = doc.tf[stem] ?? 0
                guard f > 0 else { continue }
                let dfTerm: Double = df[stem] ?? 0
                let idf: Double = log((N - dfTerm + 0.5) / (dfTerm + 0.5) + 1)
                let k1: Double = 1.4
                let b: Double = 0.7
                let lengthNorm: Double = 1 - b + b * Double(doc.length) / max(1, avgLen)
                let tfPart: Double = (f * (k1 + 1)) / (f + k1 * lengthNorm)
                score += idf * tfPart
                matchedTerms.append(term)
                if memory.title.range(of: term, options: .caseInsensitive) != nil { score += 0.8 }
            }
            if !matchedTerms.isEmpty {
                let display = matchedTerms.map { t in query.split(separator: " ").map(String.init).first { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) == t } ?? t }
                reasons.append("Matches “\(display.joined(separator: ", "))”")
            }

            // Type preference
            if !parsed.types.isEmpty {
                if parsed.types.contains(memory.memoryType) { score += 1.5; reasons.append(memory.memoryType.label) }
                else if parsed.intent == .listOfType { score -= 2 }
            }

            // Timeframe
            if let tf = parsed.timeframe {
                let inWindow = (memory.referencedDateStart.map { $0 >= tf.start.adding(days: -1) && $0 <= tf.end.adding(days: 1) } ?? false)
                    || (memory.createdAt >= tf.start && memory.createdAt <= tf.end.adding(days: 1))
                if inWindow { score += 1.5; reasons.append("In \(tf.description)") } else { score -= 0.5 }
            }

            // Recency tie-breaker
            let age = memory.createdAt.daysUntil(context.now)
            score += max(0, 0.6 - Double(age) / 365)

            guard score > 1.0 else { continue }
            hits.append(SearchResult.Hit(memoryID: memory.id, score: score, reason: reasons.joined(separator: " · "), snippet: memory.summary.isBlank ? memory.content.truncated(120) : memory.summary))
        }

        hits.sort { $0.score > $1.score }

        // Stage 2: semantic re-rank of the keyword shortlist only. Sentence embeddings cost tens of
        // milliseconds each, so they never run over the whole corpus.
        if let qv = queryVector {
            let docByID = Dictionary(uniqueKeysWithValues: docs.map { ($0.0.id, $0.1) })
            let shortlist = min(hits.count, Self.semanticRerankLimit)
            for i in 0..<shortlist {
                guard let d = docByID[hits[i].memoryID], let mv = EmbeddingCache.shared.meanVector(tokens: d.semanticTokens, key: d.key) else { continue }
                let sim = cosine(qv, mv)
                if sim > 0.5 {
                    hits[i].score += (sim - 0.5) * 3
                    if hits[i].reason.isEmpty { hits[i].reason = "Similar meaning" }
                }
            }
            hits[0..<shortlist].sort { $0.score > $1.score }
        }
        let top = Array(hits.prefix(limit))
        let answer = synthesize(parsed: parsed, hits: top, memories: candidates)
        return SearchResult(query: query, answer: answer, hits: top, peopleNames: parsed.people, interpretedIntent: parsed.intent)
    }

    // MARK: Answer synthesis (template, grounded in hits only)

    private func synthesize(parsed: ParsedQuery, hits: [SearchResult.Hit], memories: [MemorySnapshot]) -> String? {
        guard let first = hits.first, first.score >= 2.0 else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: memories.map { ($0.id, $0) })
        let topMemories = hits.prefix(5).compactMap { byID[$0.memoryID] }
        guard let best = topMemories.first else { return nil }
        let who = parsed.people.first
        let dateText = best.createdAt.formatted(.dateTime.month(.wide).day())

        switch parsed.intent {
        case .whatDidPersonWant:
            if best.memoryType == .giftIdea || best.memoryType == .purchase {
                return "\(best.title) — mentioned on \(dateText)."
            }
            return "\(best.title) (\(dateText))."
        case .whatDidPersonPromise:
            let promises = topMemories.filter { $0.memoryType == .promise }
            guard !promises.isEmpty else { return nil }
            if promises.count == 1 { return "\(promises[0].title) — \(promises[0].createdAt.relativeDescription)." }
            return "\(promises.count) promises found" + (who.map { " involving \($0)" } ?? "") + ". The latest: \(promises[0].title)."
        case .whenDidWeTalkAbout:
            let term = parsed.terms.first?.capitalizedFirst ?? "that"
            if topMemories.count == 1 { return "\(term) came up on \(dateText)" + (best.peopleNames.first.map { " with \($0)" } ?? "") + "." }
            let dates = topMemories.prefix(3).map { $0.createdAt.formatted(.dateTime.month(.abbreviated).day()) }
            return "\(term) came up \(topMemories.count) times — \(dates.joined(separator: ", "))."
        case .whoMentioned:
            let names = Array(Set(topMemories.flatMap(\.peopleNames))).sorted()
            guard !names.isEmpty else { return nil }
            return "\(names.joined(separator: ", ")) — see \(topMemories.count) memor\(topMemories.count == 1 ? "y" : "ies") below."
        case .listOfType:
            let matching = topMemories.filter { parsed.types.contains($0.memoryType) }
            guard !matching.isEmpty else { return nil }
            return "\(matching.count) saved: " + matching.prefix(4).map(\.title).joined(separator: " · ")
        case .whatDoIKnowAbout:
            return nil // The People screen handles this properly.
        case .myTasks:
            let tasks = topMemories.filter { $0.memoryType == .task }
            guard !tasks.isEmpty else { return nil }
            return tasks.prefix(5).map(\.title).joined(separator: " · ")
        case .general:
            if first.score >= 4 { return "\(best.title) — \(dateText)" + (best.peopleNames.first.map { ", with \($0)" } ?? "") + "." }
            return nil
        }
    }

    // MARK: Helpers

    /// Fast word tokenizer over UTF-8 bytes (lowercased ASCII fast path; non-ASCII runs go through
    /// `lowercased()`). Runs over every memory on every cold query, so it avoids String indexing.
    func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var buffer: [UInt8] = []
        buffer.reserveCapacity(24)
        var nonASCII = false
        func flush() {
            guard !buffer.isEmpty else { return }
            var s = String(decoding: buffer, as: UTF8.self)
            if nonASCII { s = s.lowercased() }
            if s.count > 1 || (s.utf8.first.map { $0 >= 48 && $0 <= 57 } ?? false) { out.append(s) }
            buffer.removeAll(keepingCapacity: true)
            nonASCII = false
        }
        for b in text.utf8 {
            switch b {
            case 65...90: buffer.append(b | 0x20)            // A-Z → a-z
            case 97...122, 48...57: buffer.append(b)          // a-z, 0-9
            case 39: continue                                 // apostrophe: "sarah's" → "sarahs"
            case 128...: buffer.append(b); nonASCII = true    // multi-byte scalar, keep
            default: flush()
            }
        }
        flush()
        return out
    }

    private func stemmed(_ word: String) -> String {
        var w = word
        for suffix in ["ing", "ed", "es", "s"] where w.count > 4 && w.hasSuffix(suffix) { w = String(w.dropLast(suffix.count)); break }
        return w
    }

    private func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (sqrt(na) * sqrt(nb))
    }
}
