import SwiftUI
import PhotosUI

/// Home: NOW (what's happening right now) on top, then Moments ranked by who you know and
/// what you were part of. Not a scroll of strangers.
struct SocialHomeView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showNowComposer = false
    @State private var selectedNow: NowPost?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: MSpacing.l) {
                    AccountBanner()
                    UploadBanner()
                    nowStrip
                    if let oneYear = env.social.onThisDay.first { onThisDayCard(oneYear) }
                    if env.social.feed.isEmpty && !env.social.isLoadingFeed {
                        emptyFeed
                    }
                    ForEach(env.social.feed, id: \.moment.id) { scored in
                        NavigationLink(value: SocialRoute.moment(scored.moment.id)) {
                            MomentFeedCard(moment: scored.moment, reason: scored.reason)
                        }
                        .buttonStyle(PressScaleStyle())
                        .onAppear { env.social.markSeen(scored.moment.id) }
                    }
                }
                .padding(.horizontal, MSpacing.l)
                .padding(.bottom, 96)
            }
            .background(MColor.background)
            .navigationTitle("Moments")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: SocialRoute.newMoment) { Image(systemName: "plus.circle.fill").font(.title3) }
                        .accessibilityLabel("New Moment").accessibilityIdentifier("newMoment")
                }
            }
            .refreshable { await env.social.refreshAll() }
            .socialDestinations()
            .sheet(isPresented: $showNowComposer) { NowComposerView() }
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
}

extension View {
    /// Same registry as `momentDestinations()`; both stacks resolve social and private routes.
    func socialDestinations() -> some View { momentDestinations() }
}
