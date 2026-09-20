import SwiftUI

/// Liquid glass: translucent, refractive surfaces that float over content. Built from system materials so
/// Reduce Transparency and Increase Contrast still work. When the toolchain gains the native glass API
/// (`glassEffect`), these are the seams to swap.
enum Glass {
    static let radius: CGFloat = 22
    static let pillRadius: CGFloat = 999

    /// Specular rim: bright at the top-left where light lands, fading to nothing.
    static func rim(_ shape: some InsettableShape, strength: Double = 1) -> some View {
        shape.strokeBorder(
            LinearGradient(colors: [Color.white.opacity(0.75 * strength), Color.white.opacity(0.12 * strength), Color.white.opacity(0.0), Color.white.opacity(0.28 * strength)], startPoint: .topLeading, endPoint: .bottomTrailing),
            lineWidth: 1
        )
    }
    /// Inner sheen: a soft highlight across the upper third, like light through curved glass.
    static func sheen(_ shape: some Shape) -> some View {
        shape.fill(LinearGradient(colors: [Color.white.opacity(0.28), Color.white.opacity(0.04), .clear], startPoint: .top, endPoint: .center))
            .allowsHitTesting(false)
    }
}

struct GlassSurface: ViewModifier {
    var radius: CGFloat = Glass.radius
    var tint: Color? = nil
    var prominent = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                ZStack {
                    if reduceTransparency { shape.fill(MColor.surface) }
                    else { shape.fill(prominent ? .regularMaterial : .ultraThinMaterial) }
                    if let tint { shape.fill(tint.opacity(scheme == .dark ? 0.22 : 0.14)) }
                    Glass.sheen(shape)
                    Glass.rim(shape, strength: scheme == .dark ? 0.55 : 0.9)
                }
            }
            .clipShape(shape)
            .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.10), radius: 18, y: 8)
            .shadow(color: .black.opacity(scheme == .dark ? 0.2 : 0.05), radius: 2, y: 1)
    }
}

struct GlassPillSurface: ViewModifier {
    var tint: Color? = nil
    var prominent = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    if reduceTransparency { Capsule().fill(MColor.surface) }
                    else { Capsule().fill(prominent ? .regularMaterial : .ultraThinMaterial) }
                    if let tint { Capsule().fill(tint.opacity(scheme == .dark ? 0.28 : 0.18)) }
                    Glass.sheen(Capsule())
                    Glass.rim(Capsule(), strength: scheme == .dark ? 0.55 : 0.9)
                }
            }
            .clipShape(Capsule())
            .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.10), radius: 12, y: 6)
    }
}

extension View {
    /// A floating glass card.
    func glass(radius: CGFloat = Glass.radius, tint: Color? = nil, prominent: Bool = false) -> some View { modifier(GlassSurface(radius: radius, tint: tint, prominent: prominent)) }
    /// A glass capsule (chips, floating buttons, toolbars).
    func glassPill(tint: Color? = nil, prominent: Bool = false) -> some View { modifier(GlassPillSurface(tint: tint, prominent: prominent)) }
}

/// Primary glass button: tinted glass with a specular rim; the press squashes it slightly like a soft lens.
struct GlassButtonStyle: ButtonStyle {
    var tint: Color = MColor.accent
    var filled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .frame(minHeight: 40)
            .foregroundStyle(filled ? Color.white : MColor.textPrimary)
            .background {
                if filled {
                    ZStack {
                        Capsule().fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                        Glass.sheen(Capsule())
                        Glass.rim(Capsule(), strength: 0.9)
                    }
                    .shadow(color: tint.opacity(0.45), radius: 14, y: 6)
                }
            }
            .modifier(OptionalGlassPill(enabled: !filled, tint: tint))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
    private struct OptionalGlassPill: ViewModifier {
        var enabled: Bool; var tint: Color
        func body(content: Content) -> some View { if enabled { content.glassPill(tint: tint) } else { content } }
    }
}

/// Slow, soft colour drift behind glass so the material has something to refract. Respects Reduce Motion.
struct LiquidBackdrop: View {
    var tint: Color = MColor.accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var phase = false
    var body: some View {
        ZStack {
            MColor.background
            Circle().fill(tint.opacity(scheme == .dark ? 0.35 : 0.22)).frame(width: 360).blur(radius: 90).offset(x: phase ? -110 : -60, y: phase ? -240 : -300)
            Circle().fill(Color.orange.opacity(scheme == .dark ? 0.22 : 0.16)).frame(width: 300).blur(radius: 90).offset(x: phase ? 140 : 100, y: phase ? -40 : 40)
            Circle().fill(Color.pink.opacity(scheme == .dark ? 0.18 : 0.12)).frame(width: 320).blur(radius: 100).offset(x: phase ? -60 : 20, y: phase ? 320 : 260)
        }
        .ignoresSafeArea()
        .onAppear { if !reduceMotion { withAnimation(.easeInOut(duration: 14).repeatForever(autoreverses: true)) { phase = true } } }
        .accessibilityHidden(true)
    }
}
