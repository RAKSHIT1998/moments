// Renders the MOMENT app icon and logo marks.
//
// The mark: two rounded "frames" overlapping — two people's perspectives of the same experience —
// with the overlap lit as a warm "moment". Nothing borrowed: no camera, no heart, no chat bubble.
// Usage: swift Tools/render_icon.swift  (writes into the asset catalog)
import AppKit
import CoreGraphics

let cs = CGColorSpace(name: CGColorSpace.sRGB)!

func render(size: Int, background: Bool, dark: Bool = false) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: (background ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue)!
    let s = CGFloat(size)
    if background {
        // Deep ink with a faint vertical lift; warm, not neon.
        let top = CGColor(red: 0.13, green: 0.13, blue: 0.16, alpha: 1)
        let bottom = CGColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1)
        let grad = CGGradient(colorsSpace: cs, colors: [top, bottom] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    }
    let ink: CGColor = background || dark ? CGColor(red: 0.97, green: 0.96, blue: 0.94, alpha: 1) : CGColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1)
    let glow = CGColor(red: 1.0, green: 0.62, blue: 0.24, alpha: 1)        // the moment: warm amber

    // Two frames, rotated ±12°, sharing a centre. Stroked, rounded, slightly different sizes.
    func frame(cx: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat, angle: CGFloat, width: CGFloat, color: CGColor) {
        ctx.saveGState()
        ctx.translateBy(x: cx, y: cy)
        ctx.rotate(by: angle)
        let r = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
        let p = CGPath(roundedRect: r, cornerWidth: w * 0.22, cornerHeight: w * 0.22, transform: nil)
        ctx.addPath(p)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.strokePath()
        ctx.restoreGState()
    }
    let lw = s * 0.062
    frame(cx: s * 0.44, cy: s * 0.52, w: s * 0.50, h: s * 0.50, angle: -0.21, width: lw, color: ink)
    frame(cx: s * 0.56, cy: s * 0.48, w: s * 0.46, h: s * 0.46, angle: 0.21, width: lw, color: ink)

    // The overlap lit: a soft amber disc where the two frames meet, plus a crisp core.
    let c = CGPoint(x: s * 0.50, y: s * 0.50)
    let halo = CGGradient(colorsSpace: cs, colors: [glow.copy(alpha: 0.55)!, glow.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(halo, startCenter: c, startRadius: 0, endCenter: c, endRadius: s * 0.20, options: [])
    ctx.setFillColor(glow)
    let r = s * 0.075
    ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    return ctx.makeImage()!
}

func write(_ img: CGImage, to path: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

let base = "Moment/Resources/Assets.xcassets"
write(render(size: 1024, background: true), to: "\(base)/AppIcon.appiconset/icon-1024.png")
// Logo marks used in-app (template-free: light and dark variants, transparent background).
try? FileManager.default.createDirectory(atPath: "\(base)/LogoMark.imageset", withIntermediateDirectories: true)
write(render(size: 512, background: false, dark: false), to: "\(base)/LogoMark.imageset/logo-light.png")
write(render(size: 512, background: false, dark: true), to: "\(base)/LogoMark.imageset/logo-dark.png")
let contents = """
{
  "images" : [
    { "filename" : "logo-light.png", "idiom" : "universal", "scale" : "1x" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ], "filename" : "logo-dark.png", "idiom" : "universal", "scale" : "1x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try! contents.write(toFile: "\(base)/LogoMark.imageset/Contents.json", atomically: true, encoding: .utf8)
