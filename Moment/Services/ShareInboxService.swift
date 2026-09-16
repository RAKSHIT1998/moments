import Foundation
import UIKit

/// Drains items dropped by the Share Extension into the pipeline.
@MainActor
@Observable
final class ShareInboxService {
    @ObservationIgnored private let importer: ImportService
    @ObservationIgnored private var isDraining = false
    /// Free-tier check; items stay queued (never lost) when the limit is reached.
    @ObservationIgnored var canCreateMemory: () -> Bool = { true }
    private(set) var blockedByLimit = false
    /// Photos/videos the user chose to "Add to a Moment" from the share sheet; the app asks which one.
    private(set) var pendingForMoment: [PendingMomentMedia] = []
    struct PendingMomentMedia: Identifiable, Equatable { let id: UUID; let url: URL; let isVideo: Bool }

    init(importer: ImportService) { self.importer = importer }

    func clearPendingForMoment() {
        for p in pendingForMoment { try? FileManager.default.removeItem(at: p.url) }
        pendingForMoment = []
    }

    /// Returns the number of captures processed.
    @discardableResult
    func drain() async -> Int {
        guard !isDraining else { return 0 }
        isDraining = true
        defer { isDraining = false }
        var count = 0
        for item in ShareInbox.pending() {
            if item.intent == .addToMoment {
                if let url = ShareInbox.payloadURL(for: item) {
                    let dest = FileManager.default.temporaryDirectory.appending(path: "share-\(item.id.uuidString).\(url.pathExtension)")
                    try? FileManager.default.removeItem(at: dest)
                    if (try? FileManager.default.copyItem(at: url, to: dest)) != nil { pendingForMoment.append(PendingMomentMedia(id: item.id, url: dest, isVideo: url.pathExtension.lowercased() == "mov")) }
                }
                ShareInbox.remove(item)
                continue
            }
            guard canCreateMemory() else { blockedByLimit = true; break }
            blockedByLimit = false
            let input: CaptureInput?
            switch item.kind {
            case .text: input = item.text.map { CaptureInput(payload: .text($0), sourceType: .shareSheet, sourceApp: item.sourceApp, createdAt: item.createdAt) }
            case .url: input = item.text.flatMap(URL.init(string:)).map { CaptureInput(payload: .url($0), sourceType: .shareSheet, sourceApp: item.sourceApp, createdAt: item.createdAt) }
            case .image:
                input = ShareInbox.payloadURL(for: item).flatMap { try? Data(contentsOf: $0) }.map { CaptureInput(payload: .image($0), sourceType: .screenshot, sourceApp: item.sourceApp, createdAt: item.createdAt) }
            case .pdf: input = ShareInbox.payloadURL(for: item).map { CaptureInput(payload: .pdf($0), sourceType: .pdf, sourceApp: item.sourceApp, createdAt: item.createdAt) }
            case .file: input = ShareInbox.payloadURL(for: item).map { CaptureInput(payload: .file($0), sourceType: .shareSheet, sourceApp: item.sourceApp, createdAt: item.createdAt) }
            }
            if let input {
                do { _ = try await importer.run(input); count += 1 } catch { Log.capture.error("Share item failed: \(error.localizedDescription)") }
            }
            ShareInbox.remove(item)
        }
        return count
    }
}
