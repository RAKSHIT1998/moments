import SwiftUI

// MARK: - Earn (creator side)

/// Set up what you sell, see who's paying, and what you've earned. One plan per creator, priced by tier.
struct CreatorEarnView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var title = ""
    @State private var pitch = ""
    @State private var tier: CreatorPlan.Tier = .t2
    @State private var perks: [String] = ["", "", ""]
    @State private var payoutHint = ""
    @State private var saving = false
    @State private var editing = false
    @State private var confirmRemove = false

    private var plan: CreatorPlan? { env.social.myPlan }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MSpacing.xl) {
                if let plan, !editing { live(plan) } else { form }
            }
            .padding(.horizontal, MSpacing.page)
            .padding(.vertical, MSpacing.l)
            .padding(.bottom, 80)
        }
        .background(LiquidBackdrop(tint: .orange))
        .navigationTitle("Earn")
        .navigationBarTitleDisplayMode(.inline)
        .task { await env.social.refreshCreator(); load() }
        .modifier(SocialErrorAlert())
    }

    private func load() {
        guard let p = plan else { return }
        title = p.title; pitch = p.pitch; tier = p.tier; payoutHint = p.payoutHint
        perks = (p.perks + ["", "", ""]).prefix(3).map { $0 }
    }

    // Live plan: earnings first, then people, then the offer.
    private func live(_ plan: CreatorPlan) -> some View {
        VStack(alignment: .leading, spacing: MSpacing.xl) {
            VStack(alignment: .leading, spacing: MSpacing.s) {
                Text("THIS MONTH").font(MFont.eyebrow).foregroundStyle(MColor.textSecondary).tracking(1)
                Text(env.social.earningsEstimate, format: .currency(code: "INR").precision(.fractionLength(0))).font(MFont.hero).monospacedDigit()
                    .accessibilityIdentifier("earningsEstimate")
                Text("\(env.social.activeSubscriberCount) active \(env.social.activeSubscriberCount == 1 ? "subscriber" : "subscribers") · \(env.social.price(for: plan.tier)) each · \(env.social.tipsReceived.count) \(env.social.tipsReceived.count == 1 ? "tip" : "tips")").font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
                Text("Estimate after App Store fees (\(Int(CreatorEconomics.appStoreShare * 100))%) and MOMENT's share; you keep \(Int(CreatorEconomics.creatorShare * 100))% of the net. Paid out monthly to the details below.").font(MFont.footnote).foregroundStyle(MColor.textTertiary)
            }
            .padding(MSpacing.l).frame(maxWidth: .infinity, alignment: .leading).glass(tint: .orange)

            VStack(alignment: .leading, spacing: MSpacing.m) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plan.title).font(MFont.headline)
                        Text("\(plan.tier.label) · \(env.social.price(for: plan.tier)) / 30 days").font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
                    }
                    Spacer()
                    Button("Edit") { editing = true }.buttonStyle(GlassButtonStyle()).accessibilityIdentifier("editPlan")
                }
                Text(plan.pitch).font(MFont.body)
                ForEach(plan.perks, id: \.self) { Label($0, systemImage: "checkmark").font(MFont.subheadline) }
            }
            .padding(MSpacing.l).frame(maxWidth: .infinity, alignment: .leading).glass()

            VStack(alignment: .leading, spacing: MSpacing.m) {
                Text("SUBSCRIBERS").font(MFont.eyebrow).foregroundStyle(MColor.textSecondary).tracking(1)
                if env.social.subscribers.isEmpty {
                    Text("Nobody yet. Share a subscribers-only Moment — the locked preview does the selling.").font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
                } else {
                    ForEach(env.social.subscribers) { s in
                        HStack(spacing: MSpacing.m) {
                            AvatarView(userID: s.subscriberID, name: s.subscriberName, size: 36)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.subscriberName).font(.subheadline.weight(.semibold))
                                Text(s.isActive ? "Until \(s.expiresAt.formatted(date: .abbreviated, time: .omitted))" : "Lapsed \(s.expiresAt.formatted(.relative(presentation: .named)))").font(MFont.caption).foregroundStyle(MColor.textSecondary)
                            }
                            Spacer()
                            Text(s.tier.label).font(MFont.caption).padding(.horizontal, 10).padding(.vertical, 5).glassPill(tint: s.isActive ? .green : nil)
                        }
                    }
                }
            }
            .padding(MSpacing.l).frame(maxWidth: .infinity, alignment: .leading).glass()

            if !env.social.tipsReceived.isEmpty {
                VStack(alignment: .leading, spacing: MSpacing.m) {
                    Text("TIPS").font(MFont.eyebrow).foregroundStyle(MColor.textSecondary).tracking(1)
                    ForEach(env.social.tipsReceived.prefix(20)) { t in
                        HStack(spacing: MSpacing.m) {
                            Text(t.amount.emoji).font(.title3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(t.fromName) · \(env.social.price(for: t.amount))").font(.subheadline.weight(.semibold))
                                if !t.note.isEmpty { Text(t.note).font(MFont.caption).foregroundStyle(MColor.textSecondary) }
                            }
                            Spacer()
                            Text(t.createdAt.formatted(.relative(presentation: .named))).font(MFont.caption).foregroundStyle(MColor.textTertiary)
                        }
                    }
                }
                .padding(MSpacing.l).frame(maxWidth: .infinity, alignment: .leading).glass()
            }
            NavigationLink(value: SocialRoute.newMoment) { Label("New subscribers-only Moment", systemImage: "crown") }.buttonStyle(PrimaryButtonStyle(tint: .orange))
            Button("Stop selling", role: .destructive) { confirmRemove = true }.font(MFont.footnote).frame(maxWidth: .infinity)
                .confirmationDialog("Stop selling?", isPresented: $confirmRemove) {
                    Button("Stop selling", role: .destructive) { Task { await env.social.removePlan() } }
                } message: { Text("Current subscribers keep what they already have until it expires. New Moments can't be sold until you set up a plan again.") }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: MSpacing.xl) {
            VStack(alignment: .leading, spacing: MSpacing.s) {
                Text(plan == nil ? "Sell what you make" : "Your plan").font(MFont.title)
                Text("Subscribers pay for 30 days at a time and see every Moment you mark for subscribers. No ads, no algorithm between you and them. MOMENT keeps nothing about who paid beyond the receipt.").font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
            }
            VStack(alignment: .leading, spacing: MSpacing.m) {
                TextField("Name it — “The raw frames”", text: $title).font(MFont.headline).accessibilityIdentifier("planTitle")
                Divider()
                TextField("What do they get?", text: $pitch, axis: .vertical).lineLimit(2...5).accessibilityIdentifier("planPitch")
            }
            .padding(MSpacing.l).glass()

            VStack(alignment: .leading, spacing: MSpacing.s) {
                Text("PRICE · 30 DAYS").font(MFont.eyebrow).foregroundStyle(MColor.textSecondary).tracking(1)
                HStack(spacing: MSpacing.s) {
                    ForEach(CreatorPlan.Tier.allCases, id: \.self) { t in
                        Button { tier = t } label: {
                            VStack(spacing: 2) { Text(env.social.price(for: t)).font(.headline.weight(.semibold)); Text(t.label).font(MFont.caption) }
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                        }
                        .buttonStyle(.plain).foregroundStyle(tier == t ? Color.white : MColor.textPrimary)
                        .background { if tier == t { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(MColor.accent) } }
                        .glass(radius: 14)
                        .accessibilityIdentifier("tier-\(t.rawValue)")
                    }
                }
                Text("Prices are set by the App Store in each country. Apple takes its cut on every purchase.").font(MFont.footnote).foregroundStyle(MColor.textTertiary)
            }

            VStack(alignment: .leading, spacing: MSpacing.s) {
                Text("PERKS").font(MFont.eyebrow).foregroundStyle(MColor.textSecondary).tracking(1)
                ForEach(0..<3, id: \.self) { i in TextField(["Full-res photos, same night", "Vote on the next spot", "Ask me anything"][i], text: $perks[i]).padding(.horizontal, MSpacing.l).padding(.vertical, 10).glass(radius: 14) }
            }

            VStack(alignment: .leading, spacing: MSpacing.s) {
                Text("PAYOUT").font(MFont.eyebrow).foregroundStyle(MColor.textSecondary).tracking(1)
                TextField("UPI ID, PayPal email or IBAN", text: $payoutHint).textInputAutocapitalization(.never).autocorrectionDisabled().padding(.horizontal, MSpacing.l).padding(.vertical, 10).glass(radius: 14).accessibilityIdentifier("payoutHint")
                Text("Read only by the payouts process, once a month. You can change it any time.").font(MFont.footnote).foregroundStyle(MColor.textTertiary)
            }

            Button {
                saving = true
                Task { if await env.social.savePlan(title: title, pitch: pitch, tier: tier, perks: perks, payoutHint: payoutHint) { editing = false }; saving = false }
            } label: { Text(plan == nil ? "Start selling" : "Save") }
                .buttonStyle(PrimaryButtonStyle(tint: .orange)).disabled(title.isBlank || pitch.isBlank || saving)
                .accessibilityIdentifier("savePlan")
            if editing { Button("Cancel") { editing = false; load() }.frame(maxWidth: .infinity) }
        }
    }
}

// MARK: - Subscribe (fan side)

/// The paywall: what you get, what it costs, one button. Opens from a profile or a locked Moment.
struct SubscribeSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let creatorID: String
    @State private var done = false

    private var plan: CreatorPlan? { env.social.plan(for: creatorID) }

    var body: some View {
        VStack(alignment: .leading, spacing: MSpacing.xl) {
            if let plan {
                HStack(spacing: MSpacing.m) {
                    AvatarView(userID: creatorID, name: plan.creatorName, size: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plan.creatorName).font(MFont.headline)
                        Text(plan.title).font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
                    }
                }
                Text(plan.pitch).font(MFont.body)
                VStack(alignment: .leading, spacing: MSpacing.s) {
                    ForEach(plan.perks, id: \.self) { Label($0, systemImage: "checkmark.circle.fill").font(MFont.subheadline).foregroundStyle(MColor.textPrimary) }
                }
                .padding(MSpacing.l).frame(maxWidth: .infinity, alignment: .leading).glass()
                Spacer(minLength: 0)
                if done || env.social.isSubscribed(to: creatorID) {
                    Label("You're in. Everything unlocks now.", systemImage: "checkmark.seal.fill").font(MFont.headline).frame(maxWidth: .infinity)
                    Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle())
                } else {
                    Button {
                        Task {
                            if await env.social.subscribe(to: creatorID) {
                                done = true; Haptics.saved()
                                try? await Task.sleep(for: .seconds(1.2)); dismiss()   // the unlocked Moment is right behind this sheet
                            }
                        }
                    } label: {
                        if env.social.purchasing { ProgressView().tint(.white) } else { Text("Subscribe · \(env.social.price(for: plan.tier)) for 30 days") }
                    }
                    .buttonStyle(PrimaryButtonStyle(tint: .orange)).disabled(env.social.purchasing)
                    .accessibilityIdentifier("subscribeButton")
                    Text("One payment through the App Store, no auto-renew. The creator gets the majority; MOMENT keeps no card details and never sees your name against a purchase.").font(MFont.footnote).foregroundStyle(MColor.textTertiary)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .padding(MSpacing.page)
        .background(LiquidBackdrop(tint: .orange))
        .task { await env.social.loadCreatorPlan(creatorID) }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .modifier(SocialErrorAlert())
    }
}

/// Frosted lock over paid media, with the price on the glass.
struct LockedOverlay: View {
    @Environment(AppEnvironment.self) private var env
    let moment: SocialMoment
    var onSubscribe: () -> Void
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            VStack(spacing: MSpacing.m) {
                Image(systemName: "lock.fill").font(.title2)
                Text("For subscribers").font(MFont.headline)
                Text("\(moment.mediaCount) \(moment.mediaCount == 1 ? "photo" : "photos") · \(moment.creatorName)").font(MFont.caption).foregroundStyle(MColor.textSecondary)
                Button { onSubscribe() } label: {
                    Text(env.social.plan(for: moment.creatorID).map { "Unlock · \(env.social.price(for: $0.tier))" } ?? "Subscribe")
                }
                .buttonStyle(GlassButtonStyle(tint: .orange, filled: true))
                .accessibilityIdentifier("unlock-\(moment.id)")
            }
            .padding(MSpacing.l)
        }
        .task { if env.social.plan(for: moment.creatorID) == nil { await env.social.loadCreatorPlan(moment.creatorID) } }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - My subscriptions

struct MySubscriptionsView: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        List {
            if env.social.mySubscriptions.isEmpty {
                Text("You're not subscribed to anyone. Creators you support show up here, with what you paid for and until when.").font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
            }
            ForEach(env.social.mySubscriptions) { s in
                NavigationLink(value: SocialRoute.profile(s.creatorID)) {
                    HStack(spacing: MSpacing.m) {
                        AvatarView(userID: s.creatorID, name: env.social.plan(for: s.creatorID)?.creatorName ?? "Creator", size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(env.social.plan(for: s.creatorID)?.creatorName ?? "Creator").font(.subheadline.weight(.semibold))
                            Text(s.isActive ? "Active until \(s.expiresAt.formatted(date: .abbreviated, time: .omitted))" : "Expired \(s.expiresAt.formatted(.relative(presentation: .named)))").font(MFont.caption).foregroundStyle(MColor.textSecondary)
                        }
                        Spacer()
                        Text(env.social.price(for: s.tier)).font(MFont.caption).foregroundStyle(MColor.textSecondary)
                    }
                }
                .task { if env.social.plan(for: s.creatorID) == nil { await env.social.loadCreatorPlan(s.creatorID) } }
            }
        }
        .scrollContentBackground(.hidden)
        .background(LiquidBackdrop())
        .navigationTitle("Subscriptions")
        .task { await env.social.refreshCreator() }
    }
}

// MARK: - Tips

/// Three amounts, an optional line, one tap. Shows on any Moment by a creator who has a plan.
struct TipSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let creatorID: String
    let creatorName: String
    var momentID: String? = nil
    @State private var amount: CreatorTip.Amount = .medium
    @State private var note = ""
    @State private var sent = false

    var body: some View {
        VStack(alignment: .leading, spacing: MSpacing.xl) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Thank \(creatorName.split(separator: " ").first.map(String.init) ?? creatorName)").font(MFont.title)
                Text("A one-off. They get \(Int(CreatorEconomics.creatorShare * 100))% of what's left after the App Store.").font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
            }
            HStack(spacing: MSpacing.s) {
                ForEach(CreatorTip.Amount.allCases, id: \.self) { a in
                    Button { amount = a } label: {
                        VStack(spacing: 4) { Text(a.emoji).font(.title2); Text(env.social.price(for: a)).font(.headline.weight(.semibold)) }
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                    }
                    .buttonStyle(.plain).foregroundStyle(amount == a ? Color.white : MColor.textPrimary)
                    .background { if amount == a { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.orange) } }
                    .glass(radius: 16)
                    .accessibilityIdentifier("tip-\(a.rawValue)")
                }
            }
            TextField("Say something (optional)", text: $note).padding(.horizontal, MSpacing.l).padding(.vertical, 12).glass(radius: 14)
            Spacer(minLength: 0)
            if sent {
                Label("Sent. They'll see it on their Earn page.", systemImage: "checkmark.seal.fill").font(MFont.headline).frame(maxWidth: .infinity)
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle())
            } else {
                Button {
                    Task { if await env.social.tip(creatorID: creatorID, momentID: momentID, amount: amount, note: note) { sent = true; Haptics.saved() } }
                } label: { if env.social.purchasing { ProgressView().tint(.white) } else { Text("Send \(env.social.price(for: amount))") } }
                    .buttonStyle(PrimaryButtonStyle(tint: .orange)).disabled(env.social.purchasing)
                    .accessibilityIdentifier("sendTip")
            }
        }
        .padding(MSpacing.page)
        .background(LiquidBackdrop(tint: .orange))
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .modifier(SocialErrorAlert())
    }
}

/// The small glass "Tip" pill that lives in action rows. Only renders when the creator sells something.
struct TipButton: View {
    @Environment(AppEnvironment.self) private var env
    let creatorID: String
    let creatorName: String
    var momentID: String? = nil
    @State private var show = false
    var body: some View {
        Group {
            if creatorID != env.social.myID, env.social.plan(for: creatorID) != nil {
                Button { show = true } label: { HStack(spacing: 4) { Image(systemName: "gift.fill"); Text("Tip") }.font(.subheadline.weight(.semibold)).foregroundStyle(.orange) }
                    .padding(.horizontal, 12).padding(.vertical, 6).glassPill(tint: .orange)
                    .accessibilityIdentifier("tip-\(momentID ?? creatorID)")
                    .sheet(isPresented: $show) { TipSheet(creatorID: creatorID, creatorName: creatorName, momentID: momentID) }
            }
        }
        .task { if env.social.plan(for: creatorID) == nil, !env.social.checkedPlans.contains(creatorID) { await env.social.loadCreatorPlan(creatorID) } }
    }
}
