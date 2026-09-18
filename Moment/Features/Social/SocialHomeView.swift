import SwiftUI

/// Home: calm. A greeting, who's out right now, then the Moments — large, photographic, few.
/// Sections are typography and space, not boxes. One dominant action per screen: open a Moment.
struct SocialHomeView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showNowComposer = false
    @State private var showAnyoneUp = false
    @State private var showScanner = false
    @State private var showStart = false
    @State private var selectedNow: NowPost?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: MSpacing.section) {
                    greeting
                    AccountBanner()
                    UploadBanner()
                    nowRow
                    liveSection
                    momentsSection
                    forYouSection
                    memoriesSection
                }
                .padding(.horizontal, MSpacing.page)
                .padding(.bottom, 96)
            }
            .background(MColor.background)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showScanner = true } label: { Image(systemName: "qrcode.viewfinder").fontWeight(.light) }.accessibilityLabel("Scan to join").accessibilityIdentifier("scanQR")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: SocialRoute.inbox) {
                        Image(systemName: env.social.unreadActivity > 0 ? "bell.badge" : "bell").fontWeight(.light)
                    }
                    .accessibilityLabel("Inbox\(env.social.unreadActivity > 0 ? ", \(env.social.unreadActivity) new" : "")").accessibilityIdentifier("inboxButton")
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .refreshable { await env.social.refreshAll() }
            .socialDestinations()
            .sheet(isPresented: $showNowComposer) { NowComposerView() }
            .sheet(isPresented: $showAnyoneUp) { AnyoneUpComposer() }
            .sheet(isPresented: $showScanner) { QRScannerView() }
            .sheet(isPresented: $showStart) { StartActivityView() }
            .fullScreenCover(item: $selectedNow) { post in NowViewerView(post: post) }
        }
        .modifier(SocialErrorAlert())
    }

    // MARK: Sections

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(timeGreeting).font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
            Text(env.social.displayName == "You" ? "Moments" : env.social.displayName.split(separator: " ").first.map(String.init) ?? "Moments").displayStyle()
        }
        .padding(.top, MSpacing.s)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var timeGreeting: String {
        let h = Calendar.current.component(.hour, from: .now)
        return h < 5 ? "Still up" : h < 12 ? "Good morning" : h < 17 ? "Good afternoon" : h < 22 ? "Good evening" : "Good night"
    }

    /// NOW as presence, not a feed: avatars, a word each.
    private var nowRow: some View {
        VStack(alignment: .leading, spacing: MSpacing.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Now").sectionLabel()
                Spacer()
                NavigationLink(value: SocialRoute.now) { Text("See who's out").font(.subheadline.weight(.medium)).foregroundStyle(MColor.textSecondary) }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: MSpacing.l) {
                    Button { showAnyoneUp = true } label: {
                        VStack(spacing: 6) {
                            ZStack {
                                Circle().strokeBorder(MColor.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 4])).frame(width: 56, height: 56)
                                Image(systemName: "plus").font(.body.weight(.light)).foregroundStyle(MColor.textPrimary)
                            }
                            Text("You").font(MFont.caption).foregroundStyle(MColor.textSecondary)
                        }
                    }
                    .buttonStyle(PressScaleStyle()).accessibilityLabel("Say what you're up to").accessibilityIdentifier("nowCompose")
                    ForEach(env.social.nowPosts.prefix(12)) { post in
                        Button { if post.isStatus { showAnyoneUp = false; env.social.pendingNowID = post.id } else { selectedNow = post } } label: {
                            VStack(spacing: 6) {
                                AvatarView(userID: post.authorID, name: post.authorName, size: 56)
                                    .overlay(alignment: .bottomTrailing) { if post.isStatus { Text(post.activity.emoji).font(.caption2).padding(3).background(MColor.background, in: Circle()) } }
                                Text(post.authorID == env.social.myID ? "You" : post.authorName.split(separator: " ").first.map(String.init) ?? post.authorName).font(MFont.caption).foregroundStyle(MColor.textPrimary).lineLimit(1)
                                Text(post.isStatus ? post.activity.label : "Posted").font(.caption2).foregroundStyle(MColor.textTertiary).lineLimit(1)
                            }
                            .frame(width: 64)
                        }
                        .buttonStyle(PressScaleStyle())
                        .accessibilityLabel("\(post.authorName): \(post.isStatus ? post.activity.line : post.text)")
                        .accessibilityIdentifier("now-\(post.id)")
                    }
                    if env.social.nowPosts.isEmpty { Text("Nobody's out yet.").font(MFont.footnote).foregroundStyle(MColor.textTertiary).padding(.top, 18) }
                }
            }
        }
    }

    @ViewBuilder private var liveSection: some View {
        let live = env.social.feed.map(\.moment).filter(\.isLive)
        if !live.isEmpty {
            VStack(alignment: .leading, spacing: MSpacing.m) {
                Text("Happening now").sectionLabel()
                ForEach(live) { m in
                    NavigationLink(value: SocialRoute.moment(m.id)) {
                        HStack(spacing: MSpacing.m) {
                            SocialImage(ref: m.coverRef).frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.title).font(MFont.headline).foregroundStyle(MColor.textPrimary).lineLimit(1)
                                Text("\(m.memberIDs.count) \(m.memberIDs.count == 1 ? "person" : "people") · \(m.creatorName.split(separator: " ").first.map(String.init) ?? "")").font(MFont.footnote).foregroundStyle(MColor.textSecondary).lineLimit(1)
                            }
                            Spacer()
                            if m.memberIDs.contains(env.social.myID) { Text("Add your side").font(.subheadline.weight(.medium)).foregroundStyle(MColor.textSecondary) }
                            else { Button("Join") { Task { if await env.social.join(momentID: m.id) { env.toast("You're in.") } } }.buttonStyle(ChipButtonStyle(prominent: true)).accessibilityIdentifier("joinLive-\(m.id)") }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .accessibilityIdentifier("liveSection")
        }
    }

    private var momentsSection: some View {
        let mine = env.social.feed.filter { $0.moment.memberIDs.contains(env.social.myID) && !$0.moment.isLive }
        return VStack(alignment: .leading, spacing: MSpacing.l) {
            Text("Moments").sectionLabel()
            if env.social.feed.isEmpty && !env.social.hasLoadedOnce && env.social.accountStatus != .noAccount {
                SkeletonFeedCard()
            } else if mine.isEmpty && env.social.hasLoadedOnce {
                EmptyMoments()
            }
            ForEach(mine, id: \.moment.id) { scored in feedRow(scored) }
        }
    }

    @ViewBuilder private var forYouSection: some View {
        let others = env.social.feed.filter { !$0.moment.memberIDs.contains(env.social.myID) && !$0.moment.isLive }
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: MSpacing.l) {
                Text("For you").sectionLabel()
                ForEach(others.prefix(6), id: \.moment.id) { scored in feedRow(scored) }
                NavigationLink(value: SocialRoute.discover) { Text("More to discover →").font(.subheadline.weight(.medium)).foregroundStyle(MColor.textSecondary) }
            }
        }
    }

    @ViewBuilder private var memoriesSection: some View {
        if let tm = env.social.timeMachine.first, let m = tm.moments.first {
            VStack(alignment: .leading, spacing: MSpacing.l) {
                Text("Memories").sectionLabel()
                TimeMachineCard(yearsAgo: tm.yearsAgo, moment: m)
            }
        }
    }

    private func feedRow(_ scored: FeedRanker.Scored) -> some View {
        NavigationLink(value: SocialRoute.moment(scored.moment.id)) { MomentFeedCard(moment: scored.moment) }
            .buttonStyle(PressScaleStyle())
            .onAppear { env.social.markSeen(scored.moment.id) }
    }
}

/// "Your first one starts here."
struct EmptyMoments: View {
    var body: some View {
        VStack(alignment: .leading, spacing: MSpacing.m) {
            Text("No Moments yet").font(MFont.title)
            Text("Your first one starts here.").font(MFont.body).foregroundStyle(MColor.textSecondary)
            NavigationLink(value: SocialRoute.newMoment) { Text("Create Moment").frame(maxWidth: .infinity) }.buttonStyle(PrimaryButtonStyle())
        }
        .padding(.vertical, MSpacing.l)
        .accessibilityIdentifier("emptyFeed")
    }
}

// MARK: - Routes

enum SocialRoute: Hashable {
    case moment(String)
    case newMoment
    case addSide(String)
    case profile(String)
    case friendship(String)
    case conversation(String)
    case editMoment(String)
    case members(String)
    case safety
    case blockedUsers
    case followers(String, Bool)
    case editProfile
    case myMemories
    case collections
    case collection(String)
    case timeMachine
    case groups
    case group(String)
    case newMomentForGroup(String)
    case map
    case passport
    case scan
    case inbox
    case discover
    case now
}

extension View {
    /// Same registry as `momentDestinations()`; both stacks resolve social and private routes.
    func socialDestinations() -> some View { momentDestinations() }
}
