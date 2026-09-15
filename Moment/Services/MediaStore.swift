import Foundation
import UIKit

/// Encrypted-at-rest media (screenshots, voice notes, PDFs). Files are AES-GCM sealed with a
/// Keychain key, so even a raw filesystem copy is unreadable. Thumbnails are generated on demand.
actor MediaStore {
    enum MediaError: Error { case noDirectory, notFound }

    private let directory: URL
    private var thumbnailCache: [String: UIImage] = [:]

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "MomentMedia", directoryHint: .isDirectory)
        self.directory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    }

    /// Stores data and returns the relative reference to persist on the model.
    func store(_ data: Data, extension ext: String) throws -> String {
        let name = "\(UUID().uuidString).\(ext).enc"
        let sealed = try FileCrypto.encrypt(data)
        try sealed.write(to: directory.appending(path: name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return name
    }

    /// Downscales large images before storing so we never hold multi-megabyte screenshots.
    func storeImage(_ data: Data, maxDimension: CGFloat = 2000) throws -> String {
        guard let image = UIImage(data: data) else { return try store(data, extension: "img") }
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        let resized: UIImage
        if scale < 1 {
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            resized = UIGraphicsImageRenderer(size: size, format: .init()).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        } else { resized = image }
        let jpeg = resized.jpegData(compressionQuality: 0.85) ?? data
        return try store(jpeg, extension: "jpg")
    }

    func load(_ reference: String) throws -> Data {
        let url = directory.appending(path: reference)
        guard FileManager.default.fileExists(atPath: url.path()) else { throw MediaError.notFound }
        return try FileCrypto.decrypt(Data(contentsOf: url))
    }

    func loadImage(_ reference: String) -> UIImage? {
        (try? load(reference)).flatMap(UIImage.init(data:))
    }

    func thumbnail(_ reference: String, side: CGFloat = 160) -> UIImage? {
        if let cached = thumbnailCache[reference] { return cached }
        guard let image = loadImage(reference) else { return nil }
        let scale = side / max(image.size.width, image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let thumb = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        thumbnailCache[reference] = thumb
        return thumb
    }

    /// Writes a decrypted temporary copy (for playback / sharing). Caller deletes it.
    func temporaryURL(for reference: String, extension ext: String) throws -> URL {
        let data = try load(reference)
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).\(ext)")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    func delete(_ reference: String) {
        try? FileManager.default.removeItem(at: directory.appending(path: reference))
        thumbnailCache[reference] = nil
    }

    func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        thumbnailCache.removeAll()
    }

    func totalSize() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
