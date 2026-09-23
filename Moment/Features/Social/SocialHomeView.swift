import SwiftUI

/// Home: a stack of nights. One Moment fills the screen, everyone who was there is on it, swipe for the next.
/// NOW and the stories strip float on top in glass.
struct SocialHomeView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showNowComposer = false
    @State private var showScanner = false
    @State private var selectedNow: NowPost?

    @AppStorage("homeTab") private var homeTab = 0

    var body: some View {
        NavigationStack {
            Group {
                if homeTab == 0 {
                    CreatorFeedView()
                        .safeAreaInset(edge: .top) { homeHeader }
                } else {
                    ImmersiveFeedView(showNowComposer: $showNowComposer, selectedNow: $selectedNow, showScanner: $showScanner)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await env.social.refreshAll() }
            .socialDestinations()
            .sheet(isPresented: $showNowComposer) { NowComposerView() }
            .sheet(isPresented: $showScanner) { QRScannerView() }
            .fullScreenCover(item: $selectedNow) { post in NowViewerView(post: post) }
        }
        .modifier(SocialErrorAlert())
    }

    /// Wordmark, the two ways to look at the app, and the way into what's happening now.
    private var homeHeader: some View {
        VStack(spacing: MSpacing.s) {
            HStack(spacing: MSpacing.m) {
                Wordmark(size: 19)
                Spacer()
                NavigationLink(value: SocialRoute.reels(nil)) { Image(systemName: "play.rectangle.fill").font(.title3) }.accessibilityIdentifier("reelsLink")
                NavigationLink(value: SocialRoute.now) { Glyph(.now, size: 20) }.accessibilityLabel("Now").accessibilityIdentifier("nowLink")
                NavigationLink(value: SocialRoute.nearby) { Glyph(.nearby, size: 20) }.accessibilityLabel("Nearby").accessibilityIdentifier("nearbyLink")
                Button { showScanner = true } label: { Glyph(.scan, size: 20) }.accessibilityLabel("Scan to join").accessibilityIdentifier("scanQR")
                NavigationLink(value: SocialRoute.inbox) {
                    Glyph(.activity, size: 20).overlay(alignment: .topTrailing) { if env.social.unreadActivity > 0 { Circle().fill(MColor.danger).frame(width: 8, height: 8).offset(x: 2, y: -2) } }
                }
                .accessibilityLabel("Activity").accessibilityIdentifier("inboxButton")
            }
            .foregroundStyle(MColor.textPrimary)
            Picker("Home", selection: $homeTab) { Text("Feed").tag(0); Text("Moments").tag(1) }
                .pickerStyle(.segmented).accessibilityIdentifier("homeTabs")
        }
        .padding(.horizontal, MSpacing.page)
        .padding(.bottom, MSpacing.s)
        .background(.bar)
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
    case earn
    case storefront(String)
    case vaultSet(String)
    case studio
    case bookings
    case reels(String?)
    case subscriptions
    case scan
    case inbox
    case messages
    case now
    case nearby
    case nearbyMap
    case place(SocialPlace)
    case identity
    case invite
    case network
}

extension View {
    /// Same registry as `momentDestinations()`; both stacks resolve social and private routes.
    func socialDestinations() -> some View { momentDestinations() }
}
