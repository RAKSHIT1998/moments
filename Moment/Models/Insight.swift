import Foundation
import SwiftData

/// A surfaced observation ("You have 3 memories about the same Goa plan").
/// Persisted so it can be dismissed and not re-shown.
@Model
final class Insight {
    @Attribute(.unique) var id: UUID
    /// "duplicate", "stalePlan", "completedPromise", "outdated", "samePerson"
    var kind: String
    var title: String
    var body: String
    var memoryIDs: [UUID]
    var personIDs: [UUID]
    var createdAt: Date
    var dismissedAt: Date?
    var resolvedAt: Date?
    /// Stable key so the same insight isn't recreated after dismissal.
    @Attribute(.unique) var dedupeKey: String

    init(id: UUID = UUID(), kind: String, title: String, body: String, memoryIDs: [UUID] = [], personIDs: [UUID] = [], dedupeKey: String, createdAt: Date = .now) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.memoryIDs = memoryIDs
        self.personIDs = personIDs
        self.dedupeKey = dedupeKey
        self.createdAt = createdAt
    }

    var isOpen: Bool { dismissedAt == nil && resolvedAt == nil }
}
