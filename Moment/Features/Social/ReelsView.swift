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
                    Text("Video posts show up here. Creators you follow or pay, newest first.").font(MFont.subheadline).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                    NavigationLink(value: SocialRoute.studio) { Text("Post a video") }.buttonStyle(GlassButtonStyle(filled: true))
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

/// One reel: the clip, who made it, and the way in when it's locked.
struct ReelPage: View {
    @Environment(AppEnvironment.self) private var env
    let reel: Reel
    var isCurrent: Bool
    @Binding var muted: Bool
    @State private var buying: VaultSet?
    @State private var showComments = false

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
        .sheet(item: $buying) { s in BuySetSheet(set: s) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reel-\(reel.id)")
    }

    @ViewBuilder private var media: some View {
        if let video = reel.video {
            ReelVideo(ref: video, isCurrent: isCurrent, muted: $muted)
        } else {
            ZStack {
                SocialImage(ref: reel.cover).blur(radius: 26)
                Rectangle().fill(.black.opacity(0.25))
                VStack(spacing: MSpacing.m) {
                    Image(systemName: "lock.fill").font(.title).foregroundStyle(.white)
                    if case .buy(let minor, let currency) = reel.gate {
                        Button {
                            buying = env.social.sets(of: reel.creatorID).first { $0.id == reel.setID }
                        } label: {
                            Text("Unlock · \((Double(minor) / 100).formatted(.currency(code: currency).precision(.fractionLength(0))))")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 22).padding(.vertical, 12)
                                .background(Capsule().fill(MColor.accent))
                        }
                        .buttonStyle(.plain).accessibilityIdentifier("unlockReel-\(reel.setID)")
                    }
                }
            }
        }
    }

    private var bottom: some View {
        VStack(alignment: .leading, spacing: MSpacing.s) {
            HStack(spacing: MSpacing.s) {
                NavigationLink(value: SocialRoute.profile(reel.creatorID)) { AvatarView(userID: reel.creatorID, name: reel.creatorName, size: 32) }.buttonStyle(.plain)
                NavigationLink(value: SocialRoute.profile(reel.creatorID)) { Text(reel.creatorName).font(.subheadline.weight(.semibold)).foregroundStyle(.white) }.buttonStyle(.plain)
                if env.social.plan(for: reel.creatorID) != nil, !env.social.isSubscribed(to: reel.creatorID), reel.creatorID != env.social.myID {
                    NavigationLink(value: SocialRoute.profile(reel.creatorID)) { Text("Subscribe").font(.caption.weight(.bold)).foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 5).background(Capsule().fill(MColor.accent)) }
                        .buttonStyle(.plain)
                }
            }
            Text(reel.title).font(MFont.headline).foregroundStyle(.white).lineLimit(2)
            if !reel.blurb.isEmpty { Text(reel.blurb).font(MFont.subheadline).foregroundStyle(.white.opacity(0.85)).lineLimit(2) }
        }
        .padding(.horizontal, MSpacing.page)
        .padding(.bottom, 84)
        .padding(.trailing, 72)
    }

    private var dock: some View {
        VStack(spacing: MSpacing.l) {
            NavigationLink(value: SocialRoute.storefront(reel.creatorID)) {
                Image(systemName: "bag.fill").font(.title3).foregroundStyle(.white).frame(width: 46, height: 46)
            }
            .buttonStyle(.plain).glass(radius: 23).accessibilityLabel("Shop").accessibilityIdentifier("reelShop-\(reel.id)")
            if reel.creatorID != env.social.myID, env.social.plan(for: reel.creatorID) != nil {
                TipButton(creatorID: reel.creatorID, creatorName: reel.creatorName, momentID: nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, MSpacing.l)
        .padding(.bottom, 96)
        .opacity(showComments ? 0 : 1)
    }
}

/// A video side, looping, muted by default like every reel feed.
struct ReelVideo: View {
    @Environment(AppEnvironment.self) private var env
    let ref: MediaRef
    var isCurrent: Bool
    @Binding var muted: Bool
    @State private var player: AVPlayer?
    @State private var looper: Any?

    var body: some View {
        ZStack {
            Color.black
            if let player { VideoPlayerLayer(player: player).allowsHitTesting(false) }
            else { Color.black }
        }
        .task(id: ref.remoteID ?? ref.localRef ?? "") {
            guard player == nil, let url = await env.social.videoURL(for: ref) else { return }
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
