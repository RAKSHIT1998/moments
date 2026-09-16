import SwiftUI
import PhotosUI

/// Home: NOW (what's happening right now) on top, then Moments ranked by who you know and
/// what you were part of. Not a scroll of strangers.
struct SocialHomeView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showNowComposer = false
    @State private var showAnyoneUp = false
    @State private var showScanner = false
    @State private var selectedNow: NowPost?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: MSpacing.l) {
                    AccountBanner()
                    UploadBanner()
                    nowStrip
                    AnyoneUpSection(showComposer: $showAnyoneUp)
                    liveSection
                    if let tm = env.social.timeMachine.first, let m = tm.moments.first { TimeMachineCard(yearsAgo: tm.yearsAgo, moment: m) }
                    if env.social.feed.isEmpty && !env.social.hasLoadedOnce && env.social.accountStatus != .noAccount {
                        SkeletonFeedCard(); SkeletonFeedCard()
                    } else if env.social.feed.isEmpty && !env.social.isLoadingFeed {
                        emptyFeed
                    }
                    let mine = env.social.feed.filter { $0.moment.memberIDs.contains(env.social.myID) && !$0.moment.isLive }
                    let friends = env.social.feed.filter { !$0.moment.memberIDs.contains(env.social.myID) && !$0.moment.isLive }
                    if !mine.isEmpty { sectionHeader("YOUR MOMENTS", "Experiences you were part of") }
                    ForEach(mine, id: \.moment.id) { scored in feedRow(scored) }
                    if !friends.isEmpty { sectionHeader("FRIENDS & DISCOVER", "Where your people were") }
                    ForEach(friends, id: \.moment.id) { scored in feedRow(scored) }
                }
                .padding(.horizontal, MSpacing.l)
                .padding(.bottom, 96)
            }
            .background(MColor.background)
            .navigationTitle("Moments")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showScanner = true } label: { Image(systemName: "qrcode.viewfinder") }.accessibilityLabel("Scan a Moment QR").accessibilityIdentifier("scanQR")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: SocialRoute.newMoment) { Image(systemName: "plus.circle.fill").font(.title3) }
                        .accessibilityLabel("New Moment").accessibilityIdentifier("newMoment")
                }
            }
            .refreshable { await env.social.refreshAll() }
            .socialDestinations()
            .sheet(isPresented: $showNowComposer) { NowComposerView() }
            .sheet(isPresented: $showAnyoneUp) { AnyoneUpComposer() }
            .sheet(isPresented: $showScanner) { QRScannerView() }
            .fullScreenCover(item: $selectedNow) { post in NowViewerView(post: post) }
        }
        .modifier(SocialErrorAlert())
    }

    private var nowStrip: some View {
        VStack(alignment: .leading, spacing: MSpacing.s) {
            HStack {
                Text("NOW").font(MFont.eyebrow).foregroundStyle(MColor.textSecondary).tracking(1)
                Text("· gone in 24h").font(MFont.caption).foregroundStyle(MColor.textTertiary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: MSpacing.m) {
                    Button { showNowComposer = true } label: {
                        VStack(spacing: 6) {
                            ZStack {
                                Circle().fill(MColor.accentGradient).frame(width: 60, height: 60)
                                Image(systemName: "plus").font(.title3.weight(.bold)).foregroundStyle(.white)
                            }
                            Text("You").font(MFont.caption).foregroundStyle(MColor.textSecondary)
                        }
                    }
                    .buttonStyle(PressScaleStyle())
                    .accessibilityLabel("Post to NOW").accessibilityIdentifier("nowCompose")
                    ForEach(env.social.nowPosts) { post in
                        Button { selectedNow = post } label: {
                            VStack(spacing: 6) {
                                PersonAvatar(name: post.authorName, size: 56)
                                    .overlay(Circle().strokeBorder(post.savedToMomentID == nil ? MColor.accent : MColor.textTertiary, lineWidth: 2.5).padding(-3))
                                Text(post.authorID == env.social.myID ? "You" : post.authorName.split(separator: " ").first.map(String.init) ?? post.authorName).font(MFont.caption).foregroundStyle(MColor.textSecondary).lineLimit(1)
                            }
                            .frame(width: 64)
                        }
                        .buttonStyle(PressScaleStyle())
                        .accessibilityLabel("\(post.authorName): \(post.text)")
                        .accessibilityIdentifier("now-\(post.id)")
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func feedRow(_ scored: FeedRanker.Scored) -> some View {
        NavigationLink(value: SocialRoute.moment(scored.moment.id)) {
            MomentFeedCard(moment: scored.moment, reason: scored.reason)
        }
        .buttonStyle(PressScaleStyle())
        .onAppear { env.social.markSeen(scored.moment.id) }
    }

    private func sectionHeader(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(MFont.eyebrow).tracking(1).foregroundStyle(MColor.textSecondary)
            Text(sub).font(MFont.footnote).foregroundStyle(MColor.textTertiary)
        }
        .padding(.top, MSpacing.s)
    }

    /// Moments happening right now that you can join — the "Moment Together" entry point.
    @ViewBuilder private var liveSection: some View {
        let live = env.social.feed.map(\.moment).filter(\.isLive)
        if !live.isEmpty {
            VStack(alignment: .leading, spacing: MSpacing.s) {
                HStack(spacing: 6) {
                    Circle().fill(MColor.danger).frame(width: 8, height: 8)
                    Text("HAPPENING NOW").font(MFont.eyebrow).tracking(1).foregroundStyle(MColor.textSecondary)
                }
                ForEach(live) { m in
                    HStack(spacing: MSpacing.m) {
                        SocialImage(ref: m.coverRef).frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: MRadius.chip, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.title).font(MFont.headline).lineLimit(1)
                            Text("\(m.creatorName.split(separator: " ").first.map(String.init) ?? m.creatorName) started it · \(m.memberIDs.count) in · \(m.contributionCount) added").font(MFont.footnote).foregroundStyle(MColor.textSecondary).lineLimit(1)
                        }
                        Spacer()
                        if m.memberIDs.contains(env.social.myID) {
                            NavigationLink(value: SocialRoute.addSide(m.id)) { Text("ADD") }.buttonStyle(ChipButtonStyle(prominent: true))
                        } else {
                            Button("JOIN") { Task { if await env.social.join(momentID: m.id) { env.toast("You're in.") } } }.buttonStyle(ChipButtonStyle(prominent: true)).accessibilityIdentifier("joinLive-\(m.id)")
                        }
                    }
                    .momentCard(padding: MSpacing.m)
                    .overlay(RoundedRectangle(cornerRadius: MRadius.card, style: .continuous).strokeBorder(MColor.danger.opacity(0.25), lineWidth: 1))
                    .onTapGesture { env.social.pendingMomentID = m.id }
                }
            }
            .accessibilityIdentifier("liveSection")
        }
    }

    private func onThisDayCard(_ m: SocialMoment) -> some View {
        NavigationLink(value: SocialRoute.moment(m.id)) {
            HStack(spacing: MSpacing.m) {
                SocialImage(ref: m.coverRef).frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: MRadius.chip, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("ONE YEAR AGO").font(MFont.eyebrow).foregroundStyle(MColor.accent)
                    Text(m.title).font(MFont.headline).foregroundStyle(MColor.textPrimary)
                    Text("with \(m.memberNames.filter { $0 != env.social.displayName }.joined(separator: ", "))").font(MFont.footnote).foregroundStyle(MColor.textSecondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(MColor.textTertiary)
            }
            .momentCard()
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityIdentifier("onThisDay")
    }

    private var emptyFeed: some View {
        VStack(alignment: .leading, spacing: MSpacing.m) {
            Text("Nothing here yet.").font(MFont.title)
            Text("Make a Moment from something that happened and invite the people who were there. Their side shows up next to yours.").font(MFont.body).foregroundStyle(MColor.textSecondary)
            NavigationLink(value: SocialRoute.newMoment) { Text("Make your first Moment").frame(maxWidth: .infinity) }.buttonStyle(PrimaryButtonStyle())
        }
        .momentCard()
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
}

extension View {
    /// Same registry as `momentDestinations()`; both stacks resolve social and private routes.
    func socialDestinations() -> some View { momentDestinations() }
}
