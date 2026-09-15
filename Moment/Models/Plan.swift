import Foundation
import SwiftData

/// An intention, not a calendar event. "Goa in December" lives here until the user makes it real.
@Model
final class Plan {
    @Attribute(.unique) var id: UUID
    var title: String
    var details: String
    var location: String?
    var possibleDateStart: Date?
    var possibleDateEnd: Date?
    var possiblePrecisionRaw: String?
    var confirmedDate: Date?
    var statusRaw: String
    var nextAction: String?
    var createdAt: Date
    var updatedAt: Date
    var isDeleted: Bool

    var people: [Person]
    @Relationship(inverse: \Memory.plans) var memories: [Memory]

    init(id: UUID = UUID(), title: String, details: String = "", location: String? = nil, status: PlanStatus = .idea, createdAt: Date = .now) {
        self.id = id
        self.title = title
        self.details = details
        self.location = location
        self.statusRaw = status.rawValue
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.isDeleted = false
        self.people = []
        self.memories = []
    }

    var status: PlanStatus {
        get { PlanStatus(rawValue: statusRaw) ?? .idea }
        set { statusRaw = newValue.rawValue }
    }
    var possiblePrecision: TemporalPrecision? {
        get { possiblePrecisionRaw.flatMap(TemporalPrecision.init(rawValue:)) }
        set { possiblePrecisionRaw = newValue?.rawValue }
    }
    /// The best date we have: confirmed, else the start of the possible window.
    var anchorDate: Date? { confirmedDate ?? possibleDateStart }
    var sourceMemory: Memory? { memories.min { $0.createdAt < $1.createdAt } }
}
