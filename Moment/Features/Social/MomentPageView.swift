import SwiftUI
import AVKit
import CloudKit

/// The Moment page: hero, who was there, the timeline of everyone's sides, comments, reactions,
/// and the one CTA that matters — ADD YOUR SIDE.
struct MomentPageView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let momentID: String
    @State private var showShare = false
    @State private var shareItems: [Any] = []
    @State private var showCloudSharing = false
    @State private var showReport = false
    @State private var confirmDelete = false
    @State private var commentText = ""
    @State private var showExport = false
    @State private var expanded: Contribution?
    @FocusState private var commentFocused: Bool

    private var moment: SocialMoment? { env.social.moments[momentID] }
    private var isMember: Bool { moment?.memberIDs.contains(env.social.myID) ?? false }
    private var isOwner: Bool { moment?.creatorID == env.social.myID }

    var body: some View {
        Group {
            if let moment {
                ScrollView {
                    VStack(alignment: .leading, spacing: MSpacing.xl) {
                        hero(moment)
                        VStack(alignment: .leading, spacing: MSpacing.xl) {
                            meta(moment)
                            if !moment.description.isEmpty { Text(moment.description).font(MFont.body) }
                            ReactionBar(momentID: moment.id, counts: moment.reactionCounts)
                            timeline(moment)
                            comments(moment)
                        }
                        .padding(.horizontal, MSpacing.l)
                        .padding(.bottom, 120)
                    }
                }
                .background(MColor.background)
                .safeAreaInset(edge: .bottom) { bottomBar(moment) }
                .toolbar { toolbar(moment) }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await env.social.loadMoment(momentID) }
        .refreshable { await env.social.loadMoment(momentID) }
        .sheet(isPresented: $showShare) { ShareSheet(items: shareItems) }
        .sheet(isPresented: $showCloudSharing) { if let m = moment { CloudSharingView(momentID: m.id) } }
        .sheet(isPresented: $showReport) { ReportSheet(momentID: momentID, userID: moment?.creatorID) }
        .sheet(isPresented: $showInvitePicker) { InvitePickerSheet(momentID: momentID) }
        .sheet(isPresented: $showExport) { if let m = moment { MomentExportSheet(moment: m) } }
        .fullScreenCover(item: $expanded) { c in ContributionViewer(contribution: c) }
        .confirmationDialog("Delete this Moment for everyone?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Moment", role: .destructive) { Task { if await env.social.delete(momentID: momentID) { dismiss() } } }
        } message: { Text("Everyone who was invited loses access. Their own photos stay on their phones.") }
        .modifier(SocialErrorAlert())
    }

    // MARK: Sections

    private func hero(_ m: SocialMoment) -> some View {
        ZStack(alignment: .bottomLeading) {
            SocialImage(ref: m.coverRef).frame(height: 420).frame(maxWidth: .infinity)
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: MSpacing.s) {
                if m.isLive {
                    Label("HAPPENING NOW", systemImage: "dot.radiowaves.left.and.right").font(MFont.eyebrow).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4).background(MColor.danger, in: Capsule())
                }
                Text(m.title).font(.system(size: 34, weight: .bold)).tracking(-0.6).foregroundStyle(.white).lineLimit(3)
                HStack(spacing: 6) {
                    Text(m.dateLabel)
                    if let p = m.locationName, !p.isEmpty { Text("·"); Text(p) }
                }
                .font(MFont.subheadline).foregroundStyle(.white.opacity(0.9))
            }
            .padding(MSpacing.l)
        }
        .ignoresSafeArea(edges: .top)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("momentHero")
    }

    private func meta(_ m: SocialMoment) -> some View {
        VStack(alignment: .leading, spacing: MSpacing.m) {
            NavigationLink(value: SocialRoute.members(m.id)) {
                HStack(spacing: MSpacing.m) {
                    AvatarStack(names: m.memberNames, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(whoLine(m)).font(MFont.headline).foregroundStyle(MColor.textPrimary)
                        Text("\(m.contributionCount) \(m.contributionCount == 1 ? "side" : "sides") · \(m.mediaCount) photos · \(m.visibility.label)").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(MColor.textTertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("momentMembers")
            if isMember, m.isGroup {
                Text("You were there too.").font(MFont.callout).foregroundStyle(MColor.accent)
            } else if !isMember, m.visibility == .publicAll {
                Text("Public Moment by \(m.creatorName). You can react, comment and remix it.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
            }
        }
    }

    private func whoLine(_ m: SocialMoment) -> String {
        let others = m.memberNames.filter { $0 != env.social.displayName }
        if others.isEmpty { return isMember ? "Just you" : m.creatorName }
        if isMember { return others.count <= 2 ? others.joined(separator: ", ") + " + you" : "\(others[0]), \(others[1]) + \(others.count - 1) more" }
        return others.count <= 3 ? others.joined(separator: ", ") : "\(others[0]), \(others[1]) + \(others.count - 2) more"
    }

    private func timeline(_ m: SocialMoment) -> some View {
        let all = env.social.allContributions(m.id)
        let entries = MomentTimeline.build(all)
        return VStack(alignment: .leading, spacing: MSpacing.l) {
            if all.isEmpty {
                VStack(alignment: .leading, spacing: MSpacing.s) {
                    Text("No sides yet.").font(MFont.headline)
                    Text(isMember ? "Add photos, a video or a note. Everyone who was there sees it here." : "Waiting for the people who were there.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                }
                .momentCard()
            }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: MSpacing.s) {
                    Text(entry.label.uppercased()).font(MFont.eyebrow).foregroundStyle(MColor.textTertiary).tracking(1)
                    ForEach(entry.contributions) { c in
                        ContributionCard(contribution: c, momentID: m.id, canRemove: c.authorID == env.social.myID || isOwner) { expanded = c }
                    }
                }
            }
        }
        .accessibilityIdentifier("momentTimeline")
    }

    private func comments(_ m: SocialMoment) -> some View {
        VStack(alignment: .leading, spacing: MSpacing.m) {
            Text("Comments").font(MFont.headline)
            ForEach(env.social.comments[m.id] ?? []) { c in
                HStack(alignment: .top, spacing: MSpacing.s) {
                    NavigationLink(value: SocialRoute.profile(c.authorID)) { PersonAvatar(name: c.authorName, size: 28) }.buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(c.authorID == env.social.myID ? "You" : c.authorName).font(.subheadline.weight(.semibold))
                            Text(c.createdAt.formatted(.relative(presentation: .named))).font(MFont.caption).foregroundStyle(MColor.textTertiary)
                        }
                        Text(c.text).font(MFont.body)
                    }
                    Spacer()
                    Menu {
                        if c.authorID == env.social.myID || isOwner { Button("Delete", role: .destructive) { Task { await env.social.deleteComment(c) } } }
                        if c.authorID != env.social.myID { Button("Report", systemImage: "flag") { showReport = true } }
                    } label: { Image(systemName: "ellipsis").foregroundStyle(MColor.textTertiary).frame(width: 32, height: 32) }
                }
                .accessibilityElement(children: .combine)
            }
            if isMember || m.visibility == .publicAll || env.social.isFriend(m.creatorID) {
                HStack(spacing: MSpacing.s) {
                    TextField("Say something", text: $commentText, axis: .vertical).lineLimit(1...4).focused($commentFocused)
                        .textFieldStyle(.plain).padding(.horizontal, MSpacing.m).padding(.vertical, 10)
                        .background(MColor.surfaceSecondary, in: RoundedRectangle(cornerRadius: MRadius.control, style: .continuous))
                        .accessibilityIdentifier("commentField")
                    Button {
                        let t = commentText; commentText = ""
                        Task { if await env.social.comment(momentID: m.id, text: t) { env.toast("Posted.") } else { commentText = t } }
                    } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .disabled(commentText.isBlank)
                        .accessibilityLabel("Post comment").accessibilityIdentifier("postComment")
                }
            }
        }
    }

    private func bottomBar(_ m: SocialMoment) -> some View {
        HStack(spacing: MSpacing.m) {
            if isMember || m.visibility == .publicAll && m.allowsContributions {
                NavigationLink(value: SocialRoute.addSide(m.id)) {
                    Label("ADD YOUR SIDE", systemImage: "plus").font(.headline.weight(.bold)).tracking(0.8).frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("addYourSide")
            } else if m.visibility == .publicAll {
                Button { Task { await remix(m) } } label: { Label("Remix", systemImage: "wand.and.stars").frame(maxWidth: .infinity) }.buttonStyle(PrimaryButtonStyle())
            }
            Button { Task { await invite(m) } } label: { Image(systemName: "person.badge.plus").font(.title3).frame(width: 52, height: 52) }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityLabel("Invite people").accessibilityIdentifier("inviteButton")
        }
        .padding(.horizontal, MSpacing.l).padding(.vertical, MSpacing.m)
        .background(.ultraThinMaterial)
    }

    @ToolbarContentBuilder
    private func toolbar(_ m: SocialMoment) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Share link", systemImage: "link") { Task { await shareLink(m) } }
                if m.allowsReshare || isMember { Button("Export as video / images", systemImage: "square.and.arrow.up") { showExport = true } }
                if m.visibility == .publicAll || isMember { Button("Remix into a new Moment", systemImage: "wand.and.stars") { Task { await remix(m) } } }
                Divider()
                if isOwner {
                    NavigationLink(value: SocialRoute.editMoment(m.id)) { Label("Edit", systemImage: "pencil") }
                    Button("Delete Moment", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } else {
                    if isMember { Button("Leave Moment", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { Task { if await env.social.leave(momentID: m.id) { dismiss() } } } }
                    Button("Report", systemImage: "flag") { showReport = true }
                    Button("Block \(m.creatorName)", systemImage: "hand.raised", role: .destructive) { Task { await env.social.block(m.creatorID); dismiss() } }
                }
            } label: { Image(systemName: "ellipsis.circle") }
            .accessibilityLabel("More").accessibilityIdentifier("momentMenu")
        }
    }

    // MARK: Actions

    private func shareLink(_ m: SocialMoment) async {
        var url = m.shareURL
        if url == nil, isOwner { url = await env.social.shareLink(momentID: m.id) }
        guard let url else { env.toast("Only the creator can share this."); return }
        shareItems = ["\(m.title) — you were there. Add your side on MOMENT.", url]
        showShare = true
    }

    /// Invite = the viral loop. CloudKit uses the system sharing UI (adds people, manages access);
    /// the in-memory backend picks from friends.
    private func invite(_ m: SocialMoment) async {
        env.analytics.track(.contextualInviteShown)
        if isOwner, env.social.backend is CloudKitBackend { showCloudSharing = true; return }
        if isOwner { showInvitePicker = true; return }
        await shareLink(m)
    }
    @State private var showInvitePicker = false

    private func remix(_ m: SocialMoment) async {
        env.analytics.track(.momentRemixed)
        env.social.remixDraft = SocialService.NewMomentInput(title: m.title, description: "", visibility: .group, templateID: m.templateID, remixedFromID: m.id)
        env.pendingTab = .create
    }
}

/// One person's side: photo / video / voice / note, with author, time, reactions.
struct ContributionCard: View {
    @Environment(AppEnvironment.self) private var env
    let contribution: Contribution
    let momentID: String
    var canRemove = false
    var onOpen: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: MSpacing.s) {
            HStack(spacing: MSpacing.s) {
                NavigationLink(value: SocialRoute.profile(contribution.authorID)) { PersonAvatar(name: contribution.authorName, size: 28) }.buttonStyle(.plain)
                Text(contribution.authorID == env.social.myID ? "You" : contribution.authorName).font(.subheadline.weight(.semibold))
                Spacer()
                switch contribution.uploadState {
                case .pending, .uploading: Label("Uploading", systemImage: "icloud.and.arrow.up").font(MFont.caption).foregroundStyle(MColor.textTertiary)
                case .failed: Label("Failed", systemImage: "exclamationmark.icloud").font(MFont.caption).foregroundStyle(MColor.danger)
                case .uploaded: EmptyView()
                }
                Menu {
                    if canRemove { Button("Remove", systemImage: "trash", role: .destructive) { Task { await env.social.removeContribution(contribution) } } }
                    if contribution.authorID != env.social.myID { Button("Report", systemImage: "flag") { showReport = true } }
                } label: { Image(systemName: "ellipsis").foregroundStyle(MColor.textTertiary).frame(width: 32, height: 32) }
            }
            switch contribution.kind {
            case .photo, .video:
                Button(action: onOpen) {
                    ZStack(alignment: .bottomTrailing) {
                        SocialImage(ref: contribution.media).frame(height: 320).frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: MRadius.tile, style: .continuous))
                        if contribution.kind == .video {
                            Image(systemName: "play.fill").font(.title3).foregroundStyle(.white).padding(10).background(.black.opacity(0.5), in: Circle()).padding(MSpacing.m)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(contribution.kind == .video ? "Video" : "Photo") by \(contribution.authorName)")
                if !contribution.caption.isEmpty { Text(contribution.caption).font(MFont.callout) }
            case .voice:
                Label("Voice note", systemImage: "waveform").font(MFont.callout)
                    .padding(MSpacing.m).background(MColor.surfaceSecondary, in: RoundedRectangle(cornerRadius: MRadius.chip, style: .continuous))
            case .text:
                Text(contribution.caption).font(.title3.weight(.medium)).padding(MSpacing.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(MColor.accentSoft, in: RoundedRectangle(cornerRadius: MRadius.tile, style: .continuous))
            }
            ReactionBar(momentID: momentID, contributionID: contribution.id, counts: contribution.reactionCounts, compact: true)
        }
        .momentCard(padding: MSpacing.m)
        .sheet(isPresented: $showReport) { ReportSheet(momentID: momentID, contributionID: contribution.id, userID: contribution.authorID) }
        .accessibilityIdentifier("contribution-\(contribution.id)")
    }
    @State private var showReport = false
}

/// Full-screen viewer for a photo or video contribution.
struct ContributionViewer: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let contribution: Contribution
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if contribution.kind == .video {
                if let player { VideoPlayer(player: player).ignoresSafeArea() } else { ProgressView().tint(.white) }
            } else {
                SocialImage(ref: contribution.media, contentMode: .fit).ignoresSafeArea()
            }
            Button { dismiss() } label: { Image(systemName: "xmark").font(.headline).foregroundStyle(.white).padding(12).background(.black.opacity(0.5), in: Circle()) }
                .padding().accessibilityLabel("Close")
        }
        .task {
            guard contribution.kind == .video, let ref = contribution.media, let url = await env.social.videoURL(for: ref) else { return }
            let p = AVPlayer(url: url); player = p; p.play()
        }
    }
}

/// Apple's sharing UI for CloudKit: add people by contact, set permissions, copy the link.
struct CloudSharingView: UIViewControllerRepresentable {
    @Environment(AppEnvironment.self) private var env
    let momentID: String

    func makeUIViewController(context: Context) -> UIViewController {
        let host = UIViewController()
        host.view.backgroundColor = .clear
        Task { @MainActor in
            guard let ck = env.social.backend as? CloudKitBackend else { return }
            do {
                let (share, _) = try await ck.shareRecord(momentID: momentID)
                let controller = UICloudSharingController(share: share, container: ck.container)
                controller.availablePermissions = [.allowPrivate, .allowReadWrite]
                controller.delegate = context.coordinator
                controller.modalPresentationStyle = .formSheet
                host.present(controller, animated: true)
            } catch { env.social.lastError = error.localizedDescription }
        }
        return host
    }
    func updateUIViewController(_ vc: UIViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(env: env, momentID: momentID) }

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let env: AppEnvironment; let momentID: String
        init(env: AppEnvironment, momentID: String) { self.env = env; self.momentID = momentID }
        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) { Task { @MainActor in env.social.lastError = error.localizedDescription } }
        func itemTitle(for csc: UICloudSharingController) -> String? { env.social.moments[momentID]?.title }
        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            Task { @MainActor in env.analytics.track(.momentShared, category: "cloudkit"); await env.social.loadMoment(momentID) }
        }
    }
}

/// Picks friends to add (in-memory backend). Also used as the "who was there" step of creation.
struct InvitePickerSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let momentID: String
    @State private var query = ""
    @State private var results: [SocialUser] = []
    @State private var chosen: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(results) { u in
                    Button {
                        if chosen.contains(u.id) { chosen.remove(u.id) } else { chosen.insert(u.id) }
                    } label: {
                        HStack { PersonAvatar(name: u.displayName, size: 36); VStack(alignment: .leading) { Text(u.displayName); Text("@\(u.handle)").font(MFont.caption).foregroundStyle(MColor.textSecondary) }; Spacer(); if chosen.contains(u.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(MColor.accent) } }
                    }
                    .accessibilityIdentifier("invite-\(u.handle)")
                }
            }
            .searchable(text: $query, prompt: "Name or @handle")
            .task(id: query) { results = await env.social.search(people: query) }
            .navigationTitle("Who was there?")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Invite \(chosen.count)") {
                        Task { _ = await env.social.shareLink(momentID: momentID, with: Array(chosen)); env.toast("Invited."); dismiss() }
                    }.disabled(chosen.isEmpty).accessibilityIdentifier("sendInvites")
                }
            }
        }
    }
}
