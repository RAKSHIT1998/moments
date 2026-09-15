import Foundation
import SwiftData

/// Edge in the memory graph. Kept as its own model (not a self-referential relationship)
/// so the graph can carry a kind, a reason, and be removed by the user without touching memories.
@Model
final class MemoryRelation {
    @Attribute(.unique) var id: UUID
    var fromMemoryID: UUID
    var toMemoryID: UUID
    var kindRaw: String
    /// Human-readable reason, e.g. "Both mention Goa".
    var reason: String
    var strength: Double
    var createdAt: Date
    var isUserRemoved: Bool

    init(id: UUID = UUID(), from: UUID, to: UUID, kind: RelationKind, reason: String, strength: Double = 0.5, createdAt: Date = .now) {
        self.id = id
        self.fromMemoryID = from
        self.toMemoryID = to
        self.kindRaw = kind.rawValue
        self.reason = reason
        self.strength = strength
        self.createdAt = createdAt
        self.isUserRemoved = false
    }

    var kind: RelationKind {
        get { RelationKind(rawValue: kindRaw) ?? .manual }
        set { kindRaw = newValue.rawValue }
    }
}
