import SwiftUI

/// Where a memory came from: "Screenshot · Aug 17".
struct SourceBadge: View {
    let type: SourceType
    let date: Date
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: type.symbol)
            Text(type.label)
            Text("·")
            Text(date.shortDate)
        }
        .font(MFont.caption)
        .foregroundStyle(MColor.textSecondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Source: \(type.label), \(date.mediumDate)")
    }
}

/// Small contextual fact ("December", "3 people", "Pending").
struct ContextPill: View {
    let text: String
    var symbol: String? = nil
    var tone: Tone = .neutral
    enum Tone { case neutral, accent, warning, success }
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.caption2.weight(.semibold)) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(background, in: Capsule())
        .foregroundStyle(foreground)
    }
    private var background: Color {
        switch tone { case .neutral: MColor.fill; case .accent: MColor.accentSoft; case .warning: MColor.warning.opacity(0.14); case .success: MColor.success.opacity(0.14) }
    }
    private var foreground: Color {
        switch tone { case .neutral: MColor.textSecondary; case .accent: MColor.accent; case .warning: MColor.warning; case .success: MColor.success }
    }
}

/// Universal memory card. Adapts its second line and pills to the memory type so a plan,
/// a promise and a gift feel related but different.
struct MomentCard: View {
    let memory: Memory
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: MSpacing.s) {
            HStack(spacing: 6) {
                Image(systemName: memory.memoryType.symbol).font(.caption.weight(.semibold)).foregroundStyle(MColor.accent).accessibilityHidden(true)
                Text(memory.memoryType.label).eyebrowStyle()
                Spacer()
                if memory.isPinned { Image(systemName: "star.fill").font(.caption2).foregroundStyle(MColor.warning).accessibilityLabel("Important") }
            }
            Text(memory.title).font(compact ? MFont.headline : MFont.title).tracking(compact ? 0 : -0.3).lineLimit(compact ? 2 : 3)
            if let line = secondLine { Text(line).font(MFont.subheadline).foregroundStyle(MColor.textSecondary).lineLimit(2) }
            HStack(spacing: 6) {
                ForEach(pills, id: \.text) { p in ContextPill(text: p.text, symbol: p.symbol, tone: p.tone) }
                Spacer()
                if let s = memory.source { SourceBadge(type: s.type, date: memory.createdAt) }
            }
        }
        .momentCard(padding: compact ? MSpacing.m : MSpacing.l)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(memory.memoryType.label): \(memory.title). \(secondLine ?? "")")
    }

    private var secondLine: String? {
        switch memory.memoryType {
        case .promise: return memory.promises.first.map { ($0.direction == .userOwes ? "You owe " : "") + $0.summary.capitalizedFirst }
        case .giftIdea: return memory.giftIdeas.first.map { g in g.person.map { "For \($0.displayName)" } ?? "Gift idea" }
        case .plan: return memory.plans.first.map { plan in TemporalFormatter.describe(start: plan.anchorDate, end: plan.possibleDateEnd, precision: plan.confirmedDate != nil ? .day : plan.possiblePrecision).map { "You mentioned \($0)." } ?? "No date yet." }
        case .event: return memory.events.first.map { $0.isAnnual ? $0.date.formatted(.dateTime.month(.wide).day()) : $0.date.mediumDate }
        default: return memory.summary.isBlank ? nil : memory.summary
        }
    }

    private var pills: [(text: String, symbol: String?, tone: ContextPill.Tone)] {
        var out: [(String, String?, ContextPill.Tone)] = []
        switch memory.memoryType {
        case .plan:
            if let plan = memory.plans.first {
                out.append((plan.status.label, nil, plan.status == .planned ? .success : .accent))
                if !plan.people.isEmpty { out.append(("\(plan.people.count) \(plan.people.count == 1 ? "person" : "people")", "person.2", .neutral)) }
            }
        case .promise:
            if let p = memory.promises.first { out.append((p.status == .pending ? (p.isOverdue ? "Overdue" : "Pending") : p.status.label, nil, p.status == .pending ? (p.isOverdue ? .warning : .accent) : .success)) }
        case .giftIdea:
            if let g = memory.giftIdeas.first, let b = g.person?.birthday {
                let d = Date.now.daysUntil(Event(title: "", date: b, isAnnual: true).nextOccurrence())
                if d <= 30 { out.append(("Birthday in \(d) days", "birthday.cake", .warning)) }
            }
        case .task:
            if memory.metadata["completedAt"] != nil { out.append(("Done", "checkmark", .success)) }
            else if let t = TemporalFormatter.describe(start: memory.referencedDateStart, end: memory.referencedDateEnd, precision: memory.referencedPrecision) { out.append((t.capitalizedFirst, "calendar", .accent)) }
        default:
            if let p = memory.people.first { out.append((p.displayName, "person", .neutral)) }
        }
        if memory.confidence == .low { out.append(("Needs review", "questionmark.circle", .warning)) }
        return out.map { (text: $0.0, symbol: $0.1, tone: $0.2) }
    }
}

/// One line in the Vault timeline: date rail on the left, title on the right.
struct TimelineRow: View {
    let memory: Memory
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: MSpacing.m) {
            Text(memory.createdAt.formatted(.dateTime.day()))
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(MColor.textTertiary)
                .frame(width: 28, alignment: .trailing)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(memory.title).font(MFont.body).lineLimit(2)
                HStack(spacing: 6) {
                    Text(memory.memoryType.label)
                    if let p = memory.people.first { Text("· \(p.displayName)") }
                }
                .font(MFont.caption).foregroundStyle(MColor.textTertiary)
            }
            Spacer(minLength: 0)
            Image(systemName: memory.memoryType.symbol).font(.caption).foregroundStyle(MColor.textTertiary).accessibilityHidden(true)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(memory.createdAt.mediumDate): \(memory.title)")
    }
}

/// "Why am I seeing this?" — a small sheet with a plain-language explanation and the source.
struct WhySheet: View {
    let title: String
    let explanation: String
    var source: (type: SourceType, date: Date)? = nil
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: MSpacing.l) {
            Text("Why am I seeing this?").eyebrowStyle()
            Text(title).font(MFont.title).tracking(-0.3)
            Text(explanation).font(MFont.body)
            if let source { SourceBadge(type: source.type, date: source.date) }
            Spacer()
            Button("Got it") { dismiss() }.buttonStyle(SecondaryButtonStyle())
        }
        .padding(MSpacing.xl)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

/// A gentle, understated confirmation ("Got it.", "Saved.") that fades out.
struct Toast: View {
    let text: String
    var body: some View {
        Text(text)
            .font(MFont.headline)
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(MColor.separator.opacity(0.3), lineWidth: 0.5))
            .accessibilityAddTraits(.isStaticText)
    }
}

/// App-wide toast host. Views call `env.toast("Saved.")`.
struct ToastHost: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let t = env.toastText {
                Toast(text: t)
                    .padding(.top, MSpacing.s)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    .animation(MAnimation.spring(reduce: reduceMotion), value: env.toastText)
            }
        }
    }
}
