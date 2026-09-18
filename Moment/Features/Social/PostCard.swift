import SwiftUI

/// A Moment in the feed, laid out the way everyone already reads a feed: header, media, actions,
/// people line, caption, comments. The Moments twist is the action row — ➕ Add your side — and the
/// "6 people were there" line instead of a like count.
struct MomentPostCard: View {
    @Environment(AppEnvironment.self) private var env
    let moment: SocialMoment
    @State private var burst: String?
    @State private var showComments = false
    @State private var showShare = false
    @State private var shareItems: [Any] = []

    private var isMember: Bool { moment.memberIDs.contains(env.social.myID) }
    private var mine: ReactionKind? { env.social.myReaction(momentID: moment.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            media
            actions
            VStack(alignment: .leading, spacing: 4) {
                peopleLine
                caption
                if moment.commentCount > 0 {
                    Button { showComments = true } label: { Text("View all \(moment.commentCount) comments").font(MFont.subheadline).foregroundStyle(MColor.textSecondary) }.buttonStyle(.plain)
                }
                Text(moment.createdAt.formatted(.relative(presentation: .named))).font(MFont.caption).foregroundStyle(MColor.textTertiary).padding(.top, 2)
            }
            .padding(.horizontal, MSpacing.m)
            .padding(.top, 6)
        }
        .padding(.bottom, MSpacing.m)
        .reactionBurst($burst)
        .sheet(isPresented: $showComments) { CommentsSheet(momentID: moment.id) }
        .sheet(isPresented: $showShare) { ShareSheet(items: shareItems) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("feedMoment-\(moment.id)")
    }

    private var header: some View {
        HStack(spacing: MSpacing.s) {
            NavigationLink(value: SocialRoute.profile(moment.creatorID)) { AvatarView(userID: moment.creatorID, name: moment.creatorName, size: 34) }.buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    NavigationLink(value: SocialRoute.profile(moment.creatorID)) { Text(moment.creatorName).font(.subheadline.weight(.semibold)).foregroundStyle(MColor.textPrimary) }.buttonStyle(.plain)
                    if moment.isLive { Text("· Live").font(.subheadline.weight(.semibold)).foregroundStyle(MColor.danger) }
                }
                if let p = moment.coarsePlace, !p.isEmpty { Text(p).font(MFont.caption).foregroundStyle(MColor.textSecondary) }
                else { Text(moment.dateLabel).font(MFont.caption).foregroundStyle(MColor.textSecondary) }
            }
            Spacer()
            NavigationLink(value: SocialRoute.moment(moment.id)) { Image(systemName: "ellipsis").foregroundStyle(MColor.textPrimary).frame(width: 36, height: 36) }.buttonStyle(.plain).accessibilityLabel("Open Moment")
        }
        .padding(.horizontal, MSpacing.m)
        .padding(.vertical, 8)
    }

    private var media: some View {
        NavigationLink(value: SocialRoute.moment(moment.id)) {
            ZStack(alignment: .topTrailing) {
                SocialImage(ref: moment.coverRef).aspectRatio(4/5, contentMode: .fill).frame(maxWidth: .infinity)
                    .blur(radius: moment.isTeaser && !isMember ? 24 : 0)
                if moment.mediaCount > 1 {
                    Image(systemName: "square.on.square.fill").foregroundStyle(.white).shadow(radius: 3).padding(MSpacing.m)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            Haptics.saved(); burst = ReactionKind.core.emoji
            Task { await env.social.react(momentID: moment.id, kind: .core) }
        })
    }

    private var actions: some View {
        HStack(spacing: MSpacing.l) {
            Button {
                if mine == nil { Haptics.saved(); burst = ReactionKind.core.emoji }
                Task { await env.social.react(momentID: moment.id, kind: .core) }
            } label: { Image(systemName: mine == .core ? "heart.fill" : "heart").foregroundStyle(mine == .core ? MColor.danger : MColor.textPrimary) }
                .accessibilityLabel(mine == .core ? "Unlike" : "Like").accessibilityIdentifier("react-core")
            Button { showComments = true } label: { Image(systemName: "bubble.right") }.accessibilityLabel("Comments").accessibilityIdentifier("comments-\(moment.id)")
            Button { Task { await share() } } label: { Image(systemName: "paperplane") }.accessibilityLabel("Share")
            Spacer()
            if isMember {
                NavigationLink(value: SocialRoute.addSide(moment.id)) {
                    Label("Add your side", systemImage: "plus.square.on.square").font(.subheadline.weight(.semibold))
                }
                .accessibilityIdentifier("addYourSide")
            } else {
                Button("I was there") { Task { if await env.social.join(momentID: moment.id) { env.toast("You're in.") } } }.font(.subheadline.weight(.semibold)).accessibilityIdentifier("iWasThere")
            }
        }
        .font(.title3.weight(.regular))
        .foregroundStyle(MColor.textPrimary)
        .padding(.horizontal, MSpacing.m)
        .padding(.top, 10)
    }

    private var peopleLine: some View {
        NavigationLink(value: SocialRoute.members(moment.id)) {
            HStack(spacing: 6) {
                AvatarStack(names: moment.memberNames, size: 20, max: 3)
                Text(peopleText).font(.subheadline.weight(.semibold)).foregroundStyle(MColor.textPrimary)
            }
        }
        .buttonStyle(.plain)
    }

    private var peopleText: String {
        let n = moment.memberIDs.count
        if n <= 1 { return "Just \(moment.creatorID == env.social.myID ? "you" : moment.creatorName.split(separator: " ").first.map(String.init) ?? "them")" }
        let others = moment.memberNames.filter { $0 != env.social.displayName }.map { $0.split(separator: " ").first.map(String.init) ?? $0 }
        if isMember { return "You, \(others.first ?? "") and \(max(0, n - 2)) others were there" }
        return "\(others.first ?? ""), \(others.dropFirst().first ?? "") and \(max(0, n - 2)) others were there"
    }

    @ViewBuilder private var caption: some View {
        if !moment.description.isEmpty {
            (Text(moment.creatorName.split(separator: " ").first.map(String.init) ?? "").font(.subheadline.weight(.semibold)) + Text(" ") + Text(moment.description).font(MFont.subheadline))
                .foregroundStyle(MColor.textPrimary).lineLimit(3)
        } else {
            (Text(moment.creatorName.split(separator: " ").first.map(String.init) ?? "").font(.subheadline.weight(.semibold)) + Text(" ") + Text(moment.title).font(MFont.subheadline))
                .foregroundStyle(MColor.textPrimary).lineLimit(2)
        }
    }

    private func share() async {
        var url = moment.shareURL
        if url == nil, moment.creatorID == env.social.myID { url = await env.social.shareLink(momentID: moment.id) }
        guard let url else { env.toast("Only the creator can share this."); return }
        shareItems = ["\(moment.title) — you were there. Add your side on MOMENT.", url]
        showShare = true
    }
}

/// Bottom-sheet comments, the way people expect them.
struct CommentsSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let momentID: String
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: MSpacing.l) {
                        let comments = env.social.comments[momentID] ?? []
                        if comments.isEmpty { Text("No comments yet.").font(MFont.subheadline).foregroundStyle(MColor.textSecondary).padding(.top, MSpacing.xl) }
                        ForEach(comments) { c in
                            HStack(alignment: .top, spacing: MSpacing.s) {
                                AvatarView(userID: c.authorID, name: c.authorName, size: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(c.authorID == env.social.myID ? "You" : c.authorName).font(.subheadline.weight(.semibold))
                                        Text(c.createdAt.formatted(.relative(presentation: .named))).font(MFont.caption).foregroundStyle(MColor.textTertiary)
                                    }
                                    MentionText(text: c.text)
                                }
                                Spacer()
                            }
                            .contextMenu { if c.authorID == env.social.myID { Button("Delete", role: .destructive) { Task { await env.social.deleteComment(c) } } } }
                        }
                    }
                    .padding(MSpacing.l)
                }
                HStack(spacing: MSpacing.s) {
                    AvatarView(userID: env.social.myID, name: env.social.displayName, size: 32)
                    TextField("Add a comment…", text: $text, axis: .vertical).lineLimit(1...4).focused($focused).textFieldStyle(.plain).accessibilityIdentifier("commentField")
                    Button("Post") {
                        let t = text; text = ""
                        Task { if await env.social.comment(momentID: momentID, text: t) { Haptics.saved() } else { text = t } }
                    }
                    .font(.subheadline.weight(.semibold)).disabled(text.isBlank).accessibilityIdentifier("postComment")
                }
                .padding(MSpacing.m)
                .background(.bar)
            }
            .navigationTitle("Comments").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task { await env.social.loadMoment(momentID); focused = (env.social.comments[momentID] ?? []).isEmpty }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .modifier(SocialErrorAlert())
    }
}

/// Stories-style row: your NOW first, then friends' NOW and live Moments, ringed when unseen.
struct StoriesRow: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var showComposer: Bool
    @Binding var selectedNow: NowPost?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: MSpacing.l) {
                Button { showComposer = true } label: {
                    VStack(spacing: 6) {
                        ZStack(alignment: .bottomTrailing) {
                            AvatarView(userID: env.social.myID, name: env.social.displayName, size: 64)
                            Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(MColor.accent).background(MColor.background, in: Circle())
                        }
                        Text("Your NOW").font(MFont.caption).foregroundStyle(MColor.textPrimary)
                    }
                }
                .buttonStyle(.plain).accessibilityLabel("Post to NOW").accessibilityIdentifier("nowCompose")
                ForEach(env.social.feed.map(\.moment).filter(\.isLive)) { m in
                    NavigationLink(value: SocialRoute.moment(m.id)) {
                        VStack(spacing: 6) {
                            SocialImage(ref: m.coverRef).frame(width: 64, height: 64).clipShape(Circle())
                                .overlay(Circle().strokeBorder(MColor.danger, lineWidth: 2.5).padding(-3))
                            Text("Live · \(m.title)").font(MFont.caption).foregroundStyle(MColor.textPrimary).lineLimit(1)
                        }
                        .frame(width: 76)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(env.social.nowPosts.filter { $0.authorID != env.social.myID }) { post in
                    Button { selectedNow = post } label: {
                        VStack(spacing: 6) {
                            AvatarView(userID: post.authorID, name: post.authorName, size: 64)
                                .overlay(Circle().strokeBorder(post.savedToMomentID == nil ? MColor.accent : MColor.separator, lineWidth: 2.5).padding(-3))
                                .overlay(alignment: .bottomTrailing) { if post.isStatus { Text(post.activity.emoji).font(.caption).padding(3).background(MColor.background, in: Circle()) } }
                            Text(post.authorName.split(separator: " ").first.map(String.init) ?? post.authorName).font(MFont.caption).foregroundStyle(MColor.textPrimary).lineLimit(1)
                        }
                        .frame(width: 76)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(post.authorName): \(post.isStatus ? post.activity.line : post.text)")
                    .accessibilityIdentifier("now-\(post.id)")
                }
            }
            .padding(.horizontal, MSpacing.m)
            .padding(.vertical, MSpacing.s)
        }
    }
}
