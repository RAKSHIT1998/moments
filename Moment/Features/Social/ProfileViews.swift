import SwiftUI
import PhotosUI

/// Your profile (or someone else's): a creator page. What's for sale, what a subscription opens,
/// and how to reach them — nothing else.
struct SocialProfileView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let userID: String
    @State private var user: SocialUser?
    @State private var showReport = false
    @State private var showMemories = false
    @State private var showSettings = false
    @State private var openConversation: String?
    @State private var query = ""

    /// The Profile tab is built before the session resolves, so an empty id means "me".
    private var isMe: Bool { userID.isEmpty || userID == env.social.myID }
    private var resolvedID: String { userID.isEmpty ? env.social.myID : userID }
    @State private var section = 0   // Posts · About
    @State private var shareItems: [Any] = []
    @State private var showShare = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MSpacing.l) {
                banner
                header
                if isMe { AccountBanner(); UploadBanner() }
                sectionPicker
                sectionContent
            }
            .padding(.horizontal, MSpacing.page)
            .padding(.top, MSpacing.s)
            .padding(.bottom, 90)
        }
        .background(MColor.background)
        .navigationTitle(user?.displayName ?? "Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { menu } }
        .task { await load() }
        .modifier(ProfileSheets(userID: userID, resolvedID: resolvedID, name: user?.displayName ?? "them", shareItems: shareItems, showReport: $showReport, showShare: $showShare, showSubscribe: $showSubscribe, showAsk: $showAsk))
        .fullScreenCover(isPresented: $showMemories) { PrivateMemoryHubView() }
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView().socialDestinations() } }
        .navigationDestination(item: $openConversation) { id in ChatView(conversationID: id) }
        .modifier(SocialErrorAlert())
    }

    @ViewBuilder private var menu: some View {
        if isMe {
            Menu {
                Button("Settings", systemImage: "gearshape") { showSettings = true }
                NavigationLink(value: SocialRoute.studio) { Label("Creator mode", systemImage: "chart.line.uptrend.xyaxis") }
                NavigationLink(value: SocialRoute.subscriptions) { Label("My subscriptions", systemImage: "heart.text.square") }
                NavigationLink(value: SocialRoute.invite) { Label("Invite friends", systemImage: "person.badge.plus") }
                NavigationLink(value: SocialRoute.identity) { Label("Identity & recovery", systemImage: "key") }
                Button("My private memory", systemImage: "lock") { showMemories = true }
                NavigationLink(value: SocialRoute.safety) { Label("Privacy & safety", systemImage: "shield") }
            } label: { Image(systemName: "line.3.horizontal") }
            .accessibilityLabel("More").accessibilityIdentifier("profileSettings")
        } else {
            Menu {
                Button("Message", systemImage: "bubble") { Task { if let c = await env.social.conversation(with: userID) { openConversation = c.id } } }
                Divider()
                Button(env.social.muted.contains(userID) ? "Unmute" : "Mute", systemImage: "speaker.slash") { Task { await env.social.mute(userID) } }
                Button("Report", systemImage: "flag") { showReport = true }
                if env.social.blocked.contains(userID) { Button("Unblock", systemImage: "hand.raised.slash") { Task { await env.social.unblock(userID) } } }
                else { Button("Block", systemImage: "hand.raised", role: .destructive) { Task { await env.social.block(userID); dismiss() } } }
            } label: { Image(systemName: "ellipsis.circle") }.accessibilityIdentifier("profileMenu")
        }
    }

    private var sectionPicker: some View {
        Picker("Section", selection: $section) { Text("Posts").tag(0); Text("About").tag(3) }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("profileSections")
    }

    @ViewBuilder private var sectionContent: some View {
        if section == 0 { shopTab } else { aboutTab }
    }

    private func load() async {
        user = isMe ? env.social.me : await env.social.user(userID)
        if isMe {
            await env.social.refreshClaims(); await env.social.refreshCreator(); await env.social.refreshStorefront()
        } else {
            await env.social.loadCreatorPlan(userID); await env.social.loadStorefront(userID)
        }
    }

    // MARK: Header

    private var sets: [VaultSet] { env.social.sets(of: resolvedID).filter { $0.visible } }
    private var plan: CreatorPlan? { env.social.plan(for: resolvedID) }
    private var links: CreatorLinks { env.social.links(of: resolvedID) }

    /// Nothing uploaded for this: the banner is the creator's own newest free cover.
    private var bannerRef: MediaRef? {
        sets.first(where: { $0.isFree })?.cover ?? sets.first?.cover
    }

    /// Banner with the avatar sitting on its edge — the shape people expect from a creator page.
    private var banner: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let bannerRef { SocialImage(ref: bannerRef) }
                else { LinearGradient(colors: [MColor.accent.opacity(0.55), MColor.accent.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing) }
            }
            .frame(height: 148).frame(maxWidth: .infinity).clipped()
            .overlay(LinearGradient(colors: [.clear, MColor.background], startPoint: .center, endPoint: .bottom))

            ZStack {
                if let ref = user?.avatarRef { SocialImage(ref: ref).frame(width: 84, height: 84).clipShape(Circle()) }
                else { PersonAvatar(name: user?.displayName ?? "?", size: 84) }
            }
            .overlay(Circle().strokeBorder(MColor.background, lineWidth: 4))
            .offset(x: MSpacing.page, y: 30)
        }
        .padding(.horizontal, -MSpacing.page)
        .padding(.top, -MSpacing.s)
        .padding(.bottom, 32)
        .accessibilityHidden(true)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: MSpacing.m) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(user?.displayName ?? "…").font(.title3.weight(.bold))
                    if user?.publicKey != nil { Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(MColor.accent).accessibilityLabel("Signed identity") }
                }
                HStack(spacing: 8) {
                    if let h = user?.handle, !h.isEmpty { Text("@\(h)").font(MFont.subheadline).foregroundStyle(MColor.textSecondary) }
                    if let id = isMe ? env.identity.momentID : user?.momentID { Text(id).font(.system(.caption2, design: .monospaced)).foregroundStyle(MColor.textTertiary) }
                }
                if let bio = user?.bio, !bio.isEmpty { Text(bio).font(MFont.subheadline).padding(.top, 2) }
                else if isMe { Button("Add a line about you") { showEdit = true }.font(MFont.subheadline).foregroundStyle(MColor.textSecondary) }
            }

            stats

            if !links.all.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: MSpacing.s) {
                        ForEach(links.all, id: \.url) { label, handle, url in
                            Link(destination: url) { HStack(spacing: 5) { Image(systemName: "link"); Text(handle) }.font(MFont.caption).padding(.horizontal, 10).padding(.vertical, 6) }
                                .glassPill().accessibilityIdentifier("link-\(label)")
                        }
                    }
                }
            }

            if isMe { myActions } else { theirActions }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("profileHeader")
        .navigationDestination(isPresented: $showEdit) { EditProfileView() }
    }
    @State private var showEdit = false
    @State private var showSubscribe = false
    @State private var showAsk = false

    /// Three numbers that mean something on a creator page. On your own: who pays you, what you've
    /// posted, who you follow. On someone else's: how much there is, and how much of it is free.
    private var stats: some View {
        HStack(spacing: 0) {
            if isMe {
                stat("\(env.social.activeSubscriberCount)", "Subscribers")
                stat("\(sets.count)", "Posts")
                stat("\(env.social.graph.following.count)", "Following")
            } else {
                stat("\(sets.count)", "Posts")
                stat("\(sets.filter(\.isFree).count)", "Free")
                stat("\(sets.count - sets.filter(\.isFree).count)", "Locked")
            }
        }
    }

    private var myActions: some View {
        VStack(spacing: MSpacing.s) {
            HStack(spacing: MSpacing.s) {
                Button { showEdit = true } label: { Text("Edit profile") }.buttonStyle(ProfileButtonStyle()).accessibilityIdentifier("editProfile")
                Button { Task { await shareProfile() } } label: { Text("Share profile") }.buttonStyle(ProfileButtonStyle()).accessibilityIdentifier("shareProfile")
            }
            NavigationLink(value: SocialRoute.studio) {
                HStack(spacing: MSpacing.m) {
                    Image(systemName: "chart.line.uptrend.xyaxis").font(.headline)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(env.social.isCreator ? "Creator mode" : "Start earning").font(.subheadline.weight(.semibold))
                        Text(env.social.isCreator
                             ? env.social.storefrontEarnings.formatted(.currency(code: "INR").precision(.fractionLength(0))) + " this month"
                             : "Sell sets, subscriptions and your time")
                            .font(MFont.caption).foregroundStyle(.white.opacity(0.85))
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, MSpacing.l).padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(LinearGradient(colors: [MColor.accent, MColor.accent.opacity(0.78)], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain).accessibilityIdentifier("studioLink")
        }
    }

    private var theirActions: some View {
        VStack(spacing: MSpacing.s) {
            if let plan {
                Button { if !env.social.isSubscribed(to: resolvedID) { showSubscribe = true } } label: {
                    VStack(spacing: 2) {
                        Text(env.social.isSubscribed(to: resolvedID) ? "SUBSCRIBED" : "SUBSCRIBE · \(plan.priceLabel())")
                            .font(.subheadline.weight(.bold))
                        if !env.social.isSubscribed(to: resolvedID) { Text(plan.title).font(MFont.caption).opacity(0.9) }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .foregroundStyle(.white)
                    .background(env.social.isSubscribed(to: resolvedID) ? AnyShapeStyle(MColor.textTertiary) : AnyShapeStyle(LinearGradient(colors: [MColor.accent, MColor.accent.opacity(0.78)], startPoint: .top, endPoint: .bottom)), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain).disabled(env.social.isSubscribed(to: resolvedID)).accessibilityIdentifier("subscribeBox")
            }
            HStack(spacing: MSpacing.s) {
                Button { Task { if let c = await env.social.conversation(with: resolvedID) { openConversation = c.id } } } label: { Text("Message") }
                    .buttonStyle(ProfileButtonStyle()).accessibilityIdentifier("messageButton")
                Button { showAsk = true } label: { Text("Ask") }.buttonStyle(ProfileButtonStyle()).accessibilityIdentifier("askButton")
                Button { Task { await env.social.follow(resolvedID) } } label: { Text(env.social.isFollowing(resolvedID) ? "Following" : "Follow") }
                    .buttonStyle(ProfileButtonStyle()).accessibilityIdentifier("followToggle")
            }
        }
    }

    private func shareProfile() async {
        shareItems = ["\(env.social.displayName) on MOMENT", URL(string: "https://moment.social/u/\(env.identity.momentID)")!]
        showShare = true
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 0) {
            Text(value).font(.headline.weight(.bold)).monospacedDigit()
            Text(label).font(MFont.caption).foregroundStyle(MColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// What they sell, in a grid. For me it's also the way in to publishing more.
    private var shopTab: some View {
        VStack(alignment: .leading, spacing: MSpacing.m) {
            if sets.isEmpty {
                VStack(alignment: .leading, spacing: MSpacing.s) {
                    Text(isMe ? "Nothing for sale yet." : "Nothing for sale yet.").font(MFont.headline)
                    Text(isMe ? "A free set is how people find you; a paid one is how you earn." : "Follow them — new sets show up in your feed.")
                        .font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
                    if isMe { NavigationLink(value: SocialRoute.studio) { Text("Open Creator mode").frame(maxWidth: .infinity) }.buttonStyle(PrimaryButtonStyle()) }
                }
                .padding(MSpacing.l).frame(maxWidth: .infinity, alignment: .leading).glass()
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: MSpacing.s)], spacing: MSpacing.s) {
                    ForEach(sets) { s in SetTile(set: s) { showSubscribe = false } }
                }
            }
            if !env.social.offers(of: resolvedID).filter(\.active).isEmpty || plan != nil {
                NavigationLink(value: SocialRoute.storefront(resolvedID)) { Text(isMe ? "See your shop" : "See everything").frame(maxWidth: .infinity) }
                    .buttonStyle(SecondaryButtonStyle()).accessibilityIdentifier("shopLink")
            }
        }
    }

    /// ABOUT — who this is, what the subscription opens, and the controls that belong to you.
    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: MSpacing.l) {
            if let plan {
                VStack(alignment: .leading, spacing: 6) {
                    Text(isMe ? "Your subscription" : "Subscription").font(MFont.eyebrow).tracking(1).foregroundStyle(MColor.textSecondary)
                    Text(plan.priceLabel()).font(.title3.weight(.bold))
                    Text("Opens every subscribers-only post for 30 days. \(sets.filter(\.subscribersOnly).count) right now.")
                        .font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                    ForEach(plan.perks, id: \.self) { p in
                        Label(p, systemImage: "checkmark").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                    }
                }
                .padding(MSpacing.l).frame(maxWidth: .infinity, alignment: .leading).glass()
                .accessibilityIdentifier("aboutPlan")
            }

            if let created = user?.createdAt {
                Label("Here since \(created.formatted(.dateTime.month(.wide).year()))", systemImage: "calendar")
                    .font(MFont.footnote).foregroundStyle(MColor.textSecondary)
            }

            if isMe {
                HStack(spacing: MSpacing.s) {
                    NavigationLink(value: SocialRoute.followers(resolvedID, false)) { Label("Following", systemImage: "person.2").frame(maxWidth: .infinity) }.buttonStyle(ProfileButtonStyle()).accessibilityIdentifier("followingLink")
                    NavigationLink(value: SocialRoute.subscriptions) { Label("Subscriptions", systemImage: "heart.text.square").frame(maxWidth: .infinity) }.buttonStyle(ProfileButtonStyle()).accessibilityIdentifier("subscriptionsLink")
                    NavigationLink(value: SocialRoute.safety) { Image(systemName: "shield").frame(width: 44) }.buttonStyle(ProfileButtonStyle()).accessibilityLabel("Privacy & safety").accessibilityIdentifier("safetyLink")
                }

                Button { showMemories = true } label: {
                    HStack(spacing: MSpacing.m) {
                        Image(systemName: "lock").frame(width: 44, height: 44).background(MColor.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("My private memory").font(.subheadline.weight(.semibold)).foregroundStyle(MColor.textPrimary)
                            Text("Screenshots, promises, plans — on this iPhone only. \(env.storage.memoryCount) saved.").font(MFont.caption).foregroundStyle(MColor.textSecondary).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(MColor.textTertiary)
                    }
                }
                .buttonStyle(.plain).accessibilityIdentifier("myMemories")

                Text("Your posts live on your own storage. Buyers get a key, not a copy from us — so nobody, including us, can take this page down.")
                    .font(MFont.caption).foregroundStyle(MColor.textTertiary)
            }
        }
    }

}

/// The profile's sheets, lifted out so the body stays small enough for the type checker.
private struct ProfileSheets: ViewModifier {
    let userID: String
    let resolvedID: String
    let name: String
    let shareItems: [Any]
    @Binding var showReport: Bool
    @Binding var showShare: Bool
    @Binding var showSubscribe: Bool
    @Binding var showAsk: Bool
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showReport) { ReportSheet(userID: userID) }
            .sheet(isPresented: $showShare) { ShareSheet(items: shareItems) }
            .sheet(isPresented: $showSubscribe) { SubscribeSheet(creatorID: resolvedID) }
            .sheet(isPresented: $showAsk) { AskSheet(creatorID: resolvedID, creatorName: name) }
    }
}

struct FollowListView: View {
    @Environment(AppEnvironment.self) private var env
    let userID: String
    let followers: Bool
    @State private var users: [SocialUser] = []
    var body: some View {
        List(users) { u in
            NavigationLink(value: SocialRoute.profile(u.id)) { HStack { PersonAvatar(name: u.displayName, size: 36); VStack(alignment: .leading) { Text(u.displayName); Text("@\(u.handle)").font(MFont.caption).foregroundStyle(MColor.textSecondary) } } }
        }
        .navigationTitle(followers ? "Followers" : "Following")
        .task {
            let ids = followers ? env.social.graph.followers : env.social.graph.following
            var out: [SocialUser] = []
            for id in ids.sorted() { if let u = await env.social.user(id) { out.append(u) } }
            users = out
        }
    }
}

struct EditProfileView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var handle = ""
    @State private var bio = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var avatar: Data?
    @State private var saving = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        if let avatar, let img = UIImage(data: avatar) { Image(uiImage: img).resizable().scaledToFill().frame(width: 88, height: 88).clipShape(Circle()) }
                        else { PersonAvatar(name: name.isEmpty ? "?" : name, size: 88) }
                    }
                    Spacer()
                }
            }
            Section("Name") { TextField("Your name", text: $name).accessibilityIdentifier("profileName") }
            Section("Handle") { TextField("handle", text: $handle).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("profileHandle") }
            Section("Bio") { TextField("A line about you", text: $bio, axis: .vertical).lineLimit(1...3) }
        }
        .navigationTitle("Edit profile")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(saving ? "Saving…" : "Save") { Task { saving = true; if await env.social.updateProfile(displayName: name, handle: handle, bio: bio, avatar: avatar) { env.toast("Saved."); dismiss() }; saving = false } }.disabled(name.isBlank || handle.isBlank || saving).accessibilityIdentifier("saveProfile") } }
        .onAppear { if let me = env.social.me { name = me.displayName; handle = me.handle; bio = me.bio } else { name = env.settings.displayName } }
        .onChange(of: pickerItem) { _, item in Task { if let item, let d = try? await item.loadTransferable(type: Data.self) { avatar = MediaPipeline.thumbnail(d, side: 512) } } }
    }
}

/// Privacy controls every account has from day one.
struct SafetySettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var s = SafetySettings()

    var body: some View {
        Form {
            Section {
                Toggle("Private account", isOn: $s.privateAccount).accessibilityIdentifier("privateAccount")
                Text("People must be approved before they can follow you or see anything you post to followers.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
            }
            Section("Who can…") {
                Picker("Comment on my posts", selection: $s.whoCanComment) { ForEach(SafetySettings.Audience.allCases, id: \.self) { Text($0.label).tag($0) } }
                Picker("Message me", selection: $s.whoCanMessage) { ForEach(SafetySettings.Audience.allCases, id: \.self) { Text($0.label).tag($0) } }
                Picker("Mention me", selection: $s.whoCanMention) { ForEach(SafetySettings.Audience.allCases, id: \.self) { Text($0.label).tag($0) } }
            }
            Section {
                NavigationLink(value: SocialRoute.blockedUsers) { Label("Blocked people (\(env.social.blocked.count))", systemImage: "hand.raised") }
            }
            Section("Your data") {
                Text("What you post lives in your own iCloud (private database) and, once someone buys or subscribes, in theirs. Deleting a post stops new keys going out; copies people already opened are theirs.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
            }
        }
        .navigationTitle("Privacy & safety")
        .onAppear { s = env.social.safety }
        .onChange(of: s) { _, new in Task { await env.social.updateSafety(new) } }
    }
}

struct BlockedUsersView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var users: [SocialUser] = []
    var body: some View {
        List {
            if env.social.blocked.isEmpty { Text("No one blocked.").foregroundStyle(MColor.textSecondary) }
            ForEach(users) { u in
                HStack { PersonAvatar(name: u.displayName, size: 36); Text(u.displayName); Spacer(); Button("Unblock") { Task { await env.social.unblock(u.id); users.removeAll { $0.id == u.id } } }.buttonStyle(ChipButtonStyle()) }
            }
        }
        .navigationTitle("Blocked")
        .task { var out: [SocialUser] = []; for id in env.social.blocked.sorted() { if let u = await env.social.user(id) { out.append(u) } }; users = out }
    }
}

/// The original private memory layer (screenshots → people/plans/promises), kept whole under Profile.
struct PrivateMemoryHubView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var tab: PrivateTab = .home
    enum PrivateTab: String, CaseIterable, Identifiable {
        case home, search, people, vault
        var id: String { rawValue }
        var label: String { switch self { case .home: "Home"; case .search: "Search"; case .people: "People"; case .vault: "Vault" } }
        var symbol: String { switch self { case .home: "house"; case .search: "magnifyingglass"; case .people: "person.2"; case .vault: "archivebox" } }
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab(PrivateTab.home.label, systemImage: PrivateTab.home.symbol, value: .home) { HomeView() }
            Tab(PrivateTab.search.label, systemImage: PrivateTab.search.symbol, value: .search) { SearchView() }
            Tab(PrivateTab.people.label, systemImage: PrivateTab.people.symbol, value: .people) { PeopleView() }
            Tab(PrivateTab.vault.label, systemImage: PrivateTab.vault.symbol, value: .vault) { VaultView() }.badge(env.surface.inboxCount)
        }
        .tint(MColor.accent)
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-uitest") { await DemoData.seedAsync(into: env) }
            #endif
        }
        .overlay(alignment: .top) {
            HStack {
                Label("Private · on-device", systemImage: "lock.fill").font(MFont.caption).foregroundStyle(MColor.textSecondary)
                Spacer()
                Button("Done") { dismiss() }.font(.subheadline.weight(.semibold)).accessibilityIdentifier("memoriesDone")
            }
            .padding(.horizontal, MSpacing.l).padding(.vertical, 6)
            .background(.bar)
        }
    }
}


/// The grey "Edit profile" button everyone recognises.
struct ProfileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(MColor.textPrimary)
            .padding(.vertical, 8)
            .frame(minHeight: 34)
            .frame(maxWidth: .infinity)
            .glass(radius: 12)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
