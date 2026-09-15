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
                if let tint { RoundedRectangle(cornerRadius: 18, style: .continuous).fill(tint) }
                else { RoundedRectangle(cornerRadius: 18, style: .continuous).fill(MColor.accentGradient) }
            }
            .shadow(color: (tint ?? MColor.accent).opacity(configuration.isPressed ? 0.1 : 0.25), radius: 12, y: 6)
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
            .background(MColor.fill.opacity(configuration.isPressed ? 0.6 : 1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .frame(minHeight: MTouch.minimum - 8)
            .foregroundStyle(light ? (prominent ? MColor.accent : Color.white) : (prominent ? Color.white : MColor.accent))
            .background {
                if light { Capsule().fill(prominent ? Color.white : Color.white.opacity(0.22)) }
                else if prominent { Capsule().fill(MColor.accentGradient) } else { Capsule().fill(MColor.accentSoft) }
            }
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
            Text(title).font(MFont.title)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action).font(.subheadline.weight(.semibold))
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
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(MColor.accentGradient.opacity(0.9), in: Circle())
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
