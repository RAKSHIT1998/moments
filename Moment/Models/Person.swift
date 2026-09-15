import Foundation
import SwiftData

/// A person in the user's life, built only from what the user captured.
/// MOMENT never imports the whole address book and never infers sensitive attributes.
@Model
final class Person {
    @Attribute(.unique) var id: UUID
    var displayName: String
    /// Lowercased alternative spellings/nicknames used for resolution ("rahul from gym").
    var aliases: [String]
    /// User-written notes only.
    var notes: String
    /// Factual relationship only when explicitly stated ("my brother Rahul").
    var statedRelationship: String?
    var createdAt: Date
    var updatedAt: Date
    var lastInteractionAt: Date?
    /// 0–100, derived from memory activity.
    var importance: Int
    var avatarPath: String?
    var birthday: Date?
    /// Identifier of a linked Contacts entry, only if the user explicitly linked one.
    var contactIdentifier: String?
    var isDeleted: Bool

    @Relationship(inverse: \Memory.people) var memories: [Memory]
    @Relationship(inverse: \Plan.people) var plans: [Plan]
    @Relationship(inverse: \Promise.person) var promises: [Promise]
    @Relationship(inverse: \GiftIdea.person) var giftIdeas: [GiftIdea]
    @Relationship(inverse: \Event.people) var events: [Event]

    init(id: UUID = UUID(), displayName: String, aliases: [String] = [], createdAt: Date = .now) {
        self.id = id
        self.displayName = displayName
        self.aliases = aliases
        self.notes = ""
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.importance = 30
        self.isDeleted = false
        self.memories = []
        self.plans = []
        self.promises = []
        self.giftIdeas = []
        self.events = []
    }

    var allNames: [String] { [displayName.lowercased()] + aliases.map { $0.lowercased() } }

    var visibleMemories: [Memory] { memories.filter(\.isVisible) }
    var pendingPromises: [Promise] { promises.filter { $0.status == .pending && !$0.isDeleted } }
    var activePlans: [Plan] { plans.filter { $0.status.isActive && !$0.isDeleted } }
    var openGiftIdeas: [GiftIdea] { giftIdeas.filter { $0.status.isOpen && !$0.isDeleted } }
}
