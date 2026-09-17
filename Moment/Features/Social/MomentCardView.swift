import SwiftUI

/// A single shareable image of a Moment: cover, title, who was there, count. 1080×1350 (4:5) so it
/// drops straight into Instagram/WhatsApp. Rendered from the same SwiftUI view you preview.
struct MomentCardView: View {
    let moment: SocialMoment
    let cover: UIImage?
    let tint: Color
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let cover { Image(uiImage: cover).resizable().scaledToFill() } else { LinearGradient(colors: [tint, tint.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing) }
            }
            .frame(width: 360, height: 450).clipped()
            LinearGradient(colors: [.black.opacity(0.1), .clear, tint.opacity(0.4), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 10) {
                if moment.isLive { Text("HAPPENING NOW").font(.system(size: 11, weight: .bold)).tracking(1.2).foregroundStyle(MColor.overlayLight).padding(.horizontal, 8).padding(.vertical, 4).background(.red, in: Capsule()) }
                Text(moment.title).font(.system(size: 34, weight: .bold, design: .serif)).foregroundStyle(MColor.overlayLight).lineLimit(3).minimumScaleFactor(0.7)
                HStack(spacing: 6) {
                    Text(moment.dateLabel)
                    if let p = moment.coarsePlace, !p.isEmpty { Text("·"); Text(p) }
                }
                .font(.system(size: 14, weight: .medium)).foregroundStyle(MColor.overlayLight.opacity(0.9))
                HStack(spacing: 8) {
                    HStack(spacing: -8) { ForEach(Array(moment.memberNames.prefix(4).enumerated()), id: \.offset) { _, n in PersonAvatar(name: n, size: 26).overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5)) } }
                    Text(peopleLine).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Spacer()
                    Text("MOMENT").font(.system(size: 11, weight: .heavy)).tracking(2).foregroundStyle(.white.opacity(0.8))
                }
            }
            .padding(22)
        }
        .frame(width: 360, height: 450)
        .clipShape(RoundedRectangle(cornerRadius: 0))
    }
    private var peopleLine: String {
        let n = moment.memberIDs.count
        return n <= 1 ? "1 person" : "\(n) people were there"
    }
}

/// Preview + share for the card. Free, unlimited — it is the invite that travels.
struct MomentCardSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let moment: SocialMoment
    @State private var cover: UIImage?
    @State private var tint: Color = MColor.accent
    @State private var items: [Any] = []
    @State private var showShare = false

    var body: some View {
        NavigationStack {
            VStack(spacing: MSpacing.l) {
                MomentCardView(moment: moment, cover: cover, tint: tint)
                    .clipShape(RoundedRectangle(cornerRadius: MRadius.card, style: .continuous))
                    .shadow(color: tint.opacity(0.35), radius: 24, y: 12)
                    .scaleEffect(0.86)
                Text("A card for the people who weren't there — and the ones who were. The invite link goes with it.").font(MFont.footnote).foregroundStyle(MColor.textSecondary).multilineTextAlignment(.center).padding(.horizontal, MSpacing.xl)
                Button { Task { await share() } } label: { Label("Share card", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }.buttonStyle(PrimaryButtonStyle()).padding(.horizontal, MSpacing.l).accessibilityIdentifier("shareCard")
            }
            .padding(.top, MSpacing.s)
            .background(MColor.background)
            .navigationTitle("Moment Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { cover = await env.social.image(for: moment.coverRef); tint = await env.social.tint(for: moment) }
            .sheet(isPresented: $showShare) { ShareSheet(items: items) }
        }
    }

    @MainActor private func share() async {
        let renderer = ImageRenderer(content: MomentCardView(moment: moment, cover: cover, tint: tint))
        renderer.scale = 3
        guard let ui = renderer.uiImage, let data = ui.jpegData(compressionQuality: 0.92) else { return }
        let url = FileManager.default.temporaryDirectory.appending(path: "\(moment.title.replacingOccurrences(of: #"[^A-Za-z0-9 _-]"#, with: "", options: .regularExpression).trimmed.isEmpty ? "Moment" : moment.title.replacingOccurrences(of: #"[^A-Za-z0-9 _-]"#, with: "", options: .regularExpression).trimmed).jpg")
        try? data.write(to: url, options: .atomic)
        var out: [Any] = [url]
        var link = moment.shareURL
        if link == nil, moment.creatorID == env.social.myID { link = await env.social.shareLink(momentID: moment.id) }
        if let link { out.append(link) }
        items = out
        env.analytics.track(.momentShared, category: "card")
        showShare = true
    }
}
