import SwiftUI

/// Home: a stack of nights. One Moment fills the screen, everyone who was there is on it, swipe for the next.
/// NOW and the stories strip float on top in glass.
struct SocialHomeView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showNew = false

    var body: some View {
        NavigationStack {
            CreatorFeedView()
                .safeAreaInset(edge: .top) { header }
                .toolbar(.hidden, for: .navigationBar)
                .socialDestinations()
                .sheet(isPresented: $showNew) { EditSetSheet(set: nil) }
        }
        .modifier(SocialErrorAlert())
    }

    /// Wordmark, the people you pay, and the two inboxes.
    private var header: some View {
        HStack(spacing: MSpacing.l) {
            Wordmark(size: 19)
            Spacer()
            NavigationLink(value: SocialRoute.reels(nil)) { Image(systemName: "play.rectangle.fill").font(.title3) }
                .accessibilityLabel("Reels").accessibilityIdentifier("reelsLink")
            if env.social.isCreator {
                Button { showNew = true } label: { Image(systemName: "plus.square").font(.title3) }
                    .accessibilityLabel("New post").accessibilityIdentifier("newPostLink")
            }
            NavigationLink(value: SocialRoute.inbox) {
                Image(systemName: "bell").font(.title3)
                    .overlay(alignment: .topTrailing) { if env.social.unreadActivity > 0 { Circle().fill(MColor.danger).frame(width: 8, height: 8).offset(x: 3, y: -2) } }
            }
            .accessibilityLabel("Notifications").accessibilityIdentifier("inboxButton")
        }
        .foregroundStyle(MColor.textPrimary)
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
    case place(SocialPlace)
    case identity
    case invite
    case network
}

extension View {
    /// Same registry as `momentDestinations()`; both stacks resolve social and private routes.
    func socialDestinations() -> some View { momentDestinations() }
}
