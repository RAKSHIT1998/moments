import SwiftUI
import PhotosUI

// MARK: - Earn (creator side)

/// Set up what you sell, see who's paying, and what you've earned. One plan per creator, priced by tier.
struct CreatorEarnView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var title = ""
    @State private var pitch = ""
    @State private var price = "499"
    @State private var bundles: [Int: Int] = [:]
    @State private var goalTitle = ""
    @State private var goalAmount = ""
    private func discount(_ months: Int) -> Int { bundles[months] ?? 0 }
    private func setDiscount(_ months: Int, _ value: Int) { bundles[months] = value }
    @State private var perks: [String] = ["", "", ""]
    @State private var payoutHint = ""
    @State private var saving = false
    @State private var editing = false
    @State private var confirmRemove = false
    @State private var showMass = false

    private var plan: CreatorPlan? { env.social.myPlan }
    private var priceMinor: Int { max(0, (Int(price.filter(\.isNumber)) ?? 0) * 100) }
    /// Used only to show which App Store product this price would map to.
    private var draftPlan: CreatorPlan { CreatorPlan(creatorID: "", creatorName: "", title: "", pitch: "", priceMinor: priceMinor, currency: "INR", perks: [], payoutHint: "", createdAt: .now) }

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
        .task { await env.social.refreshCreator(); await env.social.refreshStorefront(); load() }
        .sheet(isPresented: $showMass) { MassMessageSheet() }
        .modifier(SocialErrorAlert())
    }

    private func load() {
        guard let p = plan else { return }
        title = p.title; pitch = p.pitch; price = String(p.priceMinor / 100); payoutHint = p.payoutHint
        bundles = Dictionary(uniqueKeysWithValues: p.bundles.map { ($0.months, $0.discountPercent) })
        goalTitle = p.goalTitle; goalAmount = p.goalAmountMinor > 0 ? String(p.goalAmountMinor / 100) : ""
        perks = (p.perks + ["", "", ""]).prefix(3).map { $0 }
    }

    // Live plan: earnings first, then people, then the offer.
    private func live(_ plan: CreatorPlan) -> some View {
        VStack(alignment: .leading, spacing: MSpacing.xl) {
            VStack(alignment: .leading, spacing: MSpacing.s) {
                Text("THIS MONTH").font(MFont.eyebrow).foregroundStyle(MColor.textSecondary).tracking(1)
                Text(env.social.earningsEstimate, format: .currency(code: "INR").precision(.fractionLength(0))).font(MFont.hero).monospacedDigit()
                    .accessibilityIdentifier("earningsEstimate")
                Text("\(env.social.activeSubscriberCount) active \(env.social.activeSubscriberCount == 1 ? "subscriber" : "subscribers") · \(plan.priceLabel()) each · \(env.social.tipsReceived.count) \(env.social.tipsReceived.count == 1 ? "tip" : "tips")").font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
                Text("Estimate after App Store fees (\(Int(CreatorEconomics.appStoreShare * 100))%) and MOMENT's share; you keep \(Int(CreatorEconomics.creatorShare * 100))% of the net. Paid out monthly to the details below.").font(MFont.footnote).foregroundStyle(MColor.textTertiary)
            }
            .padding(MSpacing.l).frame(maxWidth: .infinity, alignment: .leading).glass(tint: .orange)

            VStack(alignment: .leading, spacing: MSpacing.m) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plan.title).font(MFont.headline)
                        Text("\(plan.priceLabel()) / 30 days").font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
                    }
                    Spacer()
                    Button("Edit") { editing = true }.buttonStyle(GlassButtonStyle()).accessibilityIdentifier("editPlan")
                }
                Text(plan.pitch).font(MFont.body)
                ForEach(plan.perks, id: \.self) { Label($0, systemImage: "checkmark").font(MFont.subheadline) }
            }
            .padding(MSpacing.l).frame(maxWidth: .infinity, alignment: .leading).glass()

            if !env.social.earningsBreakdown.isEmpty {
                VStack(alignment: .leading, spacing: MSpacing.s) {
                    Text("WHERE IT CAME FROM").font(MFont.eyebrow).foregroundStyle(MColor.textSecondary).tracking(1)
                    ForEach(env.social.earningsBreakdown, id: \.label) { row in
                        HStack { Text(row.label).font(MFont.subheadline); Spacer(); Text(row.amount, format: .currency(code: "INR").precision(.fractionLength(0))).font(.subheadline.weight(.semibold)).monospacedDigit() }
                    }
                }
                .padding(MSpacing.l).frame(maxWidth: .infinity, alignment: .leading).glass()
            }

            if let progress = env.social.goalProgress(for: plan) {
                VStack(alignment: .leading, spacing: MSpacing.s) {
                    Text(plan.goalTitle.isEmpty ? "Your goal" : plan.goalTitle).font(MFont.headline)
                    ProgressView(value: progress.fraction).tint(.orange)
                    Text("\(progress.raised.formatted(.currency(code: "INR").precision(.fractionLength(0)))) of \((Double(plan.goalAmountMinor) / 100).formatted(.currency(code: "INR").precision(.fractionLength(0)))) this month").font(MFont.caption).foregroundStyle(MColor.textSecondary)
                }
                .padding(MSpacing.l).frame(maxWidth: .infinity, alignment: .leading).glass(tint: .orange)
            }

            Button { showMass = true } label: { Label("Message all subscribers", systemImage: "megaphone.fill").frame(maxWidth: .infinity) }
                .buttonStyle(SecondaryButtonStyle()).accessibilityIdentifier("massMessage")

            if !env.social.topSupporters.isEmpty {
                VStack(alignment: .leading, spacing: MSpacing.m) {
                    Text("TOP SUPPORTERS").font(MFont.eyebrow).foregroundStyle(MColor.textSecondary).tracking(1)
                    ForEach(env.social.topSupporters, id: \.id) { s in
                        HStack(spacing: MSpacing.m) {
                            AvatarView(userID: s.id, name: s.name, size: 34)
                            Text(s.name).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(s.amount, format: .currency(code: "INR").precision(.fractionLength(0))).font(.subheadline.weight(.semibold)).monospacedDigit()
                        }
                    }
                    Text("This month, across subscriptions, sets, requests and tips.").font(MFont.footnote).foregroundStyle(MColor.textTertiary)
                }
                .padding(MSpacing.l).frame(maxWidth: .infinity, alignment: .leading).glass()
            }

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
                    Text("₹").font(MFont.hero).foregroundStyle(MColor.textSecondary)
                    TextField("499", text: $price).keyboardType(.numberPad).font(MFont.hero).accessibilityIdentifier("planPrice")
                }
                .padding(.horizontal, MSpacing.l).padding(.vertical, MSpacing.m).glass(radius: 16)
                Text(env.social.rail == .web
                     ? "Your price, charged on card checkout. MOMENT keeps \(Int(CreatorEconomics.platformFee * 100))%."
                     : "Your price. Through the App Store the charge is the nearest product Apple sells (\(env.social.appStorePrice(for: draftPlan))), and Apple takes \(Int(CreatorEconomics.appStoreShare * 100))% — card checkout charges exactly what you set.")
                    .font(MFont.footnote).foregroundStyle(MColor.textTertiary)
            }

            VStack(alignment: .leading, spacing: MSpacing.s) {
                Text("BUNDLES").font(MFont.eyebrow).foregroundStyle(MColor.textSecondary).tracking(1)
                ForEach([3, 6, 12], id: \.self) { months in
                    HStack(spacing: MSpacing.m) {
                        Text("\(months) months").font(MFont.body).frame(width: 96, alignment: .leading)
                        Stepper("\(discount(months))% off", value: Binding(get: { discount(months) }, set: { setDiscount(months, $0) }), in: 0...60, step: 5)
                        if discount(months) > 0, priceMinor > 0 {
                            Text((Double(CreatorPlan.Bundle(months: months, discountPercent: discount(months)).totalMinor(monthly: priceMinor)) / 100).formatted(.currency(code: "INR").precision(.fractionLength(0))))
                                .font(.subheadline.weight(.semibold)).monospacedDigit()
                        }
                    }
                    .padding(.horizontal, MSpacing.m).padding(.vertical, 8).glass(radius: 12)
                    .accessibilityIdentifier("bundle-\(months)")
                }
                Text("People who commit for longer churn less. 0% means that length isn't offered.").font(MFont.footnote).foregroundStyle(MColor.textTertiary)
            }

            VStack(alignment: .leading, spacing: MSpacing.s) {
                Text("A GOAL (OPTIONAL)").font(MFont.eyebrow).foregroundStyle(MColor.textSecondary).tracking(1)
                TextField("What you're saving for", text: $goalTitle).padding(.horizontal, MSpacing.l).padding(.vertical, 10).glass(radius: 14).accessibilityIdentifier("goalTitle")
                HStack(spacing: MSpacing.s) {
                    Text("₹").foregroundStyle(MColor.textSecondary)
                    TextField("Amount", text: $goalAmount).keyboardType(.numberPad).accessibilityIdentifier("goalAmount")
                }
                .padding(.horizontal, MSpacing.l).padding(.vertical, 10).glass(radius: 14)
                Text("Shown on your profile with the real total tipped this month. Nothing is padded.").font(MFont.footnote).foregroundStyle(MColor.textTertiary)
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
                Task {
                    let bs = bundles.filter { $0.value > 0 }.map { CreatorPlan.Bundle(months: $0.key, discountPercent: $0.value) }.sorted { $0.months < $1.months }
                    if await env.social.savePlan(title: title, pitch: pitch, priceMinor: priceMinor, perks: perks, payoutHint: payoutHint, bundles: bs, goalTitle: goalTitle, goalAmountMinor: (Int(goalAmount.filter(\.isNumber)) ?? 0) * 100) { editing = false }
                    saving = false
                }
            } label: { Text(plan == nil ? "Start selling" : "Save") }
                .buttonStyle(PrimaryButtonStyle(tint: .orange)).disabled(title.isBlank || pitch.isBlank || priceMinor == 0 || saving)
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
                    if !plan.bundles.isEmpty {
                        VStack(alignment: .leading, spacing: MSpacing.s) {
                            Text("SAVE BY COMMITTING").font(MFont.eyebrow).tracking(1).foregroundStyle(MColor.textSecondary)
                            ForEach(plan.bundles) { b in
                                Button {
                                    Task { if await env.social.subscribe(to: creatorID, bundle: b) { done = true; Haptics.saved(); try? await Task.sleep(for: .seconds(1.2)); dismiss() } }
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(b.label).font(.subheadline.weight(.semibold))
                                            Text("\((Double(b.perMonthMinor(monthly: plan.priceMinor)) / 100).formatted(.currency(code: plan.currency).precision(.fractionLength(0))))/month").font(MFont.caption).foregroundStyle(MColor.textSecondary)
                                        }
                                        Spacer()
                                        Text("\(b.discountPercent)% off").font(MFont.caption).foregroundStyle(.orange)
                                        Text(plan.bundleLabel(b)).font(.subheadline.weight(.bold))
                                    }
                                    .padding(MSpacing.m)
                                }
                                .buttonStyle(.plain).glass(radius: 14)
                                .accessibilityIdentifier("bundle-\(b.months)")
                            }
                        }
                    }
                    Button {
                        Task {
                            if await env.social.subscribe(to: creatorID) {
                                done = true; Haptics.saved()
                                try? await Task.sleep(for: .seconds(1.2)); dismiss()   // the unlocked Moment is right behind this sheet
                            }
                        }
                    } label: {
                        if env.social.purchasing { ProgressView().tint(.white) } else { Text("Subscribe · \(plan.priceLabel()) for 30 days") }
                    }
                    .buttonStyle(PrimaryButtonStyle(tint: .orange)).disabled(env.social.purchasing)
                    .accessibilityIdentifier("subscribeButton")
                    Text(env.social.rail == .web
                         ? "One payment, 30 days, no auto-renew. \(plan.creatorName) set this price and keeps \(Int((1 - CreatorEconomics.platformFee) * 100))% of it."
                         : "One payment through the App Store, no auto-renew. Apple charges \(env.social.appStorePrice(for: plan)) — the nearest product to \(plan.priceLabel()).")
                        .font(MFont.footnote).foregroundStyle(MColor.textTertiary)
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
                    Text(env.social.plan(for: moment.creatorID).map { "Unlock · \($0.priceLabel())" } ?? "Subscribe")
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
                        Text(env.social.plan(for: s.creatorID)?.priceLabel() ?? "").font(MFont.caption).foregroundStyle(MColor.textSecondary)
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

/// One message to everyone who subscribes — optionally locked behind a price.
struct MassMessageSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var item: PhotosPickerItem?
    @State private var data: Data?
    @State private var locked = false
    @State private var price = "499"
    @State private var sentTo: Int?

    private var count: Int { env.social.activeSubscriberCount }

    var body: some View {
        VStack(alignment: .leading, spacing: MSpacing.l) {
            Text("Message \(count) \(count == 1 ? "subscriber" : "subscribers")").font(MFont.title)
            TextField("What do you want to say?", text: $text, axis: .vertical).lineLimit(2...5).padding(MSpacing.m).glass(radius: 14).accessibilityIdentifier("massText")
            PhotosPicker(selection: $item, matching: .images) {
                HStack { Image(systemName: data == nil ? "photo.badge.plus" : "checkmark.circle.fill"); Text(data == nil ? "Attach a photo" : "Photo attached") }
                    .font(MFont.subheadline).padding(MSpacing.m).frame(maxWidth: .infinity, alignment: .leading).glass(radius: 14)
            }
            if data != nil {
                Toggle("Lock it behind a price", isOn: $locked).accessibilityIdentifier("massLock")
                if locked {
                    HStack(spacing: MSpacing.s) {
                        Text("₹").foregroundStyle(MColor.textSecondary)
                        TextField("499", text: $price).keyboardType(.numberPad).accessibilityIdentifier("massPrice")
                    }
                    .padding(.horizontal, MSpacing.l).padding(.vertical, 10).glass(radius: 14)
                }
            }
            Spacer(minLength: 0)
            if let sentTo {
                Label("Sent to \(sentTo).", systemImage: "checkmark.seal.fill").font(MFont.headline)
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle())
            } else {
                Button {
                    Task { sentTo = await env.social.massMessage(text: text, photo: data, priceMinor: locked ? (Int(price.filter(\.isNumber)) ?? 0) * 100 : 0) }
                } label: { if env.social.busy { ProgressView().tint(.white) } else { Text("Send to everyone").frame(maxWidth: .infinity) } }
                .buttonStyle(PrimaryButtonStyle(tint: .orange)).disabled((text.isBlank && data == nil) || count == 0 || env.social.busy).accessibilityIdentifier("sendMass")
                Text("Each person gets it in their own chat — nobody sees anyone else.").font(MFont.footnote).foregroundStyle(MColor.textTertiary)
            }
        }
        .padding(MSpacing.page).background(LiquidBackdrop(tint: .orange))
        .onChange(of: item) { _, i in Task { if let i, let d = try? await i.loadTransferable(type: Data.self) { data = d } } }
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        .modifier(SocialErrorAlert())
    }
}
