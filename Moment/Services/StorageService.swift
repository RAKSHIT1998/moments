import Foundation
import SwiftData

/// Owns the SwiftData container and the on-disk layout. Data is protected with iOS Data Protection
/// (complete until first unlock) and lives in the app's own container, never in a shared location.
@MainActor
final class StorageService {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    let isInMemory: Bool

    static var storeDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "MomentStore", directoryHint: .isDirectory)
    }

    init(inMemory: Bool = false, directory: URL? = nil) throws {
        isInMemory = inMemory
        let schema = Schema(MomentSchema.models)
        let config: ModelConfiguration
        if inMemory {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            let dir = directory ?? Self.storeDirectory
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            config = ModelConfiguration("Moment", schema: schema, url: dir.appending(path: "Moment.store"), allowsSave: true)
        }
        container = try ModelContainer(for: schema, migrationPlan: MomentMigrationPlan.self, configurations: [config])
        container.mainContext.autosaveEnabled = true
    }

    /// Last-resort store when even an in-memory container can't be created (should never happen; keeps launch crash-free).
    static func unavailable() -> StorageService {
        // ModelContainer(for:) with an in-memory configuration cannot fail for our schema; if it somehow does,
        // the process has no way to persist anything and the UI shows `storageUnavailable`.
        do { return try StorageService(inMemory: true) } catch { fatalError("SwiftData could not create an in-memory container: \(error)") }
    }

    func save() {
        do { try context.save() } catch { Log.storage.error("Save failed: \(error.localizedDescription)") }
    }

    // MARK: Fetch helpers

    func fetchMemories(includeArchived: Bool = false, includeUnreviewed: Bool = false) -> [Memory] {
        let descriptor = FetchDescriptor<Memory>(predicate: #Predicate { !$0.isDeleted }, sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let all = (try? context.fetch(descriptor)) ?? []
        return all.filter { m in
            (includeArchived || !m.isArchived) && (includeUnreviewed || m.reviewStatus == .saved) && m.reviewStatus != .dismissed
        }
    }

    func fetchInbox() -> [Memory] {
        let descriptor = FetchDescriptor<Memory>(predicate: #Predicate { !$0.isDeleted && $0.reviewStatusRaw == "needsReview" }, sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func fetchPeople() -> [Person] {
        let descriptor = FetchDescriptor<Person>(predicate: #Predicate { !$0.isDeleted }, sortBy: [SortDescriptor(\.displayName)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func fetchPlaces() -> [Place] {
        let descriptor = FetchDescriptor<Place>(predicate: #Predicate { !$0.isDeleted })
        return (try? context.fetch(descriptor)) ?? []
    }

    func fetchPlans() -> [Plan] {
        let descriptor = FetchDescriptor<Plan>(predicate: #Predicate { !$0.isDeleted }, sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func fetchPromises() -> [Promise] {
        let descriptor = FetchDescriptor<Promise>(predicate: #Predicate { !$0.isDeleted }, sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func fetchGiftIdeas() -> [GiftIdea] {
        let descriptor = FetchDescriptor<GiftIdea>(predicate: #Predicate { !$0.isDeleted }, sortBy: [SortDescriptor(\.dateMentioned, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func fetchEvents() -> [Event] {
        let descriptor = FetchDescriptor<Event>(predicate: #Predicate { !$0.isDeleted }, sortBy: [SortDescriptor(\.date)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func fetchRelations(for memoryID: UUID) -> [MemoryRelation] {
        let descriptor = FetchDescriptor<MemoryRelation>(predicate: #Predicate { ($0.fromMemoryID == memoryID || $0.toMemoryID == memoryID) && !$0.isUserRemoved })
        return (try? context.fetch(descriptor)) ?? []
    }

    func fetchInsights(openOnly: Bool = true) -> [Insight] {
        let descriptor = FetchDescriptor<Insight>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let all = (try? context.fetch(descriptor)) ?? []
        return openOnly ? all.filter(\.isOpen) : all
    }

    func fetchCorrections() -> [EntityCorrection] {
        (try? context.fetch(FetchDescriptor<EntityCorrection>())) ?? []
    }

    func memory(id: UUID) -> Memory? {
        var d = FetchDescriptor<Memory>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    func person(id: UUID) -> Person? {
        var d = FetchDescriptor<Person>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    func plan(id: UUID) -> Plan? {
        var d = FetchDescriptor<Plan>(predicate: #Predicate { $0.id == id }); d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    func profile() -> UserProfile {
        if let existing = try? context.fetch(FetchDescriptor<UserProfile>()).first { return existing }
        let p = UserProfile()
        context.insert(p)
        save()
        return p
    }

    var memoryCount: Int {
        (try? context.fetchCount(FetchDescriptor<Memory>(predicate: #Predicate { !$0.isDeleted && $0.reviewStatusRaw == "saved" }))) ?? 0
    }

    // MARK: Snapshots for the AI layer

    func analysisContext(now: Date = .now) -> AnalysisContext {
        let people = fetchPeople().map { PersonSnapshot(id: $0.id, displayName: $0.displayName, aliases: $0.aliases, statedRelationship: $0.statedRelationship, birthday: $0.birthday) }
        let places = fetchPlaces().map { PlaceSnapshot(id: $0.id, name: $0.name, kind: $0.kind) }
        let corrections = Dictionary(fetchCorrections().filter { $0.entityKind == "person" }.map { ($0.fromText, $0.toEntityID) }, uniquingKeysWith: { _, b in b })
        let profile = profile()
        return AnalysisContext(knownPeople: people, knownPlaces: places, personCorrections: corrections, userFirstName: profile.firstName, userBirthday: profile.birthday, now: now)
    }

    func snapshot(_ m: Memory) -> MemorySnapshot {
        MemorySnapshot(
            id: m.id, title: m.title, summary: m.summary, content: m.content, memoryType: m.memoryType, createdAt: m.createdAt,
            importance: m.importance, confidence: m.confidence, peopleNames: m.peopleNamesCache, placeNames: m.placeNamesCache,
            tags: m.tags, sourceType: m.sourceType, referencedDateStart: m.referencedDateStart, referencedDateEnd: m.referencedDateEnd,
            referencedPrecision: m.referencedPrecision, isPinned: m.isPinned
        )
    }

    // MARK: Destructive

    /// Deletes every record. Media files and the encryption key are handled by `DataLifecycleService`.
    func deleteEverything() throws {
        // Many-to-many relationships must be cleared object-by-object; batch deletes can't nullify them.
        for m in try context.fetch(FetchDescriptor<Memory>()) {
            m.people.removeAll(); m.places.removeAll(); m.plans.removeAll(); m.promises.removeAll(); m.giftIdeas.removeAll(); m.events.removeAll()
            context.delete(m)
        }
        for p in try context.fetch(FetchDescriptor<Plan>()) { p.people.removeAll(); context.delete(p) }
        for e in try context.fetch(FetchDescriptor<Event>()) { e.people.removeAll(); context.delete(e) }
        for x in try context.fetch(FetchDescriptor<Promise>()) { context.delete(x) }
        for x in try context.fetch(FetchDescriptor<GiftIdea>()) { context.delete(x) }
        for x in try context.fetch(FetchDescriptor<Place>()) { context.delete(x) }
        for x in try context.fetch(FetchDescriptor<Person>()) { context.delete(x) }
        for x in try context.fetch(FetchDescriptor<Source>()) { context.delete(x) }
        for x in try context.fetch(FetchDescriptor<MemoryRelation>()) { context.delete(x) }
        for x in try context.fetch(FetchDescriptor<Insight>()) { context.delete(x) }
        for x in try context.fetch(FetchDescriptor<EntityCorrection>()) { context.delete(x) }
        for x in try context.fetch(FetchDescriptor<UserProfile>()) { context.delete(x) }
        for x in try context.fetch(FetchDescriptor<MomentStory>()) { context.delete(x) }
        try context.save()
    }
}
