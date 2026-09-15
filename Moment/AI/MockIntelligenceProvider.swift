#if DEBUG
import Foundation

/// Deterministic provider for tests and previews. Returns whatever it's configured with.
final class MockIntelligenceProvider: IntelligenceProvider, @unchecked Sendable {
    let name = "mock"
    let isRemote = false

    var analysisResult: AnalysisResult
    var searchResult: SearchResult?
    var error: Error?
    private(set) var analyzeCalls: [CaptureInput] = []

    init(analysisResult: AnalysisResult = AnalysisResult(), searchResult: SearchResult? = nil, error: Error? = nil) {
        self.analysisResult = analysisResult
        self.searchResult = searchResult
        self.error = error
    }

    func analyze(_ input: CaptureInput, context: AnalysisContext) async throws -> AnalysisResult {
        analyzeCalls.append(input)
        if let error { throw error }
        return analysisResult
    }

    func search(query: String, candidates: [MemorySnapshot], context: AnalysisContext) async throws -> SearchResult {
        if let error { throw error }
        return searchResult ?? .empty(query)
    }

    func summarize(memories: [MemorySnapshot]) async throws -> String { "Mock summary of \(memories.count) memories." }
    func generateInsight(for person: PersonSnapshot, memories: [MemorySnapshot]) async throws -> InsightDraft? { nil }
}
#endif
