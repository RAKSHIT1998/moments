import Foundation

/// The user owns their data. JSON (complete), plain text (readable), CSV (spreadsheet).
@MainActor
struct ExportService {
    enum Format: String, CaseIterable, Identifiable {
        case json, text, csv
        var id: String { rawValue }
        var label: String { switch self { case .json: "JSON"; case .text: "Plain text"; case .csv: "CSV" } }
        var fileExtension: String { rawValue == "text" ? "txt" : rawValue }
    }

    struct ExportedMemory: Codable {
        var id: UUID; var createdAt: Date; var title: String; var summary: String; var content: String
        var type: String; var importance: Int; var confidence: String; var status: String
        var people: [String]; var places: [String]; var tags: [String]
        var sourceType: String?; var sourceText: String?; var sourceURL: String?
        var referencedDateStart: Date?; var referencedDateEnd: Date?; var referencedPrecision: String?
        var plans: [String]; var promises: [String]; var giftIdeas: [String]; var events: [String]
        var isArchived: Bool; var isPinned: Bool
    }

    struct ExportedPerson: Codable {
        var id: UUID; var displayName: String; var aliases: [String]; var statedRelationship: String?; var birthday: Date?; var notes: String
    }

    struct Bundle: Codable {
        var exportedAt: Date
        var app = "MOMENT"
        var version = 1
        var memories: [ExportedMemory]
        var people: [ExportedPerson]
    }

    let storage: StorageService

    func makeBundle() -> Bundle {
        let memories = storage.fetchMemories(includeArchived: true, includeUnreviewed: true).map { m in
            ExportedMemory(id: m.id, createdAt: m.createdAt, title: m.title, summary: m.summary, content: m.content, type: m.memoryType.rawValue, importance: m.importance, confidence: m.confidence.rawValue, status: m.reviewStatus.rawValue, people: m.people.map(\.displayName), places: m.places.map(\.name), tags: m.tags, sourceType: m.source?.type.rawValue, sourceText: m.source?.originalText, sourceURL: m.sourceURL?.absoluteString, referencedDateStart: m.referencedDateStart, referencedDateEnd: m.referencedDateEnd, referencedPrecision: m.referencedPrecisionRaw, plans: m.plans.map(\.title), promises: m.promises.map(\.summary), giftIdeas: m.giftIdeas.map(\.item), events: m.events.map(\.title), isArchived: m.isArchived, isPinned: m.isPinned)
        }
        let people = storage.fetchPeople().map { ExportedPerson(id: $0.id, displayName: $0.displayName, aliases: $0.aliases, statedRelationship: $0.statedRelationship, birthday: $0.birthday, notes: $0.notes) }
        return Bundle(exportedAt: .now, memories: memories, people: people)
    }

    func export(_ format: Format) throws -> URL {
        let bundle = makeBundle()
        let data: Data
        switch format {
        case .json:
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
            data = try enc.encode(bundle)
        case .text:
            data = Data(plainText(bundle).utf8)
        case .csv:
            data = Data(csv(bundle).utf8)
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "MOMENT-export-\(Date.now.formatted(.iso8601.year().month().day())).\(format.fileExtension)")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    func plainText(_ b: Bundle) -> String {
        var out = "MOMENT export — \(b.exportedAt.formatted())\n\n"
        for m in b.memories.sorted(by: { $0.createdAt > $1.createdAt }) {
            out += "## \(m.title)\n\(m.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(m.type)\n"
            if !m.summary.isEmpty { out += "\(m.summary)\n" }
            if !m.people.isEmpty { out += "People: \(m.people.joined(separator: ", "))\n" }
            if !m.places.isEmpty { out += "Places: \(m.places.joined(separator: ", "))\n" }
            if let s = m.sourceType { out += "Source: \(s)\n" }
            out += "\n\(m.content)\n\n"
        }
        return out
    }

    func csv(_ b: Bundle) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var rows = ["id,createdAt,title,summary,type,importance,confidence,people,places,tags,sourceType,content"]
        let iso = ISO8601DateFormatter()
        for m in b.memories {
            rows.append([m.id.uuidString, iso.string(from: m.createdAt), q(m.title), q(m.summary), m.type, String(m.importance), m.confidence, q(m.people.joined(separator: "; ")), q(m.places.joined(separator: "; ")), q(m.tags.joined(separator: "; ")), m.sourceType ?? "", q(m.content)].joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }
}
