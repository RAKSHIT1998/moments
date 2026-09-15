import Foundation
import SwiftData
import UIKit

/// Everything about shareable Moments: composing from memories, Memory Drop, recaps, friendship
/// stories, remixing, packages in/out, reactions and sides. Local-first; the only thing that ever
/// leaves the device is a rendered asset or a `.moment` file the user hands to the share sheet.
@MainActor
@Observable
final class StoryService {
    static let freeExportsPerMonth = 3

    private let storage: StorageService
    private let media: MediaStore
    private let importer: ImportService
    private let settings: SettingsStore
    private let analytics: AnalyticsService
    private let subscriptions: SubscriptionService
    let exporter: StoryExporter

    /// Set when a `.moment` file was opened; the UI presents the viewer.
    var pendingStoryID: UUID?
    var lastImportError: String?

    init(storage: StorageService, media: MediaStore, importer: ImportService, settings: SettingsStore, analytics: AnalyticsService, subscriptions: SubscriptionService) {
        self.storage = storage
        self.media = media
        self.importer = importer
        self.settings = settings
        self.analytics = analytics
        self.subscriptions = subscriptions
        self.exporter = StoryExporter(media: media)
    }

    var authorName: String { settings.displayName.isBlank ? "You" : settings.displayName }

    // MARK: Fetch

    func stories(includeReceived: Bool = true) -> [MomentStory] {
        let d = FetchDescriptor<MomentStory>(predicate: #Predicate { !$0.isDeleted }, sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let all = (try? storage.context.fetch(d)) ?? []
        return includeReceived ? all : all.filter { !$0.isReceived }
    }

    func received() -> [MomentStory] { stories().filter(\.isReceived) }

    func story(id: UUID) -> MomentStory? {
        var d = FetchDescriptor<MomentStory>(predicate: #Predicate { $0.id == id }); d.fetchLimit = 1
        return try? storage.context.fetch(d).first
    }

    func delete(_ story: MomentStory) {
        story.isDeleted = true
        storage.context.delete(story)
        storage.save()
    }

    // MARK: Composition inputs

    func storyMemory(_ m: Memory) -> StoryMemory {
        let plan = m.plans.first { !$0.isDeleted }
        let promise = m.promises.first { !$0.isDeleted }
        return StoryMemory(id: m.id, title: m.title, summary: m.summary, content: m.source?.originalText ?? m.content, type: m.memoryType, createdAt: m.createdAt, importance: m.importance, isPinned: m.isPinned, peopleNames: m.peopleNamesCache, placeNames: m.placeNamesCache, imageRef: m.imagePath, sourceType: m.sourceType, planTitle: plan?.title, planStatus: plan?.status, promiseSummary: promise?.summary, promiseStatus: promise?.status, promiseDirection: promise?.direction, taskDone: m.metadata["completedAt"] != nil, giftItem: m.giftIdeas.first?.item, eventTitle: m.events.first?.title, interactions: Int(m.metadata["interactions"] ?? "0") ?? 0)
    }

    private var composer: StoryComposer { StoryComposer(userName: settings.displayName.isBlank ? nil : settings.displayName) }

    // MARK: Create

    /// Compose and persist a Moment from memories with a template.
    @discardableResult
    func create(kind: StoryKind, template: MomentTemplate, memories: [Memory], periodLabel: String? = nil, person: String? = nil, fallbackTitle: String? = nil, remixedFrom: String? = nil) -> MomentStory? {
        guard !memories.isEmpty else { return nil }
        let out = composer.compose(template: template, memories: memories.map(storyMemory), periodLabel: periodLabel, person: person, fallbackTitle: fallbackTitle)
        let story = MomentStory(title: out.title, subtitle: out.subtitle, kind: kind, templateID: template.id, memoryIDs: memories.map(\.id), slides: out.slides, stats: out.stats, peopleNames: out.peopleNames)
        story.remixedFrom = remixedFrom
        storage.context.insert(story)
        storage.save()
        if analytics.count(.firstMomentCreated) == 0 { analytics.track(.firstMomentCreated, category: kind.rawValue) }
        analytics.track(.momentCreated, category: kind.rawValue)
        if remixedFrom != nil { analytics.track(.momentRemixed) }
        return story
    }

    /// Memory Drop: photos → memories (through the real pipeline, so chats become quotes) → a story.
    func memoryDrop(photos: [Data], progress: @escaping @MainActor (Int, Int) -> Void) async -> MomentStory? {
        var created: [Memory] = []
        for (i, data) in photos.enumerated() {
            progress(i, photos.count)
            let date = PhotoMetadata.captureDate(from: data) ?? .now
            let input = CaptureInput(payload: .image(data), sourceType: .photo, createdAt: date)
            if let outcome = try? await importer.run(input) {
                for m in outcome.memories { m.reviewStatus = .saved; created.append(m) }
            }
        }
        storage.save()
        progress(photos.count, photos.count)
        guard !created.isEmpty else { return nil }
        let hasPlace = created.contains { !$0.placeNamesCache.isEmpty }
        let template = MomentTemplate.find(hasPlace ? "drop.trip" : "drop.night") ?? MomentTemplate.builtIn[0]
        let month = created.map(\.createdAt).min()?.formatted(.dateTime.month(.wide).year())
        let story = create(kind: .drop, template: template, memories: created, periodLabel: month, fallbackTitle: month)
        analytics.track(.memoryDropCreated)
        return story
    }

    // MARK: Recaps

    func monthRecap(for date: Date = .now) -> MomentStory? {
        let all = storage.fetchMemories(includeArchived: true)
        guard let interval = Calendar.current.dateInterval(of: .month, for: date) else { return nil }
        let memories = all.filter { interval.contains($0.createdAt) }
        guard RecapEngine().isWorthRecapping(memories.map(storyMemory)), let t = MomentTemplate.find("month.recap") else { return nil }
        let label = date.formatted(.dateTime.month(.wide))
        let s = create(kind: .monthRecap, template: t, memories: memories, periodLabel: label, fallbackTitle: label)
        analytics.track(.recapViewed, category: "month")
        return s
    }

    func yearRecap(year: Int) -> MomentStory? {
        let memories = storage.fetchMemories(includeArchived: true).filter { Calendar.current.component(.year, from: $0.createdAt) == year }
        guard RecapEngine().isWorthRecapping(memories.map(storyMemory)), let t = MomentTemplate.find("year.full") else { return nil }
        let s = create(kind: .yearRecap, template: t, memories: memories, periodLabel: String(year), fallbackTitle: "Your \(year)")
        analytics.track(.recapViewed, category: "year")
        return s
    }

    /// The previous month, once it has ended, if it has enough substance and hasn't been shown.
    func pendingMonthRecap(now: Date = .now) -> (label: String, count: Int)? {
        guard let lastMonth = Calendar.current.date(byAdding: .month, value: -1, to: now), let interval = Calendar.current.dateInterval(of: .month, for: lastMonth) else { return nil }
        let key = lastMonth.formatted(.dateTime.year().month())
        guard settings.lastMonthRecapShown != key else { return nil }
        let count = storage.fetchMemories(includeArchived: true).filter { interval.contains($0.createdAt) }.count
        guard count >= 5 else { return nil }
        return (lastMonth.formatted(.dateTime.month(.wide)), count)
    }

    func markMonthRecapShown(now: Date = .now) {
        if let lastMonth = Calendar.current.date(byAdding: .month, value: -1, to: now) { settings.lastMonthRecapShown = lastMonth.formatted(.dateTime.year().month()) }
    }

    // MARK: Friendship / plan / remix

    func friendship(with person: Person) -> MomentStory? {
        let memories = person.visibleMemories
        guard memories.count >= 2, let t = MomentTemplate.find("friendship") else { return nil }
        return create(kind: .friendship, template: t, memories: memories, person: person.displayName, fallbackTitle: "Me & \(person.displayName)")
    }

    func planStory(_ plan: Plan) -> MomentStory? {
        let memories = plan.memories.filter { !$0.isDeleted }
        guard !memories.isEmpty, let t = MomentTemplate.find("drop.trip") else { return nil }
        return create(kind: .plan, template: t, memories: memories, fallbackTitle: plan.title)
    }

    /// "Make your own": the same template, your memories. Chooses the period/person the template implies.
    func remix(_ received: MomentStory) -> MomentStory? {
        let template = MomentTemplate.find(received.templateID) ?? MomentTemplate.builtIn[0]
        let all = storage.fetchMemories(includeArchived: true)
        let year = Calendar.current.component(.year, from: .now)
        let memories: [Memory]
        switch received.kind {
        case .monthRecap: memories = all.filter { Calendar.current.isDate($0.createdAt, equalTo: .now, toGranularity: .month) }
        case .yearRecap: memories = all.filter { Calendar.current.component(.year, from: $0.createdAt) == year }
        case .friendship:
            let top = storage.fetchPeople().max { $0.visibleMemories.count < $1.visibleMemories.count }
            memories = top?.visibleMemories ?? []
            return create(kind: .friendship, template: template, memories: memories, person: top?.displayName, fallbackTitle: template.name, remixedFrom: received.originAuthor.map { "\($0)'s “\(received.title)”" })
        default: memories = Array(all.prefix(40))
        }
        return create(kind: received.kind == .drop ? .collection : received.kind, template: template, memories: memories, periodLabel: received.kind == .monthRecap ? Date.now.formatted(.dateTime.month(.wide)) : String(year), fallbackTitle: template.name, remixedFrom: received.originAuthor.map { "\($0)'s “\(received.title)”" })
    }

    /// The narrative for "Tell me about my Goa trip".
    func tell(about subject: String) -> (lines: [String], memories: [Memory]) {
        let all = storage.fetchMemories(includeArchived: true)
        let lower = subject.lowercased()
        let matching = all.filter { $0.placeNamesCache.contains { $0.lowercased() == lower } || $0.peopleNamesCache.contains { $0.lowercased() == lower } || $0.plans.contains { $0.title.lowercased().contains(lower) } || $0.title.lowercased().contains(lower) }
        let plan = storage.fetchPlans().first { $0.title.lowercased().contains(lower) || $0.location?.lowercased() == lower }
        let lines = composer.narrative(about: subject, memories: matching.map(storyMemory), plan: plan.map { ($0.title, $0.status, $0.createdAt, $0.anchorDate) })
        return (lines, matching)
    }

    // MARK: Sharing

    /// Free tier: a few exports a month. Viewing, receiving and reacting are never gated.
    func canExport() -> Bool {
        let key = Date.now.formatted(.dateTime.year().month())
        if settings.storyExportsMonthKey != key { settings.storyExportsMonthKey = key; settings.storyExportsThisMonth = 0 }
        return subscriptions.isPro || settings.storyExportsThisMonth < Self.freeExportsPerMonth
    }

    func noteExport(_ story: MomentStory, kind: String) {
        settings.storyExportsThisMonth += 1
        story.shareCount += 1
        story.visibility = .sharedWithPeople
        storage.save()
        analytics.track(.momentShared, category: kind)
    }

    func package(_ story: MomentStory) async throws -> URL {
        let pkg = await MomentPackage.make(from: story, author: authorName, media: media)
        return try pkg.write()
    }

    /// Opening a `.moment` file from Messages/AirDrop/Files.
    func importPackage(at url: URL) async {
        do {
            let pkg = try MomentPackage.read(from: url)
            if let existing = story(id: pkg.id) {
                // Same Moment coming back with new sides/reactions: merge, keep mine.
                let mine = existing.contributions.filter(\.isMine)
                let theirs = (await pkg.materialize(media: media)).contributions.filter { c in !mine.contains { $0.id == c.id } }
                existing.contributions = mine + theirs
                for r in pkg.reactions where !existing.reactions.contains(where: { $0.id == r.id }) { existing.reactions.append(r) }
                existing.updatedAt = .now
                pendingStoryID = existing.id
            } else {
                let story = await pkg.materialize(media: media)
                storage.context.insert(story)
                pendingStoryID = story.id
                analytics.track(.sharedMomentOpened)
            }
            storage.save()
            lastImportError = nil
        } catch {
            lastImportError = error.localizedDescription
            Log.app.error("Package import failed: \(error.localizedDescription)")
        }
    }

    func react(_ story: MomentStory, _ reaction: MemoryReaction) {
        story.reactions.removeAll { $0.authorName == authorName }
        story.reactions.append(StoryReaction(authorName: authorName, reaction: reaction))
        story.updatedAt = .now
        storage.save()
        analytics.track(.reactionAdded, category: reaction.rawValue)
    }

    func addSide(_ story: MomentStory, text: String, photo: Data?) async {
        var ref: String? = nil
        if let photo { ref = try? await media.storeImage(photo) }
        story.contributions.append(StoryContribution(authorName: authorName, text: text, mediaRef: ref, isMine: true))
        story.slides.append(StorySlide(kind: .side, title: text, body: authorName, mediaRef: ref, date: .now))
        story.updatedAt = .now
        storage.save()
        analytics.track(.sideAdded)
    }
}
