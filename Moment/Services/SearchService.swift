import Foundation

/// Retrieval-first search over the local store. Never ships the database anywhere.
@MainActor
final class SearchService {
    struct Suggestion: Identifiable, Hashable {
        enum Kind { case person, plan, promise, place, question, recent }
        var id: String { "\(kind)-\(text)" }
        var kind: Kind
        var text: String
        var symbol: String {
            switch kind {
            case .person: "person"
            case .plan: "map"
            case .promise: "hand.raised"
            case .place: "mappin"
            case .question: "questionmark.bubble"
            case .recent: "clock.arrow.circlepath"
            }
        }
    }

    private let storage: StorageService
    private let settings: SettingsStore
    private let analytics: AnalyticsService
    private let index: SearchIndex
    private var cachedSnapshots: [MemorySnapshot] = []
    private var cachedToken: Int = -1
    /// Bumped by `SurfaceService.noteDataChanged` via AppEnvironment.
    var changeToken: () -> Int = { 0 }

    init(storage: StorageService, settings: SettingsStore, analytics: AnalyticsService) {
        self.storage = storage
        self.settings = settings
        self.analytics = analytics
        self.index = SearchIndex(modelContainer: storage.container)
    }

    /// Snapshot index, rebuilt off the main actor only when data changed.
    func snapshots() async -> [MemorySnapshot] {
        let token = changeToken()
        if token != cachedToken || cachedSnapshots.isEmpty {
            if let fresh = try? await index.snapshots() { cachedSnapshots = fresh; cachedToken = token }
        }
        return cachedSnapshots
    }

    func search(_ query: String) async -> (SearchResult, [Memory]) {
        let snapshots = await snapshots()
        let context = storage.analysisContext()
        let provider = LocalIntelligenceProvider()
        let result = (try? await provider.search(query: query, candidates: snapshots, context: context)) ?? .empty(query)
        let hits = result.hits.compactMap { storage.memory(id: $0.memoryID) }
        settings.rememberSearch(query)
        analytics.track(.searchUsed, category: result.interpretedIntent.rawValue)
        return (result, hits)
    }

    func suggestions() -> [Suggestion] {
        var out: [Suggestion] = []
        out += settings.recentSearches.prefix(3).map { Suggestion(kind: .recent, text: $0) }
        let people = storage.fetchPeople().sorted { ($0.lastInteractionAt ?? .distantPast) > ($1.lastInteractionAt ?? .distantPast) }
        for p in people.prefix(3) { out.append(Suggestion(kind: .person, text: "What do I know about \(p.displayName)?")) }
        if let p = people.first(where: { !$0.pendingPromises.isEmpty }) { out.append(Suggestion(kind: .promise, text: "What did \(p.displayName) promise me?")) }
        if let p = people.first(where: { !$0.openGiftIdeas.isEmpty }) { out.append(Suggestion(kind: .question, text: "What did \(p.displayName) want?")) }
        for plan in storage.fetchPlans().filter({ $0.status.isActive }).prefix(2) { out.append(Suggestion(kind: .plan, text: "When did we talk about \(plan.title)?")) }
        if !storage.fetchPlaces().isEmpty { out.append(Suggestion(kind: .place, text: "What restaurants did I save?")) }
        out.append(Suggestion(kind: .question, text: "What did I say I needed to do this week?"))
        return Array(out.prefix(8))
    }
}
