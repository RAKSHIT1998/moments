import SwiftUI

/// Permanent groups: the crew, family, work. A group is a shared chat.
struct GroupsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showNew = false
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MSpacing.l) {
                if env.social.groups.isEmpty {
                    VStack(alignment: .leading, spacing: MSpacing.s) {
                        Text("Find your people.").font(MFont.title)
                        Text("A group is one private chat for the people you talk to together.").font(MFont.body).foregroundStyle(MColor.textSecondary)
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
        HStack(spacing: MSpacing.m) {
            ZStack {
                RoundedRectangle(cornerRadius: MRadius.tile, style: .continuous).fill(MColor.accentSoft).frame(width: 72, height: 72)
                Text(group.emoji).font(.title).shadow(radius: 3)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(group.name).font(MFont.headline).foregroundStyle(MColor.textPrimary)
                Text(group.memberIDs.count == 1 ? "1 person" : "\(group.memberIDs.count) people").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
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
                VStack(alignment: .leading, spacing: MSpacing.xl) {
                    HStack(alignment: .firstTextBaseline, spacing: MSpacing.s) { Text(g.emoji).font(.largeTitle); Text(g.name).displayStyle() }
                    HStack(spacing: MSpacing.s) {
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
                }
                .padding(MSpacing.l).padding(.bottom, 80)
            }
        }
        .background(MColor.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Menu { Button(group?.ownerID == env.social.myID ? "Delete group" : "Leave group", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { confirmLeave = true } } label: { Image(systemName: "ellipsis.circle") } } }
        .confirmationDialog(group?.ownerID == env.social.myID ? "Delete this group?" : "Leave this group?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button(group?.ownerID == env.social.myID ? "Delete" : "Leave", role: .destructive) { Task { await env.social.leaveGroup(groupID); dismiss() } }
        } message: { Text("The chat stays with the people in it.") }
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
                Text("A group is a shared chat. You can add people to it afterwards.").font(MFont.footnote).foregroundStyle(MColor.textSecondary)
                Spacer()
            }
            .padding(MSpacing.l)
            .navigationTitle("New group").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Create") { Task { _ = await env.social.createGroup(name: name, emoji: emoji, members: members); Haptics.completed(); dismiss() } }.disabled(name.isBlank).accessibilityIdentifier("createGroup") }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.large])
    }
}
