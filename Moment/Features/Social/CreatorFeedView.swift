import SwiftUI

/// Home for a creator platform: a column of posts from the people you follow and pay.
/// Locked posts show the cover blurred with the price on the lock — never a bait thumbnail.
struct CreatorFeedView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var buying: VaultSet?
    @State private var subscribing: String?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: MSpacing.l) {
                SuggestedCreatorsRow()
                if env.social.creatorFeed.isEmpty {
                    VStack(spacing: MSpacing.m) {
                        Text("Nothing here yet.").font(MFont.title)
                        Text("Follow a creator, or post a set of your own — free sets are how people find you.").font(MFont.subheadline).foregroundStyle(MColor.textSecondary).multilineTextAlignment(.center)
                        NavigationLink(value: SocialRoute.studio) { Text("Open Studio") }.buttonStyle(PrimaryButtonStyle())
                    }
                    .padding(MSpacing.xl)
                }
                ForEach(env.social.creatorFeed) { post in
                    CreatorPostCard(post: post,
                                    onBuy: { if case .set(let s) = post.source { buying = s } },
                                    onSubscribe: { subscribing = post.creatorID })
                }
            }
            .padding(.horizontal, MSpacing.m)
            .padding(.top, MSpacing.s)
            .padding(.bottom, 90)
        }
        .background(MColor.background)
        .refreshable { await env.social.refreshCreatorFeed() }
        .task { await env.social.refreshCreatorFeed() }
        .task(id: env.social.hasLoadedOnce) { if env.social.hasLoadedOnce { await env.social.refreshCreatorFeed() } }
        .sheet(item: $buying) { s in BuySetSheet(set: s) }
        .sheet(item: Binding(get: { subscribing.map { BoxedID(id: $0) } }, set: { subscribing = $0?.id })) { b in SubscribeSheet(creatorID: b.id) }
    }
}

/// The card: creator row, media (blurred when locked), caption, actions, and one unlock button.
struct CreatorPostCard: View {
    @Environment(AppEnvironment.self) private var env
    let post: CreatorPost
    var onBuy: () -> Void
    var onSubscribe: () -> Void
    @State private var burst: String?

    private var mine: ReactionKind? { post.momentID.flatMap { env.social.myReaction(momentID: $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            media
            actions
            if !post.blurb.isEmpty {
                Text(post.blurb).font(MFont.subheadline).foregroundStyle(MColor.textPrimary)
                    .padding(.horizontal, MSpacing.m).padding(.top, 2)
            }
            Text(post.createdAt.formatted(.relative(presentation: .named))).font(MFont.caption).foregroundStyle(MColor.textTertiary)
                .padding(.horizontal, MSpacing.m).padding(.top, 4).padding(.bottom, MSpacing.m)
        }
        .background(MColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(MColor.separator, lineWidth: 0.5))
        .reactionBurst($burst)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("post-\(post.id)")
    }

    private var header: some View {
        HStack(spacing: MSpacing.s) {
            NavigationLink(value: SocialRoute.profile(post.creatorID)) { AvatarView(userID: post.creatorID, name: post.creatorName, size: 40) }.buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 1) {
                NavigationLink(value: SocialRoute.profile(post.creatorID)) { Text(post.creatorName).font(.subheadline.weight(.semibold)).foregroundStyle(MColor.textPrimary) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("creatorLink-\(post.creatorID)")
                Text(post.title).font(MFont.caption).foregroundStyle(MColor.textSecondary).lineLimit(1)
            }
            Spacer()
            if case .subscribe = post.gate { Image(systemName: "crown.fill").foregroundStyle(MColor.accent) }
            NavigationLink(value: SocialRoute.storefront(post.creatorID)) { Image(systemName: "ellipsis").foregroundStyle(MColor.textSecondary).frame(width: 34, height: 34) }.buttonStyle(.plain)
        }
        .padding(.horizontal, MSpacing.m).padding(.vertical, MSpacing.s)
    }

    /// A 4:5 cover on a tall phone makes a card that doesn't fit on the screen — you could never see a
    /// post's price and its cover at the same time, which is the one thing this feed exists to show.
    /// Capping the height keeps the whole card on screen and lets the next post peek in under it.
    private var coverHeight: CGFloat {
        min(UIScreen.main.bounds.width * 5 / 4, UIScreen.main.bounds.height * 0.52)
    }

    @ViewBuilder private var media: some View {
        // A `.fill` image is larger than its box in one axis, so it has to sit *inside* something
        // whose size is already decided — otherwise it widens the card past the screen edge, which
        // silently moves every tap target in the card with it. An empty container of the exact size
        // with the image as an overlay is the only arrangement where the layout can't be pushed around.
        let cover = Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: coverHeight)
            .overlay { SocialImage(ref: post.cover).aspectRatio(contentMode: .fill) }
            .clipped()
            .contentShape(Rectangle())
        if post.isLocked {
            ZStack {
                cover.blur(radius: 26).clipped()
                Rectangle().fill(.black.opacity(0.25))
                VStack(spacing: MSpacing.m) {
                    Image(systemName: "lock.fill").font(.title).foregroundStyle(.white)
                    Text("\(post.itemCount) \(post.isVideo ? (post.itemCount == 1 ? "video" : "videos") : (post.itemCount == 1 ? "photo" : "photos"))").font(MFont.subheadline).foregroundStyle(.white.opacity(0.9))
                    unlockButton
                }
            }
            .clipped()
        } else {
            NavigationLink(value: destination) { cover.clipped() }.buttonStyle(.plain)
                .overlay(alignment: .topTrailing) {
                    if post.itemCount > 1 { Label("\(post.itemCount)", systemImage: "square.on.square.fill").font(.caption.weight(.semibold)).foregroundStyle(.white).padding(8).shadow(radius: 3) }
                }
        }
    }

    private var destination: SocialRoute { .vaultSet(post.setID ?? "") }

    @ViewBuilder private var unlockButton: some View {
        switch post.gate {
        case .open: EmptyView()
        case .buy(let minor, let currency):
            Button(action: onBuy) {
                Text(minor == 0 ? "Unlock" : "Unlock for \((Double(minor) / 100).formatted(.currency(code: currency).precision(.fractionLength(0))))")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    .background(Capsule().fill(MColor.accent))
            }
            .buttonStyle(.plain).accessibilityIdentifier("unlockPost-\(post.id)")
        case .subscribe(let tier, _):
            Button(action: onSubscribe) {
                Text("Subscribe · \(env.social.plan(for: post.creatorID)?.priceLabel() ?? "")")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    .background(Capsule().fill(MColor.accent))
            }
            .buttonStyle(.plain).accessibilityIdentifier("subscribePost-\(post.id)")
        }
    }

    private var actions: some View {
        HStack(spacing: MSpacing.l) {
            if let momentID = post.momentID {
                Button {
                    if mine == nil { Haptics.saved(); burst = ReactionKind.core.emoji }
                    Task { await env.social.react(momentID: momentID, kind: .core) }
                } label: { Image(systemName: mine == .core ? "heart.fill" : "heart").font(.title3).foregroundStyle(mine == .core ? MColor.danger : MColor.textPrimary) }
                    .accessibilityLabel(mine == .core ? "Unlike" : "Like")
            } else {
                Image(systemName: "photo.stack").font(.title3).foregroundStyle(MColor.textSecondary)
            }
            TipButton(creatorID: post.creatorID, creatorName: post.creatorName, momentID: post.momentID)
            Spacer()
            NavigationLink(value: SocialRoute.storefront(post.creatorID)) { Text("Shop").font(.subheadline.weight(.semibold)).foregroundStyle(MColor.accent) }.buttonStyle(.plain)
        }
        .padding(.horizontal, MSpacing.m).padding(.vertical, MSpacing.s)
    }
}

/// A row of creators worth paying, with what they charge. Suggestion is by overlap, never by "hotness".
struct SuggestedCreatorsRow: View {
    @Environment(AppEnvironment.self) private var env
    private var creators: [(id: String, name: String, price: String?)] {
        var seen: Set<String> = [env.social.myID]
        var out: [(String, String, String?)] = []
        for s in env.social.setsByCreator.values.flatMap({ $0 }).sorted(by: { $0.createdAt > $1.createdAt }) where seen.insert(s.creatorID).inserted {
            out.append((s.creatorID, s.creatorName, env.social.plan(for: s.creatorID).map { $0.priceLabel() }))
        }
        return out
    }
    var body: some View {
        if !creators.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: MSpacing.m) {
                    ForEach(creators, id: \.id) { c in
                        NavigationLink(value: SocialRoute.storefront(c.id)) {
                            VStack(spacing: 4) {
                                AvatarView(userID: c.id, name: c.name, size: 50)
                                    .overlay(Circle().strokeBorder(MColor.accent, lineWidth: 2).padding(-2.5))
                                Text(c.name.split(separator: " ").first.map(String.init) ?? c.name)
                                    .font(.caption2.weight(.medium)).foregroundStyle(MColor.textPrimary).lineLimit(1)
                                if let p = c.price { Text(p).font(.system(size: 10, weight: .semibold)).foregroundStyle(MColor.accent) }
                            }
                            .frame(width: 66)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, MSpacing.s).padding(.vertical, MSpacing.s)
            }
        }
    }
}
