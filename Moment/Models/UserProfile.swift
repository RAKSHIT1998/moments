import Foundation
import SwiftData

/// Singleton-ish record for the user's own preferences that belong with the data.
@Model
final class UserProfile {
    @Attribute(.unique) var id: UUID
    var firstName: String?
    var birthday: Date?
    var createdAt: Date
    var onboardingCompletedAt: Date?
    var firstMomentCapturedAt: Date?
    /// North-star metric, counted locally: memories resurfaced that the user acted on.
    var usefulMemoriesResurfaced: Int

    init(id: UUID = UUID(), createdAt: Date = .now) {
        self.id = id
        self.createdAt = createdAt
        self.usefulMemoriesResurfaced = 0
    }
}
