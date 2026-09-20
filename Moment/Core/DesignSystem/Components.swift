import SwiftUI

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MFont.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .foregroundStyle(.white)
            .background {
                // Tinted glass: the accent seen through a curved lens, with a specular rim.
                let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
                ZStack {
                    shape.fill(LinearGradient(colors: [(tint ?? MColor.accent).opacity(0.95), (tint ?? MColor.accent).opacity(0.72)], startPoint: .top, endPoint: .bottom))
                    Glass.sheen(shape)
                    Glass.rim(shape, strength: 0.9)
                }
                .shadow(color: (tint ?? MColor.accent).opacity(0.4), radius: 16, y: 8)
            }
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .spring(duration: 0.25), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MFont.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .foregroundStyle(MColor.textPrimary)
            .glass(radius: 14)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

/// Compact inline action, used inside cards ("Remind me", "Done").
struct ChipButtonStyle: ButtonStyle {
    var prominent = false
    /// On a gradient (hero) surface: white pill when prominent, translucent white otherwise.
    var light = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: MTouch.minimum - 8)
            .foregroundStyle(light ? (prominent ? Color.black : Color.white) : (prominent ? Color.white : MColor.textPrimary))
            .background {
                ZStack {
                    if light { Capsule().fill(prominent ? Color.white : Color.white.opacity(0.18)) }
                    else if prominent { Capsule().fill(LinearGradient(colors: [MColor.accent.opacity(0.95), MColor.accent.opacity(0.72)], startPoint: .top, endPoint: .bottom)) }
                    else { Capsule().fill(.ultraThinMaterial) }
                    if !light { Glass.sheen(Capsule()); Glass.rim(Capsule(), strength: 0.7) }
                }
            }
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

struct SectionHeader: View {
    let title: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).sectionLabel()
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action).font(.subheadline.weight(.medium)).foregroundStyle(MColor.textSecondary)
            }
        }
        .padding(.horizontal, MSpacing.l)
        .accessibilityAddTraits(.isHeader)
    }
}

/// "Understood / Likely / Needs review" — subtle, never a scary percentage.
struct ConfidenceBadge: View {
    let confidence: Confidence
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(confidence.label)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .accessibilityLabel("Confidence: \(confidence.label)")
    }
    private var symbol: String {
        switch confidence {
        case .high: "checkmark.circle.fill"
        case .medium: "circle.lefthalf.filled"
        case .low: "questionmark.circle"
        }
    }
    private var color: Color {
        switch confidence {
        case .high: MColor.success
        case .medium: MColor.textSecondary
        case .low: MColor.warning
        }
    }
}

struct TagChip: View {
    let text: String
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.caption2) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(MColor.accentSoft, in: Capsule())
        .foregroundStyle(MColor.accent)
    }
}

/// Simple key/value row used in detail screens ("Source: Screenshot").
struct LabeledRow: View {
    let label: String
    let value: String
    var symbol: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
            Spacer(minLength: MSpacing.m)
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.footnote) }
                Text(value).font(MFont.subheadline)
            }
            .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Avatar with initials. No photos unless the user added one.
struct PersonAvatar: View {
    let name: String
    var size: CGFloat = 40
    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
            .foregroundStyle(MColor.onInk)
            .frame(width: size, height: size)
            .background(MColor.ink.opacity(0.85), in: Circle())
            .accessibilityHidden(true)
    }
    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        }
    }
}

/// Animated processing rows for the capture flow: "Reading text…", "Understanding context…".
struct ProcessingStepsView: View {
    let steps: [String]
    let currentIndex: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: MSpacing.m) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(spacing: MSpacing.m) {
                    Group {
                        if index < currentIndex {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(MColor.success)
                        } else if index == currentIndex {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "circle").foregroundStyle(MColor.textTertiary)
                        }
                    }
                    .frame(width: 20)
                    Text(step)
                        .font(MFont.body)
                        .foregroundStyle(index <= currentIndex ? MColor.textPrimary : MColor.textTertiary)
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: currentIndex)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(currentIndex < steps.count ? steps[currentIndex] : "Done")
    }
}
