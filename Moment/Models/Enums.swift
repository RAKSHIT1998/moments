import Foundation

// MARK: - Memory classification

enum MemoryType: String, Codable, CaseIterable, Sendable {
    case conversation, idea, plan, promise, giftIdea, personFact, place, event, task, reference, purchase, photo, voiceNote, link, unknown

    var label: String {
        switch self {
        case .conversation: "Conversation"
        case .idea: "Idea"
        case .plan: "Plan"
        case .promise: "Promise"
        case .giftIdea: "Gift idea"
        case .personFact: "About someone"
        case .place: "Place"
        case .event: "Event"
        case .task: "To do"
        case .reference: "Reference"
        case .purchase: "Purchase"
        case .photo: "Photo"
        case .voiceNote: "Voice note"
        case .link: "Link"
        case .unknown: "Memory"
        }
    }

    var symbol: String {
        switch self {
        case .conversation: "bubble.left.and.bubble.right"
        case .idea: "lightbulb"
        case .plan: "map"
        case .promise: "hand.raised"
        case .giftIdea: "gift"
        case .personFact: "person"
        case .place: "mappin.and.ellipse"
        case .event: "calendar"
        case .task: "checkmark.circle"
        case .reference: "bookmark"
        case .purchase: "bag"
        case .photo: "photo"
        case .voiceNote: "waveform"
        case .link: "link"
        case .unknown: "circle.dashed"
        }
    }
}

/// How sure MOMENT is. Shown subtly; never pretends certainty.
enum Confidence: String, Codable, Comparable, Sendable {
    case low, medium, high

    private var rank: Int { switch self { case .low: 0; case .medium: 1; case .high: 2 } }
    static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rank < rhs.rank }

    var label: String {
        switch self {
        case .high: "Understood"
        case .medium: "Likely"
        case .low: "Needs review"
        }
    }

    init(score: Double) {
        switch score {
        case ..<0.45: self = .low
        case ..<0.75: self = .medium
        default: self = .high
        }
    }
}

/// Where a memory is in the review flow.
enum ReviewStatus: String, Codable, Sendable {
    case needsReview, saved, dismissed
}

enum PlanStatus: String, Codable, CaseIterable, Sendable {
    case idea, discussed, tentative, planned, completed, cancelled
    var label: String { rawValue.capitalized }
    var isActive: Bool { self != .completed && self != .cancelled }
}

enum PromiseStatus: String, Codable, CaseIterable, Sendable {
    case pending, completed, cancelled, unknown
    var label: String { rawValue.capitalized }
}

enum PromiseDirection: String, Codable, Sendable {
    /// The user owes the other person something.
    case userOwes
    /// The other person owes the user something.
    case personOwes
    case unknown
}

enum GiftStatus: String, Codable, CaseIterable, Sendable {
    case idea, considering, purchased, given, dismissed
    var label: String { rawValue.capitalized }
    var isOpen: Bool { self == .idea || self == .considering }
}

enum SourceType: String, Codable, CaseIterable, Sendable {
    case screenshot, shareSheet, voice, photo, manual, pdf, clipboard, link, scan, demo

    var label: String {
        switch self {
        case .screenshot: "Screenshot"
        case .shareSheet: "Share Sheet"
        case .voice: "Voice"
        case .photo: "Photo"
        case .manual: "Typed"
        case .pdf: "PDF"
        case .clipboard: "Clipboard"
        case .link: "Link"
        case .scan: "Scan"
        case .demo: "Demo"
        }
    }

    var symbol: String {
        switch self {
        case .screenshot: "rectangle.on.rectangle"
        case .shareSheet: "square.and.arrow.up"
        case .voice: "waveform"
        case .photo: "photo"
        case .manual: "keyboard"
        case .pdf: "doc.text"
        case .clipboard: "doc.on.clipboard"
        case .link: "link"
        case .scan: "doc.viewfinder"
        case .demo: "flask"
        }
    }
}

enum RelationKind: String, Codable, Sendable {
    case samePerson, sameTopic, samePlace, samePlan, sameEvent, sameObject, sameTimeframe, mergedFrom, manual
}

/// Approximate timing when an exact date isn't known. MOMENT never invents exact dates.
enum TemporalPrecision: String, Codable, Sendable {
    case exact      // 2026-12-14 15:00
    case day        // 2026-12-14
    case week
    case month      // December
    case season
    case year
    case vague      // "later", "sometime"
}
