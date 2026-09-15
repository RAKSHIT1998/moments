import AppIntents
import Foundation

/// Siri / Shortcuts entry points. Each one is small and defers to the app's services.
struct CaptureMomentIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture a Moment"
    static let description = IntentDescription("Save something to MOMENT. It will be understood and remembered.")
    static let openAppWhenRun = false

    @Parameter(title: "What to remember") var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let env = AppDelegate.environment else { throw IntentError.appNotReady }
        let outcome = try await env.importer.run(CaptureInput(payload: .text(text), sourceType: .manual, sourceApp: "Shortcuts"))
        env.actions.saveAll(outcome.memories)
        await env.surface.refresh()
        let first = outcome.memories.first?.title ?? "Saved"
        return .result(dialog: "Remembered: \(first)")
    }
}

struct SearchMemoriesIntent: AppIntent {
    static let title: LocalizedStringResource = "Search My Memories"
    static let description = IntentDescription("Ask MOMENT a question about what you've saved.")

    @Parameter(title: "Question") var query: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        guard let env = AppDelegate.environment else { throw IntentError.appNotReady }
        let (result, hits) = await env.search.search(query)
        let answer = result.answer ?? (hits.first.map { "Closest match: \($0.title)" } ?? "Nothing in your memories matched.")
        return .result(value: answer, dialog: "\(answer)")
    }
}

struct ShowTodaysMomentsIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Today's Moments"
    static let openAppWhenRun = true
    @MainActor
    func perform() async throws -> some IntentResult {
        AppDelegate.environment?.pendingTab = .home
        return .result()
    }
}

struct ShowPendingPromisesIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Pending Promises"
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let env = AppDelegate.environment else { throw IntentError.appNotReady }
        let pending = env.storage.fetchPromises().filter { $0.status == .pending }
        if pending.isEmpty { return .result(dialog: "No pending promises.") }
        let lines = pending.prefix(5).map { ($0.direction == .userOwes ? "You'll " : "\($0.person?.displayName ?? "Someone") will ") + $0.summary }
        return .result(dialog: "\(lines.joined(separator: ". "))")
    }
}

struct ShowUpcomingPlansIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Upcoming Plans"
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let env = AppDelegate.environment else { throw IntentError.appNotReady }
        let plans = env.storage.fetchPlans().filter { $0.status.isActive }.sorted { ($0.anchorDate ?? .distantFuture) < ($1.anchorDate ?? .distantFuture) }
        if plans.isEmpty { return .result(dialog: "No plans yet.") }
        let lines = plans.prefix(5).map { $0.title + (TemporalFormatter.describe(start: $0.anchorDate, end: $0.possibleDateEnd, precision: $0.possiblePrecision).map { " — \($0)" } ?? "") }
        return .result(dialog: "\(lines.joined(separator: ". "))")
    }
}

struct ShowGiftIdeasIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Gift Ideas"
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let env = AppDelegate.environment else { throw IntentError.appNotReady }
        let gifts = env.storage.fetchGiftIdeas().filter { $0.status.isOpen }
        if gifts.isEmpty { return .result(dialog: "No gift ideas saved.") }
        let lines = gifts.prefix(5).map { $0.item + ($0.person.map { " for \($0.displayName)" } ?? "") }
        return .result(dialog: "\(lines.joined(separator: ". "))")
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case appNotReady
    var localizedStringResource: LocalizedStringResource { "MOMENT isn't ready yet. Open the app once." }
}

struct MomentShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CaptureMomentIntent(), phrases: ["Remember this in \(.applicationName)", "Capture a moment in \(.applicationName)"], shortTitle: "Capture a Moment", systemImageName: "plus")
        AppShortcut(intent: SearchMemoriesIntent(), phrases: ["Ask \(.applicationName)", "Search my memories in \(.applicationName)"], shortTitle: "Search Memories", systemImageName: "magnifyingglass")
        AppShortcut(intent: ShowPendingPromisesIntent(), phrases: ["Show pending promises in \(.applicationName)"], shortTitle: "Pending Promises", systemImageName: "hand.raised")
        AppShortcut(intent: ShowUpcomingPlansIntent(), phrases: ["Show upcoming plans in \(.applicationName)"], shortTitle: "Upcoming Plans", systemImageName: "map")
        AppShortcut(intent: ShowGiftIdeasIntent(), phrases: ["Show gift ideas in \(.applicationName)"], shortTitle: "Gift Ideas", systemImageName: "gift")
    }
}
