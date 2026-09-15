import SwiftUI
import StoreKit

/// Shown only after value has been experienced (free tier exhausted or Pro feature tapped).
/// Prices come from StoreKit. No countdowns, no fake discounts, no gated data access.
struct PaywallView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let presentedAsSheet: Bool
    @State private var selected: Product?
    @State private var purchasing = false

    var body: some View {
        Group {
            if presentedAsSheet { NavigationStack { content.toolbar { ToolbarItem(placement: .cancellationAction) { Button("Not now") { dismiss() } } } } }
            else { content }
        }
        .task { if env.subscriptions.products.isEmpty { await env.subscriptions.load() }; selected = env.subscriptions.products.first { $0.id == SubscriptionService.ProductID.yearly.rawValue } ?? env.subscriptions.products.first }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MSpacing.xl) {
                VStack(alignment: .leading, spacing: MSpacing.s) {
                    Text(env.subscriptions.isPro ? "You're on MOMENT Pro." : "Remember more. Forget less.").displayStyle()
                    Text(env.subscriptions.isPro ? "Thank you. Everything is unlocked." : "Free keeps \(SubscriptionService.freeMemoryLimit) memories, capture, search, reminders and \(StoryService.freeExportsPerMonth) shared Moments a month. Pro removes the limits.").font(MFont.body).foregroundStyle(MColor.textSecondary)
                }
                VStack(alignment: .leading, spacing: MSpacing.m) {
                    feature("A better memory of your life: unlimited memories")
                    feature("Unlimited Moment stories, videos and recaps to share")
                    feature("Natural-language memory search")
                    feature("Smart resurfacing at the right time")
                    feature("Voice memory")
                    feature("Contextual people, plans and promises")
                    feature("Home and Lock Screen widgets")
                }.momentCard()

                if !env.subscriptions.isPro {
                    if env.subscriptions.products.isEmpty {
                        if env.subscriptions.isLoading { ProgressView().frame(maxWidth: .infinity) }
                        else { Text(env.subscriptions.lastError ?? "Prices aren't available right now.").font(MFont.footnote).foregroundStyle(MColor.textSecondary) }
                    }
                    ForEach(env.subscriptions.products, id: \.id) { p in
                        Button { selected = p } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.displayName).font(MFont.headline)
                                    Text(p.description).font(MFont.caption).foregroundStyle(MColor.textSecondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(p.displayPrice).font(MFont.headline)
                                    Text(Self.periodLabel(p)).font(MFont.caption).foregroundStyle(MColor.textSecondary)
                                }
                                Image(systemName: selected?.id == p.id ? "checkmark.circle.fill" : "circle").foregroundStyle(MColor.accent)
                            }
                            .padding(MSpacing.l)
                            .background(MColor.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(selected?.id == p.id ? MColor.accent : MColor.separator.opacity(0.3), lineWidth: selected?.id == p.id ? 2 : 0.5))
                            .shadow(color: selected?.id == p.id ? MColor.accent.opacity(0.15) : .clear, radius: 12, y: 6)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(p.displayName), \(p.displayPrice)")
                        .accessibilityAddTraits(selected?.id == p.id ? .isSelected : [])
                    }
                    if !env.subscriptions.products.isEmpty {
                        Button(purchasing ? "…" : "Continue") { purchase() }.buttonStyle(PrimaryButtonStyle()).disabled(selected == nil || purchasing)
                    }
                    Button("Restore purchases") { Task { await env.subscriptions.restore() } }.font(MFont.subheadline).frame(maxWidth: .infinity)
                }
                Text("Your memories are always yours: viewing, exporting and deleting never require a subscription.").font(MFont.footnote).foregroundStyle(MColor.textTertiary)
                if !env.subscriptions.isPro, env.subscriptions.products.contains(where: { $0.subscription != nil }) {
                    Text("Payment is charged to your Apple Account at confirmation of purchase. Subscriptions renew automatically unless cancelled at least 24 hours before the end of the current period, and you can manage or cancel them in your Apple Account settings. Lifetime is a one-time purchase.")
                        .font(MFont.footnote).foregroundStyle(MColor.textTertiary)
                }
                HStack(spacing: MSpacing.l) {
                    if let url = AppConfig.termsURL { Link("Terms of Use", destination: url) }
                    if let url = AppConfig.privacyPolicyURL { Link("Privacy Policy", destination: url) }
                }
                .font(MFont.footnote)
            }
            .padding(MSpacing.l)
        }
        .background(AmbientBackdrop(intensity: 0.6).ignoresSafeArea())
        .navigationTitle("MOMENT Pro")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// "per month" / "per year" / "one-time", from StoreKit metadata — never hardcoded per product.
    static func periodLabel(_ p: Product) -> String {
        guard let period = p.subscription?.subscriptionPeriod else { return "one-time" }
        switch (period.unit, period.value) {
        case (.month, 1): return "per month"
        case (.year, 1): return "per year"
        case (.week, 1): return "per week"
        case (.day, 1): return "per day"
        case (let unit, let n): return "every \(n) \(unit)s"
        }
    }

    private func feature(_ text: String) -> some View {
        HStack(spacing: MSpacing.m) { Image(systemName: "checkmark").foregroundStyle(MColor.accent); Text(text).font(MFont.body) }
    }

    private func purchase() {
        guard let selected else { return }
        purchasing = true
        Task {
            let ok = await env.subscriptions.purchase(selected, analytics: env.analytics)
            purchasing = false
            if ok { Haptics.completed(); if presentedAsSheet { dismiss() } }
        }
    }
}
