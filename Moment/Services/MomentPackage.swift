import Foundation
import UIKit
import UniformTypeIdentifiers

/// A self-contained `.moment` file: the slides, media and template of one Moment. Sent through
/// iMessage, WhatsApp, AirDrop or any share target and opened directly in MOMENT — no server,
/// nothing public, revocable by simply not sending it. Recipients can react, add their side,
/// send it back, or make their own from the same template.
struct MomentPackage: Codable, Sendable {
    static let currentVersion = 1
    static let uti = UTType(exportedAs: "com.rakshitbargotra.moment.package", conformingTo: .data)
    static let fileExtension = "moment"
    /// Media is downscaled and re-encoded so a 10-photo Moment stays a few MB.
    static let maxMediaSide: CGFloat = 1280
    static let maxPackageBytes = 40 * 1024 * 1024

    struct Slide: Codable, Sendable {
        var slide: StorySlide
        var mediaBase64: String?
    }
    struct Contribution: Codable, Sendable {
        var contribution: StoryContribution
        var mediaBase64: String?
    }

    var version: Int
    var id: UUID
    var title: String
    var subtitle: String
    var kind: StoryKind
    var template: MomentTemplate
    var author: String
    var createdAt: Date
    var slides: [Slide]
    var stats: [String: String]
    var peopleNames: [String]
    var contributions: [Contribution]
    var reactions: [StoryReaction]
    var madeWith: String
    var remixedFrom: String?

    enum PackageError: Error, LocalizedError {
        case unsupportedVersion, tooLarge, unreadable
        var errorDescription: String? {
            switch self {
            case .unsupportedVersion: "This Moment was made with a newer version of MOMENT."
            case .tooLarge: "This Moment is too large to open."
            case .unreadable: "This file isn't a Moment."
            }
        }
    }

    // MARK: Export

    @MainActor
    static func make(from story: MomentStory, author: String, media: MediaStore) async -> MomentPackage {
        var slides: [Slide] = []
        for s in story.slides {
            var b64: String? = nil
            if let ref = s.mediaRef, let image = await media.loadImage(ref) { b64 = encode(image) }
            var copy = s; copy.mediaRef = nil
            slides.append(Slide(slide: copy, mediaBase64: b64))
        }
        var contributions: [Contribution] = []
        for c in story.contributions {
            var b64: String? = nil
            if let ref = c.mediaRef, let image = await media.loadImage(ref) { b64 = encode(image) }
            var copy = c; copy.mediaRef = nil
            contributions.append(Contribution(contribution: copy, mediaBase64: b64))
        }
        let template = MomentTemplate.find(story.templateID) ?? MomentTemplate.builtIn[0]
        return MomentPackage(version: currentVersion, id: story.id, title: story.title, subtitle: story.subtitle, kind: story.kind, template: template, author: author, createdAt: story.createdAt, slides: slides, stats: story.stats, peopleNames: story.peopleNames, contributions: contributions, reactions: story.reactions, madeWith: "MOMENT", remixedFrom: story.remixedFrom)
    }

    func write(to directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        guard data.count <= Self.maxPackageBytes else { throw PackageError.tooLarge }
        let safeName = title.replacingOccurrences(of: #"[^A-Za-z0-9 _-]"#, with: "", options: .regularExpression).trimmed
        let url = directory.appending(path: "\(safeName.isEmpty ? "Moment" : safeName).\(Self.fileExtension)")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    // MARK: Import

    static func read(from url: URL) throws -> MomentPackage {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard data.count <= maxPackageBytes else { throw PackageError.tooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let pkg = try? decoder.decode(MomentPackage.self, from: data), pkg.madeWith == "MOMENT" else { throw PackageError.unreadable }
        guard pkg.version <= currentVersion else { throw PackageError.unsupportedVersion }
        return pkg
    }

    /// Materializes media into the local store and returns a received `MomentStory`.
    @MainActor
    func materialize(media: MediaStore) async -> MomentStory {
        var slides: [StorySlide] = []
        for s in self.slides {
            var slide = s.slide
            if let b64 = s.mediaBase64, let data = Data(base64Encoded: b64), let ref = try? await media.store(data, extension: "jpg") { slide.mediaRef = ref }
            slides.append(slide)
        }
        var contributions: [StoryContribution] = []
        for c in self.contributions {
            var contribution = c.contribution
            contribution.isMine = false
            if let b64 = c.mediaBase64, let data = Data(base64Encoded: b64), let ref = try? await media.store(data, extension: "jpg") { contribution.mediaRef = ref }
            contributions.append(contribution)
        }
        let story = MomentStory(id: id, title: title, subtitle: subtitle, kind: kind, templateID: template.id, memoryIDs: [], slides: slides, stats: stats, peopleNames: peopleNames, createdAt: createdAt)
        story.originAuthor = author
        story.isReceived = true
        story.contributions = contributions
        story.reactions = reactions
        story.remixedFrom = remixedFrom
        return story
    }

    private static func encode(_ image: UIImage) -> String? {
        let scale = min(1, maxMediaSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = scale < 1 ? UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) } : image
        return resized.jpegData(compressionQuality: 0.8)?.base64EncodedString()
    }
}
