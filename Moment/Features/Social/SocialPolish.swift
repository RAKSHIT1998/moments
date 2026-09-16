import SwiftUI

// MARK: - Shimmer / skeleton

struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1
    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    LinearGradient(colors: [.clear, .white.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 180)
                        .offset(x: phase * 400)
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                }
            }
            .clipped()
            .onAppear { withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 } }
    }
}
extension View { func shimmer() -> some View { modifier(Shimmer()) } }

/// Placeholder that mirrors a feed card while the first fetch runs.
struct SkeletonFeedCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: 0).fill(MColor.fill).frame(height: 300)
            HStack(spacing: MSpacing.m) {
                Circle().fill(MColor.fill).frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 6) {
                    Capsule().fill(MColor.fill).frame(width: 140, height: 12)
                    Capsule().fill(MColor.fill).frame(width: 90, height: 10)
                }
                Spacer()
            }
            .padding(MSpacing.l)
        }
        .background(MColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: MRadius.card, style: .continuous))
        .shimmer()
        .accessibilityHidden(true)
    }
}

// MARK: - Avatars with real photos

/// Uses the person's uploaded avatar when there is one, initials otherwise.
struct AvatarView: View {
    @Environment(AppEnvironment.self) private var env
    let userID: String
    let name: String
    var size: CGFloat = 40
    @State private var ref: MediaRef?
    var body: some View {
        ZStack {
            if let ref { SocialImage(ref: ref).frame(width: size, height: size).clipShape(Circle()) }
            else { PersonAvatar(name: name, size: size) }
        }
        .task(id: userID) {
            if userID == env.social.myID { ref = env.social.me?.avatarRef }
            else if let u = env.social.users[userID] { ref = u.avatarRef }
            else if let u = await env.social.user(userID) { ref = u.avatarRef }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Reaction burst

/// Emoji floats up and fades when you react. Purely decorative; respects Reduce Motion.
struct ReactionBurst: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var burst: String?
    @State private var particles: [Particle] = []
    struct Particle: Identifiable { let id = UUID(); let emoji: String; let dx: CGFloat; let delay: Double; let scale: CGFloat }

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            ZStack {
                ForEach(particles) { p in
                    FloatingEmoji(emoji: p.emoji, dx: p.dx, delay: p.delay, scale: p.scale)
                }
            }
            .allowsHitTesting(false)
        }
        .onChange(of: burst) { _, new in
            guard let new, !reduceMotion else { burst = nil; return }
            particles = (0..<7).map { i in Particle(emoji: new, dx: CGFloat.random(in: -60...60), delay: Double(i) * 0.05, scale: CGFloat.random(in: 0.8...1.5)) }
            Task { try? await Task.sleep(for: .seconds(1.4)); particles = []; burst = nil }
        }
    }
}

private struct FloatingEmoji: View {
    let emoji: String; let dx: CGFloat; let delay: Double; let scale: CGFloat
    @State private var up = false
    var body: some View {
        Text(emoji).font(.system(size: 28 * scale))
            .offset(x: dx, y: up ? -160 : 20)
            .opacity(up ? 0 : 1)
            .scaleEffect(up ? 1.2 : 0.6)
            .onAppear { withAnimation(.easeOut(duration: 1.1).delay(delay)) { up = true } }
    }
}
extension View { func reactionBurst(_ burst: Binding<String?>) -> some View { modifier(ReactionBurst(burst: burst)) } }

// MARK: - Pills & glass

struct GlassPill: View {
    let text: String
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.caption.weight(.semibold)) }
            Text(text).font(MFont.caption)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
    }
}

// MARK: - Mosaic grid for many photos

/// 1 photo → full width; 2 → halves; 3+ → one big + a column, then a 3-up grid. No cropping surprises.
struct MosaicGrid<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    var spacing: CGFloat = 4
    @ViewBuilder let cell: (Item) -> Cell

    var body: some View {
        VStack(spacing: spacing) {
            if items.count == 1 { cell(items[0]).aspectRatio(4/5, contentMode: .fill).frame(maxWidth: .infinity).clipped() }
            else if items.count == 2 {
                HStack(spacing: spacing) { ForEach(items) { cell($0).aspectRatio(0.8, contentMode: .fill).clipped() } }
            } else {
                HStack(spacing: spacing) {
                    cell(items[0]).aspectRatio(0.8, contentMode: .fill).frame(maxWidth: .infinity).clipped()
                    VStack(spacing: spacing) {
                        cell(items[1]).aspectRatio(1.6, contentMode: .fill).clipped()
                        cell(items[2]).aspectRatio(1.6, contentMode: .fill).clipped()
                    }
                    .frame(maxWidth: .infinity)
                }
                let rest = Array(items.dropFirst(3))
                ForEach(Array(stride(from: 0, to: rest.count, by: 3)), id: \.self) { i in
                    HStack(spacing: spacing) {
                        ForEach(rest[i..<min(i + 3, rest.count)]) { cell($0).aspectRatio(1, contentMode: .fill).clipped() }
                        if rest.count - i < 3 { ForEach(0..<(3 - (rest.count - i)), id: \.self) { _ in Color.clear.aspectRatio(1, contentMode: .fill) } }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: MRadius.tile, style: .continuous))
    }
}

// MARK: - Stat tiles

struct StatTile: View {
    let value: String
    let label: String
    var symbol: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.caption).foregroundStyle(MColor.accent) }
            Text(value).font(.system(.title2, design: .rounded, weight: .bold)).monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
            Text(label).font(MFont.caption).foregroundStyle(MColor.textSecondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MSpacing.m)
        .background(MColor.surfaceSecondary, in: RoundedRectangle(cornerRadius: MRadius.chip, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Emoji picker row for collections.
struct EmojiRow: View {
    @Binding var selection: String
    static let options = ["📁", "✈️", "🎂", "🌙", "🏃", "🍜", "🎶", "🏖️", "🎓", "🏠", "❤️", "🔥"]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MSpacing.s) {
                ForEach(Self.options, id: \.self) { e in
                    Button { selection = e; Haptics.selection() } label: {
                        Text(e).font(.title2).frame(width: 44, height: 44)
                            .background(selection == e ? MColor.accentSoft : MColor.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selection == e ? MColor.accent : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(e)
                }
            }
        }
    }
}
