import Foundation
import SwiftData

/// Every user-facing mutation of a memory lives here so the UI stays thin and behavior stays consistent.
/// Nothing is ever destroyed silently; deletes are explicit and media is reference-counted.
@MainActor
final class MemoryActions {
    private let storage: StorageService
    private let media: MediaStore
    private let notifications: NotificationService
    private let analytics: AnalyticsService
    /// Invoked after every mutation; wired to `SurfaceService.noteDataChanged` by AppEnvironment.
    var onChange: () -> Void = {}

    init(storage: StorageService, media: MediaStore, notifications: NotificationService, analytics: AnalyticsService) {
        self.storage = storage
        self.media = media
        self.notifications = notifications
        self.analytics = analytics
    }

    // MARK: Review

    func save(_ memory: Memory) {
        memory.reviewStatus = .saved
        memory.updatedAt = .now
        if storage.profile().firstMomentCapturedAt == nil, !memory.isDemo { storage.profile().firstMomentCapturedAt = .now }
        storage.save()
        onChange()
    }

    func saveAll(_ memories: [Memory]) { memories.forEach(save) }

    func dismiss(_ memory: Memory) {
        memory.reviewStatus = .dismissed
        memory.updatedAt = .now
        // Dismissed captures drop their derived entities so they don't haunt People/Plans.
        detachDerivedEntities(memory)
        storage.save()
        onChange()
    }

    // MARK: Edits

    func update(_ memory: Memory, title: String, summary: String, type: MemoryType, importance: Int? = nil) {
        memory.title = title.trimmed
        memory.summary = summary.trimmed
        memory.memoryType = type
        if let importance { memory.importance = importance }
        memory.metadata["userEdited"] = "true"
        memory.updatedAt = .now
        analytics.track(.memoryEdited)
        storage.save()
        onChange()
    }

    func togglePin(_ memory: Memory) {
        memory.isPinned.toggle()
        memory.importance = ImportanceEngine.rescore(base: memory.importance, isPinned: memory.isPinned, userEdited: memory.metadata["userEdited"] == "true", ageDays: memory.createdAt.daysUntil(.now), hasOpenItem: !memory.promises.filter { $0.status == .pending }.isEmpty)
        storage.save()
        onChange()
    }

    func archive(_ memory: Memory, _ archived: Bool = true) {
        memory.isArchived = archived
        memory.updatedAt = .now
        storage.save()
        onChange()
    }

    func setReminder(_ memory: Memory, at date: Date?) {
        memory.reminderAt = date
        memory.updatedAt = .now
        if date == nil { notifications.cancelReminder(for: memory.id) }
        storage.save()
        onChange()
    }

    /// "No, that's not Sarah. That's Priya." — moves the memory (and its derived items) to the right
    /// person and stores a correction so future captures resolve the same way.
    func correctPerson(in memory: Memory, from wrong: Person?, to correctName: String) {
        let name = correctName.trimmed
        guard !name.isEmpty else { return }
        let target = storage.fetchPeople().first { $0.allNames.contains(name.lowercased()) } ?? { let p = Person(displayName: name); storage.context.insert(p); return p }()
        if let wrong {
            memory.people.removeAll { $0.id == wrong.id }
            for promise in memory.promises where promise.person?.id == wrong.id { promise.person = target }
            for gift in memory.giftIdeas where gift.person?.id == wrong.id { gift.person = target }
            for plan in memory.plans { if let i = plan.people.firstIndex(where: { $0.id == wrong.id }) { plan.people[i] = target } }
            for event in memory.events { if let i = event.people.firstIndex(where: { $0.id == wrong.id }) { event.people[i] = target } }
            // Rewrite the title/summary where the wrong name appears.
            memory.title = memory.title.replacingOccurrences(of: wrong.displayName, with: target.displayName)
            memory.summary = memory.summary.replacingOccurrences(of: wrong.displayName, with: target.displayName)
            // Remember the correction for the evidence text (e.g. a chat header we misread).
            let haystack = [memory.sourceText, memory.content, memory.source?.originalText].compactMap { $0 }.joined(separator: "\n").lowercased()
            if haystack.contains(wrong.displayName.lowercased()) {
                storage.context.insert(EntityCorrection(entityKind: "person", fromText: wrong.displayName, toEntityID: target.id))
            }
            if wrong.memories.isEmpty && wrong.promises.isEmpty && wrong.giftIdeas.isEmpty && wrong.plans.isEmpty { wrong.isDeleted = true }
        }
        if !memory.people.contains(where: { $0.id == target.id }) { memory.people.append(target) }
        target.lastInteractionAt = max(target.lastInteractionAt ?? .distantPast, memory.createdAt)
        memory.refreshCaches()
        memory.metadata["userEdited"] = "true"
        memory.updatedAt = .now
        analytics.track(.memoryEdited, category: "person")
        storage.save()
        onChange()
    }

    func addPerson(_ name: String, to memory: Memory) {
        correctPerson(in: memory, from: nil, to: name)
    }

    /// Renaming a person updates every memory's cached names.
    func rename(_ person: Person, to name: String, relationship: String?, notes: String, birthday: Date?) {
        person.displayName = name.trimmed
        person.statedRelationship = relationship
        person.notes = notes
        person.birthday = birthday
        person.updatedAt = .now
        person.memories.forEach { $0.refreshCaches() }
        storage.save()
        onChange()
    }

    // MARK: Promises / tasks / gifts / plans

    func complete(_ promise: Promise) {
        promise.status = .completed
        promise.completedAt = .now
        promise.updatedAt = .now
        for m in promise.memories { m.updatedAt = .now; notifications.cancelReminder(for: m.id) }
        analytics.track(.memoryEdited, category: "promiseDone")
        storage.save()
        onChange()
    }

    func reopen(_ promise: Promise) {
        promise.status = .pending; promise.completedAt = nil; promise.updatedAt = .now
        storage.save()
        onChange()
    }

    func completeTask(_ memory: Memory) {
        memory.metadata["completedAt"] = ISO8601DateFormatter().string(from: .now)
        memory.isArchived = true
        memory.updatedAt = .now
        notifications.cancelReminder(for: memory.id)
        storage.save()
        onChange()
    }

    func setStatus(_ gift: GiftIdea, _ status: GiftStatus) {
        gift.status = status; gift.updatedAt = .now
        storage.save()
        onChange()
    }

    func setStatus(_ plan: Plan, _ status: PlanStatus) {
        plan.status = status; plan.updatedAt = .now
        if status == .planned, plan.confirmedDate == nil, let s = plan.possibleDateStart, plan.possiblePrecision == .day || plan.possiblePrecision == .exact { plan.confirmedDate = s }
        storage.save()
        onChange()
    }

    func setConfirmedDate(_ plan: Plan, _ date: Date?) {
        plan.confirmedDate = date
        if date != nil { plan.status = .planned }
        plan.updatedAt = .now
        storage.save()
        onChange()
    }

    // MARK: Merge

    /// Merges memories into the first one, preserving every source (as related, never deleted).
    func merge(_ memories: [Memory]) -> Memory? {
        guard let primary = memories.first, memories.count > 1 else { return nil }
        for other in memories.dropFirst() {
            for p in other.people where !primary.people.contains(where: { $0.id == p.id }) { primary.people.append(p) }
            for p in other.places where !primary.places.contains(where: { $0.id == p.id }) { primary.places.append(p) }
            for p in other.plans where !primary.plans.contains(where: { $0.id == p.id }) { primary.plans.append(p) }
            for p in other.promises where !primary.promises.contains(where: { $0.id == p.id }) { primary.promises.append(p) }
            for g in other.giftIdeas where !primary.giftIdeas.contains(where: { $0.id == g.id }) { primary.giftIdeas.append(g) }
            for e in other.events where !primary.events.contains(where: { $0.id == e.id }) { primary.events.append(e) }
            primary.tags = Array(Set(primary.tags + other.tags))
            if !primary.content.contains(other.content) { primary.content += "\n\n— \(other.createdAt.mediumDate) —\n" + other.content }
            primary.importance = max(primary.importance, other.importance)
            // The merged memory keeps its evidence: archived, linked, never deleted.
            other.isArchived = true
            other.metadata["mergedInto"] = primary.id.uuidString
            storage.context.insert(MemoryRelation(from: primary.id, to: other.id, kind: .mergedFrom, reason: "Merged on \(Date.now.mediumDate)", strength: 1))
        }
        primary.summary = "\(memories.count) captures merged. " + primary.summary
        primary.refreshCaches()
        primary.updatedAt = .now
        storage.save()
        onChange()
        return primary
    }

    /// Merge two people into one, keeping every memory and a correction mapping.
    func merge(person duplicate: Person, into canonical: Person) {
        for m in duplicate.memories where !m.people.contains(where: { $0.id == canonical.id }) { m.people.append(canonical) }
        for p in duplicate.promises { p.person = canonical }
        for g in duplicate.giftIdeas { g.person = canonical }
        for pl in duplicate.plans where !pl.people.contains(where: { $0.id == canonical.id }) { pl.people.append(canonical) }
        for e in duplicate.events where !e.people.contains(where: { $0.id == canonical.id }) { e.people.append(canonical) }
        canonical.aliases = Array(Set(canonical.aliases + [duplicate.displayName.lowercased()] + duplicate.aliases))
        if canonical.birthday == nil { canonical.birthday = duplicate.birthday }
        if canonical.statedRelationship == nil { canonical.statedRelationship = duplicate.statedRelationship }
        canonical.lastInteractionAt = max(canonical.lastInteractionAt ?? .distantPast, duplicate.lastInteractionAt ?? .distantPast)
        storage.context.insert(EntityCorrection(entityKind: "person", fromText: duplicate.displayName, toEntityID: canonical.id))
        let affected = duplicate.memories
        duplicate.memories.removeAll()
        duplicate.isDeleted = true
        affected.forEach { $0.refreshCaches() }
        storage.save()
        onChange()
    }

    // MARK: Delete

    func delete(_ memory: Memory) async {
        notifications.cancelReminder(for: memory.id)
        detachDerivedEntities(memory)
        let image = memory.imagePath, audio = memory.audioPath, file = memory.source?.fileReference
        memory.isDeleted = true
        memory.people.removeAll()
        SpotlightService.remove(memory.id)
        storage.context.delete(memory)
        storage.save()
        onChange()
        // Remove media only when no other memory references it.
        let remaining = storage.fetchMemories(includeArchived: true, includeUnreviewed: true)
        for ref in [image, audio, file].compactMap({ $0 }) where !remaining.contains(where: { $0.imagePath == ref || $0.audioPath == ref || $0.source?.fileReference == ref }) {
            await media.delete(ref)
        }
        analytics.track(.memoryDeleted)
    }

    private func detachDerivedEntities(_ memory: Memory) {
        for promise in memory.promises where promise.memories.count <= 1 { promise.isDeleted = true }
        for gift in memory.giftIdeas where gift.memories.count <= 1 { gift.isDeleted = true }
        for event in memory.events where event.memories.count <= 1 { event.isDeleted = true }
        for plan in memory.plans where plan.memories.count <= 1 { plan.isDeleted = true }
        for person in memory.people where person.memories.count <= 1 && person.promises.allSatisfy(\.isDeleted) && person.giftIdeas.allSatisfy(\.isDeleted) {
            person.isDeleted = true
        }
    }

    func removeRelation(_ relation: MemoryRelation) {
        relation.isUserRemoved = true
        storage.save()
        onChange()
    }
}
