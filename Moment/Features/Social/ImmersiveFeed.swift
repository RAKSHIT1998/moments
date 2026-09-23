import SwiftUI

/// Home as a stack of nights, not a list of posts. One Moment per screen: the cover fills the phone,
/// everyone who was there is on it, their sides run along the bottom, and the only question is
/// "were you there?". Swipe up for the next one.
struct ImmersiveMomentCard: View {
    @Environment(AppEnvironment.self) private var env
    let moment: SocialMoment
    @State private var burst: String?
    @State private var showComments = false
    @State private var showShare = false
    @State private var showSubscribe = false
    @State private var showReplay = false
    @State private var shareItems: [Any] = []

    private var isMember: Bool { moment.memberIDs.contains(env.social.myID) }
    private var mine: ReactionKind? { env.social.myReaction(momentID: moment.id) }
    private var sides: [Contribution] { env.social.allContributions(moment.id).filter { $0.media != nil } }
    private var hidden: Bool { (moment.isTeaser && !isMember) || moment.isLocked }

    var body: some View {
        GeometryReader { g in
            card(size: g.size)
        }
    }

    private func card(size: CGSize) -> some View {
        ZStack(alignment: .bottomLeading) {
            NavigationLink(value: SocialRoute.moment(moment.id)) {
                SocialImage(ref: moment.coverRef)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .blur(radius: hidden ? 26 : 0)
                    .overlay(LinearGradient(colors: [.black.opacity(0.35), .clear, .clear, .black.opacity(0.55), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(moment.title)")
            .accessibilityIdentifier("open-\(moment.id)")

            if moment.isLocked { LockedOverlay(moment: moment) { showSubscribe = true }.padding(.bottom, 200) }

            // Bottom: who, what, the sides, the ask.
            VStack(alignment: .leading, spacing: MSpacing.m) {
                HStack(spacing: MSpacing.s) {
                    NavigationLink(value: SocialRoute.profile(moment.creatorID)) { AvatarView(userID: moment.creatorID, name: moment.creatorName, size: 30) }.buttonStyle(.plain)
                    NavigationLink(value: SocialRoute.profile(moment.creatorID)) { Text(moment.creatorName).font(.subheadline.weight(.semibold)) }.buttonStyle(.plain)
                    if moment.isLive { HStack(spacing: 4) { Circle().fill(MColor.danger).frame(width: 6, height: 6); Text("Live") }.font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 4).glassPill(tint: MColor.danger) }
                    if let p = moment.place { NavigationLink(value: SocialRoute.place(p)) { Label(p.name, systemImage: "mappin").font(MFont.caption).lineLimit(1) }.buttonStyle(.plain) }
                    else if let p = moment.coarsePlace, !p.isEmpty { Label(p, systemImage: "mappin").font(MFont.caption) }
                }
                .foregroundStyle(.white)
                Text(moment.title).font(MFont.hero).foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.7)
                HStack(spacing: MSpacing.s) {
                    AvatarStack(names: Array(moment.memberNames.prefix(4)), size: 24)
                    Text(peopleLine).font(MFont.subheadline).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                }
                if !sides.isEmpty && !hidden {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(sides.prefix(8)) { c in
                                NavigationLink(value: SocialRoute.moment(moment.id)) {
                                    SocialImage(ref: c.media).frame(width: 64, height: 84).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        .overlay(alignment: .bottomLeading) { Text(c.authorName.split(separator: " ").first.map(String.init) ?? "").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white).padding(4) }
                                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.4), lineWidth: 0.5))
                                }
                                .buttonStyle(.plain)
                            }
                            if moment.mediaCount > 8 { Text("+\(moment.mediaCount - 8)").font(.caption.weight(.semibold)).foregroundStyle(.white).frame(width: 44, height: 84).glass(radius: 10) }
                        }
                    }
                }
                HStack(spacing: MSpacing.s) {
                    cta
                    Spacer()
                    Text(moment.createdAt.formatted(.relative(presentation: .named))).font(MFont.caption).foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, MSpacing.page)
            .padding(.bottom, 96)
            .padding(.trailing, 64)
            .accessibilityElement(children: .contain)

            // Right rail: the dock.
            VStack(spacing: MSpacing.l) {
                dockButton(active: mine == .core, label: mine == .core ? "Unlike" : "Like", id: "react-core") {
                    if mine == nil { Haptics.saved(); burst = ReactionKind.core.emoji }
                    Task { await env.social.react(momentID: moment.id, kind: .core) }
                } icon: { Glyph(.spark, size: 24, filled: mine == .core).foregroundStyle(mine == .core ? Color(red: 1.0, green: 0.62, blue: 0.24) : .white) }
                    .overlay(alignment: .bottom) { if moment.reactionCounts.values.reduce(0, +) > 0 { Text("\(moment.reactionCounts.values.reduce(0, +))").font(.caption2.weight(.semibold)).foregroundStyle(.white).offset(y: 14) } }
                dockButton(active: false, label: "Comments", id: "comments-\(moment.id)") { showComments = true } icon: { Glyph(.reply, size: 24).foregroundStyle(.white) }
                    .overlay(alignment: .bottom) { if moment.commentCount > 0 { Text("\(moment.commentCount)").font(.caption2.weight(.semibold)).foregroundStyle(.white).offset(y: 14) } }
                dockButton(active: false, label: "Share", id: "share-\(moment.id)") { Task { await share() } } icon: { Glyph(.send, size: 24).foregroundStyle(.white) }
                if moment.mediaCount >= 3 && !hidden {
                    NavigationLink(value: SocialRoute.reels("c_\(moment.id)")) { Image(systemName: "play.fill").font(.title3).foregroundStyle(.white).frame(width: 46, height: 46) }
                        .buttonStyle(.plain).glass(radius: 23).accessibilityLabel("Watch the cut").accessibilityIdentifier("watch-\(moment.id)")
                } else if moment.mediaCount > 1 && !hidden {
                    dockButton(active: false, label: "Replay", id: "replay-\(moment.id)") { showReplay = true } icon: { Image(systemName: "play.fill").font(.title3).foregroundStyle(.white) }
                }
                if moment.creatorID != env.social.myID, env.social.plan(for: moment.creatorID) != nil {
                    TipButton(creatorID: moment.creatorID, creatorName: moment.creatorName, momentID: moment.id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, MSpacing.l)
            .padding(.bottom, 120)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .reactionBurst($burst)
        .sheet(isPresented: $showComments) { CommentsSheet(momentID: moment.id) }
        .sheet(isPresented: $showShare) { ShareSheet(items: shareItems) }
        .sheet(isPresented: $showSubscribe) { SubscribeSheet(creatorID: moment.creatorID) }
        .fullScreenCover(isPresented: $showReplay) { MomentReplayView(momentID: moment.id) }
        .task { if env.social.allContributions(moment.id).isEmpty, !hidden { _ = await env.social.loadMoment(moment.id) } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("feedMoment-\(moment.id)")
    }

    private var peopleLine: String {
        let others = moment.memberNames.enumerated().filter { moment.memberIDs[$0.offset] != env.social.myID }.map { $0.element.split(separator: " ").first.map(String.init) ?? $0.element }
        let you = isMember ? "You" : nil
        var parts: [String] = []
        if let you { parts.append(you) }
        parts.append(contentsOf: others.prefix(you == nil ? 2 : 1))
        let rest = moment.memberIDs.count - parts.count
        if rest > 0 { parts.append("\(rest) other\(rest == 1 ? "" : "s")") }
        return parts.joined(separator: ", ").replacingOccurrences(of: ", \(parts.last ?? "")", with: " and \(parts.last ?? "")") + " \(moment.memberIDs.count == 1 && !isMember ? "was" : "were") there"
    }

    @ViewBuilder private var cta: some View {
        if moment.isLocked {
            EmptyView()
        } else if isMember {
            NavigationLink(value: SocialRoute.addSide(moment.id)) { HStack(spacing: 6) { Glyph(.addSide, size: 18).foregroundStyle(.white); Text("Add your side") } }
                .buttonStyle(GlassButtonStyle(tint: Color("AccentColor"), filled: true)).accessibilityIdentifier("addYourSide")
        } else if moment.visibility == .subscribers {
            Label("Subscribers", systemImage: "crown.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.orange).padding(.horizontal, 12).padding(.vertical, 8).glassPill(tint: .orange)
        } else {
            Button { Task { if await env.social.join(momentID: moment.id) { env.toast("You're in.") } } } label: { Text("I was there") }
                .buttonStyle(GlassButtonStyle(tint: Color("AccentColor"), filled: true)).accessibilityIdentifier("iWasThere")
        }
    }

    private func dockButton(active: Bool, label: String, id: String, action: @escaping () -> Void, @ViewBuilder icon: () -> some View) -> some View {
        Button(action: action) { icon().frame(width: 46, height: 46) }
            .buttonStyle(.plain)
            .glass(radius: 23, tint: active ? .orange : nil)
            .accessibilityLabel(label)
            .accessibilityIdentifier(id)
    }

    private func share() async {
        guard let url = await env.social.shareLink(momentID: moment.id) else { return }
        shareItems = ["\(moment.title) — you were there. Add your side on MOMENT.", url]
        showShare = true
    }
}

/// The stack itself: paged, full-bleed, with a glass header (wordmark, NOW, scan, activity) and the stories strip on top.
struct ImmersiveFeedView: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var showNowComposer: Bool
    @Binding var selectedNow: NowPost?
    @Binding var showScanner: Bool

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    if env.social.feed.isEmpty && !env.social.hasLoadedOnce && env.social.accountStatus != .noAccount {
                        SkeletonFeedCard().padding(MSpacing.m).containerRelativeFrame(.vertical)
                    } else if env.social.feed.isEmpty && env.social.hasLoadedOnce {
                        VStack { Spacer(); EmptyMoments().padding(MSpacing.page); Spacer() }.containerRelativeFrame(.vertical)
                    }
                    ForEach(env.social.feed, id: \.moment.id) { scored in
                        ImmersiveMomentCard(moment: scored.moment)
                            .containerRelativeFrame(.vertical)
                            .onAppear { env.social.markSeen(scored.moment.id) }
                    }
                    if let tm = env.social.timeMachine.first, let m = tm.moments.first {
                        VStack(alignment: .leading, spacing: MSpacing.m) {
                            Spacer()
                            Text("Memories").sectionLabel()
                            TimeMachineCard(yearsAgo: tm.yearsAgo, moment: m)
                            Spacer()
                        }
                        .padding(MSpacing.page).padding(.bottom, 90)
                        .containerRelativeFrame(.vertical)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .ignoresSafeArea()
            .background(Color.black)

            header.zIndex(1)
        }
    }

    @AppStorage("homeTab") private var homeTab = 0

    private var header: some View {
        VStack(spacing: MSpacing.s) {
            HStack(spacing: MSpacing.s) {
                Image("LogoMark").resizable().scaledToFit().frame(width: 26, height: 26)
                Picker("Home", selection: $homeTab) { Text("Feed").tag(0); Text("Moments").tag(1) }
                    .pickerStyle(.segmented).frame(width: 190).colorScheme(.dark)
                    .accessibilityIdentifier("homeTabs")
                Spacer()
                NavigationLink(value: SocialRoute.reels(nil)) { Image(systemName: "play.rectangle.fill").font(.subheadline).foregroundStyle(.white).frame(width: 34, height: 34) }
                    .glass(radius: 17).accessibilityIdentifier("reelsLink")
                NavigationLink(value: SocialRoute.now) { Glyph(.now, size: 18).foregroundStyle(.white).frame(width: 34, height: 34) }
                    .glass(radius: 17).accessibilityLabel("Now").accessibilityIdentifier("nowLink")
                NavigationLink(value: SocialRoute.nearby) { Glyph(.nearby, size: 18).foregroundStyle(.white).frame(width: 34, height: 34) }
                    .glass(radius: 17).accessibilityLabel("Nearby").accessibilityIdentifier("nearbyLink")
                Button { showScanner = true } label: { Glyph(.scan, size: 18).foregroundStyle(.white).frame(width: 34, height: 34) }
                    .glass(radius: 17).accessibilityLabel("Scan to join").accessibilityIdentifier("scanQR")
                NavigationLink(value: SocialRoute.inbox) {
                    Glyph(.activity, size: 18).foregroundStyle(.white).frame(width: 34, height: 34)
                        .overlay(alignment: .topTrailing) { if env.social.unreadActivity > 0 { Circle().fill(MColor.danger).frame(width: 7, height: 7).offset(x: -3, y: 3) } }
                }
                .glass(radius: 17).accessibilityLabel("Activity").accessibilityIdentifier("inboxButton")
            }
            .padding(.horizontal, MSpacing.page)
            StoriesRow(showComposer: $showNowComposer, selectedNow: $selectedNow, onDark: true)
            AccountBanner().padding(.horizontal, MSpacing.m)
            UploadBanner().padding(.horizontal, MSpacing.m)
        }
        .padding(.top, MSpacing.s)
        .padding(.bottom, MSpacing.s)
        .background(LinearGradient(colors: [.black.opacity(0.75), .black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom).ignoresSafeArea(edges: .top))
    }
}
