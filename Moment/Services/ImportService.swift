import Foundation
import PDFKit
import SwiftData
import UIKit

/// The pipeline: CaptureInput → Normalize → Extract → Classify → Resolve → Persist → Relate → Score → Schedule.
/// Runs on the main actor for SwiftData; heavy work (OCR, encryption) is awaited off-main.
@MainActor
final class ImportService {
    enum Stage: Int, CaseIterable {
        case analyzing, reading, understanding, findingWhatMatters, done
        var label: String {
            switch self {
            case .analyzing: "Analyzing…"
            case .reading: "Reading text…"
            case .understanding: "Understanding context…"
            case .findingWhatMatters: "Finding what matters…"
            case .done: "Done"
            }
        }
    }

    struct Outcome {
        var memories: [Memory]
        var result: AnalysisResult
        var usedRemote: Bool
        var warnings: [String]
    }

    private let storage: StorageService
    private let media: MediaStore
    private let settings: SettingsStore
    private let ocr = OCRService()
    private let analytics: AnalyticsService
    var providerOverride: (any IntelligenceProvider)?
    var onChange: () -> Void = {}

    init(storage: StorageService, media: MediaStore, settings: SettingsStore, analytics: AnalyticsService) {
        self.storage = storage
        self.media = media
        self.settings = settings
        self.analytics = analytics
    }

    private var provider: any IntelligenceProvider {
        if let providerOverride { return providerOverride }
        return settings.useCloudAI && RemoteIntelligenceProvider.hasKey ? RemoteIntelligenceProvider() : LocalIntelligenceProvider()
    }

    // MARK: Pipeline

    func run(_ rawInput: CaptureInput, progress: @escaping @MainActor (Stage) -> Void = { _ in }) async throws -> Outcome {
        analytics.track(.captureStarted, category: rawInput.sourceType.rawValue)
        progress(.analyzing)
        var input = try await normalize(rawInput, progress: progress)

        progress(.understanding)
        let context = storage.analysisContext()
        var usedRemote = false
        var warnings: [String] = []
        var result: AnalysisResult
        let chosen = provider
        do {
            result = try await chosen.analyze(input, context: context)
            usedRemote = chosen.isRemote
        } catch let error as IntelligenceError {
            if chosen.isRemote {
                // Cloud failed: fall back to on-device silently but tell the user.
                warnings.append("Cloud AI wasn't available; understood on this iPhone instead.")
                result = try await LocalIntelligenceProvider().analyze(input, context: context)
            } else { throw error }
        }
        warnings.append(contentsOf: result.warnings)

        progress(.findingWhatMatters)
        if input.extractedText == nil { input.extractedText = result.normalizedText }
        let memories = try await persist(result, input: input, processedBy: usedRemote ? "remote" : "local")
        analytics.track(.captureCompleted, category: rawInput.sourceType.rawValue)
        progress(.done)
        return Outcome(memories: memories, result: result, usedRemote: usedRemote, warnings: warnings)
    }

    /// Step 1: turn any payload into analyzable text while preserving the original.
    func normalize(_ input: CaptureInput, progress: @escaping @MainActor (Stage) -> Void = { _ in }) async throws -> CaptureInput {
        var out = input
        switch input.payload {
        case .image(let data):
            progress(.reading)
            let r = try await ocr.recognize(imageData: data)
            out.extractedText = r.text
            out.extractionConfidence = r.lineCount == 0 ? 0.2 : r.confidence
            if r.lineCount == 0 { out.hints["noText"] = "true" }
        case .pdf(let url):
            progress(.reading)
            guard let doc = PDFDocument(url: url) else { throw IntelligenceError.nothingToAnalyze }
            var text = ""
            for i in 0..<min(doc.pageCount, 25) { text += (doc.page(at: i)?.string ?? "") + "\n" }
            if text.isBlank, let first = doc.page(at: 0) {
                // Scanned PDF: OCR the first page.
                let image = first.thumbnail(of: CGSize(width: 1600, height: 2200), for: .mediaBox)
                if let data = image.jpegData(compressionQuality: 0.9) {
                    let r = try await ocr.recognize(imageData: data)
                    text = r.text; out.extractionConfidence = r.confidence
                }
            }
            out.extractedText = text
            out.hints["pdfTitle"] = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String ?? url.lastPathComponent
        case .url(let url):
            out.extractedText = "\(url.absoluteString)"
            if let title = await fetchPageTitle(url) { out.extractedText = "\(title)\n\(url.absoluteString)"; out.hints["pageTitle"] = title }
        case .file(let url):
            progress(.reading)
            if let s = try? String(contentsOf: url, encoding: .utf8) { out.extractedText = s }
            else if let data = try? Data(contentsOf: url), UIImage(data: data) != nil {
                out.payload = .image(data)
                return try await normalize(out, progress: progress)
            } else { throw IntelligenceError.nothingToAnalyze }
        case .audio:
            // Transcript is supplied by SpeechService before the pipeline runs.
            if (input.extractedText ?? "").isBlank { throw IntelligenceError.nothingToAnalyze }
        case .text(let s), .clipboard(let s):
            out.extractedText = s
        }
        return out
    }

    private func fetchPageTitle(_ url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let html = String(data: data.prefix(200_000), encoding: .utf8) ?? String(data: data.prefix(200_000), encoding: .isoLatin1) else { return nil }
        guard let title = html.firstMatch(#"<title[^>]*>([^<]{1,200})</title>"#) else { return nil }
        return title.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&quot;", with: "\"").collapsedWhitespace
    }

    // MARK: Persist

    /// Steps 4–9: resolve entities, create memories and relationships, score, schedule.
    func persist(_ result: AnalysisResult, input: CaptureInput, processedBy: String) async throws -> [Memory] {
        let context = storage.context
        let source = try await makeSource(for: input, result: result, processedBy: processedBy)
        context.insert(source)

        let resolver = ContextResolver(context: storage.analysisContext())
        var createdMemories: [Memory] = []
        var peopleCache: [String: Person] = [:]
        var planInThisCapture: Plan?

        func person(named rawName: String, confidence: Double) -> Person? {
            let key = rawName.lowercased().trimmed
            if let cached = peopleCache[key] { return cached }
            let resolution = resolver.resolve(personName: rawName)
            if let id = resolution.matchedID, let existing = storage.person(id: id) {
                peopleCache[key] = existing
                return existing
            }
            let p = Person(displayName: resolution.name)
            context.insert(p)
            peopleCache[key] = p
            if let possibleID = resolution.possibleMatchID, let possibleName = resolution.possibleMatchName {
                let insight = Insight(kind: "samePerson", title: "Could these be the same person?", body: "\(p.displayName) and \(possibleName)", personIDs: [p.id, possibleID], dedupeKey: "same:" + [p.id.uuidString, possibleID.uuidString].sorted().joined(separator: ","))
                context.insert(insight)
            }
            return p
        }

        // Person-level facts (relationship, birthday) from the result.
        for ep in result.people {
            guard let p = person(named: ep.name, confidence: ep.confidence) else { continue }
            if let rel = ep.statedRelationship, p.statedRelationship == nil { p.statedRelationship = rel }
            if let b = ep.birthday, p.birthday == nil { p.birthday = b }
            p.lastInteractionAt = max(p.lastInteractionAt ?? .distantPast, input.createdAt)
            p.updatedAt = .now
        }

        for em in result.memories {
            let memory = Memory(title: em.title, summary: em.summary, content: em.content, memoryType: em.memoryType,
                                importance: em.importance, confidence: Confidence(score: em.confidence), reviewStatus: .needsReview,
                                source: nil, createdAt: input.createdAt)
            memory.tags = em.tags + em.secondaryTypes.map(\.rawValue)
            memory.sourceURL = em.url ?? input.url
            memory.sourceText = em.evidence
            memory.metadata["evidence"] = em.evidence
            memory.metadata["confidenceScore"] = String(format: "%.2f", em.confidence)
            if let t = em.temporal {
                memory.referencedDateStart = t.start
                memory.referencedDateEnd = t.end
                memory.referencedPrecision = t.precision
                memory.metadata["temporalRaw"] = t.rawText
            }
            if let ref = source.imageReference { memory.imagePath = ref }
            if let ref = source.audioReference { memory.audioPath = ref }
            // Each memory gets its own Source row pointing at the same media (cascade-safe: media is
            // reference-counted by DataLifecycleService when memories are deleted).
            memory.source = createdMemories.isEmpty ? source : cloneSource(source)
            context.insert(memory)

            for name in em.peopleNames {
                if let p = person(named: name, confidence: em.confidence), !memory.people.contains(where: { $0.id == p.id }) {
                    memory.people.append(p)
                    p.lastInteractionAt = max(p.lastInteractionAt ?? .distantPast, input.createdAt)
                }
            }
            for name in em.placeNames {
                let place = existingPlace(named: name) ?? { let pl = Place(name: name, kind: em.place?.name.lowercased() == name.lowercased() ? (em.place?.kind ?? "unknown") : EntityRecognizer.knownDestinations.contains(name.lowercased()) ? "city" : "unknown"); context.insert(pl); return pl }()
                if !memory.places.contains(where: { $0.id == place.id }) { memory.places.append(place) }
            }

            if let ep = em.plan {
                // "book flights early" right after "let's go Goa" belongs to the Goa plan, not a new one.
                let plan = (ep.destination == nil ? planInThisCapture : nil) ?? findOrCreatePlan(ep, memory: memory)
                planInThisCapture = plan
                for name in ep.peopleNames { if let p = person(named: name, confidence: em.confidence), !plan.people.contains(where: { $0.id == p.id }) { plan.people.append(p) } }
                if !memory.plans.contains(where: { $0.id == plan.id }) { memory.plans.append(plan) }
            }
            if let ep = em.promise {
                let promise = Promise(summary: ep.summary, direction: ep.direction, status: .pending, dueDate: ep.due?.start, createdAt: input.createdAt)
                promise.person = ep.personName.flatMap { person(named: $0, confidence: em.confidence) }
                context.insert(promise)
                memory.promises.append(promise)
            }
            if let eg = em.gift {
                let gift = GiftIdea(item: eg.item, details: em.evidence, dateMentioned: input.createdAt, priority: em.importance, status: .idea, url: eg.url, createdAt: input.createdAt)
                gift.price = eg.price
                gift.person = eg.forPersonName.flatMap { person(named: $0, confidence: em.confidence) }
                context.insert(gift)
                memory.giftIdeas.append(gift)
            }
            if let ee = em.event {
                let event = findOrCreateEvent(ee, memory: memory)
                for name in ee.peopleNames { if let p = person(named: name, confidence: em.confidence) {
                    if !event.people.contains(where: { $0.id == p.id }) { event.people.append(p) }
                    if ee.isAnnual, ee.title.lowercased().contains("birthday"), p.birthday == nil { p.birthday = ee.temporal.start }
                } }
                if !memory.events.contains(where: { $0.id == event.id }) { memory.events.append(event) }
            }
            memory.nextSurfaceAt = initialSurfaceDate(for: memory)
            memory.refreshCaches()
            createdMemories.append(memory)
            analytics.track(.memoryCreated, category: em.memoryType.rawValue)
        }

        storage.save()
        linkRelatedMemories(createdMemories)
        storage.save()
        onChange()
        return createdMemories
    }

    private func makeSource(for input: CaptureInput, result: AnalysisResult, processedBy: String) async throws -> Source {
        let source = Source(type: input.sourceType, createdAt: input.createdAt, originalText: input.extractedText ?? input.textForAnalysis, originalURL: input.url, appSource: input.sourceApp, confidence: input.extractionConfidence, processedBy: processedBy)
        switch input.payload {
        case .image(let data): source.imageReference = try await media.storeImage(data)
        case .audio(let url):
            if let data = try? Data(contentsOf: url) { source.audioReference = try await media.store(data, extension: url.pathExtension.isEmpty ? "caf" : url.pathExtension) }
        case .pdf(let url), .file(let url):
            if let data = try? Data(contentsOf: url), data.count < 25_000_000 { source.fileReference = try await media.store(data, extension: url.pathExtension) }
        default: break
        }
        return source
    }

    private func cloneSource(_ s: Source) -> Source {
        let c = Source(type: s.type, createdAt: s.createdAt, originalText: s.originalText, originalURL: s.originalURL, imageReference: s.imageReference, audioReference: s.audioReference, fileReference: s.fileReference, appSource: s.appSource, confidence: s.confidence, processedBy: s.processedBy)
        storage.context.insert(c)
        return c
    }

    private func existingPlace(named name: String) -> Place? {
        storage.fetchPlaces().first { $0.name.lowercased() == name.lowercased() }
    }

    /// Same destination + overlapping window → same plan (so "Goa" from three chats is one plan).
    private func findOrCreatePlan(_ ep: ExtractedPlan, memory: Memory) -> Plan {
        let title = ep.destination ?? ep.title
        if let dest = ep.destination, let existing = storage.fetchPlans().first(where: { $0.status.isActive && ($0.location?.lowercased() == dest.lowercased() || $0.title.lowercased().hasPrefix(dest.lowercased())) }) {
            if existing.possibleDateStart == nil, let t = ep.temporal { existing.possibleDateStart = t.start; existing.possibleDateEnd = t.end; existing.possiblePrecision = t.precision }
            existing.updatedAt = .now
            if existing.status == .idea { existing.status = .discussed }
            return existing
        }
        let plan = Plan(title: title, details: ep.title, location: ep.destination, status: ep.status, createdAt: memory.createdAt)
        if let t = ep.temporal { plan.possibleDateStart = t.start; plan.possibleDateEnd = t.end; plan.possiblePrecision = t.precision }
        plan.nextAction = ep.temporal == nil ? "Pick a time" : "Confirm with \(ep.peopleNames.first ?? "everyone")"
        storage.context.insert(plan)
        return plan
    }

    private func findOrCreateEvent(_ ee: ExtractedEvent, memory: Memory) -> Event {
        let cal = Calendar.current
        if let existing = storage.fetchEvents().first(where: { $0.title.lowercased() == ee.title.lowercased() && (ee.isAnnual ? cal.isDate($0.date, equalTo: ee.temporal.start, toGranularity: .day) || cal.dateComponents([.month, .day], from: $0.date) == cal.dateComponents([.month, .day], from: ee.temporal.start) : cal.isDate($0.date, inSameDayAs: ee.temporal.start)) }) {
            return existing
        }
        let event = Event(title: ee.title, date: ee.temporal.start, precision: ee.temporal.precision, location: ee.location, confidence: memory.confidence, isAnnual: ee.isAnnual, createdAt: memory.createdAt)
        storage.context.insert(event)
        return event
    }

    private func initialSurfaceDate(for memory: Memory) -> Date? {
        if let due = memory.promises.first?.dueDate { return due }
        if let start = memory.referencedDateStart, start > .now { return Calendar.current.date(byAdding: .day, value: -1, to: start) }
        if memory.memoryType == .promise { return memory.createdAt.adding(days: 3) }
        return nil
    }

    /// Step 8: automatic links — same person, same place, same plan, same timeframe.
    private func linkRelatedMemories(_ fresh: [Memory]) {
        let existing = storage.fetchMemories(includeUnreviewed: true)
        for m in fresh {
            for other in existing where other.id != m.id {
                var kind: RelationKind?
                var reason = ""
                if let p = m.people.first(where: { p in other.people.contains { $0.id == p.id } }) { kind = .samePerson; reason = "Both involve \(p.displayName)" }
                if let pl = m.places.first(where: { pl in other.places.contains { $0.id == pl.id } }) { kind = .samePlace; reason = "Both mention \(pl.name)" }
                if let plan = m.plans.first(where: { plan in other.plans.contains { $0.id == plan.id } }) { kind = .samePlan; reason = "Same plan: \(plan.title)" }
                if kind == nil, let a = m.referencedDateStart, let b = other.referencedDateStart, abs(a.daysUntil(b)) <= 3, m.referencedPrecision == other.referencedPrecision { kind = .sameTimeframe; reason = "Same time" }
                guard let kind else { continue }
                let rel = MemoryRelation(from: m.id, to: other.id, kind: kind, reason: reason, strength: kind == .samePlan ? 0.9 : kind == .samePlace ? 0.7 : 0.5)
                storage.context.insert(rel)
            }
        }
    }
}
