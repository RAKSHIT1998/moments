import Foundation
import AVFoundation
import UIKit

/// Turns a Moment into a vertical video: title card, every side in order with a slow push-in and
/// who/when, an end card with the invite link. Drawn frame by frame with Core Graphics; no templates,
/// no music, nothing invented. The thing people post elsewhere that brings the next person here.
enum ReplayExporter {
    struct Beat { var image: UIImage?; var note: String?; var author: String; var time: Date }
    struct Options { var secondsPerBeat = 2.6; var fps: Int32 = 30; var maxSeconds = 60.0; var size = CGSize(width: 1080, height: 1920) }

    enum ExportError: LocalizedError { case noBeats, writer(String)
        var errorDescription: String? { switch self { case .noBeats: "Nothing to replay yet."; case .writer(let s): "Couldn't write the video: \(s)" } }
    }

    static func export(title: String, subtitle: String, beats: [Beat], inviteLine: String, options: Options = Options(), to url: URL? = nil) async throws -> URL {
        guard !beats.isEmpty else { throw ExportError.noBeats }
        let out = url ?? FileManager.default.temporaryDirectory.appending(path: "replay-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: out)
        // Fit within the cap: drop per-beat time before dropping beats.
        var spb = options.secondsPerBeat
        let fixed = 2.2 + 2.6   // title + end card
        if Double(beats.count) * spb + fixed > options.maxSeconds { spb = max(1.2, (options.maxSeconds - fixed) / Double(beats.count)) }
        let shown = Array(beats.prefix(Int((options.maxSeconds - fixed) / spb)))

        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(options.size.width), AVVideoHeightKey: Int(options.size.height),
                                       AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: Int(options.size.width), kCVPixelBufferHeightKey as String: Int(options.size.height)])
        writer.add(input)
        guard writer.startWriting() else { throw ExportError.writer(writer.error?.localizedDescription ?? "start") }
        writer.startSession(atSourceTime: .zero)

        var frame: Int64 = 0
        func emit(_ draw: (CGContext, Double) -> Void, seconds: Double) async throws {
            let n = Int(seconds * Double(options.fps))
            for i in 0..<n {
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
                let t = n > 1 ? Double(i) / Double(n - 1) : 0
                guard let buffer = pixelBuffer(size: options.size, pool: adaptor.pixelBufferPool, draw: { ctx in draw(ctx, t) }) else { throw ExportError.writer("frame") }
                adaptor.append(buffer, withPresentationTime: CMTime(value: frame, timescale: options.fps))
                frame += 1
            }
        }
        let size = options.size
        try await emit({ ctx, t in Cards.title(ctx, size: size, title: title, subtitle: subtitle, t: t) }, seconds: 2.2)
        for var b in shown {
            // Scale once per beat (aspect-fill at the max zoom); every frame is then a cheap blit.
            if let img = b.image { b.image = Cards.prescaled(img, to: size, zoom: 1.06) }
            try await emit({ ctx, t in Cards.beat(ctx, size: size, beat: b, t: t, title: title) }, seconds: spb)
        }
        try await emit({ ctx, t in Cards.end(ctx, size: size, title: title, line: inviteLine, t: t) }, seconds: 2.6)
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw ExportError.writer(writer.error?.localizedDescription ?? "finish") }
        return out
    }

    private static func pixelBuffer(size: CGSize, pool: CVPixelBufferPool?, draw: (CGContext) -> Void) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) }
        if pb == nil { CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, nil, &pb) }
        guard let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        // UIKit-style coordinates (origin top-left) so text draws the right way up.
        ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx); defer { UIGraphicsPopContext() }
        draw(ctx)
        return buffer
    }

    /// The three kinds of frame. Everything here is plain: black, white, one amber.
    enum Cards {
        static let amber = UIColor(red: 1.0, green: 0.62, blue: 0.24, alpha: 1)
        static func ease(_ t: Double) -> Double { t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2 }

        static func title(_ ctx: CGContext, size: CGSize, title: String, subtitle: String, t: Double) {
            UIColor.black.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            let a = min(1, t * 3)
            mark(at: CGPoint(x: size.width / 2, y: size.height * 0.36), size: 120, alpha: a)
            text(title, at: CGRect(x: 80, y: size.height * 0.44, width: size.width - 160, height: 260), font: .systemFont(ofSize: 96, weight: .bold), color: .white.withAlphaComponent(a), align: .center)
            text(subtitle, at: CGRect(x: 80, y: size.height * 0.44 + 250, width: size.width - 160, height: 80), font: .systemFont(ofSize: 40, weight: .medium), color: UIColor.white.withAlphaComponent(0.7 * a), align: .center)
        }

        static func prescaled(_ image: UIImage, to size: CGSize, zoom: CGFloat) -> UIImage {
            let target = CGSize(width: size.width * zoom, height: size.height * zoom)
            let scale = max(target.width / image.size.width, target.height / image.size.height)
            let w = image.size.width * scale, h = image.size.height * scale
            let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = true
            return UIGraphicsImageRenderer(size: target, format: f).image { _ in image.draw(in: CGRect(x: (target.width - w) / 2, y: (target.height - h) / 2, width: w, height: h)) }
        }

        static func beat(_ ctx: CGContext, size: CGSize, beat: Beat, t: Double, title: String) {
            UIColor.black.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            if let img = beat.image?.cgImage {
                // Slow push-in, aspect-fill (image is pre-scaled to size × 1.06).
                let zoom = 1.0 + 0.06 * ease(t)
                let iw = CGFloat(img.width), ih = CGFloat(img.height)
                let scale = max(size.width / iw, size.height / ih) * zoom
                let w = iw * scale, h = ih * scale
                let rect = CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
                ctx.saveGState(); ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1)
                ctx.draw(img, in: CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height))
                ctx.restoreGState()
                gradient(ctx, size: size)
            } else if let note = beat.note {
                UIColor(white: 0.08, alpha: 1).setFill(); ctx.fill(CGRect(origin: .zero, size: size))
                text("“\(note)”", at: CGRect(x: 100, y: size.height * 0.35, width: size.width - 200, height: 600), font: UIFont(descriptor: UIFont.systemFont(ofSize: 64, weight: .semibold).fontDescriptor.withDesign(.serif) ?? UIFont.systemFont(ofSize: 64).fontDescriptor, size: 64), color: .white, align: .center)
            }
            // Fade in at the start of each beat.
            let fade = 1 - min(1, t * 6)
            if fade > 0 { UIColor.black.withAlphaComponent(fade).setFill(); ctx.fill(CGRect(origin: .zero, size: size)) }
            text(title, at: CGRect(x: 72, y: 150, width: size.width - 144, height: 60), font: .systemFont(ofSize: 40, weight: .semibold), color: .white, align: .left)
            text(beat.time.formatted(date: .omitted, time: .shortened), at: CGRect(x: 72, y: 210, width: size.width - 144, height: 100), font: .monospacedDigitSystemFont(ofSize: 76, weight: .bold), color: .white, align: .left)
            text(beat.author, at: CGRect(x: 72, y: size.height - 220, width: size.width - 144, height: 70), font: .systemFont(ofSize: 44, weight: .semibold), color: .white, align: .left)
        }

        static func end(_ ctx: CGContext, size: CGSize, title: String, line: String, t: Double) {
            UIColor.black.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            let a = min(1, t * 3)
            mark(at: CGPoint(x: size.width / 2, y: size.height * 0.40), size: 140, alpha: a)
            text("MOMENT", at: CGRect(x: 80, y: size.height * 0.40 + 110, width: size.width - 160, height: 90), font: .systemFont(ofSize: 64, weight: .heavy), color: .white.withAlphaComponent(a), align: .center, kern: 8)
            text("Everyone's story of \(title).", at: CGRect(x: 80, y: size.height * 0.40 + 230, width: size.width - 160, height: 120), font: .systemFont(ofSize: 40, weight: .medium), color: UIColor.white.withAlphaComponent(0.8 * a), align: .center)
            text(line, at: CGRect(x: 80, y: size.height * 0.40 + 340, width: size.width - 160, height: 80), font: .monospacedSystemFont(ofSize: 34, weight: .medium), color: amber.withAlphaComponent(a), align: .center)
        }

        /// The MOMENT mark: two overlapping frames and an amber dot (same as the app icon).
        static func mark(at c: CGPoint, size s: CGFloat, alpha: CGFloat) {
            let path1 = UIBezierPath(roundedRect: CGRect(x: c.x - s * 0.5, y: c.y - s * 0.42, width: s * 0.78, height: s * 0.78), cornerRadius: s * 0.18)
            let path2 = UIBezierPath(roundedRect: CGRect(x: c.x - s * 0.28, y: c.y - s * 0.36, width: s * 0.78, height: s * 0.78), cornerRadius: s * 0.18)
            UIColor.white.withAlphaComponent(alpha).setStroke()
            path1.lineWidth = s * 0.07; path2.lineWidth = s * 0.07
            path1.stroke(); path2.stroke()
            amber.withAlphaComponent(alpha).setFill()
            UIBezierPath(ovalIn: CGRect(x: c.x - s * 0.02, y: c.y - s * 0.02, width: s * 0.2, height: s * 0.2)).fill()
        }

        static func gradient(_ ctx: CGContext, size: CGSize) {
            let colors = [UIColor.black.withAlphaComponent(0.55).cgColor, UIColor.clear.cgColor, UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.7).cgColor] as CFArray
            guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.3, 0.65, 1]) else { return }
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: size.height), options: [])
        }

        static func text(_ s: String, at rect: CGRect, font: UIFont, color: UIColor, align: NSTextAlignment, kern: CGFloat = 0) {
            let p = NSMutableParagraphStyle(); p.alignment = align; p.lineBreakMode = .byWordWrapping
            (s as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p, .kern: kern], context: nil)
        }
    }
}
