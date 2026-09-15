import Foundation
import SwiftData
import WidgetKit

/// Builds the "What's worth remembering?" feed from the store, records what was shown,
/// schedules notifications and refreshes the widget snapshot.
@MainActor
@Observable
final class SurfaceService {
    struct FeedItem: Identifiable, Equatable {
        var id: UUID { recommendation.memoryID }
        var recommendation: SurfaceEngine.Recommendation
        var memory: Memory
        static func == (l: FeedItem, r: FeedItem) -> Bool { l.recommendation == r.recommendation }
    }

    private(set) var feed: [FeedItem] = []
    private(set) var lastRefresh: Date?
    private(set) var dailyBrief: [String] = []
    /// Observable counts for tab badges and list reloads (SwiftData fetches aren't observable on their own).
    private(set) var inboxCount = 0
    private(set) var changeToken = 0

    private let storage: StorageService
    private let notifications: NotificationService
    private let settings: SettingsStore

    init(storage: StorageService, notifications: NotificationService, settings: SettingsStore) {
        self.storage = storage
        self.notifications = notifications
        self.settings = settings
    }

    func candidates(now: Date = .now) -> [(SurfaceEngine.Candidate, Memory)] {
        let memories = storage.fetchMemories()
        let openGiftsByPerson = Dictionary(grouping: storage.fetchGiftIdeas().filter { $0.status.isOpen }, by: { $0.person?.id })
        return memories.map { m in
            let person = m.people.first
            let promise = m.promises.first { !$0.isDeleted }
            let plan = m.plans.first { !$0.isDeleted }
            let gift = m.giftIdeas.first { !$0.isDeleted }
            let event = m.events.first { !$0.isDeleted }
            let giftPerson = gift?.person ?? event?.people.first ?? person
            let c = SurfaceEngine.Candidate(
                memoryID: m.id, title: m.title, summary: m.summary, type: m.memoryType, importance: m.importance, createdAt: m.createdAt,
                lastSurfacedAt: m.lastSurfacedAt, reminderAt: m.reminderAt, referencedStart: m.referencedDateStart, referencedPrecision: m.referencedPrecision,
                personName: giftPerson?.displayName ?? promise?.person?.displayName ?? person?.displayName,
                personBirthday: giftPerson?.birthday,
                promiseStatus: promise?.status, promiseDirection: promise?.direction, promiseDue: promise?.dueDate,
                planStatus: plan?.status, planAnchor: plan?.anchorDate,
                giftStatus: gift?.status, giftItem: gift?.item,
                eventDate: event?.date, eventIsAnnual: event?.isAnnual ?? false,
                isPinned: m.isPinned, userInteractions: Int(m.metadata["interactions"] ?? "0") ?? 0,
                openGiftIdeasForPerson: openGiftsByPerson[giftPerson?.id]?.count ?? 0,
                isMuted: m.metadata["muted"] == "true",
                hasExplicitReminderLanguage: m.content.lowercased().contains("remind me")
            )
            return (c, m)
        }
    }

    /// Call after any mutation of memories/people so views observing counts update.
    func noteDataChanged() {
        inboxCount = storage.fetchInbox().count
        changeToken &+= 1
    }

    func refresh(now: Date = .now, scheduleNotifications: Bool = true) async {
        noteDataChanged()
        let memories = storage.fetchMemories()
        let pairs = candidates(now: now)
        let engine = SurfaceEngine(now: now)
        var weights: SurfaceEngine.CategoryWeights = [:]
        for (k, v) in settings.categoryFeedback { if let c = SurfaceEngine.Category(rawValue: k) { weights[c] = v } }
        if !settings.showPeopleOnHome { weights[.people] = 0 }
        if !settings.showPlansOnHome { weights[.plan] = 0 }
        if !settings.showMemoriesOnHome { weights[.remembered] = 0 }
        let recs = engine.recommend(pairs.map(\.0), limit: settings.homeDensity.limit, weights: weights).filter { $0.priority > 0 }
        let byID = Dictionary(uniqueKeysWithValues: pairs.map { ($0.1.id, $0.1) })
        feed = recs.compactMap { r in byID[r.memoryID].map { FeedItem(recommendation: r, memory: $0) } }
        for item in feed { item.memory.lastSurfacedAt = now }
        storage.save()
        lastRefresh = now
        dailyBrief = makeBrief(recs)

        if scheduleNotifications {
            let all = pairs.compactMap { engine.evaluate($0.0) }
            let explicit = pairs.compactMap { pair -> (Memory, Date)? in pair.1.reminderAt.map { (pair.1, $0) } }
            await notifications.schedule(all, explicitReminders: explicit, now: now)
        }
        writeWidgetSnapshot(recs: recs, all: pairs.compactMap { engine.evaluate($0.0) })
        generateInsights(now: now)
        let snapshots = memories.map(storage.snapshot)
        let spotlightEnabled = !settings.requireBiometrics
        Task.detached(priority: .utility) { SpotlightService.reindex(snapshots, enabled: spotlightEnabled) }
    }

    /// Smart cleanup suggestions (duplicates, stale plans, long-pending promises, probable same person).
    /// Persisted with a dedupe key so a dismissed suggestion never comes back.
    func generateInsights(now: Date = .now) {
        let engine = InsightEngine(now: now)
        let memories = storage.fetchMemories().map(storage.snapshot)
        var drafts = engine.duplicateMemories(memories)
        drafts += engine.stalePlans(storage.fetchPlans().map { InsightEngine.PlanInfo(id: $0.id, title: $0.title, status: $0.status, anchor: $0.anchorDate, updatedAt: $0.updatedAt, memoryIDs: $0.memories.map(\.id)) })
        drafts += engine.longPendingPromises(storage.fetchPromises().map { InsightEngine.PromiseInfo(id: $0.id, summary: $0.summary, status: $0.status, createdAt: $0.createdAt, memoryIDs: $0.memories.map(\.id)) })
        drafts += engine.probableSamePeople(storage.fetchPeople().map { PersonSnapshot(id: $0.id, displayName: $0.displayName, aliases: $0.aliases, statedRelationship: $0.statedRelationship, birthday: $0.birthday) })
        let existing = Set(storage.fetchInsights(openOnly: false).map(\.dedupeKey))
        var added = false
        for d in drafts where !existing.contains(d.dedupeKey) {
            storage.context.insert(Insight(kind: d.kind, title: d.title, body: d.body, memoryIDs: d.memoryIDs, personIDs: d.personIDs, dedupeKey: d.dedupeKey))
            added = true
        }
        if added { storage.save() }
    }

    /// One-sentence summary of the day, so it complements the cards instead of repeating them.
    private func makeBrief(_ recs: [SurfaceEngine.Recommendation]) -> [String] {
        guard recs.count >= 3 else { return [] }
        let counts = Dictionary(grouping: recs, by: \.category).mapValues(\.count)
        func phrase(_ c: SurfaceEngine.Category, _ singular: String, _ plural: String) -> String? {
            guard let n = counts[c], n > 0 else { return nil }
            return "\(n) \(n == 1 ? singular : plural)"
        }
        let parts = [phrase(.followUp, "follow-up", "follow-ups"), phrase(.upcoming, "thing coming up", "things coming up"), phrase(.plan, "plan in motion", "plans in motion"), phrase(.today, "thing due today", "things due today"), phrase(.opportunity, "gift idea worth a look", "gift ideas worth a look"), phrase(.remembered, "memory from the past", "memories from the past")].compactMap { $0 }
        guard !parts.isEmpty else { return [] }
        let list = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        return [list.capitalizedFirst + " today."]
    }

    private func writeWidgetSnapshot(recs: [SurfaceEngine.Recommendation], all: [SurfaceEngine.Recommendation]) {
        let items = recs.prefix(6).map { WidgetSnapshot.Item(id: $0.memoryID, category: $0.category.rawValue, headline: $0.headline, detail: $0.detail, deepLink: "\(AppGroup.urlScheme)://memory/\($0.memoryID.uuidString)") }
        let followUps = all.filter { $0.category == .followUp }.count
        let today = all.filter { $0.category == .today || $0.category == .upcoming || $0.category == .followUp }.count
        let snap = WidgetSnapshot(items: items, pendingFollowUps: followUps, todayCount: today, lockScreenAllowed: settings.lockScreenWidgetAllowed)
        do { try snap.save(); WidgetCenter.shared.reloadAllTimelines() } catch { Log.app.error("Widget snapshot failed: \(error.localizedDescription)") }
    }

    /// The user acted on a surfaced memory — the north-star metric.
    func recordUsefulResurface(_ memory: Memory, category: SurfaceEngine.Category? = nil) {
        let profile = storage.profile()
        profile.usefulMemoriesResurfaced += 1
        memory.metadata["interactions"] = String((Int(memory.metadata["interactions"] ?? "0") ?? 0) + 1)
        var log = (memory.metadata["resurfacedLog"] ?? "").split(separator: ",").map(String.init)
        log.append(String(Int(Date.now.timeIntervalSince1970)))
        memory.metadata["resurfacedLog"] = log.suffix(30).joined(separator: ",")
        if let category { settings.recordFeedback(category: category.rawValue, useful: true) }
        storage.save()
    }

    /// "Not useful" — down-weights the category and hides this card for a while.
    func recordNotUseful(_ memory: Memory, category: SurfaceEngine.Category) {
        settings.recordFeedback(category: category.rawValue, useful: false)
        memory.lastSurfacedAt = .now.adding(days: 7)
        storage.save()
        feed.removeAll { $0.memory.id == memory.id }
    }

    /// "Don't remind me about this."
    func mute(_ memory: Memory) {
        memory.metadata["muted"] = "true"
        memory.reminderAt = nil
        notifications.cancelReminder(for: memory.id)
        storage.save()
        feed.removeAll { $0.memory.id == memory.id }
    }

    /// Useful resurfaces in the current calendar month (from per-memory logs).
    func resurfacedThisMonth(now: Date = .now) -> Int {
        guard let start = Calendar.current.dateInterval(of: .month, for: now)?.start else { return 0 }
        let cutoff = Int(start.timeIntervalSince1970)
        return storage.fetchMemories(includeArchived: true).reduce(0) { acc, m in
            acc + (m.metadata["resurfacedLog"] ?? "").split(separator: ",").compactMap { Int($0) }.filter { $0 >= cutoff }.count
        }
    }
}
