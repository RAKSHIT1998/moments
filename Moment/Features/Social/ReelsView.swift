import SwiftUI
import AVKit

/// Vertical, full-bleed, autoplaying. The difference from every other reel feed: what you're watching
/// was made by everyone who was there, it keeps growing as they add sides, and you can step into it.
struct ReelsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    var startAt: String? = nil
    @State private var current: String = ""
    @State private var muted = true

    private var reels: [Reel] { env.social.reels }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if reels.isEmpty {
                VStack(spacing: MSpacing.m) {
                    Spacer()
                    Text(env.social.hasLoadedOnce ? "No reels yet." : "Loading…").font(MFont.title).foregroundStyle(.white)
                    Text("A reel appears when a night has three sides in it — or when someone adds a video. Add yours and the cut updates for everyone.").font(MFont.subheadline).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                    NavigationLink(value: SocialRoute.newMoment) { Text("Start a Moment") }.buttonStyle(GlassButtonStyle(filled: true))
                    Spacer()
                }
                .padding(MSpacing.page)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(reels) { r in
                            ReelPage(reel: r, isCurrent: current == r.id, muted: $muted)
                                .containerRelativeFrame(.vertical)
                                .id(r.id)
                                .onAppear { current = r.id; env.social.markReelSeen(r.id) }
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: Binding(get: { Optional(current) }, set: { if let v = $0 { current = v } }))
                .ignoresSafeArea()
            }
            header
        }
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(false)
        .task {
            await env.social.refreshReels()
            current = startAt ?? reels.first?.id ?? ""
        }
        .onChange(of: scenePhase) { _, p in if p != .active { current = "" } }   // pause everything in the background
        .modifier(SocialErrorAlert())
    }

    private var header: some View {
        HStack(spacing: MSpacing.m) {
            Button { dismiss() } label: { Image(systemName: "chevron.down").font(.headline).foregroundStyle(.white).frame(width: 36, height: 36) }
                .glass(radius: 18).accessibilityLabel("Close reels")
            Text("Reels").font(MFont.headline).foregroundStyle(.white)
            Spacer()
            Button { muted.toggle() } label: { Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.subheadline).foregroundStyle(.white).frame(width: 36, height: 36) }
                .glass(radius: 18).accessibilityLabel(muted ? "Unmute" : "Mute").accessibilityIdentifier("reelsMute")
        }
        .padding(.horizontal, MSpacing.page)
        .padding(.top, MSpacing.s)
    }
}

/// One reel: the media, who was there, and the ways in.
struct ReelPage: View {
    @Environment(AppEnvironment.self) private var env
    let reel: Reel
    var isCurrent: Bool
    @Binding var muted: Bool
    @State private var burst: String?
    @State private var showComments = false
    @State private var showShare = false
    @State private var shareItems: [Any] = []
    @State private var exporting = false

    private var isMember: Bool { reel.memberIDs.contains(env.social.myID) }
    private var mine: ReactionKind? { env.social.myReaction(momentID: reel.momentID) }

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .bottomLeading) {
                media.frame(width: g.size.width, height: g.size.height).clipped()
                    .overlay(LinearGradient(colors: [.black.opacity(0.3), .clear, .clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                bottom
                dock
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .reactionBurst($burst)
        .sheet(isPresented: $showComments) { CommentsSheet(momentID: reel.momentID) }
        .sheet(isPresented: $showShare) { ShareSheet(items: shareItems) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reel-\(reel.id)")
    }

    @ViewBuilder private var media: some View {
        switch reel.kind {
        case .video(let c): ReelVideo(contribution: c, isCurrent: isCurrent, muted: $muted)
        case .cut(let sides): ReelCut(sides: sides, isCurrent: isCurrent)
        }
    }

    private var bottom: some View {
        VStack(alignment: .leading, spacing: MSpacing.s) {
            HStack(spacing: MSpacing.s) {
                NavigationLink(value: SocialRoute.profile(reel.creatorID)) { AvatarView(userID: reel.creatorID, name: reel.creatorName, size: 30) }.buttonStyle(.plain)
                Text(reel.authorLine).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                if reel.isLive { HStack(spacing: 4) { Circle().fill(MColor.danger).frame(width: 6, height: 6); Text("Live") }.font(.caption.weight(.semibold)).foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 4).glassPill(tint: MColor.danger) }
                if reel.isCut { Text("Everyone's cut").font(.caption.weight(.semibold)).foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 4).glassPill(tint: MColor.accent) }
            }
            NavigationLink(value: SocialRoute.moment(reel.momentID)) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(reel.title).font(MFont.heroSmall).foregroundStyle(.white).lineLimit(2).multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        if let p = reel.place { Label(p.name, systemImage: "mappin").font(MFont.caption) }
                        else if let p = reel.coarsePlace, !p.isEmpty { Label(p, systemImage: "mappin").font(MFont.caption) }
                        Text("\(reel.memberIDs.count) \(reel.memberIDs.count == 1 ? "person" : "people") · \(reel.contributionCount) sides").font(MFont.caption)
                    }
                    .foregroundStyle(.white.opacity(0.85))
                }
            }
            .buttonStyle(.plain)
            HStack(spacing: MSpacing.s) {
                if isMember {
                    NavigationLink(value: SocialRoute.addSide(reel.momentID)) { HStack(spacing: 6) { Glyph(.addSide, size: 18).foregroundStyle(.white); Text("Add your side") } }
                        .buttonStyle(GlassButtonStyle(tint: Color("AccentColor"), filled: true)).accessibilityIdentifier("reelAddSide")
                } else {
                    Button { Task { if await env.social.join(momentID: reel.momentID) { env.toast("You're in.") } } } label: { Text("I was there") }
                        .buttonStyle(GlassButtonStyle(tint: Color("AccentColor"), filled: true)).accessibilityIdentifier("reelIWasThere")
                }
                if reel.isCut { Text("Grows as people add").font(MFont.caption).foregroundStyle(.white.opacity(0.7)) }
            }
        }
        .padding(.horizontal, MSpacing.page)
        .padding(.bottom, 84)
        .padding(.trailing, 72)
    }

    private var dock: some View {
        VStack(spacing: MSpacing.l) {
            dockButton(label: mine == .core ? "Unlike" : "Like", id: "reelLike-\(reel.id)", count: reel.reactionCount, active: mine == .core) {
                if mine == nil { Haptics.saved(); burst = ReactionKind.core.emoji }
                Task { await env.social.react(momentID: reel.momentID, kind: .core) }
            } icon: { Glyph(.spark, size: 24, filled: mine == .core).foregroundStyle(mine == .core ? Color(red: 1.0, green: 0.62, blue: 0.24) : .white) }
            dockButton(label: "Comments", id: "reelComments-\(reel.id)", count: reel.commentCount, active: false) { showComments = true } icon: { Glyph(.reply, size: 24).foregroundStyle(.white) }
            dockButton(label: "Share", id: "reelShare-\(reel.id)", count: 0, active: false) { Task { await share() } } icon: {
                Group { if exporting { ProgressView().tint(.white) } else { Glyph(.send, size: 24).foregroundStyle(.white) } }
            }
            if reel.creatorID != env.social.myID, env.social.plan(for: reel.creatorID) != nil {
                TipButton(creatorID: reel.creatorID, creatorName: reel.creatorName, momentID: reel.momentID)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, MSpacing.l)
        .padding(.bottom, 96)
    }

    private func dockButton(label: String, id: String, count: Int, active: Bool, action: @escaping () -> Void, @ViewBuilder icon: () -> some View) -> some View {
        Button(action: action) { icon().frame(width: 46, height: 46) }
            .buttonStyle(.plain).glass(radius: 23, tint: active ? .orange : nil)
            .overlay(alignment: .bottom) { if count > 0 { Text("\(count)").font(.caption2.weight(.semibold)).foregroundStyle(.white).offset(y: 14) } }
            .accessibilityLabel(label).accessibilityIdentifier(id)
    }

    /// Sharing a cut shares the real video (the Replay export); a video side shares the link.
    private func share() async {
        if reel.isCut {
            exporting = true; defer { exporting = false }
            if let url = await env.social.exportReplay(momentID: reel.momentID) { shareItems = [url]; showShare = true; return }
        }
        if let url = await env.social.shareLink(momentID: reel.momentID) {
            shareItems = ["\(reel.title) — everyone's story of that night, on MOMENT.", url]; showShare = true
        }
    }
}

/// A video side, looping, muted by default like every reel feed.
struct ReelVideo: View {
    @Environment(AppEnvironment.self) private var env
    let contribution: Contribution
    var isCurrent: Bool
    @Binding var muted: Bool
    @State private var player: AVPlayer?
    @State private var looper: Any?

    var body: some View {
        ZStack {
            Color.black
            if let player { VideoPlayerLayer(player: player).allowsHitTesting(false) }
            else { SocialImage(ref: contribution.media).allowsHitTesting(false) }
        }
        .task(id: contribution.id) {
            guard player == nil, let ref = contribution.media, let url = await env.social.videoURL(for: ref) else { return }
            let item = AVPlayerItem(url: url)
            let p = AVQueuePlayer(playerItem: item)
            looper = AVPlayerLooper(player: p, templateItem: item)
            p.isMuted = muted
            player = p
            if isCurrent { p.play() }
        }
        .onChange(of: isCurrent) { _, on in on ? player?.play() : player?.pause() }
        .onChange(of: muted) { _, m in player?.isMuted = m }
        .onDisappear { player?.pause() }
    }
}

/// The cut: everyone's sides, in order, with a slow push-in — the same beats the Replay video exports.
struct ReelCut: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let sides: [Contribution]
    var isCurrent: Bool
    @State private var index = 0
    @State private var zoom = 1.0
    private let perSide = 2.6

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
            if !sides.isEmpty {
                let c = sides[min(index, sides.count - 1)]
                SocialImage(ref: c.media).scaleEffect(reduceMotion ? 1 : zoom).animation(.linear(duration: perSide), value: zoom).id(c.id)
                    .transition(.opacity)
                    .overlay(alignment: .bottomLeading) {
                        Text(c.authorID == env.social.myID ? "You" : c.authorName).font(.caption.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5).glassPill()
                            .padding(.leading, MSpacing.page).padding(.bottom, 170)
                    }
                HStack(spacing: 3) {
                    ForEach(sides.indices, id: \.self) { i in Capsule().fill(.white.opacity(i <= index ? 0.95 : 0.3)).frame(height: 2.5) }
                }
                .padding(.horizontal, MSpacing.page).padding(.top, 54)
            }
        }
        .task(id: isCurrent) {
            guard isCurrent, sides.count > 1 else { return }
            zoom = 1.06
            while !Task.isCancelled && isCurrent {
                try? await Task.sleep(for: .seconds(perSide))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.45)) { index = (index + 1) % sides.count }
                zoom = 1.0; withAnimation(.linear(duration: perSide)) { zoom = 1.06 }
            }
        }
    }
}

/// AVPlayerLayer filling the frame — VideoPlayer's controls have no place in a reel.
struct VideoPlayerLayer: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerView { let v = PlayerView(); v.playerLayer.player = player; v.playerLayer.videoGravity = .resizeAspectFill; return v }
    func updateUIView(_ v: PlayerView, context: Context) { v.playerLayer.player = player }
    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
