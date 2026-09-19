import Foundation

/// The device's copy of the network: every valid event it has seen, on disk, append-only.
/// Deletions are events too (`delete` by the same author), applied on read.
actor EventStore {
    private let url: URL
    private(set) var events: [String: SignedEvent] = [:]
    private(set) var byKind: [SignedEvent.Kind: [String]] = [:]
    private(set) var byMoment: [String: [String]] = [:]
    private var deleted: Set<String> = []
    var onNew: (@Sendable (SignedEvent) -> Void)?

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "MomentMesh")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        url = base.appending(path: "events.jsonl")
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            for line in text.split(separator: "\n") { if let e = try? JSONDecoder.event.decode(SignedEvent.self, from: Data(line.utf8)) { index(e) } }
        }
    }

    func setOnNew(_ f: @escaping @Sendable (SignedEvent) -> Void) { onNew = f }

    /// Verifies, dedupes, persists. Returns true if the event was new.
    @discardableResult
    func ingest(_ e: SignedEvent) -> Bool {
        guard events[e.id] == nil, e.isValid else { return false }
        index(e)
        if let line = try? JSONEncoder.event.encode(e), let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line + Data("\n".utf8)); try? h.close() }
        else if let line = try? JSONEncoder.event.encode(e) { try? (line + Data("\n".utf8)).write(to: url) }
        onNew?(e)
        return true
    }

    private func index(_ e: SignedEvent) {
        events[e.id] = e
        byKind[e.kind, default: []].append(e.id)
        if let m = e.tags["moment"] { byMoment[m, default: []].append(e.id) }
        if e.kind == .delete, let target = e.tags["target"], let victim = events[target], victim.author == e.author { deleted.insert(target) }
        if deleted.contains(e.id) { return }
        // A delete can arrive before its target.
        if let d = byKind[.delete] { for id in d { if let de = events[id], de.tags["target"] == e.id, de.author == e.author { deleted.insert(e.id) } } }
    }

    func isDeleted(_ id: String) -> Bool { deleted.contains(id) }
    func all(_ kind: SignedEvent.Kind) -> [SignedEvent] { (byKind[kind] ?? []).compactMap { events[$0] }.filter { !deleted.contains($0.id) }.sorted { $0.createdAt < $1.createdAt } }
    func forMoment(_ id: String) -> [SignedEvent] { (byMoment[id] ?? []).compactMap { events[$0] }.filter { !deleted.contains($0.id) }.sorted { $0.createdAt < $1.createdAt } }
    func ids() -> Set<String> { Set(events.keys) }
    func get(_ ids: [String]) -> [SignedEvent] { ids.compactMap { events[$0] } }
    var count: Int { events.count }
}
