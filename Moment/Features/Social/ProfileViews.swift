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

    @State private var section = 0   // Moments · Places · People
    @State private var shareItems: [Any] = []
    @State private var showShare = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MSpacing.l) {
                header
                if !isMe { relationshipCard }
                if isMe { AccountBanner(); UploadBanner() }
                Picker("Section", selection: $section) { Text("Moments").tag(0); Text("Places").tag(1); Text("People").tag(2) }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("profileSections")
                switch section {
                case 0: momentsTab
                case 1: placesTab
                default: peopleTab
                }
            }
            .padding(.horizontal, MSpacing.page)
            .padding(.top, MSpacing.s)
            .padding(.bottom, 80)
        }
        .background(MColor.background)
        .navigationTitle(user?.displayName ?? "Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isMe {
                    Menu {
                        Button("Settings", systemImage: "gearshape") { showSettings = true }
                        NavigationLink(value: SocialRoute.invite) { Label("Invite friends", systemImage: "person.badge.plus") }
                        NavigationLink(value: SocialRoute.identity) { Label("Identity & recovery", systemImage: "key") }
                        Button("My private memory", systemImage: "lock") { showMemories = true }
                        NavigationLink(value: SocialRoute.collections) { Label("Collections", systemImage: "folder") }
                        NavigationLink(value: SocialRoute.timeMachine) { Label("Time Machine", systemImage: "clock.arrow.circlepath") }
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
        }
        .task { user = isMe ? env.social.me : await env.social.user(userID); if isMe { await env.social.refreshClaims() } }
        .sheet(isPresented: $showReport) { ReportSheet(userID: userID) }
        .sheet(isPresented: $showShare) { ShareSheet(items: shareItems) }
        .fullScreenCover(isPresented: $showMemories) { PrivateMemoryHubView() }
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView().socialDestinations() } }
        .navigationDestination(item: $openConversation) { id in ConversationView(conversationID: id) }
        .modifier(SocialErrorAlert())
    }

    // MARK: Header

    private var peopleCount: Int { Set(moments.flatMap(\.memberIDs)).subtracting([resolvedID]).count }
    private var placeCount: Int { Set(moments.compactMap { $0.place?.id ?? $0.coarsePlace }).count }

    private var header: some View {
        VStack(alignment: .leading, spacing: MSpacing.m) {
            HStack(alignment: .center, spacing: MSpacing.xl) {
                ZStack {
                    if let ref = user?.avatarRef { SocialImage(ref: ref).frame(width: 88, height: 88).clipShape(Circle()) }
                    else { PersonAvatar(name: user?.displayName ?? "?", size: 88) }
                }
                .overlay(Circle().strokeBorder(MColor.separator, lineWidth: 0.5))
                HStack(spacing: 0) {
                    Button { section = 0 } label: { stat("\(moments.count)", "Moments") }.buttonStyle(.plain)
                    Button { section = 2 } label: { stat("\(peopleCount)", "People") }.buttonStyle(.plain)
                    Button { section = 1 } label: { stat("\(placeCount)", "Places") }.buttonStyle(.plain)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(user?.displayName ?? "…").font(.subheadline.weight(.semibold))
                    if user?.publicKey != nil { Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(MColor.accent).accessibilityLabel("Signed identity") }
                }
                if let id = isMe ? env.identity.momentID : user?.momentID { Text(id).font(.system(.caption, design: .monospaced)).foregroundStyle(MColor.textSecondary) }
                if let bio = user?.bio, !bio.isEmpty { Text(bio).font(MFont.subheadline) }
                else if isMe { Button("Add a line about you") { showEdit = true }.font(MFont.subheadline).foregroundStyle(MColor.textSecondary) }
            }
            if isMe {
                HStack(spacing: MSpacing.s) {
                    Button { showEdit = true } label: { Text("Edit profile") }.buttonStyle(ProfileButtonStyle()).accessibilityIdentifier("editProfile")
                    NavigationLink(value: SocialRoute.invite) { Text("Invite friends") }.buttonStyle(ProfileButtonStyle()).accessibilityIdentifier("inviteFriends")
                    NavigationLink(value: SocialRoute.passport) { Image(systemName: "book.closed").frame(width: 44) }.buttonStyle(ProfileButtonStyle()).accessibilityLabel("Passport").accessibilityIdentifier("passportLink")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("profileHeader")
        .navigationDestination(isPresented: $showEdit) { EditProfileView() }
    }
    @State private var showEdit = false

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 0) { Text(value).font(.headline.weight(.semibold)).monospacedDigit(); Text(label).font(MFont.caption).foregroundStyle(MColor.textPrimary) }
            .frame(maxWidth: .infinity)
    }

    // MARK: Tabs

    /// Moments: pinned, then the grid. Collections and the year live here as quiet rows.
    private var momentsTab: some View {
        let shown = isMe && !query.isBlank ? env.social.search(moments: query) : moments
        return VStack(alignment: .leading, spacing: MSpacing.l) {
            if isMe, let y = env.social.yearSummary() {
                NavigationLink(value: SocialRoute.passport) {
                    HStack(spacing: MSpacing.s) {
                        Text(String(y.year)).font(.subheadline.weight(.semibold))
                        Text("\(y.moments) Moments · \(y.people) people · \(y.places) places\(y.topPerson.map { " · mostly with \($0.split(separator: " ").first.map(String.init) ?? $0)" } ?? "")").font(MFont.footnote).foregroundStyle(MColor.textSecondary).lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(MColor.textTertiary)
                    }
                    .padding(MSpacing.m).background(MColor.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain).accessibilityIdentifier("yearCard")
            }
            if isMe, !env.social.collections.isEmpty { collectionsStrip }
            if isMe, !env.social.featured.isEmpty { featuredRow }
            if isMe, moments.count > 6 {
                HStack(spacing: MSpacing.s) {
                    Image(systemName: "magnifyingglass").foregroundStyle(MColor.textTertiary)
                    TextField("Search your Moments", text: $query).textFieldStyle(.plain).accessibilityIdentifier("momentSearch")
                }
                .padding(.horizontal, MSpacing.m).padding(.vertical, 9)
                .background(MColor.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if shown.isEmpty {
                VStack(alignment: .leading, spacing: MSpacing.s) {
                    Text(isMe ? "No Moments yet" : (user?.isPrivateAccount == true ? "This account is private" : "Nothing to see yet")).font(MFont.title)
                    Text(isMe ? "Your first one starts here." : (user?.isPrivateAccount == true ? "Follow to see the Moments you're not in." : "Moments you share with \(user?.displayName.split(separator: " ").first.map(String.init) ?? "them") will show here.")).font(MFont.body).foregroundStyle(MColor.textSecondary)
                    if isMe { NavigationLink(value: SocialRoute.newMoment) { Text("Create Moment").frame(maxWidth: .infinity) }.buttonStyle(PrimaryButtonStyle()) }
                }
                .padding(.vertical, MSpacing.l)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                    ForEach(shown) { m in
                        NavigationLink(value: SocialRoute.moment(m.id)) {
                            SocialImage(ref: m.coverRef).aspectRatio(1, contentMode: .fill).clipped()
                                .overlay(alignment: .topTrailing) { if m.memberIDs.count > 1 { Image(systemName: "person.2.fill").font(.caption2).foregroundStyle(.white).shadow(radius: 2).padding(6) } }
                        }
                        .buttonStyle(.plain).accessibilityLabel(m.title).accessibilityIdentifier("tile-\(m.id)")
                    }
                }
                .padding(.horizontal, -MSpacing.page)
            }
        }
    }

    private var collectionsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MSpacing.m) {
                ForEach(env.social.collections) { c in
                    NavigationLink(value: SocialRoute.collection(c.id)) {
                        VStack(spacing: 6) {
                            ZStack {
                                Circle().fill(MColor.surfaceSecondary).frame(width: 64, height: 64)
                                if let first = env.social.moments(in: c).first { SocialImage(ref: first.coverRef).frame(width: 64, height: 64).clipShape(Circle()) }
                                Text(c.emoji).font(.title3).shadow(radius: 2)
                            }
                            .overlay(Circle().strokeBorder(MColor.separator, lineWidth: 0.5))
                            Text(c.title).font(MFont.caption).foregroundStyle(MColor.textPrimary).lineLimit(1)
                        }
                        .frame(width: 72)
                    }
                    .buttonStyle(.plain)
                }
                NavigationLink(value: SocialRoute.collections) {
                    VStack(spacing: 6) {
                        ZStack { Circle().strokeBorder(MColor.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 4])).frame(width: 64, height: 64); Image(systemName: "plus").foregroundStyle(MColor.textPrimary) }
                        Text("New").font(MFont.caption).foregroundStyle(MColor.textSecondary)
                    }
                    .frame(width: 72)
                }
                .buttonStyle(.plain).accessibilityIdentifier("collectionsLink")
            }
        }
    }

    /// Places: where life happened — your venues with visit counts, then map and passport.
    private var placesTab: some View {
        VStack(alignment: .leading, spacing: MSpacing.l) {
            HStack(spacing: MSpacing.s) {
                NavigationLink(value: SocialRoute.map) { Label("Map", systemImage: "map").frame(maxWidth: .infinity) }.buttonStyle(ProfileButtonStyle()).accessibilityIdentifier("mapLink")
                NavigationLink(value: SocialRoute.nearby) { Label("Nearby", systemImage: "location").frame(maxWidth: .infinity) }.buttonStyle(ProfileButtonStyle())
            }
            let places = isMe ? env.social.myPlaces : Dictionary(grouping: moments.compactMap(\.place), by: \.id).values.compactMap { g in g.first.map { (place: $0, visits: g.count) } }.sorted { $0.visits > $1.visits }
            if places.isEmpty {
                VStack(alignment: .leading, spacing: MSpacing.s) {
                    Text("No places yet").font(MFont.title)
                    Text("Add a venue to a Moment and it shows up here, on the map and on your passport.").font(MFont.body).foregroundStyle(MColor.textSecondary)
                }
                .padding(.vertical, MSpacing.l)
            }
            ForEach(places, id: \.place.id) { p in
                NavigationLink(value: SocialRoute.place(p.place)) {
                    HStack(spacing: MSpacing.m) {
                        Image(systemName: "mappin.and.ellipse").frame(width: 44, height: 44).background(MColor.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.place.name).font(.subheadline.weight(.semibold)).foregroundStyle(MColor.textPrimary)
                            Text("\(p.visits)× · \(p.place.area)").font(MFont.caption).foregroundStyle(MColor.textSecondary).lineLimit(1)
                        }
                        Spacer()
                        if env.social.claims[p.place.id]?.ownerID == env.social.myID { Image(systemName: "storefront").foregroundStyle(MColor.textTertiary) }
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(MColor.textTertiary)
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// People: who you make Moments with, your groups, and who to follow.
    private var peopleTab: some View {
        VStack(alignment: .leading, spacing: MSpacing.l) {
            if isMe {
                HStack(spacing: MSpacing.s) {
                    NavigationLink(value: SocialRoute.groups) { Label("Groups", systemImage: "person.3").frame(maxWidth: .infinity) }.buttonStyle(ProfileButtonStyle()).accessibilityIdentifier("groupsLink")
                    NavigationLink(value: SocialRoute.followers(resolvedID, false)) { Label("Following", systemImage: "person.2").frame(maxWidth: .infinity) }.buttonStyle(ProfileButtonStyle())
                    NavigationLink(value: SocialRoute.safety) { Image(systemName: "shield").frame(width: 44) }.buttonStyle(ProfileButtonStyle()).accessibilityLabel("Privacy & safety").accessibilityIdentifier("safetyLink")
                }
            }
            // Ranked by shared Moments: the people you actually spend time with.
            var counts: [String: (String, Int)] = [:]
            let _ = moments.forEach { m in for (id, n) in zip(m.memberIDs, m.memberNames) where id != resolvedID { counts[id] = (n, (counts[id]?.1 ?? 0) + 1) } }
            let together = counts.map { (id: $0.key, name: $0.value.0, shared: $0.value.1) }.sorted { $0.shared > $1.shared }
            if together.isEmpty {
                VStack(alignment: .leading, spacing: MSpacing.s) {
                    Text("Find your people").font(MFont.title)
                    Text("Make a Moment with someone and they show up here.").font(MFont.body).foregroundStyle(MColor.textSecondary)
                }
                .padding(.vertical, MSpacing.l)
            }
            ForEach(together, id: \.id) { p in
                HStack(spacing: MSpacing.m) {
                    NavigationLink(value: SocialRoute.profile(p.id)) { AvatarView(userID: p.id, name: p.name, size: 44) }.buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name).font(.subheadline.weight(.semibold))
                        Text("\(p.shared) \(p.shared == 1 ? "Moment" : "Moments") together").font(MFont.caption).foregroundStyle(MColor.textSecondary)
                    }
                    Spacer()
                    if isMe {
                        if env.social.isFollowing(p.id) { NavigationLink(value: SocialRoute.friendship(p.id)) { Text("You + \(p.name.split(separator: " ").first.map(String.init) ?? "")") }.buttonStyle(ChipButtonStyle()) }
                        else { Button("Follow") { Task { await env.social.follow(p.id); Haptics.selection() } }.buttonStyle(ChipButtonStyle(prominent: true)).accessibilityIdentifier("suggestFollow-\(p.id)") }
                    }
                }
            }
            if isMe {
                Button { showMemories = true } label: {
                    HStack(spacing: MSpacing.m) {
                        Image(systemName: "lock").frame(width: 44, height: 44).background(MColor.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("My private memory").font(.subheadline.weight(.semibold)).foregroundStyle(MColor.textPrimary)
                            Text("Screenshots, promises, plans — on this iPhone only. \(env.storage.memoryCount) memories.").font(MFont.caption).foregroundStyle(MColor.textSecondary).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(MColor.textTertiary)
                    }
                    .padding(.top, MSpacing.s)
                }
                .buttonStyle(.plain).accessibilityIdentifier("myMemories")
            }
        }
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
