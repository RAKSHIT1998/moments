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
                Text(unlocked ? (set.isFree ? "Free · \(set.itemCount)" : "Yours · \(set.itemCount)") : set.priceLabel()).font(.caption2).foregroundStyle(.white.opacity(0.85))
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
        .task { await env.social.loadItems(setID) }
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
    @State private var note = ""
    @State private var sent = false
    var body: some View {
        VStack(alignment: .leading, spacing: MSpacing.l) {
            Text(offer.minutes > 0 ? "\(offer.kind.label) · \(offer.minutes) min" : offer.kind.label).font(MFont.title)
            if !offer.note.isEmpty { Text(offer.note).font(MFont.body).foregroundStyle(MColor.textSecondary) }
            DatePicker("When", selection: $when, in: Date()...).datePickerStyle(.compact)
            TextField("Anything they should know", text: $note, axis: .vertical).lineLimit(2...4).padding(MSpacing.m).glass(radius: 14)
            Spacer(minLength: 0)
            if sent {
                Label("Requested. They'll confirm.", systemImage: "checkmark.seal.fill").font(MFont.headline)
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle())
            } else {
                Button { Task { if await env.social.requestBooking(offer, startsAt: when, note: note) != nil { sent = true; Haptics.saved() } } } label: {
                    if env.social.busy { ProgressView().tint(.white) } else { Text("Request · \(offer.priceLabel())") }
                }
                .buttonStyle(PrimaryButtonStyle(tint: .orange)).disabled(env.social.busy).accessibilityIdentifier("requestBooking")
                Text("Nothing is charged until they accept. They can decline; you can cancel.").font(MFont.footnote).foregroundStyle(MColor.textTertiary)
            }
        }
        .padding(MSpacing.page).background(LiquidBackdrop(tint: .orange))
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MSpacing.xl) {
                VStack(alignment: .leading, spacing: MSpacing.s) {
                    Text("THIS MONTH").font(MFont.eyebrow).tracking(1).foregroundStyle(MColor.textSecondary)
                    Text(env.social.storefrontEarnings, format: .currency(code: "INR").precision(.fractionLength(0))).font(MFont.hero).monospacedDigit().accessibilityIdentifier("studioEarnings")
                    Text("\(env.social.mySales.count) \(env.social.mySales.count == 1 ? "sale" : "sales") · \(env.social.activeSubscriberCount) subscribers · \(env.social.myBookings.filter { $0.creatorID == env.social.myID && $0.status == .accepted }.count) booked")
                        .font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
                    Text(env.social.rail == .web
                         ? "Card checkout: you keep \(Int((1 - CreatorEconomics.platformFee) * 100))% — MOMENT takes \(Int(CreatorEconomics.platformFee * 100))%, your processor takes its own cut."
                         : "App Store: Apple takes \(Int(CreatorEconomics.appStoreShare * 100))% first, then you keep \(Int(CreatorEconomics.creatorShare * 100))% of what's left. Card checkout is the \(Int((1 - CreatorEconomics.platformFee) * 100))% rail.")
                        .font(MFont.footnote).foregroundStyle(MColor.textTertiary)
                }
                .padding(MSpacing.l).frame(maxWidth: .infinity, alignment: .leading).glass(tint: .orange)

                HStack {
                    Text("SETS").font(MFont.eyebrow).tracking(1).foregroundStyle(MColor.textSecondary)
                    Spacer()
                    Button { newSet = true } label: { Label("New set", systemImage: "plus") }.buttonStyle(GlassButtonStyle()).accessibilityIdentifier("newSet")
                }
                if env.social.mySets.isEmpty {
                    Text("Post a free set so people can see what you make, and a paid one for the rest. You set every price.").font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: MSpacing.m)], spacing: MSpacing.m) {
                        ForEach(env.social.mySets) { s in
                            SetTile(set: s) {}
                                .contextMenu {
                                    Button("Edit", systemImage: "pencil") { editing = s }
                                    Button("Delete", systemImage: "trash", role: .destructive) { Task { await env.social.deleteSet(s.id) } }
                                }
                        }
                    }
                }

                HStack {
                    Text("TIME YOU SELL").font(MFont.eyebrow).tracking(1).foregroundStyle(MColor.textSecondary)
                    Spacer()
                    Button { editOffer = BookingOffer(id: "", creatorID: "", creatorName: "", kind: .videoCall, minutes: 15, priceMinor: 99900, currency: "INR", note: "", active: true) } label: { Label("New", systemImage: "plus") }.buttonStyle(GlassButtonStyle()).accessibilityIdentifier("newOffer")
                }
                ForEach(env.social.offers(of: env.social.myID)) { o in
                    Button { editOffer = o } label: {
                        HStack(spacing: MSpacing.m) {
                            Image(systemName: o.kind.symbol).foregroundStyle(MColor.accent).frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(o.minutes > 0 ? "\(o.kind.label) · \(o.minutes) min" : o.kind.label).font(.subheadline.weight(.semibold)).foregroundStyle(MColor.textPrimary)
                                Text(o.active ? "Live" : "Paused").font(MFont.caption).foregroundStyle(o.active ? MColor.success : MColor.textSecondary)
                            }
                            Spacer(); Text(o.priceLabel()).font(.subheadline.weight(.semibold)).foregroundStyle(MColor.textPrimary)
                        }
                        .padding(MSpacing.l)
                    }
                    .buttonStyle(.plain).glass(radius: 16)
                }

                NavigationLink(value: SocialRoute.bookings) {
                    HStack { Image(systemName: "calendar"); Text("Bookings"); Spacer()
                        let pending = env.social.myBookings.filter { $0.creatorID == env.social.myID && $0.status == .requested }.count
                        if pending > 0 { Text("\(pending) waiting").font(MFont.caption).padding(.horizontal, 8).padding(.vertical, 4).glassPill(tint: MColor.danger) }
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(MColor.textTertiary)
                    }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(MColor.textPrimary).padding(MSpacing.l)
                }
                .buttonStyle(.plain).glass(radius: 16).accessibilityIdentifier("bookingsLink")

                Button { showLinks = true } label: {
                    HStack { Image(systemName: "link"); Text("Your other handles"); Spacer(); Text(env.social.links(of: env.social.myID).all.map(\.label).joined(separator: ", ")).font(MFont.caption).foregroundStyle(MColor.textSecondary).lineLimit(1) }
                        .font(.subheadline.weight(.semibold)).foregroundStyle(MColor.textPrimary).padding(MSpacing.l)
                }
                .buttonStyle(.plain).glass(radius: 16).accessibilityIdentifier("linksButton")

                NavigationLink(value: SocialRoute.earn) { Text("Subscriptions & tips").frame(maxWidth: .infinity) }.buttonStyle(SecondaryButtonStyle())
            }
            .padding(MSpacing.page).padding(.bottom, 90)
        }
        .background(LiquidBackdrop(tint: .orange))
        .navigationTitle("Studio")
        .navigationBarTitleDisplayMode(.inline)
        .task { await env.social.refreshStorefront(); await env.social.refreshCreator() }
        .sheet(isPresented: $newSet) { EditSetSheet(set: nil) }
        .sheet(item: $editing) { s in EditSetSheet(set: s) }
        .sheet(item: $editOffer) { o in EditOfferSheet(offer: o) }
        .sheet(isPresented: $showLinks) { LinksSheet() }
        .modifier(SocialErrorAlert())
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
    @State private var free = false
    @State private var picker: [PhotosPickerItem] = []
    @State private var picked: [MediaRef] = []
    @State private var loading = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Photos") {
                    PhotosPicker(selection: $picker, maxSelectionCount: 30, matching: .any(of: [.images, .videos])) { Label(picked.isEmpty ? "Choose from your library" : "\(picked.count) chosen", systemImage: "photo.on.rectangle") }
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
                    Toggle("Free", isOn: $free).accessibilityIdentifier("setFree")
                    if !free { TextField("Price (₹)", text: $price).keyboardType(.numberPad).accessibilityIdentifier("setPrice") }
                } footer: {
                    Text(free ? "Free sets are how people find you." : "You keep \(Int((1 - CreatorEconomics.platformFee) * 100))% on card checkout. The photos stay on your storage — buyers get a key.")
                }
                Section {
                    Button { save() } label: { Text(set == nil ? "Publish set" : "Save").frame(maxWidth: .infinity) }
                        .disabled(title.isBlank || picked.isEmpty || env.social.busy).accessibilityIdentifier("saveSet")
                }
            }
            .scrollContentBackground(.hidden).background(LiquidBackdrop(tint: .orange))
            .navigationTitle(set == nil ? "New set" : "Edit set")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { if let s = set { title = s.title; blurb = s.blurb; free = s.isFree; price = s.isFree ? "" : String(s.priceMinor / 100); Task { await env.social.loadItems(s.id); picked = env.social.items(s.id).compactMap(\.media) } } }
            .onChange(of: picker) { _, items in Task { await load(items) } }
        }
    }
    private func load(_ items: [PhotosPickerItem]) async {
        loading = true; defer { loading = false }
        var refs: [MediaRef] = []
        for item in items {
            guard let d = try? await item.loadTransferable(type: Data.self) else { continue }
            if let ref = await env.social.storeLocalMedia(d, kind: .photo) { refs.append(ref) }
        }
        picked = refs
    }
    private func save() {
        let minor = free ? 0 : max(0, (Int(price.filter(\.isNumber)) ?? 0) * 100)
        var s = set ?? VaultSet(id: "", creatorID: "", creatorName: "", title: "", blurb: "", priceMinor: 0, currency: "INR", cover: nil, itemCount: 0, isVideo: false, createdAt: .now, visible: true)
        s.title = title.trimmed; s.blurb = blurb.trimmed; s.priceMinor = minor; s.cover = picked.first
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
                                    Text("Room \(b.roomID)").font(.caption.monospaced()).foregroundStyle(MColor.textSecondary)
                                    Button("Mark done") { Task { await env.social.setBooking(b.id, .done) } }.buttonStyle(GlassButtonStyle())
                                }
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
