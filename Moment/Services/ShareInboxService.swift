import Foundation
import UIKit

/// Drains items dropped by the Share Extension into the pipeline.
@MainActor
final class ShareInboxService {
    private let importer: ImportService
    private var isDraining = false
    /// Free-tier check; items stay queued (never lost) when the limit is reached.
    var canCreateMemory: () -> Bool = { true }
    private(set) var blockedByLimit = false

    init(importer: ImportService) { self.importer = importer }

    /// Returns the number of captures processed.
    @discardableResult
    func drain() async -> Int {
        guard !isDraining else { return 0 }
        isDraining = true
        defer { isDraining = false }
        var count = 0
        for item in ShareInbox.pending() {
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
