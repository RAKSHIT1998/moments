import Foundation
import SwiftUI
import AVFoundation
import CoreImage

/// Renders Moments to images and a vertical video. Slides are rendered once with SwiftUI at 3×
/// (1080 px wide); the video applies a subtle zoom and crossfades between them with CoreGraphics,
/// so exporting a 10-slide story takes seconds, not minutes.
@MainActor
final class StoryExporter {
    struct Rendered { let slide: StorySlide; let image: CGImage }

    nonisolated static let fps: Int32 = 30
    nonisolated static let slideSeconds: Double = 2.8
    nonisolated static let crossfadeSeconds: Double = 0.45

    private let media: MediaStore
    init(media: MediaStore) { self.media = media }

    // MARK: Images

    func render(_ slide: StorySlide, theme: StoryTheme, format: StoryFormat, image: UIImage?, motion: Double? = nil) -> UIImage? {
        let view = StorySlideView(slide: slide, theme: theme, format: format, image: image, motion: motion)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        renderer.isOpaque = true
        return renderer.uiImage
    }

    func loadImages(for story: MomentStory) async -> [String: UIImage] {
        var out: [String: UIImage] = [:]
        for ref in Set(story.slides.compactMap(\.mediaRef) + story.contributions.compactMap(\.mediaRef)) {
            if let img = await media.loadImage(ref) { out[ref] = img }
        }
        return out
    }

    /// PNG per slide, in a temporary folder. Caller shares/deletes.
    func exportImages(_ story: MomentStory, theme: StoryTheme, format: StoryFormat) async throws -> [URL] {
        let images = await loadImages(for: story)
        let dir = FileManager.default.temporaryDirectory.appending(path: "moment-\(story.id.uuidString.prefix(8))-\(format.rawValue.replacingOccurrences(of: ":", with: "x"))")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var urls: [URL] = []
        for (i, slide) in story.slides.enumerated() {
            await Task.yield()
            guard let ui = render(slide, theme: theme, format: format, image: slide.mediaRef.flatMap { images[$0] }), let data = ui.pngData() else { continue }
            let url = dir.appending(path: String(format: "%02d.png", i + 1))
            try data.write(to: url, options: .atomic)
            urls.append(url)
        }
        return urls
    }

    // MARK: Video

    /// H.264 MP4 at 1080×1920 (or the format's equivalent). No audio track: MOMENT ships no music.
    func exportVideo(_ story: MomentStory, theme: StoryTheme, format: StoryFormat, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let images = await loadImages(for: story)
        var rendered: [Rendered] = []
        for slide in story.slides.prefix(12) {
            await Task.yield()
            if let ui = render(slide, theme: theme, format: format, image: slide.mediaRef.flatMap { images[$0] }), let cg = ui.cgImage { rendered.append(Rendered(slide: slide, image: cg)) }
        }
        guard !rendered.isEmpty else { throw ExportError.nothingToRender }
        let width = Int(format.size.width * 3), height = Int(format.size.height * 3)
        let url = FileManager.default.temporaryDirectory.appending(path: "\(story.title.replacingOccurrences(of: #"[^A-Za-z0-9 _-]"#, with: "", options: .regularExpression).trimmed.isEmpty ? "Moment" : story.title.replacingOccurrences(of: #"[^A-Za-z0-9 _-]"#, with: "", options: .regularExpression).trimmed).mp4")
        try? FileManager.default.removeItem(at: url)
        let frames = rendered.map(\.image)
        let hasMotion = rendered.map { $0.slide.kind == .photo || $0.slide.kind == .cover || $0.slide.kind == .side }
        return try await Task.detached(priority: .userInitiated) {
            try VideoWriter.write(frames: frames, motion: hasMotion, width: width, height: height, to: url) { p in Task { @MainActor in progress(p) } }
            return url
        }.value
    }

    enum ExportError: Error, LocalizedError {
        case nothingToRender, writerFailed
        var errorDescription: String? {
            switch self { case .nothingToRender: "There's nothing to export yet."; case .writerFailed: "Couldn't write the video." }
        }
    }
}

/// Frame-by-frame H.264 writer. Pure CoreGraphics compositing; safe off the main actor.
enum VideoWriter {
    static func write(frames: [CGImage], motion: [Bool], width: Int, height: Int, to url: URL, progress: @escaping (Double) -> Void) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
        ])
        guard writer.canAdd(input) else { throw StoryExporter.ExportError.writerFailed }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? StoryExporter.ExportError.writerFailed }
        writer.startSession(atSourceTime: .zero)

        let fps = StoryExporter.fps
        let perSlide = Int(StoryExporter.slideSeconds * Double(fps))
        let fade = Int(StoryExporter.crossfadeSeconds * Double(fps))
        let total = frames.count * perSlide
        var frameIndex: Int64 = 0

        for (i, frame) in frames.enumerated() {
            for f in 0..<perSlide {
                while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
                guard let pool = adaptor.pixelBufferPool else { throw StoryExporter.ExportError.writerFailed }
                var pb: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
                guard let buffer = pb else { throw StoryExporter.ExportError.writerFailed }
                CVPixelBufferLockBaseAddress(buffer, [])
                if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                    let t = Double(f) / Double(max(1, perSlide - 1))
                    draw(frame, in: ctx, width: width, height: height, zoom: motion[i] ? 1.0 + 0.06 * t : 1.0)
                    // Crossfade the next slide in over the last `fade` frames.
                    if i + 1 < frames.count, f >= perSlide - fade {
                        let a = Double(f - (perSlide - fade)) / Double(fade)
                        ctx.setAlpha(CGFloat(a))
                        draw(frames[i + 1], in: ctx, width: width, height: height, zoom: 1.0)
                        ctx.setAlpha(1)
                    }
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                let time = CMTime(value: frameIndex, timescale: fps)
                guard adaptor.append(buffer, withPresentationTime: time) else { throw writer.error ?? StoryExporter.ExportError.writerFailed }
                frameIndex += 1
                if frameIndex % 15 == 0 { progress(Double(frameIndex) / Double(total)) }
            }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed { throw writer.error ?? StoryExporter.ExportError.writerFailed }
        progress(1)
    }

    private static func draw(_ image: CGImage, in ctx: CGContext, width: Int, height: Int, zoom: Double) {
        let w = Double(width) * zoom, h = Double(height) * zoom
        let rect = CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h)
        ctx.draw(image, in: rect)
    }
}
