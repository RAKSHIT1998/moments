import SwiftUI

/// Cinematic replay: every side in the order it happened, with the clock running. No narration —
/// just the timeline, people joining, and the media.
struct MomentReplayView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let momentID: String
    @State private var index = 0
    @State private var playing = true
    @State private var progress = 0.0
    @State private var exported: [Any] = []
    @State private var showShare = false
    private let secondsPerItem = 3.2

    private struct Beat: Identifiable { let id: String; let time: Date; let kind: Kind; enum Kind { case media(Contribution), note(Contribution), joined(String) } }

    private var beats: [Beat] {
        let all = env.social.allContributions(momentID).filter { $0.uploadState == .uploaded }.sorted { ($0.originalTimestamp ?? $0.createdAt) < ($1.originalTimestamp ?? $1.createdAt) }
        var seen = Set<String>()
        var out: [Beat] = []
        for c in all {
            let t = c.originalTimestamp ?? c.createdAt
            if seen.insert(c.authorID).inserted, c.authorID != env.social.moments[momentID]?.creatorID { out.append(Beat(id: "join-\(c.authorID)", time: t, kind: .joined(c.authorName))) }
            out.append(Beat(id: c.id, time: t, kind: c.kind == .text ? .note(c) : .media(c)))
        }
        return out
    }

    var body: some View {
        let items = beats
        ZStack {
            Color.black.ignoresSafeArea()
            if items.isEmpty {
                ContentUnavailableView("Nothing to replay yet", systemImage: "play.slash", description: Text("Add a few sides first.")).foregroundStyle(MColor.overlayLight)
            } else {
                let beat = items[min(index, items.count - 1)]
                ZStack {
                    switch beat.kind {
                    case .media(let c):
                        SocialImage(ref: c.media, contentMode: .fill).ignoresSafeArea()
                            .scaleEffect(reduceMotion ? 1 : 1 + progress * 0.06)
                            .overlay(LinearGradient(colors: [MColor.overlayDark.opacity(0.5), .clear, .clear, MColor.overlayDark.opacity(0.7)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
                    case .note(let c):
                        AmbientBackdrop(intensity: 1.5).ignoresSafeArea()
                        Text("“\(c.caption)”").font(.system(size: 30, weight: .semibold, design: .serif)).foregroundStyle(MColor.overlayLight).multilineTextAlignment(.center).padding(MSpacing.xxl)
                    case .joined(let name):
                        MColor.overlayDark
                        VStack(spacing: MSpacing.m) { PersonAvatar(name: name, size: 88); Text("\(name) joined").font(MFont.heroSmall).foregroundStyle(MColor.overlayLight) }
                    }
                }
                .id(beat.id)
                .transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .scale(scale: 1.04)), removal: .opacity))
                .animation(.easeInOut(duration: 0.5), value: index)

                VStack {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(env.social.moments[momentID]?.title ?? "").font(MFont.headline).foregroundStyle(MColor.overlayLight)
                            Text(beat.time.formatted(date: .omitted, time: .shortened)).font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(MColor.overlayLight).monospacedDigit().contentTransition(.numericText())
                        }
                        Spacer()
                        Button {
                            playing = false
                            Task { if let url = await env.social.exportReplay(momentID: momentID) { exported = [url]; showShare = true } }
                        } label: {
                            Group { if env.social.exportingReplay { ProgressView().tint(MColor.overlayLight) } else { Image(systemName: "square.and.arrow.up") } }
                                .font(.headline).foregroundStyle(MColor.overlayLight).frame(width: 36, height: 36).background(MColor.overlayDark.opacity(0.4), in: Circle())
                        }
                        .disabled(env.social.exportingReplay).accessibilityLabel("Share as video").accessibilityIdentifier("shareReplay")
                        Button { dismiss() } label: { Image(systemName: "xmark").font(.headline).foregroundStyle(MColor.overlayLight).frame(width: 36, height: 36).background(MColor.overlayDark.opacity(0.4), in: Circle()) }.accessibilityLabel("Close")
                    }
                    .padding(MSpacing.l)
                    Spacer()
                    VStack(alignment: .leading, spacing: MSpacing.s) {
                        if case .media(let c) = beat.kind {
                            HStack(spacing: 8) { PersonAvatar(name: c.authorName, size: 28); Text(c.authorID == env.social.myID ? "You" : c.authorName).font(.subheadline.weight(.semibold)).foregroundStyle(MColor.overlayLight); if !c.caption.isEmpty { Text("· \(c.caption)").font(MFont.footnote).foregroundStyle(MColor.overlayLight.opacity(0.85)).lineLimit(1) } }
                        }
                        HStack(spacing: 4) {
                            ForEach(items.indices, id: \.self) { i in
                                Capsule().fill(MColor.overlayLight.opacity(i < index ? 1 : i == index ? 0.9 : 0.3)).frame(height: 3)
                                    .overlay(alignment: .leading) { if i == index { GeometryReader { g in Capsule().fill(MColor.overlayLight).frame(width: g.size.width * progress) } } }
                            }
                        }
                        HStack {
                            Button { playing.toggle() } label: { Image(systemName: playing ? "pause.fill" : "play.fill").foregroundStyle(MColor.overlayLight).frame(width: 44, height: 44) }.accessibilityLabel(playing ? "Pause" : "Play")
                            Spacer()
                            Text("\(index + 1) / \(items.count)").font(MFont.caption).foregroundStyle(MColor.overlayLight.opacity(0.8)).monospacedDigit()
                        }
                    }
                    .padding(MSpacing.l)
                }
                HStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle()).onTapGesture { step(-1, count: items.count) }
                    Color.clear.contentShape(Rectangle()).onTapGesture { step(1, count: items.count) }
                }
                .padding(.vertical, 120)
            }
        }
        .sheet(isPresented: $showShare) { ShareSheet(items: exported) }
        .task(id: index) {
            progress = 0
            while progress < 1 {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
                if playing { progress = min(1, progress + 0.05 / secondsPerItem) }
            }
            step(1, count: beats.count)
        }
        .environment(\.colorScheme, .dark)   // local to this view; preferredColorScheme would flip the whole window
        .accessibilityIdentifier("replayView")
    }

    private func step(_ d: Int, count: Int) {
        let next = index + d
        if next < 0 { index = 0; return }
        if next >= count { dismiss(); return }
        index = next
    }
}
