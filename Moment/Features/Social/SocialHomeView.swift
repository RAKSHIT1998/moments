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
                .padding(.horizontal, MSpacing.l).padding(.vertical, 11)
                .frame(maxWidth: .infinity)
                .background(Capsule().fill(MColor.accent))
                .shadow(color: MColor.accent.opacity(0.4), radius: 12, y: 5)
                .padding(.horizontal, MSpacing.m)
                .padding(.bottom, MSpacing.s)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("joinCallBanner")
        }
    }

    /// Wordmark on the left, the two places you go from here on the right — floating, so the feed
    /// passes under it rather than starting below a hard line.
    private var header: some View {
        HStack(spacing: MSpacing.m) {
            Wordmark(size: 17)
            Spacer(minLength: MSpacing.m)
            headerButton("magnifyingglass", "Find creators", id: "discoverLink", route: .discover)
            headerButton(MSymbol.reels, "Reels", id: "reelsLink", route: .reels(nil))
            if env.social.isCreator {
                Button { showNew = true } label: { headerGlyph(MSymbol.photoSet) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New post").accessibilityIdentifier("newPostLink")
            }
            headerButton(env.social.unreadActivity > 0 ? MSymbol.notificationsOn : MSymbol.notifications,
                         "Notifications", id: "inboxButton", route: .inbox,
                         dot: env.social.unreadActivity > 0)
        }
        .padding(.leading, MSpacing.l)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .glassPill(prominent: true)
        .padding(.horizontal, MSpacing.m)
        .padding(.bottom, MSpacing.s)
    }

    private func headerButton(_ symbol: String, _ label: String, id: String, route: SocialRoute, dot: Bool = false) -> some View {
        NavigationLink(value: route) { headerGlyph(symbol, dot: dot) }
            .buttonStyle(.plain)
            .accessibilityLabel(label).accessibilityIdentifier(id)
    }

    private func headerGlyph(_ symbol: String, dot: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(dot ? MColor.accent : MColor.textPrimary)
            .frame(width: 36, height: 36)
            .background(Circle().fill(MColor.textPrimary.opacity(0.06)))
            .overlay(alignment: .topTrailing) {
                if dot { Circle().fill(MColor.danger).frame(width: 8, height: 8).offset(x: -1, y: 1) }
            }
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
    case discover
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
