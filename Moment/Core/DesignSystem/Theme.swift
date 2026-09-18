import SwiftUI

/// Semantic color system. Built on system colors so Dark Mode, Increase Contrast and
/// Reduce Transparency all work, with a warm neutral ground and a single indigo→violet accent.
/// Quiet luxury: ivory / charcoal grounds, soft-ink text, one muted accent. Every value is an
/// adaptive colour set, so Light, Dark, Increase Contrast and Reduce Transparency all work.
enum MColor {
    // Pure system colours: white/black grounds that flip with the device, like every app people already know.
    static let background = Color(uiColor: .systemBackground)
    static let surface = Color(uiColor: .secondarySystemBackground)
    static let surfaceSecondary = Color(uiColor: .tertiarySystemBackground)
    static let textPrimary = Color(uiColor: .label)
    static let textSecondary = Color(uiColor: .secondaryLabel)
    static let textTertiary = Color(uiColor: .tertiaryLabel)
    static let separator = Color(uiColor: .separator)
    static let accent = Color.accentColor
    static let accentSoft = Color.accentColor.opacity(0.10)
    /// Solid ink for filled buttons; inverts with the theme.
    static let ink = Color(uiColor: .label)
    static let onInk = Color(uiColor: .systemBackground)
    static let success = Color(uiColor: .systemGreen)
    static let warning = Color(uiColor: .systemOrange)
    static let danger = Color(uiColor: .systemRed)
    static let fill = Color(uiColor: .systemFill)
    
    /// Overlay colors that adapt to light/dark mode
    /// Use in hero views, full-screen overlays, and media displays
    static let overlayLight = Color.white
    static let overlayDark = Color.black
    
    /// Semi-transparent overlay backgrounds for content on images/video
    /// In light mode: semi-transparent black for contrast on bright images
    /// In dark mode: semi-transparent white for contrast on dark images
    static func overlayBackground(opacity: Double = 0.5) -> Color {
        // Note: This will be applied contextually with @Environment(\.colorScheme)
        // See helper function overlayBackgroundColor() in views
        Color.black.opacity(opacity)
    }
    
    /// Semi-transparent dark overlay for image gradients
    static func darkOverlay(opacity: Double = 0.8) -> Color {
        Color.black.opacity(opacity)
    }

    /// Kept for avatars and a few hero surfaces; deliberately near-flat — one accent, no rainbow.
    static let accentGradient = LinearGradient(
        colors: [Color.accentColor, Color.accentColor.opacity(0.82)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

enum MSpacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let cardRadius: CGFloat = 20
    static let chipRadius: CGFloat = 12
    /// Editorial gutters: content breathes.
    static let page: CGFloat = 20
    static let section: CGFloat = 36
}

/// Typography built on system text styles so Dynamic Type scales everything.
/// Display sizes use tighter tracking; everything else stays default for legibility.
enum MFont {
    /// Strict hierarchy: display · large title · title · body · secondary · caption. Semibold, not bold.
    static let display = Font.system(.largeTitle, design: .default, weight: .semibold)
    static let hero = Font.system(size: 38, weight: .semibold, design: .default)
    static let heroSmall = Font.system(.title2, design: .default, weight: .semibold)
    static let title = Font.system(.title2, design: .default, weight: .semibold)
    static let headline = Font.system(.headline, design: .default, weight: .semibold)
    static let body = Font.system(.body)
    static let callout = Font.system(.callout)
    static let subheadline = Font.system(.subheadline)
    static let footnote = Font.system(.footnote)
    static let caption = Font.system(.caption, weight: .regular)
    static let eyebrow = Font.system(.caption, weight: .medium)
    static let mono = Font.system(.footnote, design: .monospaced)
}

extension View {
    /// Standard card: soft surface, continuous corners, a whisper of depth instead of a hard border.
    func momentCard(padding: CGFloat = MSpacing.l) -> some View {
        modifier(CardModifier(padding: padding))
    }

    /// Small uppercase label used above card content ("FOLLOW UP", "PLAN").
    func eyebrowStyle() -> some View {
        self
            .font(MFont.eyebrow)
            .textCase(.uppercase)
            .tracking(0.9)
            .foregroundStyle(MColor.textSecondary)
    }

    /// Display text: large, bold, slightly tightened.
    func displayStyle() -> some View {
        self.font(MFont.display).tracking(-0.8)
    }

    /// Section label: small, letter-spaced, quiet. Structure through type, not boxes.
    func sectionLabel() -> some View {
        self.font(MFont.eyebrow).tracking(1.4).textCase(.uppercase).foregroundStyle(MColor.textSecondary)
    }
}

private struct CardModifier: ViewModifier {
    let padding: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MColor.surface, in: RoundedRectangle(cornerRadius: MSpacing.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: MSpacing.cardRadius, style: .continuous).strokeBorder(MColor.separator.opacity(0.7), lineWidth: 0.5))
            // A whisper of depth in light mode only; dark mode relies on the hairline.
            .shadow(color: scheme == .dark || reduceTransparency ? .clear : Color.black.opacity(0.035), radius: 10, y: 4)
    }
}

/// Soft ambient backdrop for hero screens (onboarding, home header). Uses iOS 18 MeshGradient,
/// kept faint so text contrast is unaffected, and dropped entirely under Reduce Transparency.
struct AmbientBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var intensity: Double = 1
    var body: some View {
        if reduceTransparency {
            MColor.background
        } else {
            ZStack {
                MColor.background
                MeshGradient(width: 3, height: 3, points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.45, 0.55], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1]
                ], colors: [
                    tint(0.55), tint(0.25), tint(0.10),
                    tint(0.20), tint(0.06), tint(0.02),
                    tint(0.04), tint(0.01), tint(0.0)
                ])
                .opacity(intensity * 0.6)
                .blur(radius: 60)
                .allowsHitTesting(false)
            }
        }
    }
    private func tint(_ a: Double) -> Color {
        (scheme == .dark ? Color(red: 0.45, green: 0.40, blue: 1.0) : Color(red: 0.36, green: 0.42, blue: 1.0)).opacity(a * (scheme == .dark ? 0.35 : 0.22))
    }
}

/// Helper extension to get adaptive overlay text color based on color scheme
extension View {
    /// Returns appropriate text color for overlays on images/video
    /// White text on dark backgrounds (both light and dark modes over images)
    var overlayTextColor: Color { .white }
    
    /// Returns appropriate overlay background opacity based on context
    /// Used for semi-transparent backgrounds behind text on images
    func overlayBackgroundColor(_ scheme: ColorScheme) -> Color {
        // On images, always use dark overlay for contrast
        Color.black.opacity(0.5)
    }
}
