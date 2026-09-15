// Renders the MOMENT app icon: a minimal "moment marker" — a soft indigo field with a
// single white pulse-dot rising into an "M"-shaped path. No brain, no robot, no sparkle.
import AppKit
import CoreGraphics

let size = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

// Background: deep indigo, slight vertical tone shift (subtle, not a rainbow gradient).
let top = CGColor(red: 0.27, green: 0.31, blue: 0.86, alpha: 1)
let bottom = CGColor(red: 0.18, green: 0.20, blue: 0.62, alpha: 1)
let grad = CGGradient(colorsSpace: cs, colors: [top, bottom] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: CGFloat(size)), end: CGPoint(x: 0, y: 0), options: [])

// The mark: a rounded "M" drawn as a single stroke, ending in a pulse dot.
let s = CGFloat(size)
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
ctx.setLineWidth(s * 0.085)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
let path = CGMutablePath()
let baseY = s * 0.34, topY = s * 0.66, midY = s * 0.46
path.move(to: CGPoint(x: s * 0.24, y: baseY))
path.addLine(to: CGPoint(x: s * 0.24, y: topY))
path.addLine(to: CGPoint(x: s * 0.50, y: midY))
path.addLine(to: CGPoint(x: s * 0.76, y: topY))
path.addLine(to: CGPoint(x: s * 0.76, y: s * 0.40))
ctx.addPath(path)
ctx.strokePath()
// Pulse dot: the "moment".
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
let r = s * 0.058
ctx.fillEllipse(in: CGRect(x: s * 0.76 - r, y: s * 0.30 - r, width: r * 2, height: r * 2))
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.22))
let r2 = s * 0.10
ctx.fillEllipse(in: CGRect(x: s * 0.76 - r2, y: s * 0.30 - r2, width: r2 * 2, height: r2 * 2))

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
let data = rep.representation(using: .png, properties: [:])!
let out = CommandLine.arguments[1]
try! data.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
