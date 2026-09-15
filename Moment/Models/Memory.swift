import Foundation
import SwiftData

/// The atomic unit of MOMENT. Everything captured becomes one or more memories,
/// each with provenance (`source`) and links to people/plans/promises/gifts/events/places.
@Model
final class Memory {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var updatedAt: Date

    /// Short headline, e.g. "Sarah wants New Balance 530".
    var title: String
    /// One or two sentences of what MOMENT understood.
    var summary: String
    /// The normalized content MOMENT worked from (OCR text, transcript, typed text).
    var content: String

    var memoryTypeRaw: String
    /// 0–100. See `ImportanceEngine`.
    var importance: Int
    var confidenceRaw: String
    var reviewStatusRaw: String

    var sourceURL: URL?
    var sourceText: String?
    var imagePath: String?
    var audioPath: String?

    var isArchived: Bool
    var isDeleted: Bool
    var isPinned: Bool
    var expiresAt: Date?
    var lastSurfacedAt: Date?
    var nextSurfaceAt: Date?
    /// User-facing "remind me" time, if set explicitly.
    var reminderAt: Date?

    /// Free-form, small. Used for things like OCR language, screenshot app hints, demo flags.
    var metadata: [String: String]

    /// Approximate time the memory refers to (e.g. "December"), distinct from `createdAt`.
    var referencedDateStart: Date?
    var referencedDateEnd: Date?
    var referencedPrecisionRaw: String?

    var tags: [String]

    /// Denormalized for fast indexing/lists: names of linked people/places and the source type.
    /// Kept in sync by `refreshCaches()` after every relationship change.
    var peopleNamesCache: [String] = []
    var placeNamesCache: [String] = []
    var sourceTypeRaw: String = SourceType.manual.rawValue

    @Relationship(deleteRule: .cascade) var source: Source?
    var people: [Person]
    var places: [Place]
    var plans: [Plan]
    var promises: [Promise]
    var giftIdeas: [GiftIdea]
    var events: [Event]

    init(
        id: UUID = UUID(),
        title: String,
        summary: String,
        content: String,
        memoryType: MemoryType,
        importance: Int = 40,
        confidence: Confidence = .medium,
        reviewStatus: ReviewStatus = .needsReview,
        source: Source? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.title = title
        self.summary = summary
        self.content = content
        self.memoryTypeRaw = memoryType.rawValue
        self.importance = importance
        self.confidenceRaw = confidence.rawValue
        self.reviewStatusRaw = reviewStatus.rawValue
        self.isArchived = false
        self.isDeleted = false
        self.isPinned = false
        self.metadata = [:]
        self.tags = []
        self.peopleNamesCache = []
        self.placeNamesCache = []
        self.sourceTypeRaw = source?.typeRaw ?? SourceType.manual.rawValue
        self.source = source
        self.people = []
        self.places = []
        self.plans = []
        self.promises = []
        self.giftIdeas = []
        self.events = []
    }

    var memoryType: MemoryType {
        get { MemoryType(rawValue: memoryTypeRaw) ?? .unknown }
        set { memoryTypeRaw = newValue.rawValue }
    }
    var confidence: Confidence {
        get { Confidence(rawValue: confidenceRaw) ?? .medium }
        set { confidenceRaw = newValue.rawValue }
    }
    var reviewStatus: ReviewStatus {
        get { ReviewStatus(rawValue: reviewStatusRaw) ?? .needsReview }
        set { reviewStatusRaw = newValue.rawValue }
    }
    var referencedPrecision: TemporalPrecision? {
        get { referencedPrecisionRaw.flatMap(TemporalPrecision.init(rawValue:)) }
        set { referencedPrecisionRaw = newValue?.rawValue }
    }

    var isVisible: Bool { !isDeleted && !isArchived && reviewStatus == .saved }
    var sourceType: SourceType { SourceType(rawValue: sourceTypeRaw) ?? .manual }

    /// Recompute the denormalized fields from relationships. Call after changing people/places/source.
    func refreshCaches() {
        peopleNamesCache = people.filter { !$0.isDeleted }.map(\.displayName)
        placeNamesCache = places.filter { !$0.isDeleted }.map(\.name)
        sourceTypeRaw = source?.typeRaw ?? sourceTypeRaw
    }
    var isDemo: Bool { metadata["demo"] == "true" }

    /// Text joined for indexing/search.
    var searchableText: String {
        var parts = [title, summary, content]
        parts.append(contentsOf: people.map(\.displayName))
        parts.append(contentsOf: places.map(\.name))
        parts.append(contentsOf: tags)
        parts.append(memoryType.label)
        return parts.joined(separator: " \n")
    }
}
