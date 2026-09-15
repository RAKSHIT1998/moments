import Foundation
import SwiftData

@Model
final class Place {
    @Attribute(.unique) var id: UUID
    var name: String
    /// "restaurant", "city", "hotel", "shop", "venue", "airport", "unknown"
    var kind: String
    var locality: String?
    var notes: String
    var createdAt: Date
    var updatedAt: Date
    var isDeleted: Bool

    @Relationship(inverse: \Memory.places) var memories: [Memory]

    init(id: UUID = UUID(), name: String, kind: String = "unknown", locality: String? = nil, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.kind = kind
        self.locality = locality
        self.notes = ""
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.isDeleted = false
        self.memories = []
    }
}
