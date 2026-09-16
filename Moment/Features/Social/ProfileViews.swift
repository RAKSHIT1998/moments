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

    private var isMe: Bool { userID == env.social.myID }
    private var moments: [SocialMoment] { isMe ? env.social.momentsImIn : env.social.moments(with: userID) + publicOnes }
    private var publicOnes: [SocialMoment] { env.social.moments.values.filter { $0.creatorID == userID && $0.visibility == .publicAll && !$0.memberIDs.contains(env.social.myID) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MSpacing.xl) {
                header
                if !isMe { relationshipCard }
                if isMe { AccountBanner(); UploadBanner() }
                if isMe { myMemoriesCard }
                momentsGrid
            }
            .padding(MSpacing.l)
            .padding(.bottom, 80)
        }
        .background(MColor.background)
        .navigationTitle(isMe ? "You" : (user?.displayName ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isMe {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Settings").accessibilityIdentifier("profileSettings")
                } else {
                    Menu {
                        Button("Message", systemImage: "bubble") { Task { if let c = await env.social.conversation(with: userID) { env.social.pendingConversationID = c.id } } }
                        Divider()
                        Button(env.social.muted.contains(userID) ? "Unmute" : "Mute", systemImage: "speaker.slash") { Task { await env.social.mute(userID) } }
                        Button("Report", systemImage: "flag") { showReport = true }
                        if env.social.blocked.contains(userID) { Button("Unblock", systemImage: "hand.raised.slash") { Task { await env.social.unblock(userID) } } }
                        else { Button("Block", systemImage: "hand.raised", role: .destructive) { Task { await env.social.block(userID); dismiss() } } }
                    } label: { Image(systemName: "ellipsis.circle") }.accessibilityIdentifier("profileMenu")
                }
            }
        }
        .task { user = isMe ? env.social.me : await env.social.user(userID) }
        .sheet(isPresented: $showReport) { ReportSheet(userID: userID) }
        .fullScreenCover(isPresented: $showMemories) { PrivateMemoryHubView() }
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView().socialDestinations() } }
        .navigationDestination(item: Binding(get: { env.social.pendingConversationID }, set: { env.social.pendingConversationID = $0 })) { id in ConversationView(conversationID: id) }
        .modifier(SocialErrorAlert())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: MSpacing.m) {
            HStack(alignment: .center, spacing: MSpacing.l) {
                ZStack {
                    if let ref = user?.avatarRef { SocialImage(ref: ref).frame(width: 72, height: 72).clipShape(Circle()) }
                    else { PersonAvatar(name: user?.displayName ?? "?", size: 72) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(user?.displayName ?? "…").font(MFont.title)
                    HStack(spacing: 6) {
                        Text("@\(user?.handle ?? "")").font(MFont.subheadline).foregroundStyle(MColor.textSecondary)
                        if user?.isPrivateAccount == true { Image(systemName: "lock").font(.caption).foregroundStyle(MColor.textTertiary) }
                    }
                    if let bio = user?.bio, !bio.isEmpty { Text(bio).font(MFont.callout) }
                }
                Spacer()
            }
            HStack(spacing: MSpacing.l) {
                stat("\(moments.count)", "Moments")
                stat("\(Set(moments.flatMap(\.memberIDs)).subtracting([userID]).count)", "People")
                stat("\(Set(moments.compactMap(\.coarsePlace)).count)", "Places")
                if isMe {
                    NavigationLink(value: SocialRoute.followers(userID, false)) { stat("\(env.social.graph.following.count)", "Following") }.buttonStyle(.plain)
                    NavigationLink(value: SocialRoute.followers(userID, true)) { stat("\(env.social.graph.followers.count)", "Followers") }.buttonStyle(.plain)
                }
            }
            if isMe {
                HStack(spacing: MSpacing.s) {
                    NavigationLink(value: SocialRoute.editProfile) { Label("Edit profile", systemImage: "pencil") }.buttonStyle(ChipButtonStyle()).accessibilityIdentifier("editProfile")
                    NavigationLink(value: SocialRoute.safety) { Label("Privacy & safety", systemImage: "shield") }.buttonStyle(ChipButtonStyle()).accessibilityIdentifier("safetyLink")
                }
            }
        }
        .accessibilityIdentifier("profileHeader")
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) { Text(value).font(.title3.weight(.bold)).monospacedDigit(); Text(label).font(MFont.caption).foregroundStyle(MColor.textSecondary) }
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
                Button { Task { if let c = await env.social.conversation(with: userID) { env.social.pendingConversationID = c.id } } } label: { Label("Message", systemImage: "bubble") }.buttonStyle(ChipButtonStyle()).accessibilityIdentifier("messageButton")
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

    private var myMemoriesCard: some View {
        Button { showMemories = true } label: {
            HStack(spacing: MSpacing.m) {
                Image(systemName: "lock.shield").font(.title2).foregroundStyle(.white).frame(width: MIcon.tile, height: MIcon.tile).background(MColor.accentGradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        VStack(alignment: .leading, spacing: MSpacing.s) {
            Text(isMe ? "YOUR LIFE IN MOMENTS" : "MOMENTS").font(MFont.eyebrow).foregroundStyle(MColor.textSecondary).tracking(1)
            if moments.isEmpty {
                Text(isMe ? "Make your first Moment from the + tab." : (user?.isPrivateAccount == true ? "This account is private. Follow to see shared Moments." : "No Moments you can see yet.")).font(MFont.footnote).foregroundStyle(MColor.textSecondary)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: MSpacing.s), GridItem(.flexible(), spacing: MSpacing.s)], spacing: MSpacing.s) {
                ForEach(moments) { m in NavigationLink(value: SocialRoute.moment(m.id)) { MomentTile(moment: m) }.buttonStyle(PressScaleStyle()) }
            }
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
                ForEach(shared) { m in NavigationLink(value: SocialRoute.moment(m.id)) { MomentFeedCard(moment: m) }.buttonStyle(PressScaleStyle()) }
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
                Toggle("Show my public Moments by place", isOn: $s.allowDiscoverByLocation)
                Text("Places are city-level. MOMENT never stores or shares exact coordinates.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
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
