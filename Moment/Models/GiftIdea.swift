import Foundation
import SwiftData

@Model
final class GiftIdea {
    @Attribute(.unique) var id: UUID
    var item: String
    var details: String
    var dateMentioned: Date
    /// 0–100
    var priority: Int
    var statusRaw: String
    var price: String?
    var url: URL?
    var createdAt: Date
    var updatedAt: Date
    var isDeleted: Bool

    var person: Person?
    @Relationship(inverse: \Memory.giftIdeas) var memories: [Memory]

    init(id: UUID = UUID(), item: String, details: String = "", dateMentioned: Date = .now, priority: Int = 50, status: GiftStatus = .idea, url: URL? = nil, createdAt: Date = .now) {
        self.id = id
        self.item = item
        self.details = details
        self.dateMentioned = dateMentioned
        self.priority = priority
        self.statusRaw = status.rawValue
        self.url = url
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.isDeleted = false
        self.memories = []
    }

    var status: GiftStatus {
        get { GiftStatus(rawValue: statusRaw) ?? .idea }
        set { statusRaw = newValue.rawValue }
    }
    var sourceMemory: Memory? { memories.min { $0.createdAt < $1.createdAt } }
}
