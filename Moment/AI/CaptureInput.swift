import Foundation

/// Anything the user throws at MOMENT. The pipeline normalizes it into text (+ preserved originals)
/// before intelligence runs. Raw media stays in the encrypted media store, never in memory longer than needed.
struct CaptureInput: Identifiable, Sendable {
    enum Payload: Sendable {
        case image(Data)
        case text(String)
        case audio(URL)
        case pdf(URL)
        case url(URL)
        case file(URL)
        case clipboard(String)
    }

    let id: UUID
    var payload: Payload
    var sourceType: SourceType
    /// App the content came from, if known (Share Sheet).
    var sourceApp: String?
    var createdAt: Date
    /// Filled in by the normalizer (OCR / transcription / PDF text / page title).
    var extractedText: String?
    /// Confidence of the extraction step (OCR mean confidence, speech confidence), 0–1.
    var extractionConfidence: Double
    /// Hints the normalizer discovered, e.g. "chatApp": "WhatsApp".
    var hints: [String: String]

    init(id: UUID = UUID(), payload: Payload, sourceType: SourceType, sourceApp: String? = nil, createdAt: Date = .now, extractedText: String? = nil, extractionConfidence: Double = 1.0, hints: [String: String] = [:]) {
        self.id = id
        self.payload = payload
        self.sourceType = sourceType
        self.sourceApp = sourceApp
        self.createdAt = createdAt
        self.extractedText = extractedText
        self.extractionConfidence = extractionConfidence
        self.hints = hints
    }

    /// The text the intelligence layer should analyze.
    var textForAnalysis: String {
        if let extractedText, !extractedText.isBlank { return extractedText }
        switch payload {
        case .text(let s), .clipboard(let s): return s
        case .url(let u): return u.absoluteString
        default: return ""
        }
    }

    var isImage: Bool { if case .image = payload { return true } else { return false } }
    var isAudio: Bool { if case .audio = payload { return true } else { return false } }
    var url: URL? { if case .url(let u) = payload { return u } else { return nil } }
}

/// Lightweight, Sendable view of stored entities handed to intelligence for resolution/search.
/// SwiftData models never cross into the AI layer.
struct PersonSnapshot: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var displayName: String
    var aliases: [String]
    var statedRelationship: String?
    var birthday: Date?
    var allNames: [String] { [displayName.lowercased()] + aliases.map { $0.lowercased() } }
}

struct PlaceSnapshot: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var kind: String
}

struct MemorySnapshot: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var title: String
    var summary: String
    var content: String
    var memoryType: MemoryType
    var createdAt: Date
    var importance: Int
    var confidence: Confidence
    var peopleNames: [String]
    var placeNames: [String]
    var tags: [String]
    var sourceType: SourceType
    var referencedDateStart: Date?
    var referencedDateEnd: Date?
    var referencedPrecision: TemporalPrecision?
    var isPinned: Bool

    var searchableText: String {
        ([title, summary, content] + peopleNames + placeNames + tags + [memoryType.label]).joined(separator: " \n")
    }
}

/// Known entities and corrections, so extraction can resolve "Rahul from gym" → Rahul.
struct AnalysisContext: Sendable {
    var knownPeople: [PersonSnapshot] = []
    var knownPlaces: [PlaceSnapshot] = []
    /// lowercased text → person id
    var personCorrections: [String: UUID] = [:]
    var userFirstName: String?
    var userBirthday: Date?
    var now: Date = .now
    var calendar: Calendar = .current

    static let empty = AnalysisContext()
}
