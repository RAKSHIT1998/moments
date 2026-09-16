import Foundation

/// Offline-first upload queue. Contributions and NOW posts are written to disk first, then
/// uploaded in order with exponential backoff; the UI shows them immediately as "pending".
/// The queue file lives in Application Support and survives relaunches.
@MainActor
@Observable
final class UploadQueue {
    enum Job: Codable, Sendable, Identifiable, Equatable {
        case contribution(Contribution)
        case now(NowPost)
        var id: String { switch self { case .contribution(let c): c.id; case .now(let n): n.id } }
        var mediaRef: String? { switch self { case .contribution(let c): c.media?.localRef; case .now(let n): n.media?.localRef } }
    }

    struct Entry: Codable, Sendable, Identifiable, Equatable {
        var job: Job
        var attempts: Int = 0
        var lastError: String?
        var nextAttempt: Date = .now
        var id: String { job.id }
    }

    private(set) var entries: [Entry] = []
    private(set) var isDraining = false
    var pendingCount: Int { entries.count }
    var failedCount: Int { entries.filter { $0.attempts >= UploadQueue.maxAttempts }.count }

    static let maxAttempts = 8
    private let fileURL: URL
    private let backend: any SocialBackend
    private let media: MediaStore
    private var drainTask: Task<Void, Never>?
    /// Called after a job lands so services can refresh what they show.
    var onUploaded: ((Job) -> Void)?

    init(backend: any SocialBackend, media: MediaStore, directory: URL? = nil) {
        self.backend = backend
        self.media = media
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appending(path: "upload-queue.json")
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([Entry].self, from: data) { entries = saved }
    }

    func enqueue(_ job: Job) {
        entries.removeAll { $0.id == job.id }
        entries.append(Entry(job: job))
        persist()
        drain()
    }

    func retryFailed() {
        for i in entries.indices { entries[i].attempts = 0; entries[i].nextAttempt = .now; entries[i].lastError = nil }
        persist(); drain()
    }

    func remove(id: String) { entries.removeAll { $0.id == id }; persist() }

    func isPending(_ id: String) -> Bool { entries.contains { $0.id == id } }

    func drain() {
        guard drainTask == nil, !entries.isEmpty else { return }
        isDraining = true
        drainTask = Task { [weak self] in
            await self?.drainLoop()
            self?.drainTask = nil
            self?.isDraining = false
        }
    }

    private func drainLoop() async {
        while let entry = entries.first(where: { $0.attempts < UploadQueue.maxAttempts }) {
            if entry.nextAttempt > .now {
                try? await Task.sleep(for: .seconds(max(0.1, entry.nextAttempt.timeIntervalSinceNow)))
                if Task.isCancelled { return }
            }
            var data: Data? = nil
            if let ref = entry.job.mediaRef { data = try? await media.load(ref) }
            do {
                switch entry.job {
                case .contribution(let c): _ = try await backend.addContribution(c, mediaData: data)
                case .now(let n): _ = try await backend.postNow(n, mediaData: data)
                }
                entries.removeAll { $0.id == entry.id }
                persist()
                onUploaded?(entry.job)
            } catch {
                guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { continue }
                if case SocialError.notAllowed = error {
                    // Permanent: don't retry, keep it visible as failed.
                    entries[i].attempts = UploadQueue.maxAttempts; entries[i].lastError = error.localizedDescription
                } else {
                    entries[i].attempts += 1
                    entries[i].lastError = error.localizedDescription
                    entries[i].nextAttempt = .now.addingTimeInterval(min(300, pow(2, Double(entries[i].attempts))))
                }
                persist()
                if case SocialError.offline = error { return }   // wait for a network change
            }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: fileURL, options: .atomic) }
    }
}
