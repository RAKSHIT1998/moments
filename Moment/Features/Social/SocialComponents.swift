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
        let base = used.isEmpty ? [ReactionKind.core] : used
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

/// A Moment in a list: the photograph, a title, one line of context. Nothing else.
struct MomentFeedCard: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let moment: SocialMoment
    var reason: String? = nil
    @State private var burst: String?

    var body: some View {
        VStack(alignment: .leading, spacing: MSpacing.m) {
            ZStack(alignment: .bottomLeading) {
                SocialImage(ref: moment.coverRef).frame(height: 360).frame(maxWidth: .infinity)
                    .blur(radius: moment.isTeaser && !moment.memberIDs.contains(env.social.myID) ? 24 : 0)
                LinearGradient(colors: [.clear, .clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                if moment.isLive {
                    HStack(spacing: 5) { Circle().fill(.white).frame(width: 6, height: 6); Text("Live").font(MFont.caption).foregroundStyle(.white) }
                        .padding(.horizontal, 10).padding(.vertical, 5).background(.black.opacity(0.35), in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(MSpacing.m)
                }
                Text(moment.title).font(MFont.heroSmall).foregroundStyle(.white).lineLimit(2).padding(MSpacing.l)
            }
            .clipShape(RoundedRectangle(cornerRadius: MRadius.card, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                Haptics.saved(); burst = ReactionKind.core.emoji
                Task { await env.social.react(momentID: moment.id, kind: .core) }
            }
            HStack(spacing: MSpacing.s) {
                AvatarStack(names: moment.memberNames, size: 22, max: 3)
                Text(metaLine).font(MFont.footnote).foregroundStyle(MColor.textSecondary).lineLimit(1)
                Spacer()
                Text("See Moment →").font(.subheadline.weight(.medium)).foregroundStyle(MColor.textPrimary)
            }
            .padding(.horizontal, 2)
        }
        .reactionBurst($burst)
        .scrollTransition(.interactive, axis: .vertical) { content, phase in
            content.opacity(phase.isIdentity ? 1 : 0.85).scaleEffect(reduceMotion || phase.isIdentity ? 1 : 0.985)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(moment.title). \(metaLine)")
        .accessibilityIdentifier("feedMoment-\(moment.id)")
    }

    private var metaLine: String {
        var parts: [String] = ["\(moment.memberIDs.count) \(moment.memberIDs.count == 1 ? "person" : "people")"]
        if let s = moment.startAt, let e = moment.endAt, let d = Calendar.current.dateComponents([.day], from: s, to: e).day, d >= 1 { parts.append("\(d + 1) days") }
        else { parts.append(moment.dateLabel) }
        if let p = moment.coarsePlace, !p.isEmpty { parts.append(p) }
        return parts.joined(separator: " · ")
    }
}

/// Small square tile for grids (profile, discover).
struct MomentTile: View {
    let moment: SocialMoment
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            SocialImage(ref: moment.coverRef).aspectRatio(1, contentMode: .fill)
            LinearGradient(colors: [.clear, .clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                Text(moment.title).font(.subheadline.weight(.medium)).foregroundStyle(.white).lineLimit(2)
                Text("\(moment.memberIDs.count) \(moment.memberIDs.count == 1 ? "person" : "people")").font(.caption2).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
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
            .padding(.vertical, MSpacing.m)
            .overlay(Rectangle().fill(MColor.separator).frame(height: 0.5), alignment: .bottom)
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
            Button("Try again") { Task { await env.social.refreshAll() } }
            Button("OK", role: .cancel) {}
        } message: { Text(env.social.lastError ?? "") }
    }
}

extension SocialService {
    func clearError() { lastError = nil }
}
