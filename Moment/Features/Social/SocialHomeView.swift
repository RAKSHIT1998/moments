import SwiftUI

/// Home: the creator feed, with the header over it. A call you can join right now sits above everything,
/// because it's the one thing on this screen with a deadline.
struct SocialHomeView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showNew = false

    var body: some View {
        NavigationStack {
            CreatorFeedView()
                .safeAreaInset(edge: .top) { VStack(spacing: 0) { header; joinBanner } }
                .toolbar(.hidden, for: .navigationBar)
                .socialDestinations()
                .sheet(isPresented: $showNew) { EditSetSheet(set: nil) }
        }
        .modifier(SocialErrorAlert())
    }

    /// A confirmed call whose window is open. Never shown otherwise — this is not a nag.
    @ViewBuilder private var joinBanner: some View {
        if let call = env.social.callReadyToJoin {
            NavigationLink(value: SocialRoute.call(call.id)) {
                HStack(spacing: MSpacing.m) {
                    Image(systemName: call.kind.symbol).font(.headline)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(call.kind.label) with \(call.creatorID == env.social.myID ? call.buyerName : call.creatorName)")
                            .font(.subheadline.weight(.semibold))
                        Text("\(call.paidMinutes) minutes · starts when you both join").font(MFont.caption).opacity(0.85)
                    }
                    Spacer()
                    Text("Join").font(.caption.weight(.bold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.white.opacity(0.25), in: Capsule())
                }
                .foregroundStyle(.white)
                .padding(.horizontal, MSpacing.page).padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(MColor.accent)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("joinCallBanner")
        }
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

// MARK: - Routes

enum SocialRoute: Hashable {
    case profile(String)
    case conversation(String)
    case safety
    case blockedUsers
    case followers(String, Bool)
    case editProfile
    case myMemories
    case groups
    case group(String)
    case earn
    case storefront(String)
    case vaultSet(String)
    case studio
    case bookings
    case call(String)
    case reels(String?)
    case subscriptions
    case inbox
    case messages
    case identity
    case invite
    case network
}

extension View {
    /// Same registry as `momentDestinations()`; both stacks resolve social and private routes.
    func socialDestinations() -> some View { momentDestinations() }
}
