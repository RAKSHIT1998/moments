import SwiftUI

/// Semantic color system. Built on system colors so Dark Mode, Increase Contrast and
/// Reduce Transparency all work, with a warm neutral ground and a single indigo→violet accent.
enum MColor {
    static let background = Color("Canvas")
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let surfaceSecondary = Color(uiColor: .tertiarySystemGroupedBackground)
    static let textPrimary = Color(uiColor: .label)
    static let textSecondary = Color(uiColor: .secondaryLabel)
    static let textTertiary = Color(uiColor: .tertiaryLabel)
    static let separator = Color(uiColor: .separator)
    static let accent = Color.accentColor
    static let accentSoft = Color.accentColor.opacity(0.12)
    static let success = Color(uiColor: .systemGreen)
    static let warning = Color(uiColor: .systemOrange)
    static let danger = Color(uiColor: .systemRed)
    static let fill = Color(uiColor: .systemFill)

    /// The one gradient in the app: primary actions and the capture button.
    static let accentGradient = LinearGradient(
        colors: [Color.accentColor, Color(red: 0.55, green: 0.36, blue: 0.98)],
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
    static let cardRadius: CGFloat = 24
    static let chipRadius: CGFloat = 12
}

/// Typography built on system text styles so Dynamic Type scales everything.
/// Display sizes use tighter tracking; everything else stays default for legibility.
enum MFont {
    static let display = Font.system(.largeTitle, design: .default, weight: .bold)
    /// Moment titles: a touch of serif so an experience reads like a headline, not a filename.
    static let hero = Font.system(size: 36, weight: .bold, design: .serif)
    static let heroSmall = Font.system(.title2, design: .serif, weight: .bold)
    static let title = Font.system(.title2, design: .default, weight: .bold)
    static let headline = Font.system(.headline, design: .default, weight: .semibold)
    static let body = Font.system(.body)
    static let callout = Font.system(.callout)
    static let subheadline = Font.system(.subheadline)
    static let footnote = Font.system(.footnote)
    static let caption = Font.system(.caption, weight: .medium)
    static let eyebrow = Font.system(.caption, weight: .semibold)
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
        self.font(MFont.display).tracking(-0.6)
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
            .overlay(
                RoundedRectangle(cornerRadius: MSpacing.cardRadius, style: .continuous)
                    .strokeBorder(scheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04), lineWidth: 1)
            )
            .shadow(color: scheme == .dark || reduceTransparency ? .clear : Color.black.opacity(0.05), radius: 14, y: 6)
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
                .opacity(intensity)
                .blur(radius: 40)
                .allowsHitTesting(false)
            }
        }
    }
    private func tint(_ a: Double) -> Color {
        (scheme == .dark ? Color(red: 0.45, green: 0.40, blue: 1.0) : Color(red: 0.36, green: 0.42, blue: 1.0)).opacity(a * (scheme == .dark ? 0.35 : 0.22))
    }
}
