import Foundation
import SwiftData

/// A shareable Moment: a beautiful object composed from memories (a trip, a month, a friendship,
/// a collection). Private by default; it leaves the device only when the user explicitly shares
/// a rendered image/video or a `.moment` package.
@Model
final class MomentStory {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var title: String
    var subtitle: String
    var kindRaw: String
    var templateID: String
    var memoryIDs: [UUID]
    var slides: [StorySlide]
    var stats: [String: String]
    var peopleNames: [String]
    var visibilityRaw: String
    /// Set when this Moment arrived from someone else (a `.moment` package).
    var originAuthor: String?
    var isReceived: Bool
    /// When remixed from another Moment: the original's title (credit) and template.
    var remixedFrom: String?
    var contributions: [StoryContribution]
    var reactions: [StoryReaction]
    var shareCount: Int
    var isDeleted: Bool

    init(id: UUID = UUID(), title: String, subtitle: String = "", kind: StoryKind, templateID: String, memoryIDs: [UUID] = [], slides: [StorySlide] = [], stats: [String: String] = [:], peopleNames: [String] = [], createdAt: Date = .now) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.title = title
        self.subtitle = subtitle
        self.kindRaw = kind.rawValue
        self.templateID = templateID
        self.memoryIDs = memoryIDs
        self.slides = slides
        self.stats = stats
        self.peopleNames = peopleNames
        self.visibilityRaw = StoryVisibility.privateOnly.rawValue
        self.isReceived = false
        self.contributions = []
        self.reactions = []
        self.shareCount = 0
        self.isDeleted = false
    }

    var kind: StoryKind { get { StoryKind(rawValue: kindRaw) ?? .custom } set { kindRaw = newValue.rawValue } }
    var visibility: StoryVisibility { get { StoryVisibility(rawValue: visibilityRaw) ?? .privateOnly } set { visibilityRaw = newValue.rawValue } }
    var coverSlide: StorySlide? { slides.first }
}

enum StoryKind: String, Codable, CaseIterable, Sendable {
    case drop, monthRecap, yearRecap, collection, friendship, plan, custom
    var label: String {
        switch self {
        case .drop: "Memory Drop"
        case .monthRecap: "Month in Moments"
        case .yearRecap: "Year in Moments"
        case .collection: "Collection"
        case .friendship: "Friendship"
        case .plan: "Trip"
        case .custom: "Moment"
        }
    }
}

/// Private → shared with specific people (via package) → the user chose to post the rendered
/// asset somewhere public themselves. Nothing is ever public automatically.
enum StoryVisibility: String, Codable, Sendable {
    case privateOnly, sharedWithPeople
}

/// One screen of a Moment. Pure data so it can be rendered, packaged and remixed.
struct StorySlide: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable { case cover, photo, quote, stats, people, places, timeline, list, closing, side }

    var id: UUID
    var kind: Kind
    var title: String
    var body: String
    /// Reference into the media store (local) — packages carry the bytes instead.
    var mediaRef: String?
    var date: Date?
    var caption: String?
    /// Small structured payload: list items, stat pairs, names.
    var items: [String]
    /// Which memory this slide came from, for "why am I seeing this".
    var memoryID: UUID?

    init(id: UUID = UUID(), kind: Kind, title: String, body: String = "", mediaRef: String? = nil, date: Date? = nil, caption: String? = nil, items: [String] = [], memoryID: UUID? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.mediaRef = mediaRef
        self.date = date
        self.caption = caption
        self.items = items
        self.memoryID = memoryID
    }
}

/// "Add your side": another person's perspective attached to a Moment.
struct StoryContribution: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var authorName: String
    var text: String
    var mediaRef: String?
    var createdAt: Date
    var isMine: Bool

    init(id: UUID = UUID(), authorName: String, text: String, mediaRef: String? = nil, createdAt: Date = .now, isMine: Bool) {
        self.id = id
        self.authorName = authorName
        self.text = text
        self.mediaRef = mediaRef
        self.createdAt = createdAt
        self.isMine = isMine
    }
}

/// Reactions native to memories, not likes.
enum MemoryReaction: String, Codable, CaseIterable, Sendable {
    case remember = "I remember this"
    case forgot = "I forgot this"
    case neverForget = "Never forget"
    case core = "Core memory"
    case why = "Why did we do this"
    case love = "Love this"
    case anotherPhoto = "I have another photo"

    var emoji: String {
        switch self {
        case .remember: "❤️"
        case .forgot: "😂"
        case .neverForget: "😭"
        case .core: "🔥"
        case .why: "💀"
        case .love: "🫶"
        case .anotherPhoto: "📸"
        }
    }
}

struct StoryReaction: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var authorName: String
    var reaction: MemoryReaction
    var createdAt: Date
    init(id: UUID = UUID(), authorName: String, reaction: MemoryReaction, createdAt: Date = .now) {
        self.id = id; self.authorName = authorName; self.reaction = reaction; self.createdAt = createdAt
    }
}
