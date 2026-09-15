import Foundation
import SwiftData

/// Something someone said they'd do. Direction is only set when the evidence supports it.
@Model
final class Promise {
    @Attribute(.unique) var id: UUID
    var summary: String
    var directionRaw: String
    var statusRaw: String
    var createdAt: Date
    var updatedAt: Date
    var dueDate: Date?
    var completedAt: Date?
    var isDeleted: Bool

    var person: Person?
    @Relationship(inverse: \Memory.promises) var memories: [Memory]

    init(id: UUID = UUID(), summary: String, direction: PromiseDirection = .unknown, status: PromiseStatus = .pending, dueDate: Date? = nil, createdAt: Date = .now) {
        self.id = id
        self.summary = summary
        self.directionRaw = direction.rawValue
        self.statusRaw = status.rawValue
        self.dueDate = dueDate
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.isDeleted = false
        self.memories = []
    }

    var direction: PromiseDirection {
        get { PromiseDirection(rawValue: directionRaw) ?? .unknown }
        set { directionRaw = newValue.rawValue }
    }
    var status: PromiseStatus {
        get { PromiseStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }
    var sourceMemory: Memory? { memories.min { $0.createdAt < $1.createdAt } }
    var isOverdue: Bool {
        guard status == .pending, let dueDate else { return false }
        return dueDate < .now
    }
}
