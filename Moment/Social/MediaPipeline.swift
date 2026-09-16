import Foundation
import UIKit
import AVFoundation
import ImageIO

/// Prepares media for upload: photos re-encoded to ≤2048 px HEIC/JPEG with EXIF stripped (only the
/// capture date is kept, separately), videos transcoded to 1080p H.264, thumbnails generated locally.
enum MediaPipeline {
    struct Prepared: Sendable {
        var data: Data
        var kind: MediaRef.Kind
        var width: Int
        var height: Int
        var duration: Double?
        var capturedAt: Date?
        var fileExtension: String
    }

    static let maxPhotoDimension: CGFloat = 2048
    static let maxVideoSeconds: Double = 120

    static func preparePhoto(_ data: Data) -> Prepared? {
        guard let image = UIImage(data: data) else { return nil }
        let capturedAt = PhotoMetadata.captureDate(from: data)
        let scale = min(1, maxPhotoDimension / max(image.size.width, image.size.height))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default(); format.scale = 1; format.opaque = true
        // Re-rendering drops every EXIF field (location, device, lens) — nothing but pixels leaves the phone.
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = rendered.jpegData(compressionQuality: 0.86) else { return nil }
        return Prepared(data: jpeg, kind: .photo, width: Int(size.width), height: Int(size.height), duration: nil, capturedAt: capturedAt, fileExtension: "jpg")
    }

    static func thumbnail(_ data: Data, side: CGFloat = 320) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let s = side / max(image.size.width, image.size.height)
        let size = CGSize(width: image.size.width * s, height: image.size.height * s)
        let format = UIGraphicsImageRendererFormat.default(); format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }.jpegData(compressionQuality: 0.7)
    }

    /// Transcodes to 1080p H.264 MP4 (metadata stripped). Trims to `maxVideoSeconds`.
    static func prepareVideo(at url: URL) async throws -> Prepared {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let creation = try? await asset.load(.creationDate)?.load(.dateValue)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1920x1080) else { throw SocialError.backend("Can't process this video.") }
        let out = FileManager.default.temporaryDirectory.appending(path: "upload-\(UUID().uuidString).mp4")
        export.shouldOptimizeForNetworkUse = true
        export.metadata = []
        if duration > maxVideoSeconds { export.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: maxVideoSeconds, preferredTimescale: 600)) }
        try await export.export(to: out, as: .mp4)
        let data = try Data(contentsOf: out)
        try? FileManager.default.removeItem(at: out)
        var w = 1080, h = 1920
        if let track = try? await asset.loadTracks(withMediaType: .video).first, let size = try? await track.load(.naturalSize) { w = Int(size.width); h = Int(size.height) }
        return Prepared(data: data, kind: .video, width: w, height: h, duration: min(duration, maxVideoSeconds), capturedAt: creation ?? nil, fileExtension: "mp4")
    }

    static func videoPoster(at url: URL) async -> Data? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1080, height: 1080)
        guard let (cg, _) = try? await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.8)
    }
}
