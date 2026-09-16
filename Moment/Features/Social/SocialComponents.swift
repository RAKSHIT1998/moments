import SwiftUI

/// Loads a `MediaRef` through the social service (local first, then backend) with a soft placeholder.
struct SocialImage: View {
    @Environment(AppEnvironment.self) private var env
    let ref: MediaRef?
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?

    var body: some View {
        // The rectangle takes whatever frame the caller proposes; the image is an overlay clipped to it.
        Rectangle().fill(MColor.fill)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
                } else if ref != nil {
                    ProgressView().tint(MColor.textTertiary)
                } else {
                    Image(systemName: "photo").foregroundStyle(MColor.textTertiary)
                }
            }
            .clipped()
        .task(id: ref) { image = await env.social.image(for: ref) }
    }
}

/// Overlapping avatars: "Rahul, Sarah + you".
struct AvatarStack: View {
    let names: [String]
    var size: CGFloat = 28
    var max: Int = 4
    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(Array(names.prefix(max).enumerated()), id: \.offset) { _, n in
                PersonAvatar(name: n, size: size).overlay(Circle().strokeBorder(MColor.background, lineWidth: 2))
            }
            if names.count > max {
                Text("+\(names.count - max)").font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(MColor.textPrimary)
                    .frame(width: size, height: size).background(MColor.surfaceSecondary, in: Circle()).overlay(Circle().strokeBorder(MColor.background, lineWidth: 2))
            }
        }
        .accessibilityLabel(names.joined(separator: ", "))
    }
}

/// The reaction row under a Moment or contribution. One tap toggles; long-press opens the full set.
struct ReactionBar: View {
    @Environment(AppEnvironment.self) private var env
    let momentID: String
    var contributionID: String? = nil
    let counts: [String: Int]
    var compact = false
    var onReact: ((ReactionKind) -> Void)? = nil
    @State private var showAll = false

    private var shown: [ReactionKind] {
        let used = ReactionKind.allCases.filter { (counts[$0.rawValue] ?? 0) > 0 }
        let base = used.isEmpty ? [ReactionKind.core, .forgot, .unreal] : used
        return compact ? Array(base.prefix(3)) : base
    }

    var body: some View {
        HStack(spacing: MSpacing.s) {
            ForEach(shown, id: \.self) { kind in
                let mine = env.social.myReaction(momentID: momentID, contributionID: contributionID) == kind
                Button {
                    if !mine { Haptics.saved(); onReact?(kind) }
                    Task { await env.social.react(momentID: momentID, contributionID: contributionID, kind: kind) }
                } label: {
                    HStack(spacing: 4) {
                        Text(kind.emoji)
                        if let c = counts[kind.rawValue], c > 0 { Text("\(c)").font(MFont.caption).monospacedDigit() }
                    }
                }
                .buttonStyle(ChipButtonStyle(prominent: mine))
                .accessibilityLabel("\(kind.label)\(mine ? ", selected" : "")")
                .accessibilityIdentifier("react-\(kind.rawValue)")
            }
            Button { showAll = true } label: { Image(systemName: "face.smiling").font(.subheadline) }
                .buttonStyle(ChipButtonStyle())
                .accessibilityLabel("More reactions")
        }
        .sheet(isPresented: $showAll) {
            ReactionPicker(momentID: momentID, contributionID: contributionID, onReact: onReact)
                .presentationDetents([.height(220)])
        }
    }
}

struct ReactionPicker: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let momentID: String
    var contributionID: String?
    var onReact: ((ReactionKind) -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: MSpacing.l) {
            Text("React").font(MFont.headline).padding(.top, MSpacing.l)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84))], spacing: MSpacing.m) {
                ForEach(ReactionKind.allCases, id: \.self) { kind in
                    Button {
                        Haptics.saved(); onReact?(kind)
                        Task { await env.social.react(momentID: momentID, contributionID: contributionID, kind: kind) }
                        dismiss()
                    } label: {
                        VStack(spacing: 4) {
                            Text(kind.emoji).font(.title2)
                            Text(kind.label).font(MFont.caption).foregroundStyle(MColor.textSecondary).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, MSpacing.s)
                        .background(MColor.surfaceSecondary, in: RoundedRectangle(cornerRadius: MRadius.chip, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, MSpacing.l)
        .presentationDragIndicator(.visible)
    }
}

/// A Moment in a list: cover, title, who was there, why it's here.
struct MomentFeedCard: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let moment: SocialMoment
    var reason: String? = nil
    @State private var tint: Color = MColor.accent
    @State private var burst: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                SocialImage(ref: moment.coverRef).frame(height: 300).frame(maxWidth: .infinity)
                LinearGradient(colors: [.black.opacity(0.15), .clear, tint.opacity(0.35), .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: MSpacing.xs) {
                    if moment.isLive {
                        Label("LIVE", systemImage: "dot.radiowaves.left.and.right").font(MFont.eyebrow).foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 4).background(MColor.danger, in: Capsule())
                    }
                    Text(moment.title).font(MFont.heroSmall).foregroundStyle(.white).lineLimit(2).shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                    HStack(spacing: 6) {
                        Text(moment.dateLabel)
                        if let p = moment.coarsePlace, !p.isEmpty { Text("·"); Text(p) }
                        if moment.mediaCount > 0 { Text("·"); Text("\(moment.mediaCount) photos") }
                    }
                    .font(MFont.footnote).foregroundStyle(.white.opacity(0.9))
                }
                .padding(MSpacing.l)
                if let mine = env.social.myReaction(momentID: moment.id) {
                    Text(mine.emoji).font(.title3).padding(8).background(.ultraThinMaterial, in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(MSpacing.m)
                        .accessibilityLabel("You reacted \(mine.label)")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                // Double-tap = core memory. Instant feedback, then the backend.
                Haptics.saved(); burst = ReactionKind.core.emoji
                Task { await env.social.react(momentID: moment.id, kind: .core) }
            }
            HStack(spacing: MSpacing.m) {
                AvatarStack(names: moment.memberNames.map { $0 == env.social.displayName ? "You" : $0 }, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(peopleLine).font(MFont.subheadline).foregroundStyle(MColor.textPrimary).lineLimit(1)
                    if let reason { Text(reason).font(MFont.caption).foregroundStyle(MColor.textSecondary).lineLimit(2) }
                }
                Spacer()
                if moment.memberIDs.contains(env.social.myID) {
                    Text("ADD YOUR SIDE").font(MFont.eyebrow).foregroundStyle(MColor.accent)
                } else {
                    Image(systemName: moment.visibility.symbol).foregroundStyle(MColor.textTertiary)
                }
            }
            .padding(MSpacing.l)
        }
        .background(MColor.surface, in: RoundedRectangle(cornerRadius: MRadius.card, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: MRadius.card, style: .continuous))
        .shadow(color: tint.opacity(0.18), radius: 18, y: 10)
        .reactionBurst($burst)
        .scrollTransition(.interactive, axis: .vertical) { content, phase in
            content.scaleEffect(reduceMotion ? 1 : (phase.isIdentity ? 1 : 0.96)).opacity(phase.isIdentity ? 1 : 0.75)
        }
        .task(id: moment.coverRef) { tint = await env.social.tint(for: moment) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("feedMoment-\(moment.id)")
    }

    private var peopleLine: String {
        let others = moment.memberNames.filter { $0 != env.social.displayName }.map { $0.split(separator: " ").first.map(String.init) ?? $0 }
        let me = moment.memberIDs.contains(env.social.myID)
        switch (others.count, me) {
        case (0, _): return "Just you"
        case (1, true): return "\(others[0]) + you"
        case (2, true): return "\(others[0]), \(others[1]) + you"
        case (_, true): return "\(others[0]), \(others[1]) + \(others.count - 2 + 1) more"
        case (1, false): return others[0]
        default: return "\(others[0]) + \(others.count - 1)"
        }
    }
}

/// Small square tile for grids (profile, discover).
struct MomentTile: View {
    let moment: SocialMoment
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            SocialImage(ref: moment.coverRef).aspectRatio(1, contentMode: .fill)
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                Text(moment.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(2)
                Text("\(moment.memberIDs.count) \(moment.memberIDs.count == 1 ? "person" : "people") · \(moment.dateLabel)").font(.caption2).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
            }
            .padding(MSpacing.s)
        }
        .clipShape(RoundedRectangle(cornerRadius: MRadius.tile, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(moment.title)
        .accessibilityIdentifier("tile-\(moment.id)")
    }
}

/// iCloud not signed in / offline / restricted banner.
struct AccountBanner: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        if env.social.accountStatus != .available {
            HStack(spacing: MSpacing.m) {
                Image(systemName: "icloud.slash").foregroundStyle(MColor.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(MFont.headline)
                    Text(message).font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                }
                Spacer()
                Button("Retry") { Task { await env.social.start() } }.buttonStyle(ChipButtonStyle())
            }
            .momentCard()
            .accessibilityIdentifier("accountBanner")
        }
    }
    private var title: String {
        switch env.social.accountStatus {
        case .noAccount: "Sign in to iCloud"
        case .offline: "You're offline"
        case .restricted: "iCloud is restricted"
        default: "Connecting…"
        }
    }
    private var message: String {
        switch env.social.accountStatus {
        case .noAccount: "Shared Moments use your iCloud account. Settings › Apple Account › iCloud."
        case .offline: "Your Moments are still here. Uploads resume when you're back."
        case .restricted: "Parental controls or MDM are blocking iCloud for this app."
        default: "Checking your account."
        }
    }
}

struct UploadBanner: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        if env.social.queue.pendingCount > 0 {
            HStack(spacing: MSpacing.m) {
                if env.social.queue.failedCount > 0 && env.social.queue.failedCount == env.social.queue.pendingCount {
                    Image(systemName: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90").foregroundStyle(MColor.danger)
                    Text("\(env.social.queue.failedCount) uploads need a retry").font(MFont.subheadline)
                    Spacer()
                    Button("Retry") { env.social.queue.retryFailed() }.buttonStyle(ChipButtonStyle(prominent: true))
                } else {
                    ProgressView().tint(MColor.accent)
                    Text("Uploading \(env.social.queue.pendingCount)…").font(MFont.subheadline)
                    Spacer()
                }
            }
            .padding(.horizontal, MSpacing.l).padding(.vertical, MSpacing.m)
            .background(MColor.surface, in: Capsule())
            .accessibilityIdentifier("uploadBanner")
        }
    }
}

struct SocialErrorAlert: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    func body(content: Content) -> some View {
        content.alert("Something went wrong", isPresented: Binding(get: { env.social.lastError != nil }, set: { _ in env.social.clearError() })) {
            Button("OK") {}
        } message: { Text(env.social.lastError ?? "") }
    }
}

extension SocialService {
    func clearError() { lastError = nil }
}
