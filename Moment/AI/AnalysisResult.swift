import Foundation

/// Structured output of intelligence. Codable so remote providers can return it as JSON,
/// and validated (`AnalysisValidator`) before anything touches the store.
struct AnalysisResult: Codable, Sendable, Equatable {
    var memories: [ExtractedMemory]
    var people: [ExtractedPerson]
    /// Overall confidence in the understanding of this capture, 0–1.
    var confidence: Double
    /// Text after normalization (chat chrome removed, etc.).
    var normalizedText: String
    var language: String?
    /// Non-fatal notes for the UI ("Couldn't tell who said this").
    var warnings: [String]
    /// Detected conversation partner, when the capture is a chat screenshot.
    var conversationWith: String?

    init(memories: [ExtractedMemory] = [], people: [ExtractedPerson] = [], confidence: Double = 0, normalizedText: String = "", language: String? = nil, warnings: [String] = [], conversationWith: String? = nil) {
        self.memories = memories
        self.people = people
        self.confidence = confidence
        self.normalizedText = normalizedText
        self.language = language
        self.warnings = warnings
        self.conversationWith = conversationWith
    }

    var isEmpty: Bool { memories.isEmpty }
}

/// An approximate or exact time reference. `precision` tells the UI how to phrase it.
struct TemporalHint: Codable, Sendable, Equatable, Hashable {
    var start: Date
    var end: Date
    var precision: TemporalPrecision
    var rawText: String
    var isFuture: Bool

    var description: String {
        TemporalFormatter.describe(start: start, end: end, precision: precision) ?? rawText
    }
}

struct ExtractedMemory: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var summary: String
    /// The unit of text this memory was derived from.
    var content: String
    var memoryType: MemoryType
    /// Additional classifications when a unit is more than one thing.
    var secondaryTypes: [MemoryType]
    var confidence: Double
    var importance: Int
    var peopleNames: [String]
    var placeNames: [String]
    var temporal: TemporalHint?
    var tags: [String]
    var url: URL?
    var plan: ExtractedPlan?
    var promise: ExtractedPromise?
    var gift: ExtractedGift?
    var event: ExtractedEvent?
    var place: ExtractedPlace?
    /// The exact quote this came from, for the "why" explanation.
    var evidence: String

    init(id: UUID = UUID(), title: String, summary: String, content: String, memoryType: MemoryType, secondaryTypes: [MemoryType] = [], confidence: Double, importance: Int = 40, peopleNames: [String] = [], placeNames: [String] = [], temporal: TemporalHint? = nil, tags: [String] = [], url: URL? = nil, plan: ExtractedPlan? = nil, promise: ExtractedPromise? = nil, gift: ExtractedGift? = nil, event: ExtractedEvent? = nil, place: ExtractedPlace? = nil, evidence: String = "") {
        self.id = id
        self.title = title
        self.summary = summary
        self.content = content
        self.memoryType = memoryType
        self.secondaryTypes = secondaryTypes
        self.confidence = confidence
        self.importance = importance
        self.peopleNames = peopleNames
        self.placeNames = placeNames
        self.temporal = temporal
        self.tags = tags
        self.url = url
        self.plan = plan
        self.promise = promise
        self.gift = gift
        self.event = event
        self.place = place
        self.evidence = evidence
    }
}

struct ExtractedPerson: Codable, Sendable, Equatable, Hashable {
    var name: String
    /// Only when explicitly stated ("my brother Rahul").
    var statedRelationship: String?
    var birthday: Date?
    var confidence: Double
    /// Matched a known person in the store (by name/alias/correction).
    var resolvedPersonID: UUID?
}

struct ExtractedPlan: Codable, Sendable, Equatable {
    var title: String
    var destination: String?
    var temporal: TemporalHint?
    var status: PlanStatus
    var peopleNames: [String]
}

struct ExtractedPromise: Codable, Sendable, Equatable {
    var summary: String
    var direction: PromiseDirection
    var personName: String?
    var due: TemporalHint?
}

struct ExtractedGift: Codable, Sendable, Equatable {
    var item: String
    var forPersonName: String?
    var url: URL?
    var price: String?
}

struct ExtractedEvent: Codable, Sendable, Equatable {
    var title: String
    var temporal: TemporalHint
    var isAnnual: Bool
    var peopleNames: [String]
    var location: String?
}

struct ExtractedPlace: Codable, Sendable, Equatable {
    var name: String
    var kind: String
}

/// Rejects malformed or suspicious AI output before it becomes application state.
enum AnalysisValidator {
    enum ValidationError: Error, LocalizedError {
        case tooManyMemories, emptyTitle, badConfidence, oversizedField, suspiciousContent
        var errorDescription: String? {
            switch self {
            case .tooManyMemories: "Too many items were extracted."
            case .emptyTitle: "An item had no title."
            case .badConfidence: "Confidence out of range."
            case .oversizedField: "A field was unexpectedly large."
            case .suspiciousContent: "Output contained instructions instead of data."
            }
        }
    }

    static let maxMemories = 12
    static let maxFieldLength = 4000

    /// Returns a cleaned copy, or throws when the result can't be trusted.
    static func validate(_ result: AnalysisResult) throws -> AnalysisResult {
        guard result.memories.count <= maxMemories else { throw ValidationError.tooManyMemories }
        guard (0...1).contains(result.confidence) else { throw ValidationError.badConfidence }
        var cleaned = result
        cleaned.memories = try result.memories.map { m in
            var m = m
            m.title = m.title.collapsedWhitespace.truncated(140)
            guard !m.title.isBlank else { throw ValidationError.emptyTitle }
            guard (0...1).contains(m.confidence) else { throw ValidationError.badConfidence }
            guard m.content.count <= maxFieldLength * 4, m.summary.count <= maxFieldLength else { throw ValidationError.oversizedField }
            if PromptInjectionGuard.looksLikeInstruction(m.title) || PromptInjectionGuard.looksLikeInstruction(m.summary) {
                throw ValidationError.suspiciousContent
            }
            m.importance = max(0, min(100, m.importance))
            m.peopleNames = m.peopleNames.map { $0.trimmed }.filter { !$0.isEmpty && $0.count <= 60 }
            m.placeNames = m.placeNames.map { $0.trimmed }.filter { !$0.isEmpty && $0.count <= 80 }
            m.tags = Array(Set(m.tags.map { $0.lowercased().trimmed })).filter { !$0.isEmpty }.sorted()
            return m
        }
        cleaned.people = result.people.filter { !$0.name.isBlank && $0.name.count <= 60 }
        return cleaned
    }
}

/// Imported text is DATA. If a screenshot says "ignore previous instructions", that is just a string
/// to analyze. The local provider never executes text; the remote provider wraps content in a data
/// envelope and the validator refuses outputs that read like instructions.
enum PromptInjectionGuard {
    private static let patterns = [
        #"ignore (all |the )?(previous|prior|above) instructions"#,
        #"you are now"#,
        #"system prompt"#,
        #"as an ai (language )?model"#,
        #"disregard (all|any|the) (rules|instructions)"#
    ]

    static func looksLikeInstruction(_ text: String) -> Bool {
        patterns.contains { text.matches($0) }
    }

    /// Wraps user content so a remote model can't confuse it with instructions.
    static func envelope(_ content: String) -> String {
        let sanitized = content.replacingOccurrences(of: "</user_content>", with: "[/user_content]")
        return "<user_content>\n\(sanitized)\n</user_content>"
    }
}
