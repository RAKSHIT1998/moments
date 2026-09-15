import Foundation

/// The seam between MOMENT and any intelligence — on-device rules + NaturalLanguage today,
/// a cloud model if the user opts in, a mock in tests. The UI never talks to a vendor directly.
protocol IntelligenceProvider: Sendable {
    var name: String { get }
    /// True when this provider sends content off-device.
    var isRemote: Bool { get }

    func analyze(_ input: CaptureInput, context: AnalysisContext) async throws -> AnalysisResult
    func search(query: String, candidates: [MemorySnapshot], context: AnalysisContext) async throws -> SearchResult
    func summarize(memories: [MemorySnapshot]) async throws -> String
    func generateInsight(for person: PersonSnapshot, memories: [MemorySnapshot]) async throws -> InsightDraft?
}

/// A generated observation before it becomes a persisted `Insight`.
struct InsightDraft: Sendable, Equatable {
    var kind: String
    var title: String
    var body: String
    var memoryIDs: [UUID]
    var personIDs: [UUID]
    var dedupeKey: String
}

/// Answer + evidence. The answer is only ever built from the cited memories.
struct SearchResult: Sendable, Equatable {
    struct Hit: Sendable, Equatable, Identifiable {
        var id: UUID { memoryID }
        var memoryID: UUID
        var score: Double
        /// Why it matched, e.g. "Mentions Sarah and Tosaka".
        var reason: String
        var snippet: String
    }

    var query: String
    var answer: String?
    var hits: [Hit]
    var peopleNames: [String]
    var interpretedIntent: QueryIntent

    static func empty(_ query: String) -> SearchResult {
        SearchResult(query: query, answer: nil, hits: [], peopleNames: [], interpretedIntent: .general)
    }
}

enum QueryIntent: String, Sendable {
    case general
    case whatDidPersonWant     // "What did Sarah want for her birthday?"
    case whatDidPersonPromise  // "What did Rahul promise me?"
    case whenDidWeTalkAbout    // "When did we talk about Goa?"
    case whoMentioned          // "Who mentioned Bali?"
    case listOfType            // "What restaurants did I save?"
    case whatDoIKnowAbout      // "What do I know about Rahul?"
    case myTasks               // "What did I say I needed to do?"
}

enum IntelligenceError: Error, LocalizedError {
    case nothingToAnalyze
    case providerUnavailable(String)
    case invalidResponse(String)
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .nothingToAnalyze: "There was nothing readable to understand."
        case .providerUnavailable(let why): why
        case .invalidResponse(let why): "The AI returned something unexpected: \(why)"
        case .network(let e): "Network problem: \(e.localizedDescription)"
        }
    }
}
