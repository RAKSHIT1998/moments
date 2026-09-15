import Foundation
import SwiftData

/// Builds `MemorySnapshot`s on a background context so a query never faults thousands of
/// SwiftData objects on the main actor. Cached per change token by `SearchService`.
@ModelActor
actor SearchIndex {
    func snapshots() throws -> [MemorySnapshot] {
        let descriptor = FetchDescriptor<Memory>(predicate: #Predicate { !$0.isDeleted && $0.reviewStatusRaw == "saved" }, sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return try modelContext.fetch(descriptor).map { m in
            MemorySnapshot(
                id: m.id, title: m.title, summary: m.summary, content: m.content, memoryType: m.memoryType, createdAt: m.createdAt,
                importance: m.importance, confidence: m.confidence, peopleNames: m.peopleNamesCache, placeNames: m.placeNamesCache,
                tags: m.tags, sourceType: m.sourceType, referencedDateStart: m.referencedDateStart, referencedDateEnd: m.referencedDateEnd,
                referencedPrecision: m.referencedPrecision, isPinned: m.isPinned
            )
        }
    }
}
