import SwiftUI
import UIKit

/// MOMENT's own glyph set — every icon in the tab bar and post action row is drawn here as a
/// path, so the app has its own visual language rather than another network's. Line-based,
/// 24-pt design grid, 1.7-pt stroke, round joins. `image(_:)` renders a template UIImage for
/// places that need one (tab items); everywhere else use `Glyph(.kind)` as a View.
enum MomentGlyph: String, CaseIterable {
    case home, nearby, create, now, profile           // tabs
    case spark, reply, send, addSide, scan, activity   // actions
    case logo

    /// Path in a 0…24 coordinate space.
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path { Path(roundedRect: CGRect(x: rect.minX + x * s, y: rect.minY + y * s, width: w * s, height: h * s), cornerRadius: r * s) }
        var path = Path()
        switch self {
        case .home:
            // Two overlapping frames = everyone's story. The mark, simplified.
            path.addPath(rr(4.5, 6.5, 12, 12, 3))
            path.addPath(rr(7.5, 4, 12, 12, 3))
        case .nearby:
            // A ring with a marker dot: "around you", not a map pin.
            path.addEllipse(in: CGRect(x: p(4, 4).x, y: p(4, 4).y, width: 16 * s, height: 16 * s))
            path.addEllipse(in: CGRect(x: p(10, 10).x, y: p(10, 10).y, width: 4 * s, height: 4 * s))
            path.move(to: p(12, 20)); path.addLine(to: p(12, 23))
        case .create:
            path.addPath(rr(4, 4, 16, 16, 5))
            path.move(to: p(12, 8.5)); path.addLine(to: p(12, 15.5))
            path.move(to: p(8.5, 12)); path.addLine(to: p(15.5, 12))
        case .now:
            // A pulse: dot with a broken ring — "right now", ephemeral.
            path.addEllipse(in: CGRect(x: p(9.5, 9.5).x, y: p(9.5, 9.5).y, width: 5 * s, height: 5 * s))
            path.addArc(center: p(12, 12), radius: 8 * s, startAngle: .degrees(-60), endAngle: .degrees(200), clockwise: false)
        case .profile:
            path.addEllipse(in: CGRect(x: p(8.5, 4).x, y: p(8.5, 4).y, width: 7 * s, height: 7 * s))
            path.move(to: p(4.5, 20.5))
            path.addCurve(to: p(19.5, 20.5), control1: p(5.5, 14), control2: p(18.5, 14))
        case .spark:
            // Reaction: a four-point spark, not a heart.
            path.move(to: p(12, 3)); path.addQuadCurve(to: p(21, 12), control: p(12.8, 11.2)); path.addQuadCurve(to: p(12, 21), control: p(12.8, 12.8))
            path.addQuadCurve(to: p(3, 12), control: p(11.2, 12.8)); path.addQuadCurve(to: p(12, 3), control: p(11.2, 11.2)); path.closeSubpath()
        case .reply:
            // Comment: a rounded slab with a tail on the left.
            path.addPath(rr(4, 5, 16, 11, 3.5))
            path.move(to: p(7.5, 16)); path.addLine(to: p(6, 20)); path.addLine(to: p(11, 16))
        case .send:
            // Share: an arrow leaving a tray.
            path.move(to: p(12, 15)); path.addLine(to: p(12, 3.5))
            path.move(to: p(7.5, 8)); path.addLine(to: p(12, 3.5)); path.addLine(to: p(16.5, 8))
            path.move(to: p(5, 13)); path.addLine(to: p(5, 19.5)); path.addLine(to: p(19, 19.5)); path.addLine(to: p(19, 13))
        case .addSide:
            // Your side: a second frame joining the first, with a plus.
            path.addPath(rr(4, 8, 11, 11, 2.5))
            path.move(to: p(9, 8)); path.addLine(to: p(9, 6.5)); path.addQuadCurve(to: p(10.5, 5), control: p(9, 5)); path.addLine(to: p(18.5, 5)); path.addQuadCurve(to: p(20, 6.5), control: p(20, 5)); path.addLine(to: p(20, 14.5)); path.addQuadCurve(to: p(18.5, 16), control: p(20, 16)); path.addLine(to: p(15, 16))
            path.move(to: p(9.5, 11)); path.addLine(to: p(9.5, 16)); path.move(to: p(7, 13.5)); path.addLine(to: p(12, 13.5))
        case .scan:
            for (x, y, dx, dy) in [(4, 9, 0, -5), (4, 4, 5, 0), (20, 9, 0, -5), (20, 4, -5, 0), (4, 15, 0, 5), (4, 20, 5, 0), (20, 15, 0, 5), (20, 20, -5, 0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
                path.move(to: p(x, y)); path.addLine(to: p(x + dx, y + dy))
            }
            path.move(to: p(7.5, 12)); path.addLine(to: p(16.5, 12))
        case .activity:
            // Activity: a soft diamond ("something happened") with a spark dot — not a bell, not a heart.
            path.move(to: p(12, 3.5)); path.addQuadCurve(to: p(20.5, 12), control: p(18, 6)); path.addQuadCurve(to: p(12, 20.5), control: p(18, 18))
            path.addQuadCurve(to: p(3.5, 12), control: p(6, 18)); path.addQuadCurve(to: p(12, 3.5), control: p(6, 6)); path.closeSubpath()
            path.addEllipse(in: CGRect(x: p(10.5, 10.5).x, y: p(10.5, 10.5).y, width: 3 * s, height: 3 * s))
        case .logo:
            path.addPath(rr(3, 5, 13, 13, 3.5).applying(CGAffineTransform(translationX: 0, y: 0)))
            path.addPath(rr(8, 3, 13, 13, 3.5))
            path.addEllipse(in: CGRect(x: p(10.5, 9).x, y: p(10.5, 9).y, width: 3 * s, height: 3 * s))
        }
        return path
    }

    /// Template image for UIKit-hosted places (tab bar). Cached per size.
    @MainActor static var cache: [String: UIImage] = [:]
    @MainActor func image(size: CGFloat = 26, weight: CGFloat = 1.7) -> UIImage {
        let key = "\(rawValue)-\(size)-\(weight)"
        if let c = MomentGlyph.cache[key] { return c }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let img = renderer.image { ctx in
            let rect = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: 1, dy: 1)
            let cg = path(in: rect).cgPath
            ctx.cgContext.addPath(cg)
            ctx.cgContext.setStrokeColor(UIColor.black.cgColor)
            ctx.cgContext.setLineWidth(weight * size / 24)
            ctx.cgContext.setLineCap(.round); ctx.cgContext.setLineJoin(.round)
            ctx.cgContext.strokePath()
        }.withRenderingMode(.alwaysTemplate)
        MomentGlyph.cache[key] = img
        return img
    }
}

/// SwiftUI view for a glyph: stroked in the current foreground style, optionally filled.
struct Glyph: View {
    let kind: MomentGlyph
    var size: CGFloat = 22
    var weight: CGFloat = 1.7
    var filled = false
    init(_ kind: MomentGlyph, size: CGFloat = 22, weight: CGFloat = 1.7, filled: Bool = false) { self.kind = kind; self.size = size; self.weight = weight; self.filled = filled }
    var body: some View {
        GlyphShape(kind: kind)
            .stroke(style: StrokeStyle(lineWidth: weight * size / 24, lineCap: .round, lineJoin: .round))
            .background { if filled { GlyphShape(kind: kind).fill() } }
            .frame(width: size, height: size)
            .accessibilityElement()   // a real element so the enclosing Button/Link is exposed; parents set the label
    }
}

struct GlyphShape: Shape {
    let kind: MomentGlyph
    func path(in rect: CGRect) -> Path { kind.path(in: rect.insetBy(dx: rect.width * 0.04, dy: rect.width * 0.04)) }
}

/// Wordmark: the logo mark next to "MOMENT" in a tight, heavy setting.
struct Wordmark: View {
    var size: CGFloat = 22
    var body: some View {
        HStack(spacing: 8) {
            Image("LogoMark").resizable().scaledToFit().frame(width: size + 6, height: size + 6)
            Text("MOMENT").font(.system(size: size, weight: .heavy)).tracking(size * 0.09)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("MOMENT")
        .accessibilityAddTraits(.isHeader)
    }
}
