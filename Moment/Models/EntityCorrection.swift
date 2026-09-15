import Foundation
import SwiftData

/// The feedback loop. When the user says "No, that's Priya, not Sarah" or merges
/// "Rahul from gym" into "Rahul", we store the mapping and apply it to future captures.
@Model
final class EntityCorrection {
    @Attribute(.unique) var id: UUID
    /// "person", "place"
    var entityKind: String
    /// Lowercased text as it appeared in the capture.
    var fromText: String
    /// Canonical entity id.
    var toEntityID: UUID
    var createdAt: Date

    init(id: UUID = UUID(), entityKind: String, fromText: String, toEntityID: UUID, createdAt: Date = .now) {
        self.id = id
        self.entityKind = entityKind
        self.fromText = fromText.lowercased()
        self.toEntityID = toEntityID
        self.createdAt = createdAt
    }
}
