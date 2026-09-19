import SwiftUI

/// Home: a feed people already know how to use — stories row on top, posts below — where every
/// post is a shared Moment and the main action is "Add your side".
struct SocialHomeView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showNowComposer = false
    @State private var showScanner = false
    @State private var selectedNow: NowPost?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    AccountBanner().padding(.horizontal, MSpacing.m)
                    UploadBanner().padding(.horizontal, MSpacing.m)
                    StoriesRow(showComposer: $showNowComposer, selectedNow: $selectedNow)
                    Divider()
                    if env.social.feed.isEmpty && !env.social.hasLoadedOnce && env.social.accountStatus != .noAccount {
                        SkeletonFeedCard().padding(MSpacing.m)
                    } else if env.social.feed.isEmpty && env.social.hasLoadedOnce {
                        EmptyMoments().padding(MSpacing.m)
                    }
                    ForEach(env.social.feed, id: \.moment.id) { scored in
                        MomentPostCard(moment: scored.moment).onAppear { env.social.markSeen(scored.moment.id) }
                    }
                    if let tm = env.social.timeMachine.first, let m = tm.moments.first {
                        VStack(alignment: .leading, spacing: MSpacing.s) {
                            Text("Memories").sectionLabel()
                            TimeMachineCard(yearsAgo: tm.yearsAgo, moment: m)
                        }
                        .padding(MSpacing.m)
                    }
                }
                .padding(.bottom, 80)
            }
            .background(MColor.background)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Text("MOMENT").font(.system(size: 22, weight: .heavy)).tracking(2).accessibilityAddTraits(.isHeader) }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: MSpacing.l) {
                        Button { showScanner = true } label: { Image(systemName: "qrcode.viewfinder") }.accessibilityLabel("Scan to join").accessibilityIdentifier("scanQR")
                        NavigationLink(value: SocialRoute.inbox) {
                            Image(systemName: "heart").overlay(alignment: .topTrailing) { if env.social.unreadActivity > 0 { Circle().fill(MColor.danger).frame(width: 8, height: 8).offset(x: 2, y: -2) } }
                        }
                        .accessibilityLabel("Activity").accessibilityIdentifier("inboxButton")
                        NavigationLink(value: SocialRoute.messages) { Image(systemName: "paperplane") }.accessibilityLabel("Messages")
                    }
                    .font(.title3.weight(.regular)).foregroundStyle(MColor.textPrimary)
                }
            }
            .refreshable { await env.social.refreshAll() }
            .socialDestinations()
            .sheet(isPresented: $showNowComposer) { NowComposerView() }
            .sheet(isPresented: $showScanner) { QRScannerView() }
            .fullScreenCover(item: $selectedNow) { post in NowViewerView(post: post) }
        }
        .modifier(SocialErrorAlert())
    }
}

/// "Your first one starts here."
struct EmptyMoments: View {
    var body: some View {
        VStack(alignment: .leading, spacing: MSpacing.m) {
            Text("No Moments yet").font(MFont.title)
            Text("Your first one starts here.").font(MFont.body).foregroundStyle(MColor.textSecondary)
            NavigationLink(value: SocialRoute.newMoment) { Text("Create Moment").frame(maxWidth: .infinity) }.buttonStyle(PrimaryButtonStyle(tint: MColor.accent))
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
    case messages
    case discover
    case now
    case nearby
    case nearbyMap
    case place(SocialPlace)
}

extension View {
    /// Same registry as `momentDestinations()`; both stacks resolve social and private routes.
    func socialDestinations() -> some View { momentDestinations() }
}
