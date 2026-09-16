import UIKit
import SwiftUI
import CoreImage

/// Average colour of an image, nudged toward a usable UI tint (never muddy grey, never neon).
enum ImageColor {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func dominant(_ image: UIImage) -> Color? {
        guard let cg = image.cgImage else { return nil }
        let ci = CIImage(cgImage: cg)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: ci.extent)]), let out = filter.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        context.render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // Lift saturation so pale photos still tint; clamp brightness so text stays legible on top.
        return Color(hue: h, saturation: min(0.85, max(0.35, s * 1.3)), brightness: min(0.8, max(0.45, b)))
    }
}
