import SwiftUI
import PhotosUI

/// Your profile (or someone else's): "Your life in Moments". People, places, shared experiences —
/// not a follower count contest.
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
    private var moments: [SocialMoment] { isMe ? env.social.momentsImIn : env.social.moments(with: userID) + publicOnes }
    private var publicOnes: [SocialMoment] { env.social.moments.values.filter { $0.creatorID == userID && $0.visibility == .publicAll && !$0.memberIDs.contains(env.social.myID) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MSpacing.xl) {
                header
                if !isMe { relationshipCard }
                if isMe { AccountBanner(); UploadBanner() }
                if isMe, !env.social.featured.isEmpty { featuredRow }
                if isMe, let y = env.social.yearSummary() { YearCard(summary: y) }
                if isMe { collectionsRow }
                if isMe, !env.social.myPlaces.isEmpty { placesRow }
                if isMe, !env.social.peopleSuggestions.isEmpty { suggestionsRow }
                if isMe { myMemoriesCard }
                momentsGrid
            }
            .padding(MSpacing.page)
            .padding(.bottom, 80)
        }
        .background(MColor.background)
        .navigationTitle(user?.displayName ?? "Profile")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isMe {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Settings").accessibilityIdentifier("profileSettings")
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
        }
        .task { user = isMe ? env.social.me : await env.social.user(userID); if isMe { await env.social.refreshClaims() } }
        .sheet(isPresented: $showReport) { ReportSheet(userID: userID) }
        .fullScreenCover(isPresented: $showMemories) { PrivateMemoryHubView() }
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView().socialDestinations() } }
        .navigationDestination(item: $openConversation) { id in ConversationView(conversationID: id) }
        .modifier(SocialErrorAlert())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: MSpacing.m) {
            HStack(spacing: MSpacing.xl) {
                ZStack {
                    if let ref = user?.avatarRef { SocialImage(ref: ref).frame(width: 86, height: 86).clipShape(Circle()) }
                    else { PersonAvatar(name: user?.displayName ?? "?", size: 86) }
                }
                // Stats share the remaining width evenly, centred under each number.
                HStack(spacing: 0) {
                    stat("\(moments.count)", "Moments").frame(maxWidth: .infinity)
                    NavigationLink(value: SocialRoute.followers(userID, false)) { stat("\(Set(moments.flatMap(\.memberIDs)).subtracting([userID]).count)", "People").frame(maxWidth: .infinity) }.buttonStyle(.plain)
                    NavigationLink(value: SocialRoute.map) { stat("\(Set(moments.compactMap(\.coarsePlace)).count)", "Places").frame(maxWidth: .infinity) }.buttonStyle(.plain)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(user?.displayName ?? "…").font(.subheadline.weight(.semibold))
                if let bio = user?.bio, !bio.isEmpty { Text(bio).font(MFont.subheadline) }
            }
            if isMe {
                HStack(spacing: MSpacing.s) {
                    NavigationLink(value: SocialRoute.editProfile) { Text("Edit profile").frame(maxWidth: .infinity) }.buttonStyle(ProfileButtonStyle()).accessibilityIdentifier("editProfile")
                    NavigationLink(value: SocialRoute.passport) { Text("Passport").frame(maxWidth: .infinity) }.buttonStyle(ProfileButtonStyle()).accessibilityIdentifier("passportLink")
                    NavigationLink(value: SocialRoute.groups) { Image(systemName: "person.3").frame(width: 44) }.buttonStyle(ProfileButtonStyle()).accessibilityLabel("Groups").accessibilityIdentifier("groupsLink")
                }
                HStack(spacing: MSpacing.l) {
                    NavigationLink(value: SocialRoute.map) { Text("Map") }.accessibilityIdentifier("mapLink")
                    NavigationLink(value: SocialRoute.timeMachine) { Text("Time Machine") }
                    NavigationLink(value: SocialRoute.collections) { Text("Collections") }.accessibilityIdentifier("collectionsLink")
                    NavigationLink(value: SocialRoute.safety) { Text("Privacy") }.accessibilityIdentifier("safetyLink")
                }
                .font(MFont.caption.weight(.medium)).foregroundStyle(MColor.textSecondary)
            }
        }
        .accessibilityElement(children: .contain)   // keep the children's own identifiers
        .accessibilityIdentifier("profileHeader")
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 0) { Text(value).font(.headline.weight(.semibold)).monospacedDigit(); Text(label).font(MFont.caption).foregroundStyle(MColor.textPrimary) }
    }

    private var relationshipCard: some View {
        let shared = env.social.moments(with: userID)
        return VStack(alignment: .leading, spacing: MSpacing.m) {
            HStack(spacing: MSpacing.s) {
                if env.social.isFollowing(userID) {
                    Button(env.social.isClose(userID) ? "Close friend ★" : "Following") { Task { await env.social.follow(userID, close: !env.social.isClose(userID)) } }.buttonStyle(ChipButtonStyle(prominent: true)).accessibilityIdentifier("followToggle")
                    Button("Unfollow") { Task { await env.social.unfollow(userID) } }.buttonStyle(ChipButtonStyle())
                } else {
                    Button(user?.isPrivateAccount == true ? "Request to follow" : "Follow") { Task { await env.social.follow(userID) } }.buttonStyle(ChipButtonStyle(prominent: true)).accessibilityIdentifier("followToggle")
                }
                Button { Task { if let c = await env.social.conversation(with: userID) { openConversation = c.id } } } label: { Label("Message", systemImage: "bubble") }.buttonStyle(ChipButtonStyle()).accessibilityIdentifier("messageButton")
            }
            if !shared.isEmpty {
                NavigationLink(value: SocialRoute.friendship(userID)) {
                    HStack(spacing: MSpacing.m) {
                        AvatarStack(names: [env.social.displayName, user?.displayName ?? ""], size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("You + \(user?.displayName.split(separator: " ").first.map(String.init) ?? "them")").font(MFont.headline).foregroundStyle(MColor.textPrimary)
                            Text("\(shared.count) \(shared.count == 1 ? "Moment" : "Moments") together · since \(shared.last?.dateLabel ?? "")").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(MColor.textTertiary)
                    }
                    .momentCard()
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityIdentifier("friendshipLink")
            }
        }
    }

    private var featuredRow: some View {
        VStack(alignment: .leading, spacing: MSpacing.s) {
            Text("Pinned").sectionLabel()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: MSpacing.s) {
                    ForEach(env.social.featured) { m in
                        NavigationLink(value: SocialRoute.moment(m.id)) { MomentTile(moment: m).frame(width: 200, height: 200) }.buttonStyle(PressScaleStyle())
                    }
                }
            }
        }
        .accessibilityIdentifier("featuredRow")
    }

    private var collectionsRow: some View {
        VStack(alignment: .leading, spacing: MSpacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("Collections").sectionLabel()
                Spacer()
                NavigationLink(value: SocialRoute.collections) { Text(env.social.collections.isEmpty ? "Create" : "See all").font(MFont.caption.weight(.semibold)).foregroundStyle(MColor.accent) }.accessibilityIdentifier("collectionsLink")
            }
            if env.social.collections.isEmpty {
                Text("Group Moments into albums — a trip, a year, a person.").font(MFont.footnote).foregroundStyle(MColor.textTertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: MSpacing.s) {
                        ForEach(env.social.collections) { c in
                            NavigationLink(value: SocialRoute.collection(c.id)) {
                                ZStack(alignment: .bottomLeading) {
                                    Group { if let first = env.social.moments(in: c).first { SocialImage(ref: first.coverRef) } else { RoundedRectangle(cornerRadius: 0).fill(MColor.accentSoft) } }
                                        .frame(width: 132, height: 132)
                                    LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(c.emoji).font(.title3)
                                        Text(c.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                                        Text("\(c.momentIDs.count)").font(.caption2).foregroundStyle(.white.opacity(0.8))
                                    }.padding(MSpacing.s)
                                }
                                .frame(width: 132, height: 132)
                                .clipShape(RoundedRectangle(cornerRadius: MRadius.tile, style: .continuous))
                            }
                            .buttonStyle(PressScaleStyle())
                        }
                    }
                }
            }
        }
    }

    private var placesRow: some View {
        VStack(alignment: .leading, spacing: MSpacing.s) {
            Text("Your places").sectionLabel()
            ForEach(env.social.myPlaces.prefix(5), id: \.place.id) { p in
                NavigationLink(value: SocialRoute.place(p.place)) {
                    HStack(spacing: MSpacing.m) {
                        Image(systemName: "mappin.and.ellipse").frame(width: 40, height: 40).background(MColor.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.place.name).font(.subheadline.weight(.semibold)).foregroundStyle(MColor.textPrimary)
                            Text("\(p.visits)× · \(p.place.area)").font(MFont.caption).foregroundStyle(MColor.textSecondary).lineLimit(1)
                        }
                        Spacer()
                        if env.social.claims[p.place.id]?.ownerID == env.social.myID { Image(systemName: "storefront").foregroundStyle(MColor.textTertiary) }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var suggestionsRow: some View {
        VStack(alignment: .leading, spacing: MSpacing.s) {
            Text("People you were there with").sectionLabel()
            ForEach(env.social.peopleSuggestions.prefix(5), id: \.id) { p in
                HStack(spacing: MSpacing.m) {
                    NavigationLink(value: SocialRoute.profile(p.id)) { AvatarView(userID: p.id, name: p.name, size: 44) }.buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name).font(.subheadline.weight(.semibold))
                        Text("\(p.shared) \(p.shared == 1 ? "Moment" : "Moments") together").font(MFont.caption).foregroundStyle(MColor.textSecondary)
                    }
                    Spacer()
                    Button("Follow") { Task { await env.social.follow(p.id); Haptics.selection() } }.buttonStyle(ChipButtonStyle(prominent: true)).accessibilityIdentifier("suggestFollow-\(p.id)")
                }
            }
        }
    }

    private var myMemoriesCard: some View {
        Button { showMemories = true } label: {
            HStack(spacing: MSpacing.m) {
                Image(systemName: "lock.shield").font(.title2).foregroundStyle(MColor.overlayLight).frame(width: MIcon.tile, height: MIcon.tile).background(MColor.accentGradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("My private memory").font(MFont.headline).foregroundStyle(MColor.textPrimary)
                    Text("Screenshots, promises, plans, gift ideas — on-device only. \(env.storage.memoryCount) memories.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(MColor.textTertiary)
            }
            .momentCard()
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityIdentifier("myMemories")
    }

    private var momentsGrid: some View {
        let shown = isMe && !query.isBlank ? env.social.search(moments: query) : moments
        return VStack(alignment: .leading, spacing: MSpacing.s) {
            Text("Moments").sectionLabel()
            if isMe {
                HStack(spacing: MSpacing.s) {
                    Image(systemName: "magnifyingglass").foregroundStyle(MColor.textTertiary)
                    TextField("Search titles, places, people", text: $query).textFieldStyle(.plain).accessibilityIdentifier("momentSearch")
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(MColor.textTertiary) }.accessibilityLabel("Clear") }
                }
                .padding(.horizontal, MSpacing.m).padding(.vertical, 10)
                .background(MColor.surfaceSecondary, in: RoundedRectangle(cornerRadius: MRadius.control, style: .continuous))
            }
            if moments.isEmpty {
                Text(isMe ? "Make your first Moment from the + tab." : (user?.isPrivateAccount == true ? "This account is private. Follow to see shared Moments." : "No Moments you can see yet.")).font(MFont.footnote).foregroundStyle(MColor.textSecondary)
            }
            if isMe, !query.isBlank, shown.isEmpty { Text("Nothing matches \"\(query)\".").font(MFont.footnote).foregroundStyle(MColor.textSecondary) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                ForEach(shown) { m in
                    NavigationLink(value: SocialRoute.moment(m.id)) { SocialImage(ref: m.coverRef).aspectRatio(1, contentMode: .fill).clipped() }
                        .buttonStyle(.plain).accessibilityLabel(m.title).accessibilityIdentifier("tile-\(m.id)")
                }
            }
            .padding(.horizontal, -MSpacing.page)
        }
    }
}

/// "You + Rahul": everything the two of you were part of.
struct FriendshipPageView: View {
    @Environment(AppEnvironment.self) private var env
    let userID: String
    @State private var user: SocialUser?
    var body: some View {
        let shared = env.social.moments(with: userID)
        let places = Set(shared.compactMap(\.coarsePlace))
        ScrollView {
            VStack(alignment: .leading, spacing: MSpacing.xl) {
                VStack(alignment: .leading, spacing: MSpacing.s) {
                    AvatarStack(names: [env.social.displayName, user?.displayName ?? ""], size: 56)
                    Text("You + \(user?.displayName ?? "")").displayStyle()
                    Text("\(shared.count) Moments · \(places.count) places · since \(shared.last.map { ($0.startAt ?? $0.createdAt).formatted(.dateTime.month(.wide).year()) } ?? "")").font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
                }
                HStack(spacing: MSpacing.s) {
                    StatTile(value: "\(shared.count)", label: "Moments", symbol: "rectangle.stack")
                    StatTile(value: "\(places.count)", label: "places", symbol: "mappin")
                    StatTile(value: "\(shared.reduce(0) { $0 + $1.mediaCount })", label: "photos", symbol: "photo")
                }
                // OUR STORY: the chain, oldest first — first Moment together at the top.
                VStack(alignment: .leading, spacing: MSpacing.s) {
                    Text("OUR STORY").font(MFont.eyebrow).tracking(1).foregroundStyle(MColor.textSecondary)
                    ForEach(Array(shared.reversed().enumerated()), id: \.element.id) { i, m in
                        HStack(alignment: .top, spacing: MSpacing.m) {
                            VStack(spacing: 0) {
                                Circle().fill(i == 0 ? MColor.accent : MColor.fill).frame(width: 10, height: 10)
                                Rectangle().fill(MColor.separator).frame(width: 1).frame(maxHeight: .infinity)
                            }
                            NavigationLink(value: SocialRoute.moment(m.id)) {
                                HStack(spacing: MSpacing.m) {
                                    SocialImage(ref: m.coverRef).frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: MRadius.chip, style: .continuous))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(i == 0 ? "First Moment together" : m.dateLabel).font(MFont.caption).foregroundStyle(i == 0 ? MColor.accent : MColor.textSecondary)
                                        Text(m.title).font(MFont.headline).foregroundStyle(MColor.textPrimary).lineLimit(1)
                                        if let p = m.coarsePlace { Text(p).font(MFont.footnote).foregroundStyle(MColor.textSecondary) }
                                    }
                                    Spacer()
                                }
                                .padding(.bottom, MSpacing.m)
                            }
                            .buttonStyle(.plain)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(MSpacing.l)
        }
        .background(MColor.background)
        .navigationBarTitleDisplayMode(.inline)
        .task { user = await env.social.user(userID) }
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
                Text("People must be approved to follow you and see Moments set to Friends.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
            }
            Section("Who can…") {
                Picker("Add me to Moments", selection: $s.whoCanAddMeToMoments) { ForEach(SafetySettings.Audience.allCases, id: \.self) { Text($0.label).tag($0) } }
                Picker("Comment on my Moments", selection: $s.whoCanComment) { ForEach(SafetySettings.Audience.allCases, id: \.self) { Text($0.label).tag($0) } }
                Picker("Message me", selection: $s.whoCanMessage) { ForEach(SafetySettings.Audience.allCases, id: \.self) { Text($0.label).tag($0) } }
                Picker("Mention me", selection: $s.whoCanMention) { ForEach(SafetySettings.Audience.allCases, id: \.self) { Text($0.label).tag($0) } }
            }
            Section("Discover") {
                Toggle("Show my NOW to people nearby", isOn: $s.allowDiscoverByLocation)
                Text("Only NOW posts where you picked a venue. Your phone's location is never stored or shared — the venue is.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
            }
            Section {
                NavigationLink(value: SocialRoute.blockedUsers) { Label("Blocked people (\(env.social.blocked.count))", systemImage: "hand.raised") }
            }
            Section("Your data") {
                Text("Shared Moments live in your iCloud (private database) and in the iCloud of people you share with. Leaving a Moment removes your access; deleting one you created removes it for everyone.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
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
            .background(MColor.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))   // visible grey in light mode too
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
