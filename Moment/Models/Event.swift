import Foundation
import SwiftData

/// A dated occurrence (birthday, dinner, flight). Never written to Apple Calendar without confirmation.
@Model
final class Event {
    @Attribute(.unique) var id: UUID
    var title: String
    var date: Date
    var precisionRaw: String
    var location: String?
    var confidenceRaw: String
    /// Set only after the user explicitly adds it to their calendar.
    var calendarEventIdentifier: String?
    /// Repeats yearly (birthdays, anniversaries).
    var isAnnual: Bool
    var createdAt: Date
    var updatedAt: Date
    var isDeleted: Bool

    var people: [Person]
    @Relationship(inverse: \Memory.events) var memories: [Memory]

    init(id: UUID = UUID(), title: String, date: Date, precision: TemporalPrecision = .day, location: String? = nil, confidence: Confidence = .medium, isAnnual: Bool = false, createdAt: Date = .now) {
        self.id = id
        self.title = title
        self.date = date
        self.precisionRaw = precision.rawValue
        self.location = location
        self.confidenceRaw = confidence.rawValue
        self.isAnnual = isAnnual
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.isDeleted = false
        self.people = []
        self.memories = []
    }

    var precision: TemporalPrecision {
        get { TemporalPrecision(rawValue: precisionRaw) ?? .day }
        set { precisionRaw = newValue.rawValue }
    }
    var confidence: Confidence {
        get { Confidence(rawValue: confidenceRaw) ?? .medium }
        set { confidenceRaw = newValue.rawValue }
    }

    /// Next occurrence on or after `now` (handles annual events).
    func nextOccurrence(after now: Date = .now, calendar: Calendar = .current) -> Date {
        guard isAnnual else { return date }
        var comps = calendar.dateComponents([.month, .day], from: date)
        comps.year = calendar.component(.year, from: now)
        guard let thisYear = calendar.date(from: comps) else { return date }
        if calendar.startOfDay(for: thisYear) >= calendar.startOfDay(for: now) { return thisYear }
        comps.year! += 1
        return calendar.date(from: comps) ?? date
    }
}
