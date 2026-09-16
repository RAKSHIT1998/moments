import SwiftUI

/// Permanent groups: the crew, family, work. Each has its Moments, its NOW, its chat.
struct GroupsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showNew = false
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MSpacing.l) {
                if env.social.groups.isEmpty {
                    VStack(alignment: .leading, spacing: MSpacing.s) {
                        Text("Find your people.").font(MFont.title)
                        Text("A group is a private space for the people you keep making Moments with.").font(MFont.body).foregroundStyle(MColor.textSecondary)
                        Button { showNew = true } label: { Text("Create a group").frame(maxWidth: .infinity) }.buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("newGroupEmpty")
                    }
                    .momentCard()
                }
                ForEach(env.social.groups) { g in
                    NavigationLink(value: SocialRoute.group(g.id)) { GroupCard(group: g) }.buttonStyle(PressScaleStyle())
                }
            }
            .padding(MSpacing.l).padding(.bottom, 80)
        }
        .background(MColor.background)
        .navigationTitle("Groups")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showNew = true } label: { Image(systemName: "plus") }.accessibilityLabel("New group").accessibilityIdentifier("newGroup") } }
        .sheet(isPresented: $showNew) { GroupEditorSheet() }
        .task { await env.social.refreshGroups() }
    }
}

struct GroupCard: View {
    @Environment(AppEnvironment.self) private var env
    let group: SocialGroup
    var body: some View {
        let ms = env.social.moments(for: group)
        HStack(spacing: MSpacing.m) {
            ZStack {
                RoundedRectangle(cornerRadius: MRadius.tile, style: .continuous).fill(MColor.accentSoft).frame(width: 72, height: 72)
                if let cover = ms.first?.coverRef { SocialImage(ref: cover).frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: MRadius.tile, style: .continuous)) }
                Text(group.emoji).font(.title).shadow(radius: 3)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(group.name).font(MFont.headline).foregroundStyle(MColor.textPrimary)
                Text("\(group.memberIDs.count) people · \(ms.count) Moments").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                AvatarStack(names: group.memberNames, size: 22)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(MColor.textTertiary)
        }
        .momentCard()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("group-\(group.id)")
    }
}

struct GroupDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let groupID: String
    @State private var showAdd = false
    @State private var added: [SocialUser] = []
    @State private var confirmLeave = false

    private var group: SocialGroup? { env.social.groups.first { $0.id == groupID } }

    var body: some View {
        ScrollView {
            if let g = group {
                let ms = env.social.moments(for: g)
                let nows = env.social.nowPosts.filter { g.memberIDs.contains($0.authorID) }
                VStack(alignment: .leading, spacing: MSpacing.xl) {
                    HStack(alignment: .firstTextBaseline, spacing: MSpacing.s) { Text(g.emoji).font(.largeTitle); Text(g.name).displayStyle() }
                    HStack(spacing: MSpacing.s) {
                        NavigationLink(value: SocialRoute.newMomentForGroup(g.id)) { Label("New Moment", systemImage: "plus") }.buttonStyle(ChipButtonStyle(prominent: true)).accessibilityIdentifier("groupNewMoment")
                        if let c = g.conversationID { NavigationLink(value: SocialRoute.conversation(c)) { Label("Chat", systemImage: "bubble.left.and.bubble.right") }.buttonStyle(ChipButtonStyle()).accessibilityIdentifier("groupChat") }
                        Button { showAdd = true } label: { Label("Add people", systemImage: "person.badge.plus") }.buttonStyle(ChipButtonStyle())
                    }
                    VStack(alignment: .leading, spacing: MSpacing.s) {
                        Text("PEOPLE").font(MFont.eyebrow).tracking(1).foregroundStyle(MColor.textSecondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: MSpacing.m) {
                                ForEach(Array(zip(g.memberIDs, g.memberNames)), id: \.0) { id, name in
                                    NavigationLink(value: SocialRoute.profile(id)) {
                                        VStack(spacing: 4) { AvatarView(userID: id, name: name, size: 52); Text(id == env.social.myID ? "You" : name.split(separator: " ").first.map(String.init) ?? name).font(MFont.caption).foregroundStyle(MColor.textPrimary) }
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    if !nows.isEmpty {
                        VStack(alignment: .leading, spacing: MSpacing.s) {
                            Text("NOW").font(MFont.eyebrow).tracking(1).foregroundStyle(MColor.textSecondary)
                            ForEach(nows) { n in NowStatusRow(post: n) }
                        }
                    }
                    VStack(alignment: .leading, spacing: MSpacing.s) {
                        Text("MOMENTS TOGETHER").font(MFont.eyebrow).tracking(1).foregroundStyle(MColor.textSecondary)
                        if ms.isEmpty { Text("No Moments with everyone yet. Start one — the group is invited automatically.").font(MFont.footnote).foregroundStyle(MColor.textSecondary) }
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: MSpacing.s), GridItem(.flexible(), spacing: MSpacing.s)], spacing: MSpacing.s) {
                            ForEach(ms) { m in NavigationLink(value: SocialRoute.moment(m.id)) { MomentTile(moment: m) }.buttonStyle(PressScaleStyle()) }
                        }
                    }
                }
                .padding(MSpacing.l).padding(.bottom, 80)
            }
        }
        .background(MColor.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Menu { Button(group?.ownerID == env.social.myID ? "Delete group" : "Leave group", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { confirmLeave = true } } label: { Image(systemName: "ellipsis.circle") } } }
        .sheet(isPresented: $showAdd, onDismiss: { Task { await env.social.add(members: added, to: groupID); added = [] } }) { PeoplePickerSheet(selected: $added) }
        .confirmationDialog(group?.ownerID == env.social.myID ? "Delete this group?" : "Leave this group?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button(group?.ownerID == env.social.myID ? "Delete" : "Leave", role: .destructive) { Task { await env.social.leaveGroup(groupID); dismiss() } }
        } message: { Text("Moments and chats stay with the people in them.") }
    }
}

struct GroupEditorSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var emoji = "👥"
    @State private var members: [SocialUser] = []
    @State private var showPeople = false
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: MSpacing.l) {
                TextField("The boys, Family, Travel crew…", text: $name).font(.title2.weight(.semibold)).focused($focused).accessibilityIdentifier("groupName")
                EmojiRow(selection: $emoji)
                FlowChips {
                    ForEach(members) { u in Button { members.removeAll { $0.id == u.id } } label: { Label(u.displayName, systemImage: "xmark").labelStyle(TrailingIconLabelStyle()) }.buttonStyle(ChipButtonStyle(prominent: true)) }
                    Button { showPeople = true } label: { Label("Add people", systemImage: "person.badge.plus") }.buttonStyle(ChipButtonStyle()).accessibilityIdentifier("groupAddPeople")
                }
                Text("Everyone in the group can see its Moments and chat. You can add people later.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                Spacer()
            }
            .padding(MSpacing.l)
            .navigationTitle("New group").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Create") { Task { _ = await env.social.createGroup(name: name, emoji: emoji, members: members); Haptics.completed(); dismiss() } }.disabled(name.isBlank).accessibilityIdentifier("createGroup") }
            }
            .sheet(isPresented: $showPeople) { PeoplePickerSheet(selected: $members) }
            .onAppear { focused = true }
        }
        .presentationDetents([.large])
    }
}
