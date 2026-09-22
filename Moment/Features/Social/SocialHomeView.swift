import SwiftUI

/// Home: a stack of nights. One Moment fills the screen, everyone who was there is on it, swipe for the next.
/// NOW and the stories strip float on top in glass.
struct SocialHomeView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showNowComposer = false
    @State private var showScanner = false
    @State private var selectedNow: NowPost?

    var body: some View {
        NavigationStack {
            ImmersiveFeedView(showNowComposer: $showNowComposer, selectedNow: $selectedNow, showScanner: $showScanner)
                .toolbar(.hidden, for: .navigationBar)
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
    case earn
    case meet
    case meetSetup
    case meetLikes
    case subscriptions
    case scan
    case inbox
    case messages
    case discover
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
