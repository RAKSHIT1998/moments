import Foundation
import NaturalLanguage

/// Everything on this iPhone: NaturalLanguage + the deterministic extraction engine.
/// This is the default provider and the one the product is designed around.
struct LocalIntelligenceProvider: IntelligenceProvider {
    let name = "local"
    let isRemote = false

    /// Loads the NaturalLanguage models (name tagger, word embedding) off the main actor so the first
    /// capture or search doesn't pay a multi-second model load. Safe to call repeatedly.
    static func warmUp() {
        Task.detached(priority: .utility) {
            _ = EntityRecognizer(context: .empty).recognize(in: "Sarah mentioned Goa in December.", speaker: .user)
            _ = EmbeddingCache.shared.meanVector(tokens: ["memory"], key: "warm")
        }
    }

    func analyze(_ input: CaptureInput, context: AnalysisContext) async throws -> AnalysisResult {
        let text = input.textForAnalysis
        guard !text.isBlank || input.isImage else { throw IntelligenceError.nothingToAnalyze }
        let normalizer = TextNormalizer(knownPeople: context.knownPeople)
        let normalized = normalizer.normalize(text, sourceType: input.sourceType, hints: input.hints)
        var result = MemoryExtractor(context: context).extract(from: normalized, input: input)
        result.language = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue
        return try AnalysisValidator.validate(result)
    }

    func search(query: String, candidates: [MemorySnapshot], context: AnalysisContext) async throws -> SearchResult {
        SearchEngine(context: context).search(query, in: candidates)
    }

    func summarize(memories: [MemorySnapshot]) async throws -> String {
        // Honest, template-based summary: counts and the most important titles. No generation.
        guard !memories.isEmpty else { return "Nothing saved yet." }
        let byType = Dictionary(grouping: memories, by: \.memoryType)
        let parts = byType.sorted { $0.value.count > $1.value.count }.prefix(4).map { "\($0.value.count) \($0.key.label.lowercased())\($0.value.count == 1 ? "" : "s")" }
        let top = memories.sorted { $0.importance > $1.importance }.prefix(3).map(\.title)
        return parts.joined(separator: ", ") + ". Most important: " + top.joined(separator: "; ") + "."
    }

    func generateInsight(for person: PersonSnapshot, memories: [MemorySnapshot]) async throws -> InsightDraft? {
        let recent = memories.filter { $0.peopleNames.contains { $0.lowercased() == person.displayName.lowercased() } }.sorted { $0.createdAt > $1.createdAt }
        guard recent.count >= 3 else { return nil }
        let topics = Array(Set(recent.flatMap { $0.placeNames + $0.tags.filter { !["plan", "gift", "promise", "task", "follow up", "shopping", "event", "place", "unknown"].contains($0) } })).prefix(3)
        guard !topics.isEmpty else { return nil }
        return InsightDraft(kind: "personTopics", title: "Recent with \(person.displayName)", body: topics.map { $0.capitalizedFirst }.joined(separator: " · "), memoryIDs: recent.prefix(5).map(\.id), personIDs: [person.id], dedupeKey: "topics:\(person.id):\(topics.sorted().joined(separator: ","))")
    }
}
