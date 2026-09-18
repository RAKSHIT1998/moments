import SwiftUI

/// NOW: who's out, what they're up for, and the one action — say what you're up to.
struct NowView: View {
    @Environment(AppEnvironment.self) private var env
    var embedded = false
    @State private var showAnyoneUp = false
    @State private var showComposer = false
    @State private var selected: NowPost?

    var body: some View {
        Group { if embedded { content } else { NavigationStack { content.socialDestinations() } } }
            .modifier(SocialErrorAlert())
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MSpacing.section) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Now").displayStyle()
                    Text("Who's out, right now. Gone in a few hours.").font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
                }
                .padding(.top, MSpacing.s)
                let statuses = env.social.nowPosts.filter(\.isStatus)
                let posts = env.social.nowPosts.filter { !$0.isStatus }
                if statuses.isEmpty && posts.isEmpty {
                    VStack(alignment: .leading, spacing: MSpacing.m) {
                        Text("Nobody's out yet").font(MFont.title)
                        Text("Say what you're up for and see who joins.").font(MFont.body).foregroundStyle(MColor.textSecondary)
                    }
                }
                if !statuses.isEmpty {
                    VStack(alignment: .leading, spacing: MSpacing.m) {
                        Text("Up for").sectionLabel()
                        ForEach(statuses) { NowStatusRow(post: $0) }
                    }
                }
                if !posts.isEmpty {
                    VStack(alignment: .leading, spacing: MSpacing.m) {
                        Text("Posted").sectionLabel()
                        ForEach(posts) { post in
                            Button { selected = post } label: {
                                HStack(spacing: MSpacing.m) {
                                    AvatarView(userID: post.authorID, name: post.authorName, size: 44)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(post.authorID == env.social.myID ? "You" : post.authorName).font(MFont.headline).foregroundStyle(MColor.textPrimary)
                                        Text(post.text.isEmpty ? "Photo" : post.text).font(MFont.footnote).foregroundStyle(MColor.textSecondary).lineLimit(1)
                                    }
                                    Spacer()
                                    if post.media != nil { SocialImage(ref: post.media).frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)) }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("now-\(post.id)")
                        }
                    }
                }
            }
            .padding(.horizontal, MSpacing.page).padding(.bottom, 120)
        }
        .background(MColor.background)
        .toolbarBackground(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: MSpacing.s) {
                Button { showAnyoneUp = true } label: { Text("I'm up for…").frame(maxWidth: .infinity) }.buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("imUpFor")
                Button { showComposer = true } label: { Image(systemName: "camera").font(.title3.weight(.light)).frame(width: 54, height: 54) }.buttonStyle(SecondaryButtonStyle()).accessibilityLabel("Post a photo to NOW").accessibilityIdentifier("nowCompose")
            }
            .padding(.horizontal, MSpacing.page).padding(.vertical, MSpacing.m)
            .background(.bar)
        }
        .refreshable { await env.social.refreshNow() }
        .sheet(isPresented: $showAnyoneUp) { AnyoneUpComposer() }
        .sheet(isPresented: $showComposer) { NowComposerView() }
        .fullScreenCover(item: $selected) { NowViewerView(post: $0) }
        .onChange(of: env.social.pendingNowID) { _, id in
            if let id, let p = env.social.nowPosts.first(where: { $0.id == id }) { if !p.isStatus { selected = p }; env.social.pendingNowID = nil }
        }
        .accessibilityIdentifier("nowScreen")
    }
}
