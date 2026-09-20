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
    @State private var showCollections = false
    @State private var showCard = false
    @State private var perspective: String? = nil      // nil = everyone
    @State private var showReplay = false
    @State private var showQR = false
    @State private var revealed = false
    @State private var showSubscribe = false
    @State private var mergeCandidate: SocialMoment?
    @State private var showDetails = false
    @State private var showLiveCamera = false
    @State private var burst: String?
    @State private var scrollY: CGFloat = 0
    @State private var tint: Color = MColor.accent
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
                        VStack(alignment: .leading, spacing: MSpacing.section) {
                            meta(moment)
                            if !moment.description.isEmpty { Text(moment.description).font(MFont.body).foregroundStyle(MColor.textPrimary) }
                            if let candidate = mergeCandidate { mergeCard(moment, candidate) }
                            if isMember { yourSide(moment) }
                            perspectives(moment)
                            timeline(moment)
                            DisclosureGroup(isExpanded: $showDetails) {
                                VStack(alignment: .leading, spacing: MSpacing.xl) {
                                    stats(moment)
                                    if let h = env.social.highlights(for: moment.id), h.mostReacted != nil || h.mostActiveHour != nil { highlightsCard(h) }
                                    ReactionBar(momentID: moment.id, counts: moment.reactionCounts, onReact: { burst = $0.emoji })
                                }
                                .padding(.top, MSpacing.l)
                            } label: { Text("Details").sectionLabel() }
                            .tint(MColor.textSecondary)
                            comments(moment)
                        }
                        .padding(.horizontal, MSpacing.page)
                        .padding(.bottom, 120)
                    }
                    .background(GeometryReader { g in Color.clear.preference(key: ScrollYKey.self, value: g.frame(in: .named("momentScroll")).minY) })
                }
                .coordinateSpace(name: "momentScroll")
                .onPreferenceChange(ScrollYKey.self) { scrollY = $0 }
                .background {
                    // The page takes on the Moment's own colour — a soft wash, never a flat fill.
                    ZStack { MColor.background; LinearGradient(colors: [tint.opacity(0.22), .clear], startPoint: .top, endPoint: .center) }.ignoresSafeArea()
                }
                .task(id: moment.coverRef) { tint = await env.social.tint(for: moment) }
                .reactionBurst($burst)
                .safeAreaInset(edge: .bottom) { bottomBar(moment) }
                .toolbar { toolbar(moment) }
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text(moment.title).font(MFont.headline).lineLimit(1).opacity(scrollY < -300 ? 1 : 0).animation(.easeInOut(duration: 0.2), value: scrollY < -300)
                    }
                }
                .toolbarBackground(scrollY < -300 ? .visible : .hidden, for: .navigationBar)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await env.social.loadMoment(momentID); mergeCandidate = env.social.mergeCandidates(for: momentID).first }
        .refreshable { await env.social.loadMoment(momentID) }
        .sheet(isPresented: $showShare) { ShareSheet(items: shareItems) }
        .sheet(isPresented: $showSubscribe) { if let m = moment { SubscribeSheet(creatorID: m.creatorID) } }
        .sheet(isPresented: $showCloudSharing) { if let m = moment { CloudSharingView(momentID: m.id) } }
        .sheet(isPresented: $showReport) { ReportSheet(momentID: momentID, userID: moment?.creatorID) }
        .sheet(isPresented: $showInvitePicker) { InvitePickerSheet(momentID: momentID) }
        .sheet(isPresented: $showCollections) { AddToCollectionSheet(momentID: momentID) }
        .sheet(isPresented: $showCard) { if let m = moment { MomentCardSheet(moment: m) } }
        .sheet(isPresented: $showQR) { if let m = moment { MomentQRSheet(moment: m) } }
        .fullScreenCover(isPresented: $showReplay) { MomentReplayView(momentID: momentID) }
        .sheet(isPresented: $showLiveCamera) { CameraPicker { data in Task { await env.social.addSide(momentID: momentID, photos: [data], note: ""); env.toast("Added to the live Moment."); Haptics.saved() } } }
        .sheet(isPresented: $showExport) { if let m = moment { MomentExportSheet(moment: m) } }
        .fullScreenCover(item: $expanded) { c in MediaPagerView(momentID: momentID, startAt: c) }
        .confirmationDialog("Delete this Moment for everyone?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Moment", role: .destructive) { Task { if await env.social.delete(momentID: momentID) { dismiss() } } }
        } message: { Text("Everyone who was invited loses access. Their own photos stay on their phones.") }
        .modifier(SocialErrorAlert())
    }

    // MARK: Sections

    private func hero(_ m: SocialMoment) -> some View {
        let stretch = max(0, scrollY)   // pull-down grows the cover instead of showing a gap
        let hidden = m.isTeaser && !isMember && !revealed
        return ZStack(alignment: .bottomLeading) {
            SocialImage(ref: m.coverRef).frame(height: 520 + stretch).frame(maxWidth: .infinity).offset(y: -stretch)
                .blur(radius: hidden || m.isLocked ? 28 : 0).animation(.easeOut(duration: 0.6), value: hidden)
            if m.isLocked {
                LockedOverlay(moment: m) { showSubscribe = true }.frame(height: 520 + stretch).offset(y: -stretch)
            } else if hidden {
                VStack(spacing: MSpacing.m) {
                    Text("You had to be there.").font(MFont.heroSmall).foregroundStyle(MColor.overlayLight)
                    Button { withAnimation { revealed = true }; Haptics.saved() } label: { Label("Reveal", systemImage: "eye") }.buttonStyle(ChipButtonStyle(prominent: true, light: true)).accessibilityIdentifier("reveal")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            LinearGradient(colors: [.black.opacity(0.25), .clear, .clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: MSpacing.s) {
                if m.isLive {
                    HStack(spacing: 6) { Circle().fill(.white).frame(width: 6, height: 6); Text("Live").font(MFont.caption) }.foregroundStyle(.white.opacity(0.9))
                }
                Text(m.title).font(MFont.hero).tracking(-0.8).foregroundStyle(.white).lineLimit(3)
                Text([m.memberIDs.count == 1 ? "1 person" : "\(m.memberIDs.count) people", m.dateLabel, m.coarsePlace].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(MFont.subheadline).foregroundStyle(.white.opacity(0.85))
            }
            .padding(MSpacing.page).padding(.bottom, MSpacing.s)
        }
        .ignoresSafeArea(edges: .top)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("momentHero")
    }

    private func meta(_ m: SocialMoment) -> some View {
        VStack(alignment: .leading, spacing: MSpacing.m) {
            NavigationLink(value: SocialRoute.members(m.id)) {
                HStack(spacing: MSpacing.m) {
                    AvatarStack(names: m.memberNames, size: 30)
                    Text(whoLine(m)).font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
                    Spacer()
                    if env.social.isVerified(m) { Label("Signed", systemImage: "checkmark.seal.fill").font(MFont.caption).foregroundStyle(MColor.accent).accessibilityLabel("Signed by \(m.creatorName)'s key") }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("momentMembers")
            if !isMember {
                HStack(spacing: MSpacing.m) {
                    Text("Were you there?").font(MFont.body)
                    Spacer()
                    Button("I was there") { Task { if await env.social.join(momentID: m.id) { env.toast("You're in.") } } }.buttonStyle(ChipButtonStyle(prominent: true)).accessibilityIdentifier("iWasThere")
                }
            }
        }
    }

    /// The signature interaction: a quiet prompt, one button.
    private func yourSide(_ m: SocialMoment) -> some View {
        VStack(alignment: .leading, spacing: MSpacing.m) {
            Text("Your side").sectionLabel()
            Text("Got photos from this?").font(MFont.title)
            NavigationLink(value: SocialRoute.addSide(m.id)) { HStack(spacing: 8) { Glyph(.addSide, size: 20).foregroundStyle(.white); Text("Add your side") }.frame(maxWidth: .infinity) }.buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("addYourSide")
        }
    }

    private func stats(_ m: SocialMoment) -> some View {
        let all = env.social.allContributions(m.id)
        let authors = Dictionary(grouping: all, by: \.authorName).mapValues(\.count)
        let top = authors.max { $0.value < $1.value }
        let span: String? = {
            let times = all.map { $0.originalTimestamp ?? $0.createdAt }
            guard let a = times.min(), let b = times.max(), b.timeIntervalSince(a) > 600 else { return nil }
            let h = b.timeIntervalSince(a) / 3600
            return h < 48 ? String(format: "%.0f h", h) : "\(Int(h / 24)) days"
        }()
        return HStack(spacing: MSpacing.s) {
            StatTile(value: "\(m.memberIDs.count)", label: m.memberIDs.count == 1 ? "person" : "people", symbol: "person.2")
            StatTile(value: "\(all.filter { $0.media != nil }.count)", label: "photos", symbol: "photo")
            if let span { StatTile(value: span, label: "together", symbol: "clock") }
            else if let top, all.count > 1 { StatTile(value: top.key == env.social.displayName ? "You" : String(top.key.split(separator: " ").first ?? ""), label: "added most", symbol: "star") }
        }
        .accessibilityIdentifier("momentStats")
    }

    private func whoLine(_ m: SocialMoment) -> String {
        let others = m.memberNames.filter { $0 != env.social.displayName }
        let n = m.memberIDs.count
        if others.isEmpty { return isMember ? "Just you" : m.creatorName }
        return "\(n) \(n == 1 ? "person was" : "people were") there"
    }

    /// Everyone / one person: the same night from each side.
    private func perspectives(_ m: SocialMoment) -> some View {
        let all = env.social.allContributions(m.id)
        var seen = Set<String>()
        let authors: [(id: String, name: String)] = all.compactMap { seen.insert($0.authorID).inserted ? (id: $0.authorID, name: $0.authorName) : nil }
        return Group {
            if authors.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: MSpacing.s) {
                        Button { perspective = nil; Haptics.selection() } label: { Label("Everyone", systemImage: "person.3") }.buttonStyle(ChipButtonStyle(prominent: perspective == nil)).accessibilityIdentifier("perspective-all")
                        ForEach(authors, id: \.id) { a in
                            Button { perspective = a.id; Haptics.selection() } label: {
                                HStack(spacing: 6) { PersonAvatar(name: a.name, size: 18); Text(a.id == env.social.myID ? "You" : a.name.split(separator: " ").first.map(String.init) ?? a.name) }
                            }
                            .buttonStyle(ChipButtonStyle(prominent: perspective == a.id))
                            .accessibilityIdentifier("perspective-\(a.id)")
                        }
                    }
                }
            }
        }
    }

    private func highlightsCard(_ h: SocialService.Highlights) -> some View {
        VStack(alignment: .leading, spacing: MSpacing.m) {
            HStack { Text("The Moment").sectionLabel(); Spacer(); Button { showReplay = true } label: { Label("Replay", systemImage: "play") }.buttonStyle(ChipButtonStyle()).accessibilityIdentifier("replay") }
            if let c = h.mostReacted {
                Button { expanded = c } label: {
                    HStack(spacing: MSpacing.m) {
                        SocialImage(ref: c.media).frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: MRadius.chip, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Most reacted").font(MFont.caption).foregroundStyle(MColor.textSecondary)
                            Text("\(c.authorName.split(separator: " ").first.map(String.init) ?? c.authorName)'s \(c.kind == .text ? "note" : "photo") · \(c.reactionCounts.values.reduce(0, +)) reactions").font(MFont.headline).foregroundStyle(MColor.textPrimary)
                            Text(ReactionKind.allCases.filter { (c.reactionCounts[$0.rawValue] ?? 0) > 0 }.map(\.emoji).joined(separator: " ")).font(.title3)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: MSpacing.s) {
                if let hour = h.mostActiveHour { StatTile(value: hour.formatted(date: .omitted, time: .shortened), label: "busiest · \(h.mostActiveCount) added", symbol: "bolt") }
                if let a = h.addedMost { StatTile(value: a.name == env.social.displayName ? "You" : String(a.name.split(separator: " ").first ?? ""), label: "added most · \(a.count)", symbol: "star") }
            }
        }
        .momentCard()
        .accessibilityIdentifier("highlights")
    }

    private func mergeCard(_ m: SocialMoment, _ other: SocialMoment) -> some View {
        VStack(alignment: .leading, spacing: MSpacing.s) {
            Text("Same event?").font(MFont.headline)
            Text("\"\(other.title)\" is from the same day with the same people. Merge it into this Moment? Everyone's sides stay attributed.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
            HStack(spacing: MSpacing.s) {
                Button("Merge") { Task { if await env.social.merge(sourceID: other.id, into: m.id) { env.toast("Merged."); mergeCandidate = nil; Haptics.completed() } } }.buttonStyle(ChipButtonStyle(prominent: true)).accessibilityIdentifier("mergeMoments")
                Button("Keep separate") { mergeCandidate = nil }.buttonStyle(ChipButtonStyle())
            }
        }
        .momentCard()
    }

    private func timeline(_ m: SocialMoment) -> some View {
        let all = env.social.allContributions(m.id).filter { perspective == nil || $0.authorID == perspective }
        let entries = MomentTimeline.build(all)
        return VStack(alignment: .leading, spacing: MSpacing.l) {
            if all.isEmpty {
                VStack(alignment: .leading, spacing: MSpacing.xs) {
                    Text("No sides yet").font(MFont.title)
                    Text(isMember ? "Add photos, a video or a note. Everyone who was there sees it here." : "Waiting for the people who were there.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                }
            }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: MSpacing.s) {
                    Text(entry.label).font(MFont.title).foregroundStyle(MColor.textPrimary).padding(.top, MSpacing.s)
                    let photos = entry.contributions.filter { ($0.kind == .photo || $0.kind == .video) && $0.uploadState == .uploaded }
                    let others = entry.contributions.filter { !photos.contains($0) }
                    if photos.count >= 3 {
                        // Many photos in one stretch → a mosaic, each tile tappable, author on the tile.
                        MosaicGrid(items: photos) { c in
                            Button { expanded = c } label: {
                                SocialImage(ref: c.media)
                                    .overlay(alignment: .bottomLeading) {
                                        HStack(spacing: 4) { PersonAvatar(name: c.authorName, size: 18); Text(c.authorID == env.social.myID ? "You" : c.authorName.split(separator: " ").first.map(String.init) ?? "").font(.caption2.weight(.semibold)).foregroundStyle(MColor.overlayLight) }
                                            .padding(6).background(MColor.overlayDark.opacity(0.35), in: Capsule()).padding(6)
                                    }
                                    .overlay(alignment: .topTrailing) { if c.kind == .video { Image(systemName: "play.fill").font(.caption).foregroundStyle(MColor.overlayLight).padding(6).background(MColor.overlayDark.opacity(0.4), in: Circle()).padding(6) } }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(c.kind == .video ? "Video" : "Photo") by \(c.authorName)")
                            .accessibilityIdentifier("contribution-\(c.id)")
                        }
                        ForEach(others) { c in ContributionCard(contribution: c, momentID: m.id, canRemove: c.authorID == env.social.myID || isOwner) { expanded = c } }
                    } else {
                        ForEach(entry.contributions) { c in
                            ContributionCard(contribution: c, momentID: m.id, canRemove: c.authorID == env.social.myID || isOwner) { expanded = c }
                        }
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
                        MentionText(text: c.text)
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

    @ViewBuilder private func bottomBar(_ m: SocialMoment) -> some View {
        if isMember, !m.isLive { EmptyView() } else { bottomBarContent(m) }
    }

    private func bottomBarContent(_ m: SocialMoment) -> some View {
        HStack(spacing: MSpacing.m) {
            if m.isLive, isMember, UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { showLiveCamera = true } label: { Image(systemName: "camera.fill").font(.title3).frame(width: 52, height: 52) }
                    .buttonStyle(SecondaryButtonStyle()).accessibilityLabel("Add a photo now")
            }
            if isMember || m.visibility == .publicAll && m.allowsContributions {
                NavigationLink(value: SocialRoute.addSide(m.id)) { Text("Add Your Side").frame(maxWidth: .infinity) }
                    .buttonStyle(PrimaryButtonStyle())
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
                Button("Share as a card", systemImage: "rectangle.portrait.on.rectangle.portrait") { showCard = true }
                if isOwner || m.shareURL != nil { Button("Show QR to join", systemImage: "qrcode") { showQR = true } }
                Button("Replay", systemImage: "play.circle") { showReplay = true }
                if isMember { Button("Add to collection", systemImage: "folder.badge.plus") { showCollections = true } }
                if isMember { Button(env.social.isFeatured(m.id) ? "Unpin from profile" : "Pin to profile", systemImage: env.social.isFeatured(m.id) ? "pin.slash" : "pin") { env.social.toggleFeatured(m.id); env.toast(env.social.isFeatured(m.id) ? "Pinned to your profile." : "Unpinned.") } }
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
                Text(contribution.authorID == env.social.myID ? "You" : contribution.authorName).font(.subheadline.weight(.medium)).foregroundStyle(MColor.textSecondary)
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
                        SocialImage(ref: contribution.media).frame(height: 400).frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: MRadius.tile, style: .continuous))
                        if contribution.kind == .video {
                            Image(systemName: "play.fill").font(.title3).foregroundStyle(MColor.overlayLight).padding(10).background(MColor.overlayDark.opacity(0.5), in: Circle()).padding(MSpacing.m)
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
                Text(contribution.caption).font(MFont.title).foregroundStyle(MColor.textPrimary).padding(.vertical, MSpacing.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ReactionBar(momentID: momentID, contributionID: contribution.id, counts: contribution.reactionCounts, compact: true)
        }
        .padding(.vertical, MSpacing.s)
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
    var embedded = false
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            MColor.overlayDark.ignoresSafeArea()
            if contribution.kind == .video {
                if let player { VideoPlayer(player: player).ignoresSafeArea() } else { ProgressView().tint(MColor.overlayLight) }
            } else {
                SocialImage(ref: contribution.media, contentMode: .fit).ignoresSafeArea()
            }
            if !embedded {
                Button { dismiss() } label: { Image(systemName: "xmark").font(.headline).foregroundStyle(MColor.overlayLight).padding(12).background(MColor.overlayDark.opacity(0.5), in: Circle()) }
                    .padding().accessibilityLabel("Close")
            }
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


private struct ScrollYKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Swipe through every photo/video in the Moment; author, time and reactions on each.
struct MediaPagerView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let momentID: String
    let startAt: Contribution
    @State private var current: String = ""
    @State private var burst: String?

    private var items: [Contribution] { env.social.allContributions(momentID).filter { $0.kind == .photo || $0.kind == .video } }

    var body: some View {
        ZStack(alignment: .top) {
            MColor.overlayDark.ignoresSafeArea()
            TabView(selection: $current) {
                ForEach(items) { c in
                    ContributionViewer(contribution: c, embedded: true).tag(c.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            if let c = items.first(where: { $0.id == current }) {
                VStack {
                    HStack(spacing: MSpacing.s) {
                        AvatarView(userID: c.authorID, name: c.authorName, size: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.authorID == env.social.myID ? "You" : c.authorName).font(.subheadline.weight(.semibold)).foregroundStyle(MColor.overlayLight)
                            Text((c.originalTimestamp ?? c.createdAt).formatted(date: .abbreviated, time: .shortened)).font(MFont.caption).foregroundStyle(MColor.overlayLight.opacity(0.8))
                        }
                        Spacer()
                        Text("\((items.firstIndex { $0.id == c.id } ?? 0) + 1) / \(items.count)").font(MFont.caption).foregroundStyle(MColor.overlayLight.opacity(0.8)).monospacedDigit()
                        if env.social.moments[momentID]?.creatorID == env.social.myID, c.kind == .photo {
                            Menu {
                                Button("Set as cover", systemImage: "photo.badge.checkmark") { Task { await env.social.setCover(momentID: momentID, from: c); env.toast("Cover updated."); Haptics.saved() } }
                            } label: { Image(systemName: "ellipsis").foregroundStyle(MColor.overlayLight).frame(width: 36, height: 36).background(MColor.overlayDark.opacity(0.4), in: Circle()) }
                        }
                        Button { dismiss() } label: { Image(systemName: "xmark").font(.headline).foregroundStyle(MColor.overlayLight).frame(width: 36, height: 36).background(MColor.overlayDark.opacity(0.4), in: Circle()) }.accessibilityLabel("Close")
                    }
                    .padding(MSpacing.l)
                    Spacer()
                    VStack(alignment: .leading, spacing: MSpacing.s) {
                        if !c.caption.isEmpty { Text(c.caption).font(MFont.callout).foregroundStyle(MColor.overlayLight) }
                        ReactionBar(momentID: momentID, contributionID: c.id, counts: c.reactionCounts, compact: true, onReact: { burst = $0.emoji })
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(MSpacing.l)
                    .background(LinearGradient(colors: [.clear, MColor.overlayDark.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                }
            }
        }
        .reactionBurst($burst)
        .onAppear { current = startAt.id }
        .environment(\.colorScheme, .dark)   // local to this view; preferredColorScheme would flip the whole window
    }
}


/// Comment text with @handles rendered as tappable links to profiles.
struct MentionText: View {
    @Environment(AppEnvironment.self) private var env
    let text: String
    @State private var open: SocialUser?
    var body: some View {
        Text(attributed).font(MFont.body)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "mention" else { return .systemAction }
                let handle = url.host() ?? ""
                Task { if let u = (await env.social.search(people: handle)).first(where: { $0.handle == handle }) { open = u } }
                return .handled
            })
            .navigationDestination(item: $open) { u in SocialProfileView(userID: u.id) }
    }
    private var attributed: AttributedString {
        var out = AttributedString(text)
        for m in text.allMatches(#"@([a-z0-9_]{2,20})"#) {
            guard let r = out.range(of: m) else { continue }
            out[r].foregroundColor = MColor.accent
            out[r].font = MFont.body.weight(.semibold)
            out[r].link = URL(string: "mention://\(m.dropFirst())")
        }
        return out
    }
}
