import SwiftUI
import PhotosUI

// MARK: - Fan side: a creator's storefront

/// What a creator sells: free sets to look at, paid sets to unlock, time to book, links to elsewhere.
struct StorefrontView: View {
    @Environment(AppEnvironment.self) private var env
    let creatorID: String
    var creatorName: String
    @State private var buying: VaultSet?
    @State private var booking: BookingOffer?
    @State private var asking = false

    private var sets: [VaultSet] { env.social.sets(of: creatorID) }
    private var offers: [BookingOffer] { env.social.offers(of: creatorID).filter(\.active) }
    private var links: CreatorLinks { env.social.links(of: creatorID) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MSpacing.xl) {
                if let plan = env.social.plan(for: creatorID) {
                    NavigationLink(value: SocialRoute.profile(creatorID)) {
                        HStack(spacing: MSpacing.m) {
                            Image(systemName: "crown.fill").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) { Text(plan.title).font(MFont.headline); Text("Subscription · \(plan.priceLabel()) / 30 days").font(MFont.caption).foregroundStyle(MColor.textSecondary) }
                            Spacer(); Image(systemName: "chevron.right").font(.footnote).foregroundStyle(MColor.textTertiary)
                        }
                        .padding(MSpacing.l)
                    }
                    .buttonStyle(.plain).glass(radius: 16, tint: .orange)
                }
                if !sets.isEmpty {
                    Text("SETS").font(MFont.eyebrow).tracking(1).foregroundStyle(MColor.textSecondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: MSpacing.m)], spacing: MSpacing.m) {
                        ForEach(sets) { s in SetTile(set: s) { buying = s } }
                    }
                }
                if !offers.isEmpty {
                    Text("TIME").font(MFont.eyebrow).tracking(1).foregroundStyle(MColor.textSecondary)
                    ForEach(offers) { o in
                        Button { booking = o } label: {
                            HStack(spacing: MSpacing.m) {
                                Image(systemName: o.kind.symbol).font(.title3).foregroundStyle(MColor.accent).frame(width: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(o.minutes > 0 ? "\(o.kind.label) · \(o.minutes) min" : o.kind.label).font(MFont.headline).foregroundStyle(MColor.textPrimary)
                                    if !o.note.isEmpty { Text(o.note).font(MFont.footnote).foregroundStyle(MColor.textSecondary).lineLimit(2) }
                                }
                                Spacer()
                                Text(o.priceLabel()).font(.subheadline.weight(.semibold)).foregroundStyle(MColor.textPrimary)
                            }
                            .padding(MSpacing.l)
                        }
                        .buttonStyle(.plain).glass(radius: 16)
                        .accessibilityIdentifier("offer-\(o.id)")
                    }
                }
                VStack(alignment: .leading, spacing: MSpacing.s) {
                    Text("ASK FOR SOMETHING ELSE").font(MFont.eyebrow).tracking(1).foregroundStyle(MColor.textSecondary)
                    Button { asking = true } label: {
                        HStack(spacing: MSpacing.m) {
                            Image(systemName: "hand.raised.fill").font(.title3).foregroundStyle(MColor.accent).frame(width: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Ask \(creatorName.split(separator: " ").first.map(String.init) ?? creatorName)").font(MFont.headline).foregroundStyle(MColor.textPrimary)
                                Text("A photo, a call, a meeting — they name the price for that one thing.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                            }
                            Spacer(); Image(systemName: "chevron.right").font(.footnote).foregroundStyle(MColor.textTertiary)
                        }
                        .padding(MSpacing.l)
                    }
                    .buttonStyle(.plain).glass(radius: 16).accessibilityIdentifier("askCreator")
                }
                if !links.all.isEmpty {
                    Text("ELSEWHERE").font(MFont.eyebrow).tracking(1).foregroundStyle(MColor.textSecondary)
                    FlowRow(links.all.map { ($0.label, $0.handle, $0.url) })
                }
                if sets.isEmpty && offers.isEmpty && env.social.plan(for: creatorID) == nil {
                    Text("\(creatorName) isn't selling anything yet.").font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
                }
            }
            .padding(MSpacing.page).padding(.bottom, 90)
        }
        .background(LiquidBackdrop(tint: .orange))
        .navigationTitle(creatorName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await env.social.loadStorefront(creatorID) }
        .sheet(item: $buying) { s in BuySetSheet(set: s) }
        .sheet(item: $booking) { o in BookSheet(offer: o) }
        .sheet(isPresented: $asking) { AskSheet(creatorID: creatorID, creatorName: creatorName) }
        .modifier(SocialErrorAlert())
    }
}

private struct FlowRow: View {
    let items: [(String, String, URL)]
    init(_ items: [(String, String, URL)]) { self.items = items }
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MSpacing.s) {
                ForEach(items, id: \.2) { label, handle, url in
                    Link(destination: url) { HStack(spacing: 6) { Image(systemName: "link"); Text("\(label) · \(handle)") }.font(MFont.caption).padding(.horizontal, 12).padding(.vertical, 8) }
                        .glassPill().accessibilityIdentifier("link-\(label)")
                }
            }
        }
    }
}

struct SetTile: View {
    @Environment(AppEnvironment.self) private var env
    let set: VaultSet
    var onBuy: () -> Void
    private var unlocked: Bool { env.social.isUnlocked(set) }
    var body: some View {
        Group {
            if unlocked {
                NavigationLink(value: SocialRoute.vaultSet(set.id)) { tile }
            } else {
                Button(action: onBuy) { tile }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("set-\(set.id)")
    }
    private var tile: some View {
        ZStack(alignment: .bottomLeading) {
            SocialImage(ref: set.cover).aspectRatio(3/4, contentMode: .fill).frame(maxWidth: .infinity)
                .blur(radius: unlocked ? 0 : 18)
            if !unlocked {
                VStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.title3).foregroundStyle(.white)
                    Text(set.priceLabel()).font(.subheadline.weight(.bold)).foregroundStyle(.white)
                    Text("\(set.itemCount) \(set.isVideo ? "clips" : "photos")").font(.caption2).foregroundStyle(.white.opacity(0.85))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                Text(set.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(2)
                Text(unlocked ? (set.isFree ? "Free · \(set.itemCount)" : "Yours · \(set.itemCount)") : (set.subscribersOnly ? "Subscribers" : set.priceLabel())).font(.caption2).foregroundStyle(.white.opacity(0.85))
            }
            .padding(MSpacing.s)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
    }
}

/// Inside a set you own (or a free one).
struct VaultSetView: View {
    @Environment(AppEnvironment.self) private var env
    let setID: String
    private var set: VaultSet? { env.social.setsByCreator.values.flatMap { $0 }.first { $0.id == setID } }
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6)], spacing: 6) {
                ForEach(env.social.items(setID)) { item in
                    SecureMediaView(ref: item.media, creatorID: set?.creatorID ?? "")
                        .aspectRatio(3/4, contentMode: .fill).clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(MSpacing.m)
            if let s = set, !s.isFree {
                Label("Screenshots of this set come out blank, and every view carries your MOMENT ID. A photo taken with another phone can still be traced to you.", systemImage: "eye.slash")
                    .font(MFont.footnote).foregroundStyle(MColor.textTertiary).padding(.horizontal, MSpacing.page)
            }
            if env.social.items(setID).isEmpty { Text("Nothing here yet.").font(MFont.subheadline).foregroundStyle(MColor.textSecondary).padding(MSpacing.xl) }
            if let s = set, !s.blurb.isEmpty { Text(s.blurb).font(MFont.subheadline).foregroundStyle(MColor.textSecondary).padding(MSpacing.page) }
        }
        .background(LiquidBackdrop())
        .navigationTitle(set?.title ?? "Set")
        .navigationBarTitleDisplayMode(.inline)
        // "Seen" means opened, not tapped — so the feed only demotes a post you actually looked at.
        .task { await env.social.loadItems(setID); env.social.markSetSeen(setID) }
    }
}

/// Pay for a set. Free sets unlock in place; paid ones go through whichever rail is on.
struct BuySetSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let set: VaultSet
    @State private var done = false
    var body: some View {
        VStack(alignment: .leading, spacing: MSpacing.l) {
            SocialImage(ref: set.cover).frame(height: 220).blur(radius: 14).clipShape(RoundedRectangle(cornerRadius: 18))
            Text(set.title).font(MFont.title)
            if !set.blurb.isEmpty { Text(set.blurb).font(MFont.body).foregroundStyle(MColor.textSecondary) }
            Label("\(set.itemCount) \(set.isVideo ? "clips" : "photos") from \(set.creatorName)", systemImage: "photo.stack").font(MFont.subheadline)
            Spacer(minLength: 0)
            if done {
                Label("Unlocked.", systemImage: "checkmark.seal.fill").font(MFont.headline)
                Button("See it") { dismiss() }.buttonStyle(PrimaryButtonStyle())
            } else if set.subscribersOnly {
                NavigationLink(value: SocialRoute.profile(set.creatorID)) { Text("Subscribe to open this").frame(maxWidth: .infinity) }
                    .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("goSubscribe")
                Text("This one comes with \(set.creatorName)'s subscription rather than a separate price.").font(MFont.footnote).foregroundStyle(MColor.textTertiary)
            } else {
                Button {
                    if env.social.rail == .web, let base = URL(string: env.settings.checkoutBaseURL), !env.settings.checkoutBaseURL.isBlank {
                        // The creator's own checkout. We record the purchase when they come back with a reference.
                        openURL(base.appending(path: "set/\(set.id)"))
                    } else {
                        Task { if await env.social.buySet(set) { done = true; Haptics.saved() } }
                    }
                } label: {
                    if env.social.busy { ProgressView().tint(.white) } else { Text(set.isFree ? "Unlock — free" : "Buy · \(set.priceLabel())") }
                }
                .buttonStyle(PrimaryButtonStyle(tint: .orange)).disabled(env.social.busy).accessibilityIdentifier("buySet")
                Text(set.isFree ? "The creator made this one free." : "\(set.creatorName) sets the price and keeps \(Int((1 - CreatorEconomics.platformFee) * 100))% on card checkout. Media stays on their storage; buying gets you the key, not a copy from us.")
                    .font(MFont.footnote).foregroundStyle(MColor.textTertiary)
            }
        }
        .padding(MSpacing.page).background(LiquidBackdrop(tint: .orange))
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        .modifier(SocialErrorAlert())
    }
}

/// Book time: pick when, say what you want, pay.
struct BookSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let offer: BookingOffer
    @State private var when = Date().addingTimeInterval(3600)
    @State private var slot: Date?
    @State private var note = ""
    @State private var sent = false
    @State private var loadedHours = false

    private var availability: CreatorAvailability? { env.social.availabilityByCreator[offer.creatorID] }
    /// A call is booked into the creator's hours. A shoot or a custom is a conversation, so it keeps
    /// the open date picker.
    private var usesSlots: Bool { offer.kind.hasDuration && (availability?.isOpen ?? false) }
    private var chosen: Date { usesSlots ? (slot ?? when) : when }
    private var canSend: Bool { !env.social.busy && (!usesSlots || slot != nil) }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: MSpacing.l) {
            Text(offer.minutes > 0 ? "\(offer.kind.label) · \(offer.minutes) min" : offer.kind.label).font(MFont.title)
            if !offer.note.isEmpty { Text(offer.note).font(MFont.body).foregroundStyle(MColor.textSecondary) }
            if usesSlots, let a = availability {
                SlotPicker(slots: env.social.slots(for: offer), creatorZone: a.timeZone, selection: $slot)
            } else {
                if offer.kind.hasDuration {
                    Text("They haven't set hours yet — pick a time and they'll confirm or suggest another.")
                        .font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                }
                DatePicker("When", selection: $when, in: Date()...).datePickerStyle(.compact)
            }
            TextField("Anything they should know", text: $note, axis: .vertical).lineLimit(2...4).padding(MSpacing.m).glass(radius: 14)
            Spacer(minLength: 0)
            if sent {
                Label("Requested. They'll confirm.", systemImage: "checkmark.seal.fill").font(MFont.headline)
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle())
            } else {
                Button { Task { if await env.social.requestBooking(offer, startsAt: chosen, note: note) != nil { sent = true; Haptics.saved() } } } label: {
                    if env.social.busy { ProgressView().tint(.white) } else { Text("Request · \(offer.priceLabel())") }
                }
                .buttonStyle(PrimaryButtonStyle(tint: .orange)).disabled(!canSend).accessibilityIdentifier("requestBooking")
                Text(offer.kind.isCall
                     ? "Nothing is charged until they accept. The call happens in MOMENT, and the clock only starts when you're both connected."
                     : "Nothing is charged until they accept. They can decline; you can cancel.")
                    .font(MFont.footnote).foregroundStyle(MColor.textTertiary)
            }
        }
        .padding(MSpacing.page)
        }
        .background(LiquidBackdrop(tint: .orange))
        .task { if !loadedHours { await env.social.loadAvailability(offer.creatorID); loadedHours = true } }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        .modifier(SocialErrorAlert())
    }
}

/// Looks up whose storefront this is, so the route only has to carry an id.
struct StorefrontResolver: View {
    @Environment(AppEnvironment.self) private var env
    let creatorID: String
    @State private var name = "Creator"
    var body: some View {
        StorefrontView(creatorID: creatorID, creatorName: name)
            .task {
                if creatorID == env.social.myID { name = env.social.displayName }
                else if let u = await env.social.user(creatorID) { name = u.displayName }
                else { name = env.social.sets(of: creatorID).first?.creatorName ?? env.social.plan(for: creatorID)?.creatorName ?? "Creator" }
            }
    }
}

// MARK: - Creator side: Studio

/// Everything a creator runs: what they sell, what they've made, who's booked them, where else to find them.
struct StudioView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var editing: VaultSet?
    @State private var newSet = false
    @State private var editOffer: BookingOffer?
    @State private var showLinks = false
    @State private var showMass = false

    @State private var showHours = false
    private var pendingRequests: [Booking] { env.social.myBookings.filter { $0.creatorID == env.social.myID && ($0.status == .asked || $0.status == .requested) } }
    /// What the creator's hours amount to, so the row says something true before they tap it.
    private var hoursSummary: String {
        let a = env.social.myAvailability
        guard a.acceptingBookings else { return "Paused — nobody can book a call" }
        guard !a.windows.isEmpty else { return "Not set — calls can't be booked yet" }
        let days = Set(a.windows.map(\.weekday)).count
        return "\(a.windows.count) window\(a.windows.count == 1 ? "" : "s") across \(days) day\(days == 1 ? "" : "s")"
    }
    private var plan: CreatorPlan? { env.social.myPlan }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MSpacing.xl) {
                earnings
                if !env.social.isCreator { setUp } else { quickActions }
                if !pendingRequests.isEmpty { requests }
                sets
                time
                if !env.social.topSupporters.isEmpty { supporters }
                footerLinks
            }
            .padding(.horizontal, MSpacing.page)
            .padding(.top, MSpacing.s)
            .padding(.bottom, 90)
        }
        .background(MColor.background)
        .navigationTitle("Creator mode")
        .navigationBarTitleDisplayMode(.inline)
        .task { await env.social.refreshStorefront(); await env.social.refreshCreator(); await env.social.loadAvailability(env.social.myID) }
        .sheet(isPresented: $newSet) { EditSetSheet(set: nil) }
        .sheet(isPresented: $showHours) { AvailabilityEditor() }
        .sheet(item: $editing) { s in EditSetSheet(set: s) }
        .sheet(item: $editOffer) { o in EditOfferSheet(offer: o) }
        .sheet(isPresented: $showLinks) { LinksSheet() }
        .sheet(isPresented: $showMass) { MassMessageSheet() }
        .modifier(SocialErrorAlert())
    }

    // MARK: The number, and where it came from

    /// Nothing earned yet and nobody subscribed: a 44pt ₹0 over a third of the screen is a discouraging
    /// way to open, and the setup steps underneath are the useful thing. One line is enough until
    /// there's something to show.
    private var hasEarned: Bool {
        env.social.storefrontEarnings > 0 || env.social.activeSubscriberCount > 0 || !env.social.mySales.isEmpty
    }

    private var earnings: some View {
        VStack(alignment: .leading, spacing: hasEarned ? MSpacing.m : MSpacing.s) {
            Text("THIS MONTH").font(MFont.eyebrow).tracking(1).foregroundStyle(.white.opacity(0.8))
            Text(env.social.storefrontEarnings, format: .currency(code: "INR").precision(.fractionLength(0)))
                .font(.system(size: hasEarned ? 44 : 30, weight: .bold)).monospacedDigit().foregroundStyle(.white)
                .accessibilityIdentifier("studioEarnings")
            if !hasEarned {
                Text("Nothing yet. The three steps below are how it starts.")
                    .font(MFont.caption).foregroundStyle(.white.opacity(0.85))
            }
            if hasEarned {
                HStack(spacing: MSpacing.l) {
                    metric("\(env.social.activeSubscriberCount)", "subscribers")
                    metric("\(env.social.mySales.count)", "sales")
                    metric("\(env.social.myBookings.filter { $0.creatorID == env.social.myID && $0.status.isPaid }.count)", "requests")
                }
            }
            if !env.social.earningsBreakdown.isEmpty {
                VStack(spacing: 6) {
                    ForEach(env.social.earningsBreakdown, id: \.label) { row in
                        HStack {
                            Text(row.label).font(MFont.caption).foregroundStyle(.white.opacity(0.85))
                            Spacer()
                            Text(row.amount, format: .currency(code: "INR").precision(.fractionLength(0))).font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.white)
                        }
                    }
                }
                .padding(.top, 2)
            }
            if hasEarned {
                Text(env.social.rail == .web
                     ? "Card checkout: you keep \(Int((1 - CreatorEconomics.platformFee) * 100))%."
                     : "Through Apple: Apple takes \(Int(CreatorEconomics.appStoreShare * 100))% first. Card checkout is the \(Int((1 - CreatorEconomics.platformFee) * 100))% rail.")
                    .font(.caption2).foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(MSpacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [MColor.accent, MColor.accent.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.headline.weight(.bold)).monospacedDigit().foregroundStyle(.white)
            Text(label).font(.caption2).foregroundStyle(.white.opacity(0.8))
        }
    }

    /// Before there's anything to sell, one path forward instead of an empty dashboard.
    private var setUp: some View {
        VStack(alignment: .leading, spacing: MSpacing.m) {
            Text("Set up in two minutes").font(MFont.title)
            step(1, "Post a free set", "It's how people find you.") { newSet = true }
            step(2, "Name your subscription", "One price, 30 days, your call.") { }
            step(3, "Say what you'll do", "Calls, customs — or let people just ask.") { editOffer = BookingOffer(id: "", creatorID: "", creatorName: "", kind: .videoCall, minutes: 15, priceMinor: 99900, currency: "INR", note: "", active: true) }
            NavigationLink(value: SocialRoute.earn) { Text("Set your subscription").frame(maxWidth: .infinity) }
                .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("setUpPlan")
        }
        .padding(MSpacing.l).frame(maxWidth: .infinity, alignment: .leading).glass()
    }
    private func step(_ n: Int, _ title: String, _ detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: MSpacing.m) {
                Text("\(n)").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 26, height: 26).background(Circle().fill(MColor.accent))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(MColor.textPrimary)
                    Text(detail).font(MFont.caption).foregroundStyle(MColor.textSecondary)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Everything a creator does, one tap away

    private var quickActions: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: MSpacing.s)], spacing: MSpacing.s) {
            action("New set", "plus.rectangle.on.folder", id: "newSet") { newSet = true }
            action("Message all", "megaphone.fill", id: "massMessage") { showMass = true }
            action("Subscription", "crown.fill", id: "editPlanLink") { }
                .overlay { NavigationLink(value: SocialRoute.earn) { Color.clear }.opacity(0.001) }
            action("Sell time", "video.fill", id: "newOffer") { editOffer = BookingOffer(id: "", creatorID: "", creatorName: "", kind: .videoCall, minutes: 15, priceMinor: 99900, currency: "INR", note: "", active: true) }
            action("Requests", "tray.full.fill", id: "bookingsLink") { }
                .overlay { NavigationLink(value: SocialRoute.bookings) { Color.clear }.opacity(0.001) }
            action("Handles", "link", id: "linksButton") { showLinks = true }
        }
    }
    private func action(_ title: String, _ symbol: String, id: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.title3).foregroundStyle(MColor.accent)
                Text(title).font(MFont.caption).foregroundStyle(MColor.textPrimary).lineLimit(1)
            }
            .frame(maxWidth: .infinity).padding(.vertical, MSpacing.m)
        }
        .buttonStyle(.plain).glass(radius: 16).accessibilityIdentifier(id)
    }

    private var requests: some View {
        VStack(alignment: .leading, spacing: MSpacing.m) {
            HStack {
                Text("WAITING ON YOU").font(MFont.eyebrow).tracking(1).foregroundStyle(MColor.textSecondary)
                Spacer()
                Text("\(pendingRequests.count)").font(MFont.caption).padding(.horizontal, 8).padding(.vertical, 3).glassPill(tint: MColor.danger)
            }
            ForEach(pendingRequests.prefix(3)) { b in
                NavigationLink(value: SocialRoute.bookings) {
                    HStack(spacing: MSpacing.m) {
                        AvatarView(userID: b.buyerID, name: b.buyerName, size: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(b.buyerName) · \(b.kind.label.lowercased())").font(.subheadline.weight(.semibold)).foregroundStyle(MColor.textPrimary)
                            Text(b.status == .asked ? "Wants a price" : "Paid — confirm it").font(MFont.caption).foregroundStyle(b.status == .asked ? MColor.textSecondary : MColor.success)
                        }
                        Spacer(); Image(systemName: "chevron.right").font(.footnote).foregroundStyle(MColor.textTertiary)
                    }
                    .padding(MSpacing.m)
                }
                .buttonStyle(.plain).glass(radius: 14)
            }
        }
    }

    private var sets: some View {
        VStack(alignment: .leading, spacing: MSpacing.m) {
            HStack {
                Text("YOUR SETS").font(MFont.eyebrow).tracking(1).foregroundStyle(MColor.textSecondary)
                Spacer()
                Button { newSet = true } label: { Image(systemName: "plus") }.buttonStyle(GlassButtonStyle()).accessibilityLabel("New set")
            }
            if env.social.mySets.isEmpty {
                Text("A free set is how people find you; a paid one is how you earn.").font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: MSpacing.s)], spacing: MSpacing.s) {
                    ForEach(env.social.mySets) { s in
                        SetTile(set: s) {}
                            .contextMenu {
                                Button("Edit", systemImage: "pencil") { editing = s }
                                Button("Delete", systemImage: "trash", role: .destructive) { Task { await env.social.deleteSet(s.id) } }
                            }
                    }
                }
            }
        }
    }

    private var time: some View {
        VStack(alignment: .leading, spacing: MSpacing.m) {
            Text("TIME YOU SELL").font(MFont.eyebrow).tracking(1).foregroundStyle(MColor.textSecondary)
            if env.social.offers(of: env.social.myID).isEmpty {
                Text("Nothing listed. People can still ask, and you name the price then.").font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
            }
            Button { showHours = true } label: {
                HStack(spacing: MSpacing.m) {
                    Image(systemName: "calendar.badge.clock").foregroundStyle(MColor.accent).frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("When you're free").font(.subheadline.weight(.semibold)).foregroundStyle(MColor.textPrimary)
                        Text(hoursSummary).font(MFont.caption).foregroundStyle(MColor.textSecondary)
                    }
                    Spacer(); Image(systemName: "chevron.right").font(.footnote).foregroundStyle(MColor.textTertiary)
                }
                .padding(MSpacing.m)
            }
            .buttonStyle(.plain).glass(radius: 14).accessibilityIdentifier("availabilityLink")
            ForEach(env.social.offers(of: env.social.myID)) { o in
                Button { editOffer = o } label: {
                    HStack(spacing: MSpacing.m) {
                        Image(systemName: o.kind.symbol).foregroundStyle(MColor.accent).frame(width: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(o.minutes > 0 ? "\(o.kind.label) · \(o.minutes) min" : o.kind.label).font(.subheadline.weight(.semibold)).foregroundStyle(MColor.textPrimary)
                            Text(o.active ? "Live" : "Paused").font(MFont.caption).foregroundStyle(o.active ? MColor.success : MColor.textSecondary)
                        }
                        Spacer(); Text(o.priceLabel()).font(.subheadline.weight(.semibold)).foregroundStyle(MColor.textPrimary)
                    }
                    .padding(MSpacing.m)
                }
                .buttonStyle(.plain).glass(radius: 14)
            }
        }
    }

    private var supporters: some View {
        VStack(alignment: .leading, spacing: MSpacing.m) {
            Text("TOP SUPPORTERS").font(MFont.eyebrow).tracking(1).foregroundStyle(MColor.textSecondary)
            ForEach(env.social.topSupporters, id: \.id) { s in
                HStack(spacing: MSpacing.m) {
                    AvatarView(userID: s.id, name: s.name, size: 32)
                    Text(s.name).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(s.amount, format: .currency(code: "INR").precision(.fractionLength(0))).font(.subheadline.weight(.semibold)).monospacedDigit()
                }
            }
            Text("This month, across subscriptions, sets, requests and tips.").font(.caption2).foregroundStyle(MColor.textTertiary)
        }
        .padding(MSpacing.l).frame(maxWidth: .infinity, alignment: .leading).glass()
    }

    private var footerLinks: some View {
        VStack(spacing: MSpacing.s) {
            NavigationLink(value: SocialRoute.storefront(env.social.myID)) { Text("See your shop the way fans do").frame(maxWidth: .infinity) }
                .buttonStyle(SecondaryButtonStyle()).accessibilityIdentifier("previewShop")
            NavigationLink(value: SocialRoute.earn) { Text("Subscription, bundles, goal & payouts").frame(maxWidth: .infinity) }
                .buttonStyle(SecondaryButtonStyle())
        }
    }
}

/// Make or edit a set: pick photos, name it, price it.
struct EditSetSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let set: VaultSet?
    @State private var title = ""
    @State private var blurb = ""
    @State private var price = ""
    enum Access: Hashable { case free, subscribers, price }
    @State private var access: Access = .free
    @State private var picker: [PhotosPickerItem] = []
    @State private var picked: [MediaRef] = []
    @State private var loading = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Photos") {
                    PhotosPicker(selection: $picker, maxSelectionCount: 30, matching: .any(of: [.images, .videos])) { Label(picked.isEmpty ? "Choose photos or video" : "\(picked.count) chosen", systemImage: "photo.on.rectangle") }
                        .accessibilityIdentifier("setPhotos")
                    if loading { ProgressView() }
                    if !picked.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) { ForEach(Array(picked.enumerated()), id: \.offset) { _, r in SocialImage(ref: r).frame(width: 74, height: 98).clipShape(RoundedRectangle(cornerRadius: 10)) } }
                        }
                    }
                }
                Section("Set") {
                    TextField("Title", text: $title).accessibilityIdentifier("setTitle")
                    TextField("A line about it", text: $blurb, axis: .vertical).lineLimit(1...3)
                }
                Section {
                    Picker("Who can open it", selection: $access) {
                        Text("Free").tag(Access.free)
                        Text("Subscribers").tag(Access.subscribers)
                        Text("One-off price").tag(Access.price)
                    }
                    .pickerStyle(.segmented).accessibilityIdentifier("setAccess")
                    if access == .price { TextField("Price (₹)", text: $price).keyboardType(.numberPad).accessibilityIdentifier("setPrice") }
                } footer: {
                    switch access {
                    case .free: Text("Free sets are how people find you.")
                    case .subscribers: Text("Anyone whose subscription is live opens this — that's what they're paying for. It stops opening the day they lapse.")
                    case .price: Text("Bought once, kept. You keep \(Int((1 - CreatorEconomics.platformFee) * 100))% on card checkout, and the photos stay on your storage — buyers get a key.")
                    }
                }
                Section {
                    Button { save() } label: { Text(set == nil ? "Publish set" : "Save").frame(maxWidth: .infinity) }
                        .disabled(title.isBlank || picked.isEmpty || env.social.busy).accessibilityIdentifier("saveSet")
                }
            }
            .scrollContentBackground(.hidden).background(LiquidBackdrop(tint: .orange))
            .navigationTitle(set == nil ? "New set" : "Edit set")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { if let s = set { title = s.title; blurb = s.blurb; access = s.subscribersOnly ? .subscribers : (s.isFree ? .free : .price); price = s.priceMinor > 0 ? String(s.priceMinor / 100) : ""; Task { await env.social.loadItems(s.id); picked = env.social.items(s.id).compactMap(\.media) } } }
            .onChange(of: picker) { _, items in Task { await load(items) } }
        }
    }
    private func load(_ items: [PhotosPickerItem]) async {
        loading = true; defer { loading = false }
        var refs: [MediaRef] = []
        for item in items {
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
            guard let d = try? await item.loadTransferable(type: Data.self) else { continue }
            if let ref = await env.social.storeLocalMedia(d, kind: isVideo ? .video : .photo) { refs.append(ref) }
        }
        picked = refs
    }
    private func save() {
        let minor = access == .price ? max(0, (Int(price.filter(\.isNumber)) ?? 0) * 100) : 0
        var s = set ?? VaultSet(id: "", creatorID: "", creatorName: "", title: "", blurb: "", priceMinor: 0, currency: "INR", cover: nil, itemCount: 0, isVideo: false, createdAt: .now, visible: true)
        s.title = title.trimmed; s.blurb = blurb.trimmed; s.priceMinor = minor; s.subscribersOnly = access == .subscribers
        // A video post needs a still to show before it plays and while it's locked.
        s.isVideo = picked.contains { $0.kind == .video }
        s.cover = picked.first { $0.kind == .photo } ?? picked.first
        let items = picked.enumerated().map { i, r in VaultItem(id: "", setID: s.id, kind: r.kind, media: r, caption: "", index: i) }
        Task { if await env.social.saveSet(s, items: items) != nil { dismiss() } }
    }
}

struct EditOfferSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let offer: BookingOffer
    @State private var kind: BookingOffer.Kind = .videoCall
    @State private var minutes = 15
    @State private var price = "999"
    @State private var note = ""
    @State private var active = true
    var body: some View {
        NavigationStack {
            Form {
                Picker("What", selection: $kind) { ForEach(BookingOffer.Kind.allCases, id: \.self) { Text($0.label).tag($0) } }
                if kind != .custom { Stepper("\(minutes) minutes", value: $minutes, in: 5...120, step: 5) }
                TextField("Price (₹)", text: $price).keyboardType(.numberPad).accessibilityIdentifier("offerPrice")
                TextField("What they get", text: $note, axis: .vertical).lineLimit(1...3)
                Toggle("Live", isOn: $active)
                Section {
                    Button { Task { var o = offer; o.kind = kind; o.minutes = kind == .custom ? 0 : minutes; o.priceMinor = max(0, (Int(price.filter(\.isNumber)) ?? 0) * 100); o.note = note.trimmed; o.active = active; if await env.social.saveOffer(o) != nil { dismiss() } } } label: { Text("Save").frame(maxWidth: .infinity) }
                        .accessibilityIdentifier("saveOffer")
                    if !offer.id.isEmpty { Button("Delete", role: .destructive) { Task { await env.social.deleteOffer(offer.id); dismiss() } } }
                }
            }
            .scrollContentBackground(.hidden).background(LiquidBackdrop(tint: .orange))
            .navigationTitle(offer.id.isEmpty ? "New offer" : "Offer")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { kind = offer.kind; minutes = max(5, offer.minutes); price = String(offer.priceMinor / 100); note = offer.note; active = offer.active }
        }
    }
}

struct LinksSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var l = CreatorLinks()
    var body: some View {
        NavigationStack {
            Form {
                Section("Handles") {
                    TextField("Instagram", text: $l.instagram).textInputAutocapitalization(.never).accessibilityIdentifier("linkInstagram")
                    TextField("X", text: $l.x).textInputAutocapitalization(.never)
                    TextField("TikTok", text: $l.tiktok).textInputAutocapitalization(.never)
                    TextField("YouTube", text: $l.youtube).textInputAutocapitalization(.never)
                    TextField("Website", text: $l.website).textInputAutocapitalization(.never)
                }
                Section { Button { Task { await env.social.saveLinks(l); dismiss() } } label: { Text("Save").frame(maxWidth: .infinity) }.accessibilityIdentifier("saveLinks") }
                    footer: { Text("Shown on your profile. We don't check them — they're yours to claim.") }
            }
            .scrollContentBackground(.hidden).background(LiquidBackdrop(tint: .orange))
            .navigationTitle("Your handles")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { l = env.social.links(of: env.social.myID) }
        }
    }
}

/// Both sides of bookings: what you've asked for, and what people have asked of you.
struct BookingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var quoting: Booking?
    var body: some View {
        List {
            let mine = env.social.myBookings.filter { $0.creatorID == env.social.myID }
            let theirs = env.social.myBookings.filter { $0.buyerID == env.social.myID }
            if !mine.isEmpty {
                Section("People booking you") {
                    ForEach(mine) { b in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { Text(b.buyerName).font(.subheadline.weight(.semibold)); Spacer(); Text(b.status.label).font(MFont.caption).foregroundStyle(MColor.textSecondary) }
                            Text("\(b.kind.label)\(b.minutes > 0 ? " · \(b.minutes) min" : "") · \((Double(b.amountMinor) / 100).formatted(.currency(code: b.currency).precision(.fractionLength(0)))) · \(b.startsAt.formatted(date: .abbreviated, time: .shortened))").font(MFont.caption).foregroundStyle(MColor.textSecondary)
                            if !b.note.isEmpty { Text("“\(b.note)”").font(MFont.caption) }
                            if b.status == .asked {
                                Button("Name your price") { quoting = b }.buttonStyle(GlassButtonStyle(filled: true)).accessibilityIdentifier("quote-\(b.id)")
                            } else if b.status == .quoted {
                                Text("Waiting for them to accept \((Double(b.amountMinor) / 100).formatted(.currency(code: b.currency).precision(.fractionLength(0))))").font(MFont.caption).foregroundStyle(MColor.textSecondary)
                            } else if b.status == .requested {
                                HStack(spacing: MSpacing.s) {
                                    Button("Accept") { Task { await env.social.setBooking(b.id, .accepted) } }.buttonStyle(GlassButtonStyle(filled: true)).accessibilityIdentifier("accept-\(b.id)")
                                    Button("Decline") { Task { await env.social.setBooking(b.id, .declined) } }.buttonStyle(GlassButtonStyle())
                                }
                            } else if b.status == .accepted {
                                HStack(spacing: MSpacing.s) {
                                    if b.isJoinable {
                                        NavigationLink(value: SocialRoute.call(b.id)) {
                                            Label(b.joinWindow().contains(.now) ? "Join now" : "Open call", systemImage: b.kind.symbol)
                                        }
                                        .buttonStyle(GlassButtonStyle(filled: b.joinWindow().contains(.now)))
                                        .accessibilityIdentifier("openCall-\(b.id)")
                                    }
                                    Button("Mark done") { Task { await env.social.setBooking(b.id, .done) } }.buttonStyle(GlassButtonStyle())
                                }
                            } else if b.status == .done, b.connectedAt != nil, let ended = b.endedAt, let started = b.connectedAt {
                                Text("Talked for \(CallClock.label(Int(ended.timeIntervalSince(started)))) · \(b.totalLabel())")
                                    .font(MFont.caption).foregroundStyle(MColor.textSecondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            Section("You booked") {
                if theirs.isEmpty { Text("Nothing yet.").font(MFont.subheadline).foregroundStyle(MColor.textSecondary) }
                ForEach(theirs) { b in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text(b.creatorName).font(.subheadline.weight(.semibold)); Spacer(); Text(b.status.label).font(MFont.caption).foregroundStyle(b.status == .accepted ? MColor.success : MColor.textSecondary) }
                        Text("\(b.kind.label)\(b.kind.hasDuration ? " · \(b.startsAt.formatted(date: .abbreviated, time: .shortened))" : "")").font(MFont.caption).foregroundStyle(MColor.textSecondary)
                        if b.status == .quoted {
                            HStack(spacing: MSpacing.s) {
                                Button("Pay \((Double(b.amountMinor) / 100).formatted(.currency(code: b.currency).precision(.fractionLength(0))))") { Task { await env.social.acceptQuote(b) } }
                                    .buttonStyle(GlassButtonStyle(filled: true)).accessibilityIdentifier("payQuote-\(b.id)")
                                Button("No thanks") { Task { await env.social.setBooking(b.id, .declined) } }.buttonStyle(GlassButtonStyle())
                            }
                        } else if b.isJoinable {
                            NavigationLink(value: SocialRoute.call(b.id)) {
                                Label(b.joinWindow().contains(.now) ? "Join now" : "Open call", systemImage: b.kind.symbol)
                            }
                            .buttonStyle(GlassButtonStyle(filled: b.joinWindow().contains(.now)))
                            .accessibilityIdentifier("openCall-\(b.id)")
                        } else if b.status == .done, let started = b.connectedAt, let ended = b.endedAt {
                            Text("Talked for \(CallClock.label(Int(ended.timeIntervalSince(started)))) · \(b.totalLabel())")
                                .font(MFont.caption).foregroundStyle(MColor.textSecondary)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden).background(LiquidBackdrop(tint: .orange))
        .navigationTitle("Requests")
        .sheet(item: $quoting) { b in QuoteSheet(booking: b) }
        .task { await env.social.refreshStorefront() }
    }
}

/// Ask for something that isn't on the menu. No price yet — the creator answers with one.
struct AskSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let creatorID: String
    let creatorName: String
    @State private var kind: BookingOffer.Kind = .photo
    @State private var note = ""
    @State private var when = Date().addingTimeInterval(86400)
    @State private var sent = false

    var body: some View {
        VStack(alignment: .leading, spacing: MSpacing.l) {
            Text("Ask \(creatorName.split(separator: " ").first.map(String.init) ?? creatorName)").font(MFont.title)
            Text("Say what you want. They'll name a price for it — you pay only if you accept.").font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: MSpacing.s) {
                    ForEach(BookingOffer.Kind.allCases, id: \.self) { k in
                        Button { kind = k } label: { Label(k.label, systemImage: k.symbol) }
                            .buttonStyle(ChipButtonStyle(prominent: kind == k))
                            .accessibilityIdentifier("ask-\(k.rawValue)")
                    }
                }
            }
            TextField(kind == .photo ? "What photo?" : "What do you have in mind?", text: $note, axis: .vertical)
                .lineLimit(2...5).padding(MSpacing.m).glass(radius: 14).accessibilityIdentifier("askNote")
            if kind.hasDuration { DatePicker("When", selection: $when, in: Date()...).datePickerStyle(.compact) }
            Spacer(minLength: 0)
            if sent {
                Label("Asked. You'll get a price in your chat.", systemImage: "checkmark.seal.fill").font(MFont.headline)
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle())
            } else {
                Button { Task { if await env.social.ask(creatorID, kind: kind, note: note, startsAt: when) != nil { sent = true; Haptics.saved() } } } label: {
                    if env.social.busy { ProgressView().tint(.white) } else { Text("Ask for a price") }
                }
                .buttonStyle(PrimaryButtonStyle()).disabled(note.isBlank || env.social.busy).accessibilityIdentifier("sendAsk")
                Text("Nothing is charged now. They can decline, and so can you when you see the price.").font(MFont.footnote).foregroundStyle(MColor.textTertiary)
            }
        }
        .padding(MSpacing.page).background(LiquidBackdrop(tint: .orange))
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        .modifier(SocialErrorAlert())
    }
}

/// The creator's answer: a price for that one request.
struct QuoteSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let booking: Booking
    @State private var price = ""
    @State private var note = ""
    var body: some View {
        VStack(alignment: .leading, spacing: MSpacing.l) {
            Text("Name your price").font(MFont.title)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(booking.buyerName) asked for \(booking.kind.label.lowercased())").font(MFont.headline)
                if !booking.note.isEmpty { Text("“\(booking.note)”").font(MFont.subheadline).foregroundStyle(MColor.textSecondary) }
            }
            .padding(MSpacing.l).frame(maxWidth: .infinity, alignment: .leading).glass(radius: 14)
            HStack(spacing: MSpacing.s) {
                Text("₹").font(MFont.hero).foregroundStyle(MColor.textSecondary)
                TextField("0", text: $price).keyboardType(.numberPad).font(MFont.hero).accessibilityIdentifier("quotePrice")
            }
            .padding(.horizontal, MSpacing.l).padding(.vertical, MSpacing.m).glass(radius: 16)
            TextField("Anything to add", text: $note, axis: .vertical).lineLimit(1...3).padding(MSpacing.m).glass(radius: 14)
            Spacer(minLength: 0)
            Button { Task { if await env.social.quote(booking, amountMinor: (Int(price.filter(\.isNumber)) ?? 0) * 100, note: note) != nil { dismiss() } } } label: { Text("Send price").frame(maxWidth: .infinity) }
                .buttonStyle(PrimaryButtonStyle(tint: .orange)).disabled((Int(price.filter(\.isNumber)) ?? 0) == 0).accessibilityIdentifier("sendQuote")
            Button("Decline", role: .destructive) { Task { await env.social.setBooking(booking.id, .declined); dismiss() } }.frame(maxWidth: .infinity)
            Text("You keep \(Int((1 - CreatorEconomics.platformFee) * 100))% on card checkout. They pay only if they accept.").font(MFont.footnote).foregroundStyle(MColor.textTertiary)
        }
        .padding(MSpacing.page).background(LiquidBackdrop(tint: .orange))
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        .modifier(SocialErrorAlert())
    }
}
