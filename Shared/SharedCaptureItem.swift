import Foundation

/// A single item handed from the Share Extension to the app.
/// The extension never runs AI; it just writes the raw input and a manifest.
public struct SharedCaptureItem: Codable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case image, text, url, pdf, file
    }

    public var id: UUID
    public var kind: Kind
    public var createdAt: Date
    /// Text payload for `.text`/`.url`, or a caption for files.
    public var text: String?
    /// Filename inside the ShareInbox directory for binary payloads.
    public var fileName: String?
    /// Bundle identifier of the app the content came from, if the extension could tell.
    public var sourceApp: String?

    public init(id: UUID = UUID(), kind: Kind, createdAt: Date = .now, text: String? = nil, fileName: String? = nil, sourceApp: String? = nil) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.text = text
        self.fileName = fileName
        self.sourceApp = sourceApp
    }
}

/// Tiny file-based queue in the app group. Each item is `<uuid>.json` plus an optional payload file.
public enum ShareInbox {
    public static func ensureDirectory() throws -> URL {
        guard let url = AppGroup.shareInboxURL else { throw ShareInboxError.noContainer }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static func enqueue(_ item: SharedCaptureItem, payload: Data? = nil) throws {
        let dir = try ensureDirectory()
        var item = item
        if let payload {
            let name = item.fileName ?? "\(item.id.uuidString).bin"
            item.fileName = name
            try payload.write(to: dir.appending(path: name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        let manifest = try JSONEncoder().encode(item)
        try manifest.write(to: dir.appending(path: "\(item.id.uuidString).json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    public static func pending() -> [SharedCaptureItem] {
        guard let dir = AppGroup.shareInboxURL,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(SharedCaptureItem.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public static func payloadURL(for item: SharedCaptureItem) -> URL? {
        guard let name = item.fileName, let dir = AppGroup.shareInboxURL else { return nil }
        return dir.appending(path: name)
    }

    public static func remove(_ item: SharedCaptureItem) {
        guard let dir = AppGroup.shareInboxURL else { return }
        try? FileManager.default.removeItem(at: dir.appending(path: "\(item.id.uuidString).json"))
        if let name = item.fileName {
            try? FileManager.default.removeItem(at: dir.appending(path: name))
        }
    }

    public static func removeAll() {
        guard let dir = AppGroup.shareInboxURL else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    public enum ShareInboxError: Error { case noContainer }
}
