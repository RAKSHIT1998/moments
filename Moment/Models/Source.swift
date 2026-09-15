import Foundation
import SwiftData

/// Provenance. Every memory can answer "Where did MOMENT get this?"
@Model
final class Source {
    @Attribute(.unique) var id: UUID
    var typeRaw: String
    var createdAt: Date
    /// Full original text (OCR output, transcript, pasted text). Never trimmed for display.
    var originalText: String?
    var originalURL: URL?
    /// Relative path in the encrypted media store.
    var imageReference: String?
    var audioReference: String?
    var fileReference: String?
    /// Bundle id or human name of the originating app when known (e.g. from Share Sheet).
    var appSource: String?
    /// Confidence of the *extraction step* (OCR/transcription quality), 0–1.
    var confidence: Double
    /// Which intelligence provider processed it: "local", "remote", "mock".
    var processedBy: String

    init(id: UUID = UUID(), type: SourceType, createdAt: Date = .now, originalText: String? = nil, originalURL: URL? = nil, imageReference: String? = nil, audioReference: String? = nil, fileReference: String? = nil, appSource: String? = nil, confidence: Double = 1.0, processedBy: String = "local") {
        self.id = id
        self.typeRaw = type.rawValue
        self.createdAt = createdAt
        self.originalText = originalText
        self.originalURL = originalURL
        self.imageReference = imageReference
        self.audioReference = audioReference
        self.fileReference = fileReference
        self.appSource = appSource
        self.confidence = confidence
        self.processedBy = processedBy
    }

    var type: SourceType {
        get { SourceType(rawValue: typeRaw) ?? .manual }
        set { typeRaw = newValue.rawValue }
    }
}
